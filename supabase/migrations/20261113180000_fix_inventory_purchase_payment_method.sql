CREATE OR REPLACE FUNCTION public.pos_inventory_receive(
  p_token text,p_location_id uuid,p_operation_id uuid,p_supplier text,p_reference text,p_payment_method text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_location public.locations%rowtype; v_purchase public.inventory_purchases%rowtype; v_line jsonb; v_item public.inventory_items%rowtype; v_qty numeric; v_cost integer; v_total integer:=0; v_old_qty numeric; v_new_avg numeric; v_session public.cash_sessions%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso'; END IF;
  IF p_operation_id IS NULL OR p_payment_method NOT IN ('CASH','TRANSFER','CREDIT','OTHER') OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)<1 OR jsonb_array_length(p_lines)>100 THEN RAISE EXCEPTION 'Compra inválida'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id::text,0));
  SELECT * INTO v_purchase FROM public.inventory_purchases WHERE operation_id=p_operation_id;
  IF FOUND THEN
    IF v_purchase.location_id<>p_location_id OR v_purchase.created_by<>v_operator.user_id THEN RAISE EXCEPTION 'Identificador de operación ya utilizado'; END IF;
    RETURN jsonb_build_object('success',true,'purchase_id',v_purchase.id,'duplicate',true);
  END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sucursal no disponible'; END IF;
  IF p_payment_method='CASH' AND NOT EXISTS(SELECT 1 FROM public.cash_sessions WHERE location_id=p_location_id AND status='OPEN') THEN RAISE EXCEPTION 'Abre caja antes de registrar una compra pagada en efectivo'; END IF;
  INSERT INTO public.inventory_purchases(operation_id,business_id,location_id,created_by,supplier,reference,payment_method,total_cost_cents)
  VALUES(p_operation_id,v_location.business_id,p_location_id,v_operator.user_id,left(coalesce(p_supplier,''),160),left(coalesce(p_reference,''),120),p_payment_method,0)
  RETURNING * INTO v_purchase;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    v_qty:=(v_line->>'quantity')::numeric; v_cost:=(v_line->>'total_cost_cents')::integer;
    IF v_qty<=0 OR v_cost<0 THEN RAISE EXCEPTION 'Cantidad o costo inválido'; END IF;
    SELECT * INTO v_item FROM public.inventory_items WHERE id=(v_line->>'inventory_item_id')::uuid AND location_id=p_location_id AND active FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insumo no disponible'; END IF;
    v_old_qty:=v_item.stock_on_hand;
    v_new_avg:=CASE WHEN v_old_qty+v_qty=0 THEN 0 ELSE ((v_old_qty*v_item.average_cost_cents)+v_cost)/(v_old_qty+v_qty) END;
    UPDATE public.inventory_items SET stock_on_hand=v_old_qty+v_qty,average_cost_cents=v_new_avg,updated_at=now() WHERE id=v_item.id;
    INSERT INTO public.inventory_movements(operation_id,business_id,location_id,inventory_item_id,actor_id,movement_type,quantity_delta,value_cents,reason,purchase_id)
    VALUES(p_operation_id,v_location.business_id,p_location_id,v_item.id,v_operator.user_id,'PURCHASE',v_qty,v_cost,concat_ws(' · ',nullif(left(coalesce(p_supplier,''),160),''),nullif(left(coalesce(p_reference,''),120),'')),v_purchase.id);
    v_total:=v_total+v_cost;
  END LOOP;
  UPDATE public.inventory_purchases SET total_cost_cents=v_total WHERE id=v_purchase.id;
  IF p_payment_method='CASH' THEN
    SELECT * INTO v_session FROM public.cash_sessions WHERE location_id=p_location_id AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'La caja se cerró antes de registrar la compra'; END IF;
    INSERT INTO public.cash_expenses(session_id,location_id,business_id,created_by,amount_cents,description,inventory_purchase_id)
    VALUES(v_session.id,p_location_id,v_location.business_id,v_operator.user_id,v_total,concat('Compra de inventario',CASE WHEN coalesce(p_supplier,'')<>'' THEN ' · '||left(p_supplier,120) ELSE '' END),v_purchase.id);
    UPDATE public.cash_sessions SET expenses_cents=expenses_cents+v_total WHERE id=v_session.id;
  END IF;
  RETURN jsonb_build_object('success',true,'purchase_id',v_purchase.id,'total_cost_cents',v_total);
END;
$function$;