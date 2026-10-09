-- Authenticate by opaque selected profile ID; never return a username roster
-- to an unauthenticated client. Password hashing stays compatible with the
-- existing production credentials.
CREATE OR REPLACE FUNCTION public.pos_login_session_by_user_id(
  p_user_id uuid,
  p_password text,
  p_location_id uuid
)
RETURNS TABLE(
  session_token text,
  user_id uuid,
  username text,
  display_name text,
  user_role text,
  location_name text,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  v_profile public.profiles%rowtype;
  v_role text;
  v_location_name text;
  v_token text;
BEGIN
  SELECT l.name INTO v_location_name
  FROM public.locations l
  WHERE l.id = p_location_id AND l.active = true;
  IF v_location_name IS NULL THEN RAISE EXCEPTION 'Terminal no encontrada'; END IF;

  SELECT p.* INTO v_profile
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id
    AND lm.profile_id = p_user_id
    AND lm.active = true
    AND p.active = true
    AND p.password_hash = encode(extensions.digest(coalesce(p_password, '') || '_cabana_pos_salt', 'sha256'), 'hex')
  LIMIT 1;
  IF v_profile.id IS NULL THEN RAISE EXCEPTION 'Usuario o contraseña incorrectos'; END IF;

  SELECT lm.role INTO v_role
  FROM public.location_memberships lm
  WHERE lm.location_id = p_location_id AND lm.profile_id = v_profile.id AND lm.active = true;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.pos_operator_sessions(token_hash, profile_id, location_id, expires_at)
  VALUES (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_profile.id, p_location_id, now() + interval '12 hours');

  RETURN QUERY SELECT v_token, v_profile.id, v_profile.username,
    coalesce(nullif(v_profile.display_name, ''), v_profile.username), v_role,
    v_location_name, now() + interval '12 hours';
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_login_session_by_user_id(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_login_session_by_user_id(uuid, text, uuid) TO anon, authenticated;
