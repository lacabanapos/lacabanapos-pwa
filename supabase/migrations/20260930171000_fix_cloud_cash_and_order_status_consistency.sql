-- Keep cloud cash accounting aligned with the live cash_sessions schema.
CREATE OR REPLACE FUNCTION public.record_payment_atomic(
  p_order_id uuid,
  p_cashier_id uuid,
  p_payment_method text
)
RETURNS public.tickets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  order_row public.orders%rowtype;
  session_row public.cash_sessions%rowtype;
  ticket_row public.tickets%rowtype;
  total_value integer;
  v_cashier_id uuid;
BEGIN
  IF p_payment_method NOT IN ('CASH', 'TRANSFER', 'EFECTIVO', 'TRANSFERENCIA') THEN
    RAISE EXCEPTION 'Invalid payment method';
  END IF;

  v_cashier_id := COALESCE(p_cashier_id, auth.uid());
  IF v_cashier_id IS NULL THEN
    SELECT id INTO v_cashier_id FROM profiles WHERE active = true ORDER BY created_at ASC LIMIT 1;
  END IF;

  SELECT * INTO order_row FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;

  SELECT * INTO session_row
  FROM public.cash_sessions
  WHERE location_id = order_row.location_id AND status = 'OPEN'
  ORDER BY opened_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.cash_sessions (
      location_id, business_id, opened_by, opening_cents, status, opened_at
    ) VALUES (
      order_row.location_id, order_row.business_id, v_cashier_id, 0, 'OPEN', now()
    ) RETURNING * INTO session_row;
  END IF;

  SELECT COALESCE(SUM(unit_price_cents * quantity), 0)::integer
    INTO total_value
    FROM public.order_items WHERE order_id = order_row.id;

  SELECT * INTO ticket_row FROM public.tickets WHERE order_id = order_row.id FOR UPDATE;
  IF FOUND AND ticket_row.status = 'PAID' THEN
    RAISE EXCEPTION 'Order has already been paid';
  END IF;

  IF FOUND THEN
    UPDATE public.tickets
       SET status = 'PAID', payment_method = p_payment_method,
           total_cents = total_value, cashier_id = v_cashier_id,
           cash_session_id = session_row.id, paid_at = now(),
           business_id = order_row.business_id, location_id = order_row.location_id
     WHERE id = ticket_row.id
     RETURNING * INTO ticket_row;
  ELSE
    INSERT INTO public.tickets (
      order_id, code, status, payment_method, total_cents, cashier_id,
      cash_session_id, paid_at, business_id, location_id
    ) VALUES (
      order_row.id,
      'T-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
      'PAID', p_payment_method, total_value, v_cashier_id,
      session_row.id, now(), order_row.business_id, order_row.location_id
    ) RETURNING * INTO ticket_row;
  END IF;

  UPDATE public.orders SET status = 'SERVED', updated_at = now() WHERE id = order_row.id;

  IF p_payment_method IN ('CASH', 'EFECTIVO') THEN
    UPDATE public.cash_sessions SET cash_sales_cents = cash_sales_cents + total_value
    WHERE id = session_row.id;
  ELSE
    UPDATE public.cash_sessions SET transfer_sales_cents = transfer_sales_cents + total_value
    WHERE id = session_row.id;
  END IF;

  RETURN ticket_row;
END;
$function$;

-- Kitchen status transitions must not create a payment.
CREATE OR REPLACE FUNCTION public.update_order_status(p_order_id uuid, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF p_status NOT IN ('RECEIVED', 'PREPARING', 'READY', 'SERVED', 'CANCELLED') THEN
    RAISE EXCEPTION 'Invalid order status';
  END IF;
  UPDATE public.orders SET status = p_status, updated_at = now() WHERE id = p_order_id;
  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$function$;
