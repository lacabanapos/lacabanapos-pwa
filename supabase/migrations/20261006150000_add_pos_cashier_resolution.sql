-- The desktop POS authenticates locally. Resolve its active cloud profile
-- through the terminal membership instead of relying on a direct profiles
-- SELECT that may be filtered by RLS.
CREATE OR REPLACE FUNCTION public.resolve_pos_user(p_location_id uuid, p_username text)
RETURNS TABLE(user_id uuid, username text, user_role text)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT p.id, p.username, lm.role
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id
    AND lm.active = true
    AND p.active = true
    AND lower(trim(p.username)) = lower(trim(p_username))
  LIMIT 1;
$function$;
