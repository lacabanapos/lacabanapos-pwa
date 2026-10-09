-- Resolve local POS usernames with spaces against cloud usernames that use
-- underscores, but only when that normalized match is unambiguous.
CREATE OR REPLACE FUNCTION public.resolve_pos_user(p_location_id uuid, p_username text)
RETURNS TABLE(user_id uuid, username text, user_role text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_normalized_username text;
  v_match_count integer;
BEGIN
  RETURN QUERY
  SELECT p.id, p.username, lm.role
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id
    AND lm.active = true
    AND p.active = true
    AND lower(trim(p.username)) = lower(trim(p_username))
  LIMIT 1;

  IF FOUND THEN
    RETURN;
  END IF;

  v_normalized_username := lower(regexp_replace(trim(coalesce(p_username, '')), '\s+', '_', 'g'));
  IF v_normalized_username = '' THEN
    RETURN;
  END IF;

  SELECT count(*)::integer
  INTO v_match_count
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id
    AND lm.active = true
    AND p.active = true
    AND lower(regexp_replace(trim(p.username), '\s+', '_', 'g')) = v_normalized_username;

  -- Refuse ambiguous aliases rather than linking a payment to the wrong user.
  IF v_match_count <> 1 THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT p.id, p.username, lm.role
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id
    AND lm.active = true
    AND p.active = true
    AND lower(regexp_replace(trim(p.username), '\s+', '_', 'g')) = v_normalized_username;
END;
$function$;

-- The supplied POS snapshot lists these two employees as active. Their cloud
-- profiles are active too, but their existing membership rows at the sole
-- active restaurant location were disabled. Re-enable only those exact rows.
DO $migration$
DECLARE
  v_location_id uuid;
  v_location_count integer;
  v_updated integer;
BEGIN
  SELECT count(*)::integer, (array_agg(id))[1]
  INTO v_location_count, v_location_id
  FROM public.locations
  WHERE active = true AND lower(trim(name)) = 'isidro ayora';

  IF v_location_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one active Isidro ayora location; found %', v_location_count;
  END IF;

  UPDATE public.location_memberships lm
  SET active = true
  FROM public.profiles p
  WHERE p.id = lm.profile_id
    AND lm.location_id = v_location_id
    AND lm.active = false
    AND p.active = true
    AND p.role = 'MESERO'
    AND lower(p.username) IN ('jandy_m', 'melinda_ulloa')
    AND lm.role = p.role;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 2 THEN
    RAISE EXCEPTION 'Expected to reactivate exactly 2 verified staff memberships; changed %', v_updated;
  END IF;
END;
$migration$;
