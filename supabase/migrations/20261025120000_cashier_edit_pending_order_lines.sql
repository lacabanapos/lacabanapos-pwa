-- Apply cashier edits to a ready order and charge it in one transaction.
-- Omitted original order_item IDs are removed; retained originals may change
-- quantity/notes; added lines are re-priced from this location's active menu.
CREATE OR REPLACE FUNCTION public.pos_charge_order_with_edits(
  p_order_id uuid,
  p_cashier_id uuid,
  p_payment_method text,
  p_session_token text,
  p_lines jsonb DEFAULT '[]'::jsonb
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
  existing_item public.order_items%rowtype;
  product_row public.products%rowtype;
  item_row jsonb;
  v_operator record;
  v_items jsonb;
  v_keep_ids uuid[] := ARRAY[]::uuid[];
  v_item_id uuid;
  v_qty integer;
  total_value bigint;
  item_count integer;
BEGIN
  IF p_payment_method NOT IN ('CASH','TRANSFER','EFECTIVO','TRANSFERENCIA') THEN
    RAISE EXCEPTION 'Método de pago inválido';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 OR jsonb_array_length(p_lines) > 200 THEN
    RAISE EXCEPTION 'El pedido debe contener entre 1 y 200 líneas válidas';
  END IF;

  SELECT * INTO order_row FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_session_token, order_row.location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_id <> p_cashier_id
     OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN
    RAISE EXCEPTION 'Sesión de caja vencida o no autorizada';
  END IF;

  SELECT * INTO ticket_row FROM public.tickets
   WHERE order_id = order_row.id ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  -- A retry after commit returns the receipt without applying edits or booking twice.
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
    RAISE EXCEPTION 'Solo se pueden corregir pedidos listos para cobrar';
  END IF;

  SELECT * INTO session_row FROM public.cash_sessions
   WHERE location_id = order_row.location_id AND status = 'OPEN'
   ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abra una caja antes de cobrar'; END IF;

  item_count := jsonb_array_length(p_lines);
  FOR item_row IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    IF jsonb_typeof(item_row) <> 'object' THEN RAISE EXCEPTION 'Línea inválida'; END IF;
    v_qty := (item_row->>'quantity')::integer;
    IF v_qty NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Cantidad inválida'; END IF;

    IF nullif(item_row->>'order_item_id','') IS NOT NULL THEN
      v_item_id := (item_row->>'order_item_id')::uuid;
      IF v_item_id = ANY(v_keep_ids) THEN RAISE EXCEPTION 'Línea original duplicada'; END IF;
      SELECT * INTO existing_item FROM public.order_items
       WHERE id = v_item_id AND order_id = order_row.id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Una línea ya no pertenece a este pedido; actualice y vuelva a intentar'; END IF;
      v_keep_ids := array_append(v_keep_ids, v_item_id);
      UPDATE public.order_items SET quantity = v_qty,
        notes = left(coalesce(item_row->>'notes',''),500)
       WHERE id = v_item_id;
    ELSE
      IF nullif(item_row->>'product_id','') IS NULL THEN RAISE EXCEPTION 'Producto nuevo inválido'; END IF;
      SELECT * INTO product_row FROM public.products
       WHERE id = (item_row->>'product_id')::uuid
         AND location_id = order_row.location_id AND business_id = order_row.business_id AND active
       FOR SHARE;
      IF NOT FOUND THEN RAISE EXCEPTION 'Producto no disponible en esta sucursal'; END IF;
      INSERT INTO public.order_items(order_id, product_id, product_name, quantity, unit_price_cents, notes)
      VALUES (order_row.id, product_row.id, product_row.name, v_qty, product_row.price_cents,
        CASE WHEN nullif(trim(item_row->>'notes'),'') IS NULL THEN 'ADICIONAL'
             ELSE 'ADICIONAL: ' || left(trim(item_row->>'notes'),480) END)
      RETURNING id INTO v_item_id;
      v_keep_ids := array_append(v_keep_ids, v_item_id);
    END IF;
  END LOOP;

  DELETE FROM public.order_items oi
   WHERE oi.order_id = order_row.id AND NOT (oi.id = ANY(v_keep_ids));
  UPDATE public.orders SET updated_at = now() WHERE id = order_row.id;

  SELECT coalesce(sum(oi.unit_price_cents::bigint * oi.quantity),0)
    INTO total_value FROM public.order_items oi WHERE oi.order_id = order_row.id;
  IF total_value <= 0 OR total_value > 2147483647 THEN
    RAISE EXCEPTION 'El total del pedido debe ser mayor que cero y estar dentro del límite permitido';
  END IF;

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

REVOKE ALL ON FUNCTION public.pos_charge_order_with_edits(uuid,uuid,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_charge_order_with_edits(uuid,uuid,text,text,jsonb) TO anon, authenticated;
