-- Atomically append menu items to a ready/served order and charge it.
-- The client sends product IDs and quantities only; Supabase owns names/prices.
CREATE OR REPLACE FUNCTION public.pos_charge_order_with_additions(
  p_order_id uuid,
  p_cashier_id uuid,
  p_payment_method text,
  p_session_token text,
  p_additions jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  order_row public.orders%rowtype;
  session_row public.cash_sessions%rowtype;
  ticket_row public.tickets%rowtype;
  product_row public.products%rowtype;
  item_row jsonb;
  item_count integer;
  item_qty integer;
  total_value bigint;
  v_operator record;
  v_items jsonb;
BEGIN
  IF p_payment_method NOT IN ('CASH','TRANSFER','EFECTIVO','TRANSFERENCIA') THEN
    RAISE EXCEPTION 'Método de pago inválido';
  END IF;
  IF p_additions IS NULL OR jsonb_typeof(p_additions) <> 'array' OR jsonb_array_length(p_additions) > 100 THEN
    RAISE EXCEPTION 'Lista de adicionales inválida';
  END IF;

  SELECT * INTO order_row FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_session_token, order_row.location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_id <> p_cashier_id
     OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN
    RAISE EXCEPTION 'Sesión de caja vencida o no autorizada';
  END IF;

  SELECT * INTO ticket_row FROM public.tickets WHERE order_id = order_row.id ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  -- A retried request after a successful commit returns the existing receipt;
  -- it never inserts the add-ons or books the payment twice.
  IF FOUND AND ticket_row.status = 'PAID' THEN
    IF ticket_row.payment_method IN (p_payment_method,
        CASE p_payment_method WHEN 'CASH' THEN 'EFECTIVO' WHEN 'TRANSFER' THEN 'TRANSFERENCIA' ELSE p_payment_method END) THEN
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', oi.id, 'product_id', oi.product_id, 'product_name', oi.product_name,
        'quantity', oi.quantity, 'unit_price_cents', oi.unit_price_cents, 'notes', oi.notes
      ) ORDER BY oi.created_at), '[]'::jsonb) INTO v_items
      FROM public.order_items oi WHERE oi.order_id = order_row.id;
      RETURN jsonb_build_object('ticket', to_jsonb(ticket_row), 'items', v_items, 'already_paid', true);
    END IF;
    RAISE EXCEPTION 'El pedido ya tiene un cobro registrado';
  END IF;
  IF order_row.status NOT IN ('READY','SERVED') THEN
    RAISE EXCEPTION 'Solo se pueden agregar productos a pedidos listos para cobrar';
  END IF;

  SELECT * INTO session_row FROM public.cash_sessions
   WHERE location_id = order_row.location_id AND status = 'OPEN'
   ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abra una caja antes de cobrar'; END IF;

  item_count := jsonb_array_length(p_additions);
  IF item_count > 0 THEN
    FOR item_row IN SELECT value FROM jsonb_array_elements(p_additions) LOOP
      IF jsonb_typeof(item_row) <> 'object' OR coalesce(item_row->>'product_id','') = '' THEN
        RAISE EXCEPTION 'Producto adicional inválido';
      END IF;
      item_qty := (item_row->>'quantity')::integer;
      IF item_qty NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Cantidad adicional inválida'; END IF;
      SELECT * INTO product_row FROM public.products
       WHERE id = (item_row->>'product_id')::uuid
         AND location_id = order_row.location_id AND business_id = order_row.business_id AND active
       FOR SHARE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Producto no disponible en esta sucursal'; END IF;
      INSERT INTO public.order_items(order_id, product_id, product_name, quantity, unit_price_cents, notes)
      VALUES (order_row.id, product_row.id, product_row.name, item_qty, product_row.price_cents, 'ADICIONAL');
    END LOOP;
    UPDATE public.orders SET updated_at = now() WHERE id = order_row.id;
  END IF;

  SELECT coalesce(sum(oi.unit_price_cents::bigint * oi.quantity),0)
    INTO total_value FROM public.order_items oi WHERE oi.order_id = order_row.id;
  IF total_value < 0 OR total_value > 2147483647 THEN RAISE EXCEPTION 'Total excede el límite permitido'; END IF;

  IF ticket_row.id IS NOT NULL THEN
    UPDATE public.tickets SET status = 'PAID', payment_method = p_payment_method,
      total_cents = total_value::integer, cashier_id = p_cashier_id,
      cash_session_id = session_row.id, paid_at = now(),
      business_id = order_row.business_id, location_id = order_row.location_id
    WHERE id = ticket_row.id RETURNING * INTO ticket_row;
  ELSE
    INSERT INTO public.tickets(order_id, code, status, payment_method, total_cents,
      cashier_id, cash_session_id, paid_at, business_id, location_id)
    VALUES(order_row.id, 'T-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
      'PAID', p_payment_method, total_value::integer, p_cashier_id, session_row.id,
      now(), order_row.business_id, order_row.location_id)
    RETURNING * INTO ticket_row;
  END IF;

  UPDATE public.orders SET status = 'SERVED', updated_at = now() WHERE id = order_row.id;
  IF p_payment_method IN ('CASH','EFECTIVO') THEN
    UPDATE public.cash_sessions SET cash_sales_cents = cash_sales_cents + total_value::integer WHERE id = session_row.id;
  ELSE
    UPDATE public.cash_sessions SET transfer_sales_cents = transfer_sales_cents + total_value::integer WHERE id = session_row.id;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', oi.id, 'product_id', oi.product_id, 'product_name', oi.product_name,
    'quantity', oi.quantity, 'unit_price_cents', oi.unit_price_cents, 'notes', oi.notes
  ) ORDER BY oi.created_at), '[]'::jsonb) INTO v_items
  FROM public.order_items oi WHERE oi.order_id = order_row.id;
  RETURN jsonb_build_object('ticket', to_jsonb(ticket_row), 'items', v_items, 'already_paid', false);
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_charge_order_with_additions(uuid,uuid,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_charge_order_with_additions(uuid,uuid,text,text,jsonb) TO anon, authenticated;
