-- These RPCs are not used by either client. They are SECURITY DEFINER functions:
-- cleanup_old_data permanently deletes operational records older than 3 months,
-- and get_cloud_attendance exposes attendance and location data globally.
-- Keep owner-level execution available for controlled maintenance, but remove
-- invocation through the exposed PostgREST roles.
REVOKE EXECUTE ON FUNCTION public.cleanup_old_data() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_cloud_attendance(integer) FROM PUBLIC, anon, authenticated;
