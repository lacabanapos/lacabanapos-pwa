-- Exchange a verified Supabase Auth session for the short-lived POS operator
-- token used by the existing owner/branch-management RPCs. No shared master
-- password is introduced; the platform role is read from the protected profile.
CREATE OR REPLACE FUNCTION public.pos_superadmin_create_operator_session()
RETURNS TABLE(
  session_token text,
  user_id uuid,
  username text,
  display_name text,
  user_role text,
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
  v_profile public.profiles%rowtype;
  v_location record;
  v_token text;
  v_exp timestamptz;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'Inicia sesión con tu cuenta de propietario';
  END IF;

  SELECT p.* INTO v_profile
  FROM public.profiles p
  WHERE p.id = (SELECT auth.uid())
    AND p.active
    AND p.platform_role = 'SUPERADMIN';

  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Esta cuenta no tiene permisos de propietario';
  END IF;

  SELECT l.id AS location_id, l.name AS location_name, b.name AS business_name
  INTO v_location
  FROM public.business_memberships bm
  JOIN public.businesses b ON b.id = bm.business_id AND b.active
  JOIN public.locations l ON l.business_id = b.id AND l.active
  JOIN public.location_memberships lm
    ON lm.location_id = l.id AND lm.profile_id = bm.user_id AND lm.active AND lm.role = 'ADMIN'
  WHERE bm.user_id = v_profile.id AND bm.active AND bm.role IN ('ADMIN', 'OWNER')
  ORDER BY l.created_at, l.id
  LIMIT 1;

  IF v_location.location_id IS NULL THEN
    RAISE EXCEPTION 'La cuenta propietaria aún no está vinculada a una sucursal activa';
  END IF;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_exp := now() + interval '12 hours';
  INSERT INTO public.pos_operator_sessions(token_hash, profile_id, location_id, expires_at)
  VALUES (
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    v_profile.id,
    v_location.location_id,
    v_exp
  );

  RETURN QUERY SELECT
    v_token,
    v_profile.id,
    v_profile.username,
    coalesce(nullif(v_profile.display_name, ''), v_profile.username),
    'OWNER'::text,
    v_location.location_id,
    v_location.location_name,
    v_location.business_name,
    v_exp;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_superadmin_create_operator_session() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_superadmin_create_operator_session() TO authenticated;
