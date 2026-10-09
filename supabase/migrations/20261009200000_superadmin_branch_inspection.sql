-- Let an authenticated-by-POS superadmin switch to a branch-scoped session
-- for inspection. The caller must already hold a valid opaque operator token.
CREATE OR REPLACE FUNCTION public.pos_superadmin_enter_location(
  p_token text,
  p_current_location_id uuid,
  p_target_location_id uuid
)
RETURNS TABLE(
  session_token text,
  location_id uuid,
  location_name text,
  business_name text,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions, pg_temp
AS $function$
DECLARE
  v_operator record;
  v_business_id uuid;
  v_location record;
  v_token text;
  v_exp timestamptz;
BEGIN
  SELECT * INTO v_operator
  FROM public.pos_operator_for_token(p_token, p_current_location_id);

  IF v_operator.user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_operator.user_id
      AND p.active
      AND p.platform_role = 'SUPERADMIN'
  ) THEN
    RAISE EXCEPTION 'Sesión de propietario inválida o vencida';
  END IF;

  SELECT l.business_id INTO v_business_id
  FROM public.locations l
  JOIN public.business_memberships bm
    ON bm.business_id = l.business_id
   AND bm.user_id = v_operator.user_id
   AND bm.active
   AND bm.role IN ('ADMIN', 'OWNER')
  WHERE l.id = p_current_location_id AND l.active;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'No tienes acceso de propietario a este negocio';
  END IF;

  SELECT l.id, l.name, b.name AS business_name INTO v_location
  FROM public.locations l
  JOIN public.businesses b ON b.id = l.business_id AND b.active
  JOIN public.location_memberships lm
    ON lm.location_id = l.id
   AND lm.profile_id = v_operator.user_id
   AND lm.active
   AND lm.role = 'ADMIN'
  WHERE l.id = p_target_location_id
    AND l.business_id = v_business_id
    AND l.active;

  IF v_location.id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no disponible para inspección';
  END IF;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_exp := now() + interval '12 hours';
  INSERT INTO public.pos_operator_sessions(token_hash, profile_id, location_id, expires_at)
  VALUES (
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    v_operator.user_id,
    v_location.id,
    v_exp
  );

  RETURN QUERY SELECT v_token, v_location.id, v_location.name, v_location.business_name, v_exp;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_superadmin_enter_location(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_superadmin_enter_location(text, uuid, uuid) TO anon, authenticated;
