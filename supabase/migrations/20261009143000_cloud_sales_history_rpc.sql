CREATE OR REPLACE FUNCTION public.pos_get_sales_history(p_token text,p_location_id uuid,p_limit integer DEFAULT 300)
RETURNS TABLE(
  ticket_id uuid,order_id uuid,code text,status text,payment_method text,total_cents integer,
  created_at timestamptz,paid_at timestamptz,customer_name text,cashier_username text,
  cash_session_id uuid,items jsonb
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión cloud vencida o no autorizada'; END IF;
  IF v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA','MESERO') THEN RAISE EXCEPTION 'No tiene permiso para consultar historial'; END IF;
  RETURN QUERY
  SELECT t.id,t.order_id,t.code,t.status,t.payment_method,t.total_cents,t.created_at,t.paid_at,
    coalesce(o.customer_name,'Para llevar'),p.username,t.cash_session_id,
    coalesce((SELECT jsonb_agg(jsonb_build_object('product_name',oi.product_name,'quantity',oi.quantity,
      'unit_price_cents',oi.unit_price_cents,'notes',oi.notes) ORDER BY oi.created_at)
      FROM public.order_items oi WHERE oi.order_id=t.order_id),'[]'::jsonb)
  FROM public.tickets t
  LEFT JOIN public.orders o ON o.id=t.order_id
  LEFT JOIN public.profiles p ON p.id=t.cashier_id
  WHERE t.location_id=p_location_id
    AND (v_operator.user_role IN ('ADMIN','OWNER','CAJA') OR o.waiter_id=v_operator.user_id)
  ORDER BY coalesce(t.paid_at,t.created_at) DESC
  LIMIT greatest(1,least(coalesce(p_limit,300),1000));
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_get_sales_history(text,uuid,integer) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_sales_history(text,uuid,integer) TO anon,authenticated;

-- Internal token resolver must not be called directly by API clients.
REVOKE ALL ON FUNCTION public.pos_operator_for_token(text,uuid) FROM public,anon,authenticated;
