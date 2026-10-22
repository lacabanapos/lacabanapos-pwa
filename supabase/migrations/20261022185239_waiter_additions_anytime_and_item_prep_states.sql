-- Keep the order as a single commercial ticket while tracking kitchen work
-- per line. Reopening an order for newly added items must not send already
-- prepared food back through the kitchen.
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS prep_status text NOT NULL DEFAULT 'RECEIVED';

UPDATE public.order_items oi
SET prep_status = CASE
  WHEN o.status IN ('RECEIVED','PREPARING','READY','SERVED','CANCELLED') THEN o.status
  ELSE 'RECEIVED'
END
FROM public.orders o
WHERE o.id = oi.order_id;

DO $constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.order_items'::regclass
      AND conname = 'order_items_prep_status_check'
  ) THEN
    ALTER TABLE public.order_items
      ADD CONSTRAINT order_items_prep_status_check
      CHECK (prep_status IN ('RECEIVED','PREPARING','READY','SERVED','CANCELLED'));
  END IF;
END;
$constraint$;

CREATE TABLE IF NOT EXISTS public.order_item_addition_requests (
  operation_id uuid PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.order_item_addition_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_item_addition_requests FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.pos_add_items_to_order(
  p_token text,
  p_order_id uuid,
  p_operation_id uuid,
  p_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  v_order public.orders%rowtype;
  v_operator record;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_total bigint;
  v_result jsonb;
  v_existing public.order_item_addition_requests%rowtype;
BEGIN
  IF p_operation_id IS NULL OR p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 100 THEN
    RAISE EXCEPTION 'Selecciona al menos un producto válido';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token, v_order.location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('MESERO','ADMIN','OWNER') THEN
    RAISE EXCEPTION 'Sesión vencida o sin permiso para editar pedidos';
  END IF;
  IF v_operator.user_role = 'MESERO' AND v_order.waiter_id <> v_operator.user_id THEN
    RAISE EXCEPTION 'Solo puedes agregar productos a tus propios pedidos';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id::text, 0));
  SELECT * INTO v_existing FROM public.order_item_addition_requests WHERE operation_id = p_operation_id;
  IF FOUND THEN
    IF v_existing.order_id <> p_order_id OR v_existing.actor_id <> v_operator.user_id THEN
      RAISE EXCEPTION 'Identificador de operación ya utilizado';
    END IF;
    RETURN v_existing.result;
  END IF;

  IF v_order.status = 'CANCELLED' OR v_order.status NOT IN ('RECEIVED','PREPARING','READY','SERVED') THEN
    RAISE EXCEPTION 'No se pueden agregar productos a este pedido';
  END IF;
  PERFORM 1 FROM public.tickets
    WHERE order_id = v_order.id AND status = 'PENDING'
    ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El pedido ya fue cobrado o no tiene una cuenta pendiente';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(v_item) <> 'object' OR coalesce(v_item->>'product_id','') = '' THEN
      RAISE EXCEPTION 'Producto adicional inválido';
    END IF;
    v_qty := (v_item->>'quantity')::integer;
    IF v_qty NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Cantidad inválida'; END IF;
    SELECT * INTO v_product FROM public.products
    WHERE id = (v_item->>'product_id')::uuid
      AND location_id = v_order.location_id
      AND business_id = v_order.business_id
      AND active = true
    FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto no disponible en esta sucursal'; END IF;
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, unit_price_cents, notes, prep_status)
    VALUES (v_order.id, v_product.id, v_product.name, v_qty,
      v_product.price_cents, left(coalesce(v_item->>'notes',''), 500), 'RECEIVED');
  END LOOP;

  SELECT coalesce(sum(oi.unit_price_cents::bigint * oi.quantity), 0)
  INTO v_total FROM public.order_items oi WHERE oi.order_id = v_order.id;
  IF v_total < 0 OR v_total > 2147483647 THEN RAISE EXCEPTION 'Total excede el límite permitido'; END IF;
  UPDATE public.orders SET status = 'RECEIVED', updated_at = now() WHERE id = v_order.id;
  UPDATE public.tickets SET total_cents = v_total::integer
  WHERE order_id = v_order.id AND status = 'PENDING';

  SELECT jsonb_build_object(
    'order_id', v_order.id,
    'total_cents', v_total,
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'id', oi.id, 'product_id', oi.product_id, 'product_name', oi.product_name,
      'quantity', oi.quantity, 'unit_price_cents', oi.unit_price_cents, 'notes', oi.notes,
      'prep_status', oi.prep_status
    ) ORDER BY oi.created_at), '[]'::jsonb)
  ) INTO v_result
  FROM public.order_items oi WHERE oi.order_id = v_order.id;

  INSERT INTO public.order_item_addition_requests(operation_id, order_id, actor_id, result)
  VALUES (p_operation_id, v_order.id, v_operator.user_id, v_result);
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_update_order_status(
  p_token text,
  p_order_id uuid,
  p_status text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  v_order public.orders%rowtype;
  v_operator record;
  v_next text;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,v_order.location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida o no autorizada'; END IF;

  IF v_operator.user_role IN ('COCINA','ASADOR') THEN
    v_next := CASE v_order.status WHEN 'RECEIVED' THEN 'PREPARING' WHEN 'PREPARING' THEN 'READY' ELSE NULL END;
    IF p_status IS DISTINCT FROM v_next THEN RAISE EXCEPTION 'Transición de cocina inválida'; END IF;
  ELSIF v_operator.user_role='MESERO' THEN
    IF v_order.waiter_id<>v_operator.user_id OR v_order.status<>'READY' OR p_status<>'SERVED' THEN
      RAISE EXCEPTION 'Solo puedes marcar como servido tu pedido que ya está listo';
    END IF;
  ELSIF v_operator.user_role IN ('ADMIN','OWNER','CAJA') THEN
    IF p_status NOT IN ('RECEIVED','PREPARING','READY','SERVED') THEN RAISE EXCEPTION 'Estado inválido'; END IF;
    IF p_status='SERVED' AND v_order.status<>'READY' THEN RAISE EXCEPTION 'Solo se puede servir un pedido que ya está listo'; END IF;
  ELSE
    RAISE EXCEPTION 'Este usuario no puede cambiar el estado';
  END IF;

  UPDATE public.order_items SET prep_status=p_status
  WHERE order_id=p_order_id AND prep_status=v_order.status;
  UPDATE public.orders SET status=p_status,updated_at=now() WHERE id=p_order_id;
  RETURN jsonb_build_object('success',true,'status',p_status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_get_orders(p_token text,p_location_id uuid,p_scope text DEFAULT 'ACTIVE')
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE v_operator record; v_orders jsonb;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida o no autorizada'; END IF;
  IF p_scope IN ('MINE','MINE_HISTORY') AND v_operator.user_role NOT IN ('MESERO','ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso para consultar pedidos'; END IF;
  IF p_scope='KITCHEN' AND v_operator.user_role NOT IN ('COCINA','ASADOR','ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso para consultar cocina'; END IF;
  IF p_scope='ALL' AND v_operator.user_role NOT IN ('CAJA','ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso para consultar todos los pedidos'; END IF;
  IF p_scope NOT IN ('MINE','MINE_HISTORY','KITCHEN','ALL') THEN RAISE EXCEPTION 'Consulta de pedidos inválida'; END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC), '[]'::jsonb) INTO v_orders
  FROM (
    SELECT o.id,o.waiter_id,o.customer_name,o.status,o.notes,o.created_at,o.updated_at,
      o.business_id,o.location_id,o.waiter_name,
      CASE WHEN EXISTS (
        SELECT 1 FROM public.profiles p WHERE p.id=o.waiter_id AND upper(p.role)='MESERO'
      ) THEN 'MOBILE' ELSE 'POS' END AS source,
      t.id AS ticket_id,t.code AS ticket_code,t.status AS ticket_status,t.total_cents AS ticket_total_cents,
      coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id',oi.id,'order_id',oi.order_id,'product_id',oi.product_id,
        'product_name',oi.product_name,'quantity',oi.quantity,
        'unit_price_cents',oi.unit_price_cents,'notes',oi.notes,'prep_status',oi.prep_status
      ) ORDER BY oi.created_at) FROM public.order_items oi WHERE oi.order_id=o.id),'[]'::jsonb) AS items
    FROM public.orders o
    LEFT JOIN LATERAL (SELECT tk.id,tk.code,tk.status,tk.total_cents FROM public.tickets tk WHERE tk.order_id=o.id ORDER BY tk.created_at DESC LIMIT 1) t ON true
    WHERE o.location_id=p_location_id
      AND (
        p_scope='MINE_HISTORY'
        OR (p_scope IN ('ALL','MINE') AND (
          o.status IN ('RECEIVED','PREPARING','READY')
          OR (o.status='SERVED' AND coalesce(t.status,'PENDING')='PENDING')
        ))
        OR (p_scope='KITCHEN' AND o.status IN ('RECEIVED','PREPARING','READY'))
      )
      AND (p_scope NOT IN ('MINE','MINE_HISTORY') OR o.waiter_id=v_operator.user_id)
    ORDER BY o.created_at DESC
    LIMIT CASE WHEN p_scope='MINE_HISTORY' THEN 50 ELSE 500 END
  ) q;
  RETURN v_orders;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_add_items_to_order(text,uuid,uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_update_order_status(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_orders(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_add_items_to_order(text,uuid,uuid,jsonb) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_update_order_status(text,uuid,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_orders(text,uuid,text) TO anon,authenticated;
