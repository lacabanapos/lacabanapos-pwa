-- Keep the PWA RPC name compatible with the existing owner/superadmin flow.
-- Authorization and branch scoping remain enforced by the existing function.
CREATE OR REPLACE FUNCTION public.pos_owner_enter_location_global(
  p_token text,
  p_target_location_id uuid
)
RETURNS TABLE(
  session_token text,
  location_id uuid,
  location_name text,
  business_name text,
  expires_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
  SELECT *
  FROM public.pos_superadmin_enter_location_global(p_token, p_target_location_id)
$function$;

REVOKE ALL ON FUNCTION public.pos_owner_enter_location_global(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_owner_enter_location_global(text, uuid) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
