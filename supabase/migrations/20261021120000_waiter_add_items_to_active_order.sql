-- Allow a waiter to append items to their own order while it is still
-- received/preparing. The operation UUID makes network retries idempotent.
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
  IF v_order.status NOT IN ('RECEIVED','PREPARING') THEN
    RAISE EXCEPTION 'Solo se pueden agregar productos antes de que cocina despache el pedido';
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
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, unit_price_cents, notes)
    VALUES (v_order.id, v_product.id, v_product.name, v_qty,
      v_product.price_cents, left(coalesce(v_item->>'notes',''), 500));
  END LOOP;

  SELECT coalesce(sum(oi.unit_price_cents::bigint * oi.quantity), 0)
  INTO v_total FROM public.order_items oi WHERE oi.order_id = v_order.id;
  IF v_total < 0 OR v_total > 2147483647 THEN RAISE EXCEPTION 'Total excede el límite permitido'; END IF;
  UPDATE public.orders SET updated_at = now() WHERE id = v_order.id;
  UPDATE public.tickets SET total_cents = v_total::integer
  WHERE order_id = v_order.id AND status = 'PENDING';

  SELECT jsonb_build_object(
    'order_id', v_order.id,
    'total_cents', v_total,
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'id', oi.id, 'product_id', oi.product_id, 'product_name', oi.product_name,
      'quantity', oi.quantity, 'unit_price_cents', oi.unit_price_cents, 'notes', oi.notes
    ) ORDER BY oi.created_at), '[]'::jsonb)
  ) INTO v_result
  FROM public.order_items oi WHERE oi.order_id = v_order.id;

  INSERT INTO public.order_item_addition_requests(operation_id, order_id, actor_id, result)
  VALUES (p_operation_id, v_order.id, v_operator.user_id, v_result);
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_add_items_to_order(text, uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_add_items_to_order(text, uuid, uuid, jsonb) TO anon, authenticated;
