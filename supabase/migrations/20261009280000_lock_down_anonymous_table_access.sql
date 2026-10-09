-- The PWA no longer reads the menu or employee usernames directly from tables.
-- Its menu calls pos_get_menu(token, location); staff login uses opaque user IDs.
DROP POLICY IF EXISTS "POS anon read products" ON public.products;
DROP POLICY IF EXISTS "POS anon read categories" ON public.categories;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM anon;

-- The login screen only needs an active location's name and identifier.
GRANT SELECT (id, name, business_id, active, created_at) ON public.locations TO anon;

-- Keep only display names and opaque IDs in the unauthenticated staff picker.
DROP FUNCTION IF EXISTS public.get_location_users(uuid);
CREATE FUNCTION public.get_location_users(p_location_id uuid)
RETURNS TABLE(user_id uuid, display_name text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT p.id, coalesce(nullif(p.display_name, ''), 'Personal')
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id
    AND lm.active = true
    AND p.active = true
  ORDER BY coalesce(nullif(p.display_name, ''), 'Personal');
$function$;
REVOKE ALL ON FUNCTION public.get_location_users(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_location_users(uuid) TO anon, authenticated;
