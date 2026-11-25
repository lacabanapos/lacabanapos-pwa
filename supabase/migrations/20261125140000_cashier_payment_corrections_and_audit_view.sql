CREATE OR REPLACE FUNCTION public.pos_correct_ticket_payment_method(
  p_token text,p_location_id uuid,p_ticket_id uuid,p_payment_method text,p_reason text
) RETURNS public.tickets LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_ticket public.tickets%rowtype; v_old text; v_session public.cash_sessions%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión o permiso de caja inválido'; END IF;
  IF p_payment_method NOT IN ('CASH','TRANSFER') OR length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Método o motivo de corrección inválido'; END IF;
  SELECT * INTO v_ticket FROM public.tickets WHERE id=p_ticket_id AND location_id=p_location_id FOR UPDATE;
  IF NOT FOUND OR v_ticket.status<>'PAID' OR v_ticket.cash_session_id IS NULL THEN RAISE EXCEPTION 'No se encontró un cobro válido'; END IF;
  IF EXISTS(SELECT 1 FROM public.pos_refunds WHERE ticket_id=v_ticket.id) THEN RAISE EXCEPTION 'No se puede corregir un ticket devuelto'; END IF;
  v_old:=v_ticket.payment_method;
  IF v_old=p_payment_method THEN RETURN v_ticket; END IF;
  IF v_old NOT IN ('CASH','TRANSFER') THEN RAISE EXCEPTION 'El método original no puede conciliarse automáticamente'; END IF;
  SELECT * INTO v_session FROM public.cash_sessions WHERE id=v_ticket.cash_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la sesión original de caja'; END IF;
  IF v_old='CASH' THEN
    IF v_session.cash_sales_cents<v_ticket.total_cents THEN RAISE EXCEPTION 'Los totales de efectivo de la caja no concuerdan; no se aplicó el cambio'; END IF;
    UPDATE public.cash_sessions SET cash_sales_cents=cash_sales_cents-v_ticket.total_cents,transfer_sales_cents=transfer_sales_cents+v_ticket.total_cents,
      transfer_difference_cents=CASE WHEN counted_transfer_cents IS NOT NULL THEN counted_transfer_cents-(transfer_sales_cents+v_ticket.total_cents-transfer_refunds_cents) ELSE transfer_difference_cents END WHERE id=v_session.id;
  ELSE
    IF v_session.transfer_sales_cents<v_ticket.total_cents THEN RAISE EXCEPTION 'Los totales de transferencias de la caja no concuerdan; no se aplicó el cambio'; END IF;
    UPDATE public.cash_sessions SET transfer_sales_cents=transfer_sales_cents-v_ticket.total_cents,cash_sales_cents=cash_sales_cents+v_ticket.total_cents,
      transfer_difference_cents=CASE WHEN counted_transfer_cents IS NOT NULL THEN counted_transfer_cents-(transfer_sales_cents-v_ticket.total_cents-transfer_refunds_cents) ELSE transfer_difference_cents END WHERE id=v_session.id;
  END IF;
  UPDATE public.tickets SET payment_method=p_payment_method WHERE id=v_ticket.id RETURNING * INTO v_ticket;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
  VALUES(v_operator.user_id,'ticket',v_ticket.id,'PAYMENT_METHOD_CORRECTED',jsonb_build_object('from',v_old,'to',p_payment_method,'reason',trim(p_reason),'cash_session_id',v_session.id,'total_cents',v_ticket.total_cents));
  RETURN v_ticket;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_get_ticket_payment_audit(p_token text,p_location_id uuid,p_limit integer DEFAULT 1000)
RETURNS TABLE(ticket_id uuid,from_method text,to_method text,reason text,changed_by text,created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede consultar auditoría de pagos'; END IF;
  RETURN QUERY SELECT e.entity_id,e.payload->>'from',e.payload->>'to',e.payload->>'reason',p.username,e.created_at
  FROM public.audit_events e JOIN public.profiles p ON p.id=e.actor_id
  JOIN public.tickets t ON t.id=e.entity_id AND t.location_id=p_location_id
  WHERE e.entity_type='ticket' AND e.action='PAYMENT_METHOD_CORRECTED' ORDER BY e.created_at DESC
  LIMIT greatest(1,least(coalesce(p_limit,1000),5000));
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_correct_ticket_payment_method(text,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_ticket_payment_audit(text,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_correct_ticket_payment_method(text,uuid,uuid,text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_ticket_payment_audit(text,uuid,integer) TO anon,authenticated;
