-- This legacy function deletes order, ticket and attendance history after only
-- three months. There is no approved retention policy or archive/restore flow.
-- It is unused by the application and was already revoked from client roles.
DROP FUNCTION IF EXISTS public.cleanup_old_data();
