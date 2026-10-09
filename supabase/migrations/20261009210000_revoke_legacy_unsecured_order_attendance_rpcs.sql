-- Clients now use token-scoped RPCs; retire the prior caller-identity-free write APIs.
REVOKE ALL ON FUNCTION public.create_order(text,jsonb,uuid,text,uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.update_order_status(uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.cancel_order(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.add_items_to_order(uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.mark_attendance(text,text,text,text,numeric,numeric,numeric,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.login_pos_user(text,text,uuid) FROM PUBLIC,anon,authenticated;
