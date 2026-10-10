-- A waiter can confirm handoff only for their own READY order. Collectors
-- keep seeing it in the cash queue until the associated ticket is paid.
CREATE OR REPLACE FUNCTION public.pos_update_order_status(p_token text, p_order_id uuid, p_status text)
RETURNS jsonb
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

  UPDATE public.orders SET status=p_status,updated_at=now() WHERE id=p_order_id;
  RETURN jsonb_build_object('success',true,'status',p_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_update_order_status(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_update_order_status(text,uuid,text) TO anon,authenticated;
