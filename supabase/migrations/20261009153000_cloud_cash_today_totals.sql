CREATE OR REPLACE FUNCTION public.pos_get_cash_today_totals(p_token text,p_location_id uuid)
RETURNS TABLE(ticket_count bigint,gross_cents bigint,cash_cents bigint,transfer_cents bigint,card_cents bigint)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_day_start timestamptz; v_day_end timestamptz;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión cloud vencida o sin permiso de caja'; END IF;
  v_day_start := date_trunc('day', now() AT TIME ZONE 'America/Guayaquil') AT TIME ZONE 'America/Guayaquil';
  v_day_end := v_day_start + interval '1 day';
  RETURN QUERY SELECT count(*)::bigint,coalesce(sum(t.total_cents),0)::bigint,
    coalesce(sum(t.total_cents) FILTER (WHERE t.payment_method IN ('CASH','EFECTIVO')),0)::bigint,
    coalesce(sum(t.total_cents) FILTER (WHERE t.payment_method IN ('TRANSFER','TRANSFERENCIA')),0)::bigint,
    coalesce(sum(t.total_cents) FILTER (WHERE t.payment_method IN ('CARD','TARJETA')),0)::bigint
  FROM public.tickets t WHERE t.location_id=p_location_id AND t.status='PAID' AND t.paid_at>=v_day_start AND t.paid_at<v_day_end;
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_get_cash_today_totals(text,uuid) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_cash_today_totals(text,uuid) TO anon,authenticated;
