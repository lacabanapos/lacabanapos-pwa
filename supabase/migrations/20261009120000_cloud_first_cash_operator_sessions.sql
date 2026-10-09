-- Cloud-first cash foundation. This migration is additive and does not touch existing sales.
-- Operators continue using username/password; only a short-lived opaque token is cached by clients.

CREATE TABLE IF NOT EXISTS public.pos_operator_sessions (
  token_hash text PRIMARY KEY,
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pos_operator_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_operator_sessions FROM anon, authenticated, public;

ALTER TABLE public.cash_sessions
  ADD COLUMN IF NOT EXISTS shift text NOT NULL DEFAULT 'OTRO',
  ADD COLUMN IF NOT EXISTS counted_detail_json jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.cash_expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.cash_sessions(id),
  location_id uuid NOT NULL REFERENCES public.locations(id),
  business_id uuid NOT NULL REFERENCES public.businesses(id),
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  amount_cents integer NOT NULL CHECK (amount_cents > 0),
  description text NOT NULL CHECK (length(trim(description)) > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.cash_expenses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cash_expenses FROM anon, authenticated, public;

CREATE OR REPLACE FUNCTION public.pos_login_session(
  p_username text, p_password text, p_location_id uuid
)
RETURNS TABLE(session_token text, user_id uuid, username text, display_name text, user_role text, location_name text, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE
  v_profile public.profiles%rowtype;
  v_role text;
  v_location_name text;
  v_token text;
BEGIN
  SELECT l.name INTO v_location_name FROM public.locations l WHERE l.id = p_location_id AND l.active;
  IF v_location_name IS NULL THEN RAISE EXCEPTION 'Terminal no encontrada'; END IF;
  SELECT p.* INTO v_profile
  FROM public.location_memberships lm JOIN public.profiles p ON p.id = lm.profile_id
  WHERE lm.location_id = p_location_id AND lm.active AND p.active
    AND lower(trim(p.username)) = lower(trim(p_username))
    AND p.password_hash = encode(extensions.digest(coalesce(p_password,'') || '_cabana_pos_salt','sha256'),'hex')
  LIMIT 1;
  IF v_profile.id IS NULL THEN RAISE EXCEPTION 'Usuario o contraseña incorrectos'; END IF;
  SELECT lm.role INTO v_role FROM public.location_memberships lm
  WHERE lm.location_id=p_location_id AND lm.profile_id=v_profile.id AND lm.active;
  v_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO public.pos_operator_sessions(token_hash, profile_id, location_id, expires_at)
  VALUES (encode(extensions.digest(v_token,'sha256'),'hex'), v_profile.id, p_location_id, now() + interval '12 hours');
  RETURN QUERY SELECT v_token, v_profile.id, v_profile.username,
    coalesce(nullif(v_profile.display_name,''),v_profile.username), v_role, v_location_name, now() + interval '12 hours';
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_operator_for_token(p_token text, p_location_id uuid)
RETURNS TABLE(user_id uuid, user_role text)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
  SELECT p.id, lm.role
  FROM public.pos_operator_sessions s
  JOIN public.profiles p ON p.id=s.profile_id AND p.active
  JOIN public.location_memberships lm ON lm.profile_id=p.id AND lm.location_id=s.location_id AND lm.active
  WHERE s.token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
    AND s.location_id=p_location_id AND s.expires_at>now()
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.pos_open_cash_session(
  p_token text, p_location_id uuid, p_opening_cents integer, p_shift text DEFAULT 'OTRO'
)
RETURNS public.cash_sessions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_location public.locations%rowtype; v_session public.cash_sessions%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión o permiso de caja inválido'; END IF;
  IF p_opening_cents < 0 OR p_shift NOT IN ('MANANA','TARDE','OTRO') THEN RAISE EXCEPTION 'Datos de apertura inválidos'; END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sucursal no disponible'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_location_id::text,0));
  IF EXISTS (SELECT 1 FROM public.cash_sessions WHERE location_id=p_location_id AND status='OPEN') THEN RAISE EXCEPTION 'Ya existe una caja abierta en esta sucursal'; END IF;
  INSERT INTO public.cash_sessions(location_id,business_id,opened_by,opening_cents,status,shift)
  VALUES(p_location_id,v_location.business_id,v_operator.user_id,p_opening_cents,'OPEN',p_shift)
  RETURNING * INTO v_session;
  RETURN v_session;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_close_cash_session(
  p_token text, p_location_id uuid, p_session_id uuid, p_counted_cents integer,
  p_carryover_cents integer, p_detail jsonb DEFAULT '{}'::jsonb
)
RETURNS public.cash_sessions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_session public.cash_sessions%rowtype; v_expected integer;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión o permiso de caja inválido'; END IF;
  IF p_counted_cents < 0 OR p_carryover_cents < 0 OR p_carryover_cents > p_counted_cents THEN RAISE EXCEPTION 'Conteo o fondo dejado inválido'; END IF;
  SELECT * INTO v_session FROM public.cash_sessions WHERE id=p_session_id AND location_id=p_location_id AND status='OPEN' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La caja no existe o ya fue cerrada'; END IF;
  v_expected := v_session.opening_cents + v_session.cash_sales_cents - v_session.expenses_cents;
  UPDATE public.cash_sessions SET status='CLOSED',closed_at=now(),closed_by=v_operator.user_id,
    counted_cents=p_counted_cents,carryover_cents=p_carryover_cents,
    delivered_cents=p_counted_cents-p_carryover_cents,difference_cents=p_counted_cents-v_expected,
    counted_detail_json=coalesce(p_detail,'{}'::jsonb)
  WHERE id=p_session_id RETURNING * INTO v_session;
  RETURN v_session;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_add_cash_expense(
  p_token text, p_location_id uuid, p_session_id uuid, p_amount_cents integer, p_description text
)
RETURNS public.cash_expenses
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_session public.cash_sessions%rowtype; v_expense public.cash_expenses%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión o permiso de caja inválido'; END IF;
  IF p_amount_cents <= 0 OR length(trim(coalesce(p_description,'')))=0 THEN RAISE EXCEPTION 'Egreso inválido'; END IF;
  SELECT * INTO v_session FROM public.cash_sessions WHERE id=p_session_id AND location_id=p_location_id AND status='OPEN' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe una caja abierta para este egreso'; END IF;
  INSERT INTO public.cash_expenses(session_id,location_id,business_id,created_by,amount_cents,description)
  VALUES(p_session_id,p_location_id,v_session.business_id,v_operator.user_id,p_amount_cents,trim(p_description))
  RETURNING * INTO v_expense;
  UPDATE public.cash_sessions SET expenses_cents=expenses_cents+p_amount_cents WHERE id=p_session_id;
  RETURN v_expense;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_payment_atomic(
  p_order_id uuid, p_cashier_id uuid, p_payment_method text
)
RETURNS public.tickets
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE
  order_row public.orders%rowtype; session_row public.cash_sessions%rowtype;
  ticket_row public.tickets%rowtype; total_value integer; v_role text;
BEGIN
  IF p_payment_method NOT IN ('CASH','TRANSFER','EFECTIVO','TRANSFERENCIA') THEN RAISE EXCEPTION 'Método de pago inválido'; END IF;
  SELECT * INTO order_row FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT lm.role INTO v_role FROM public.location_memberships lm
  JOIN public.profiles p ON p.id=lm.profile_id
  WHERE lm.profile_id=p_cashier_id AND lm.location_id=order_row.location_id AND lm.active AND p.active;
  IF v_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Cajero inactivo o sin permiso en esta sucursal'; END IF;
  SELECT * INTO session_row FROM public.cash_sessions WHERE location_id=order_row.location_id AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abra una caja cloud antes de cobrar'; END IF;
  SELECT coalesce(sum(unit_price_cents*quantity),0)::integer INTO total_value FROM public.order_items WHERE order_id=order_row.id;
  SELECT * INTO ticket_row FROM public.tickets WHERE order_id=order_row.id FOR UPDATE;
  IF FOUND AND ticket_row.status='PAID' THEN
    IF ticket_row.payment_method IN (p_payment_method, CASE p_payment_method WHEN 'CASH' THEN 'EFECTIVO' WHEN 'TRANSFER' THEN 'TRANSFERENCIA' ELSE p_payment_method END) THEN RETURN ticket_row; END IF;
    RAISE EXCEPTION 'El pedido ya tiene un cobro con otro método';
  END IF;
  IF FOUND THEN
    UPDATE public.tickets SET status='PAID',payment_method=p_payment_method,total_cents=total_value,
      cashier_id=p_cashier_id,cash_session_id=session_row.id,paid_at=now(),business_id=order_row.business_id,location_id=order_row.location_id
    WHERE id=ticket_row.id RETURNING * INTO ticket_row;
  ELSE
    INSERT INTO public.tickets(order_id,code,status,payment_method,total_cents,cashier_id,cash_session_id,paid_at,business_id,location_id)
    VALUES(order_row.id,'T-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),'PAID',p_payment_method,total_value,p_cashier_id,session_row.id,now(),order_row.business_id,order_row.location_id)
    RETURNING * INTO ticket_row;
  END IF;
  UPDATE public.orders SET status='SERVED',updated_at=now() WHERE id=order_row.id;
  IF p_payment_method IN ('CASH','EFECTIVO') THEN UPDATE public.cash_sessions SET cash_sales_cents=cash_sales_cents+total_value WHERE id=session_row.id;
  ELSE UPDATE public.cash_sessions SET transfer_sales_cents=transfer_sales_cents+total_value WHERE id=session_row.id; END IF;
  RETURN ticket_row;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_login_session(text,text,uuid) FROM public;
REVOKE ALL ON FUNCTION public.pos_operator_for_token(text,uuid) FROM public;
REVOKE ALL ON FUNCTION public.pos_open_cash_session(text,uuid,integer,text) FROM public;
REVOKE ALL ON FUNCTION public.pos_close_cash_session(text,uuid,uuid,integer,integer,jsonb) FROM public;
REVOKE ALL ON FUNCTION public.pos_add_cash_expense(text,uuid,uuid,integer,text) FROM public;
REVOKE ALL ON FUNCTION public.record_payment_atomic(uuid,uuid,text) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_login_session(text,text,uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_open_cash_session(text,uuid,integer,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_close_cash_session(text,uuid,uuid,integer,integer,jsonb) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_add_cash_expense(text,uuid,uuid,integer,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_payment_atomic(uuid,uuid,text) TO anon, authenticated;
