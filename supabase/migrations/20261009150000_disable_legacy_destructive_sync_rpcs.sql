-- The desktop has moved away from bulk replacement. These legacy RPCs deleted/replaced
-- catalog and account state and are no longer called by either app.
REVOKE ALL ON FUNCTION public.sync_pos_menu(uuid,jsonb,jsonb) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.sync_pos_users(uuid,jsonb) FROM public,anon,authenticated;
