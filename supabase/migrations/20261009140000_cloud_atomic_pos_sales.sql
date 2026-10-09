ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS client_operation_id uuid UNIQUE;

CREATE OR REPLACE FUNCTION public.pos_create_and_pay_sale(
  p_token text,p_location_id uuid,p_operation_id uuid,p_customer_name text,
  p_payment_method text,p_items jsonb
)
RETURNS public.tickets
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE
  v_operator record; v_location public.locations%rowtype; v_session public.cash_sessions%rowtype;
  v_order_id uuid; v_ticket public.tickets%rowtype; v_item jsonb; v_total bigint:=0;
  v_qty integer; v_unit integer; v_name text; v_role text; v_payment text;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión de caja vencida o no autorizada'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'Falta el identificador idempotente de la venta'; END IF;
  IF p_payment_method NOT IN ('CASH','TRANSFER') THEN RAISE EXCEPTION 'Método de pago inválido'; END IF;
  IF jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0 THEN RAISE EXCEPTION 'La venta debe tener productos'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id::text,0));
  SELECT o.id INTO v_order_id FROM public.orders o WHERE o.client_operation_id=p_operation_id;
  IF v_order_id IS NOT NULL THEN
    SELECT * INTO v_ticket FROM public.tickets t WHERE t.order_id=v_order_id AND t.location_id=p_location_id;
    IF v_ticket.id IS NULL THEN RAISE EXCEPTION 'La clave idempotente ya fue usada en otra sucursal'; END IF;
    RETURN v_ticket;
  END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sucursal no disponible'; END IF;
  SELECT * INTO v_session FROM public.cash_sessions WHERE location_id=p_location_id AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abra una caja cloud antes de cobrar'; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (v_item->>'quantity')::integer;
    v_unit := (v_item->>'unit_price_cents')::integer;
    v_name := trim(coalesce(v_item->>'product_name',''));
    IF v_qty<=0 OR v_unit<0 OR v_name='' THEN RAISE EXCEPTION 'Producto o cantidad inválidos'; END IF;
    v_total := v_total + v_qty::bigint*v_unit::bigint;
    IF v_total>2147483647 THEN RAISE EXCEPTION 'El total excede el límite permitido'; END IF;
  END LOOP;
  IF v_total<=0 THEN RAISE EXCEPTION 'El total de la venta debe ser mayor que cero'; END IF;

  SELECT lm.role INTO v_role FROM public.location_memberships lm WHERE lm.profile_id=v_operator.user_id AND lm.location_id=p_location_id AND lm.active;
  INSERT INTO public.orders(waiter_id,customer_name,status,notes,business_id,location_id,waiter_name,client_operation_id)
  VALUES(v_operator.user_id,coalesce(nullif(trim(p_customer_name),''),'Para llevar'),'RECEIVED','Venta directa POS',v_location.business_id,p_location_id,
    (SELECT username FROM public.profiles WHERE id=v_operator.user_id),p_operation_id)
  RETURNING id INTO v_order_id;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.order_items(order_id,product_id,product_name,quantity,unit_price_cents,notes)
    VALUES(v_order_id,NULL,trim(v_item->>'product_name'),(v_item->>'quantity')::integer,(v_item->>'unit_price_cents')::integer,coalesce(v_item->>'notes',''));
  END LOOP;
  v_payment := CASE p_payment_method WHEN 'CASH' THEN 'CASH' ELSE 'TRANSFER' END;
  INSERT INTO public.tickets(order_id,code,status,payment_method,total_cents,cashier_id,cash_session_id,paid_at,business_id,location_id)
  VALUES(v_order_id,'T-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),'PAID',v_payment,v_total::integer,v_operator.user_id,v_session.id,now(),v_location.business_id,p_location_id)
  RETURNING * INTO v_ticket;
  IF v_payment='CASH' THEN UPDATE public.cash_sessions SET cash_sales_cents=cash_sales_cents+v_total::integer WHERE id=v_session.id;
  ELSE UPDATE public.cash_sessions SET transfer_sales_cents=transfer_sales_cents+v_total::integer WHERE id=v_session.id; END IF;
  RETURN v_ticket;
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_create_and_pay_sale(text,uuid,uuid,text,text,jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_create_and_pay_sale(text,uuid,uuid,text,text,jsonb) TO anon,authenticated;
