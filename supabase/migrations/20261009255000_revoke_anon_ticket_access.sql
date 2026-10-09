-- Hotfix for the legacy policy that exposed all ticket rows to anonymous clients.
-- Data is preserved; access continues through token-validated POS RPCs.
DROP POLICY IF EXISTS "Allow anon all on tickets" ON public.tickets;
REVOKE ALL PRIVILEGES ON TABLE public.tickets FROM anon;
