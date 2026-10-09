-- Keep the established password hash formula while allowing the POS's
-- whitespace usernames to match the cloud's underscore usernames safely.
CREATE OR REPLACE FUNCTION public.login_pos_user(
  p_username text,
  p_password text,
  p_location_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(user_id uuid, username text, display_name text, user_role text, location_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_location_name text;
  v_profile_id uuid;
  v_username text;
  v_display_name text;
  v_user_role text;
  v_password_hash text;
  v_normalized_username text;
  v_match_count integer;
BEGIN
  IF p_location_id IS NULL THEN
    RAISE EXCEPTION 'Seleccione una terminal';
  END IF;

  SELECT l.name INTO v_location_name
  FROM public.locations l
  WHERE l.id = p_location_id AND l.active = true;
  IF v_location_name IS NULL THEN
    RAISE EXCEPTION 'Terminal no encontrada';
  END IF;

  SELECT count(*)::integer INTO v_match_count
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id AND lm.active = true AND p.active = true
    AND lower(trim(p.username)) = lower(trim(p_username));

  IF v_match_count = 1 THEN
    SELECT p.id, p.username, coalesce(nullif(p.display_name, ''), p.username), lm.role, p.password_hash
    INTO v_profile_id, v_username, v_display_name, v_user_role, v_password_hash
    FROM public.location_memberships lm
    JOIN public.profiles p ON p.id = lm.profile_id
    WHERE lm.location_id = p_location_id AND lm.active = true AND p.active = true
      AND lower(trim(p.username)) = lower(trim(p_username));
  ELSIF v_match_count = 0 THEN
    v_normalized_username := lower(regexp_replace(trim(coalesce(p_username, '')), '\s+', '_', 'g'));
    SELECT count(*)::integer INTO v_match_count
    FROM public.location_memberships lm
    JOIN public.profiles p ON p.id = lm.profile_id
    WHERE lm.location_id = p_location_id AND lm.active = true AND p.active = true
      AND lower(regexp_replace(trim(p.username), '\s+', '_', 'g')) = v_normalized_username;

    IF v_match_count = 1 THEN
      SELECT p.id, p.username, coalesce(nullif(p.display_name, ''), p.username), lm.role, p.password_hash
      INTO v_profile_id, v_username, v_display_name, v_user_role, v_password_hash
      FROM public.location_memberships lm
      JOIN public.profiles p ON p.id = lm.profile_id
      WHERE lm.location_id = p_location_id AND lm.active = true AND p.active = true
        AND lower(regexp_replace(trim(p.username), '\s+', '_', 'g')) = v_normalized_username;
    END IF;
  END IF;

  IF v_profile_id IS NULL OR v_password_hash IS NULL OR v_password_hash = ''
     OR v_password_hash <> encode(extensions.digest(coalesce(p_password, '') || '_cabana_pos_salt', 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'Usuario o contraseña incorrectos';
  END IF;

  RETURN QUERY SELECT v_profile_id, v_username, v_display_name, v_user_role, v_location_name;
END;
$function$;
