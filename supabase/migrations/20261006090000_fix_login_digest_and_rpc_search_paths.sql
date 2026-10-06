-- pgcrypto is installed in the extensions schema on Supabase.
-- Qualify digest so SECURITY DEFINER functions work with search_path=public.
CREATE OR REPLACE FUNCTION public.login_pos_user(p_username text, p_password text, p_location_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(user_id uuid, username text, display_name text, user_role text, location_name text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_location_name text;
  v_password_hash text;
BEGIN
  IF p_location_id IS NULL THEN RAISE EXCEPTION 'Seleccione una terminal'; END IF;
  SELECT l.name INTO v_location_name FROM public.locations l WHERE l.id = p_location_id AND l.active = true;
  IF v_location_name IS NULL THEN RAISE EXCEPTION 'Terminal no encontrada'; END IF;

  SELECT p.password_hash INTO v_password_hash
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id
    AND lower(trim(p.username)) = lower(trim(p_username))
    AND lm.active = true AND p.active = true
  LIMIT 1;

  IF v_password_hash IS NULL OR v_password_hash = ''
     OR v_password_hash <> encode(extensions.digest(p_password || '_cabana_pos_salt', 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'Usuario o contraseña incorrectos';
  END IF;

  RETURN QUERY
  SELECT p.id, p.username, coalesce(nullif(p.display_name, ''), p.username), lm.role, v_location_name
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id
    AND lower(trim(p.username)) = lower(trim(p_username))
    AND lm.active = true AND p.active = true;
END;
$function$;

ALTER FUNCTION public.create_order(text, jsonb, uuid, text, uuid, uuid) SET search_path = public, extensions;
ALTER FUNCTION public.deactivate_pos_location(uuid) SET search_path = public;
ALTER FUNCTION public.get_cloud_attendance(integer) SET search_path = public;
ALTER FUNCTION public.mark_attendance(text, text, text, text, numeric, numeric, numeric, uuid) SET search_path = public;
ALTER FUNCTION public.register_pos_location(text, uuid) SET search_path = public;
ALTER FUNCTION public.sync_pos_menu(uuid, jsonb, jsonb) SET search_path = public;
