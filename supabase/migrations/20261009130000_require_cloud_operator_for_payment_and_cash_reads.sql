-- Require the short-lived operator session for cash reads and payments.
DROP FUNCTION IF EXISTS public.record_payment_atomic(uuid,uuid,text);

CREATE OR REPLACE FUNCTION public.record_payment_atomic(
  p_order_id uuid, p_cashier_id uuid, p_payment_method text, p_session_token text
)
RETURNS public.tickets
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE
  order_row public.orders%rowtype; session_row public.cash_sessions%rowtype;
  ticket_row public.tickets%rowtype; total_value integer; v_operator record;
BEGIN
  IF p_payment_method NOT IN ('CASH','TRANSFER','EFECTIVO','TRANSFERENCIA') THEN RAISE EXCEPTION 'Método de pago inválido'; END IF;
  SELECT * INTO order_row FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_session_token,order_row.location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_id <> p_cashier_id OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN
    RAISE EXCEPTION 'Sesión de caja vencida o no autorizada';
  END IF;
  SELECT * INTO session_row FROM public.cash_sessions WHERE location_id=order_row.location_id AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abra una caja cloud antes de cobrar'; END IF;
  SELECT coalesce(sum(unit_price_cents*quantity),0)::integer INTO total_value FROM public.order_items WHERE order_id=order_row.id;
  SELECT * INTO ticket_row FROM public.tickets WHERE order_id=order_row.id FOR UPDATE;
  IF FOUND AND ticket_row.status='PAID' THEN
    IF ticket_row.payment_method IN (p_payment_method, CASE p_payment_method WHEN 'CASH' THEN 'EFECTIVO' WHEN 'TRANSFER' THEN 'TRANSFERENCIA' ELSE p_payment_method END)
      AND ticket_row.cash_session_id=session_row.id THEN RETURN ticket_row; END IF;
    RAISE EXCEPTION 'El pedido ya tiene un cobro registrado';
  END IF;
  IF FOUND THEN
    UPDATE public.tickets SET status='PAID',payment_method=p_payment_method,total_cents=total_value,cashier_id=p_cashier_id,
      cash_session_id=session_row.id,paid_at=now(),business_id=order_row.business_id,location_id=order_row.location_id
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
REVOKE ALL ON FUNCTION public.record_payment_atomic(uuid,uuid,text,text) FROM public;
GRANT EXECUTE ON FUNCTION public.record_payment_atomic(uuid,uuid,text,text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.pos_get_cash_sessions(p_token text,p_location_id uuid,p_limit integer DEFAULT 100)
RETURNS TABLE(
  id uuid,business_id uuid,location_id uuid,opened_by uuid,closed_by uuid,opened_at timestamptz,closed_at timestamptz,
  opening_cents integer,counted_cents integer,carryover_cents integer,delivered_cents integer,cash_sales_cents integer,
  card_sales_cents integer,transfer_sales_cents integer,expenses_cents integer,difference_cents integer,status text,
  shift text,counted_detail_json jsonb,opened_by_username text,closed_by_username text,ticket_count bigint
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión de caja vencida o no autorizada'; END IF;
  RETURN QUERY SELECT cs.id,cs.business_id,cs.location_id,cs.opened_by,cs.closed_by,cs.opened_at,cs.closed_at,
    cs.opening_cents,cs.counted_cents,cs.carryover_cents,cs.delivered_cents,cs.cash_sales_cents,cs.card_sales_cents,
    cs.transfer_sales_cents,cs.expenses_cents,cs.difference_cents,cs.status,cs.shift,cs.counted_detail_json,
    op.username,cp.username,count(t.id)
  FROM public.cash_sessions cs
  LEFT JOIN public.profiles op ON op.id=cs.opened_by
  LEFT JOIN public.profiles cp ON cp.id=cs.closed_by
  LEFT JOIN public.tickets t ON t.cash_session_id=cs.id AND t.status='PAID'
  WHERE cs.location_id=p_location_id
  GROUP BY cs.id,op.username,cp.username
  ORDER BY cs.opened_at DESC LIMIT greatest(1,least(coalesce(p_limit,100),500));
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_get_cash_sessions(text,uuid,integer) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_get_cash_sessions(text,uuid,integer) TO anon, authenticated;
