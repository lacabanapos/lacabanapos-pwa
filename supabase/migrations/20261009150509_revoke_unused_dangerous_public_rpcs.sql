-- These RPCs are not used by either client. They are SECURITY DEFINER functions:
-- cleanup_old_data permanently deletes operational records older than 3 months,
-- and get_cloud_attendance exposes attendance and location data globally.
-- There is no approved archive/retention process; remove the destructive routine
-- instead of merely hiding it from PostgREST. IF EXISTS supports clean installs.
DROP FUNCTION IF EXISTS public.cleanup_old_data();
REVOKE EXECUTE ON FUNCTION public.get_cloud_attendance(integer) FROM PUBLIC, anon, authenticated;
