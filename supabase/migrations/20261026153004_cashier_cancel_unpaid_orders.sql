-- Allow branch cashiers to clean up unpaid orders after a shift is closed.
-- The order row lock serializes cancellation against the atomic charge RPC.
CREATE OR REPLACE FUNCTION public.pos_cancel_unpaid_order(
  p_token text,
  p_order_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  v_order public.orders%rowtype;
  v_operator record;
  v_ticket_ids uuid[];
  v_reason text := left(trim(coalesce(p_reason, '')), 500);
BEGIN
  IF length(v_reason) < 5 THEN
    RAISE EXCEPTION 'Escribe un motivo de al menos 5 caracteres';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;

  SELECT * INTO v_operator
    FROM public.pos_operator_for_token(p_token, v_order.location_id);
  IF v_operator.user_id IS NULL THEN
    RAISE EXCEPTION 'Sesión vencida o sucursal no autorizada';
  END IF;
  IF v_operator.user_role NOT IN ('CAJA','ADMIN','OWNER') THEN
    RAISE EXCEPTION 'Solo caja o administración puede anular pedidos pendientes de cobro';
  END IF;

  -- Paid sales must use the refund flow, never cancellation.
  IF EXISTS (SELECT 1 FROM public.tickets WHERE order_id = v_order.id AND status = 'PAID') THEN
    RAISE EXCEPTION 'El pedido ya fue cobrado. Registra una devolución desde Historial.';
  END IF;

  IF v_order.status = 'CANCELLED' THEN
    RETURN jsonb_build_object('success', true, 'already_cancelled', true);
  END IF;
  IF v_order.status NOT IN ('RECEIVED','PREPARING','READY','SERVED') THEN
    RAISE EXCEPTION 'El pedido no se puede anular en su estado actual';
  END IF;

  SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_ticket_ids
    FROM public.tickets WHERE order_id = v_order.id AND status = 'PENDING';

  UPDATE public.orders SET status = 'CANCELLED', updated_at = now() WHERE id = v_order.id;
  UPDATE public.tickets SET status = 'CANCELLED'
   WHERE order_id = v_order.id AND status = 'PENDING';

  INSERT INTO public.audit_events(actor_id, entity_type, entity_id, action, payload)
  VALUES (
    v_operator.user_id, 'order', v_order.id, 'UNPAID_ORDER_CANCELLED',
    jsonb_build_object(
      'location_id', v_order.location_id,
      'previous_status', v_order.status,
      'ticket_ids', v_ticket_ids,
      'reason', v_reason
    )
  );

  RETURN jsonb_build_object('success', true, 'already_cancelled', false);
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_cancel_unpaid_order(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_cancel_unpaid_order(text,uuid,text) TO anon, authenticated;
