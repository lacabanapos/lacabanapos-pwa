-- Cash is independent per branch, not globally unique across the business.
DROP INDEX IF EXISTS public.one_open_cash_session_idx;
CREATE UNIQUE INDEX one_open_cash_session_idx
  ON public.cash_sessions (location_id)
  WHERE status = 'OPEN';

-- A waiter may mark an order served before it is collected. Keep it in the
-- cashier queue until its ticket is PAID, so service never erases a receivable.
CREATE OR REPLACE FUNCTION public.pos_get_orders(p_token text,p_location_id uuid,p_scope text DEFAULT 'ACTIVE')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  v_operator record;
  v_orders jsonb;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida o no autorizada'; END IF;
  IF p_scope IN ('MINE','MINE_HISTORY') AND v_operator.user_role NOT IN ('MESERO','ADMIN','OWNER') THEN
    RAISE EXCEPTION 'Sin permiso para consultar pedidos';
  END IF;
  IF p_scope='KITCHEN' AND v_operator.user_role NOT IN ('COCINA','ASADOR','ADMIN','OWNER') THEN
    RAISE EXCEPTION 'Sin permiso para consultar cocina';
  END IF;
  IF p_scope='ALL' AND v_operator.user_role NOT IN ('CAJA','ADMIN','OWNER') THEN
    RAISE EXCEPTION 'Sin permiso para consultar todos los pedidos';
  END IF;
  IF p_scope NOT IN ('MINE','MINE_HISTORY','KITCHEN','ALL') THEN RAISE EXCEPTION 'Consulta de pedidos inválida'; END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC), '[]'::jsonb) INTO v_orders
  FROM (
    SELECT o.id,o.waiter_id,o.customer_name,o.status,o.notes,o.created_at,o.updated_at,
      o.business_id,o.location_id,o.waiter_name,
      coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id',oi.id,'order_id',oi.order_id,'product_id',oi.product_id,
        'product_name',oi.product_name,'quantity',oi.quantity,
        'unit_price_cents',oi.unit_price_cents,'notes',oi.notes
      ) ORDER BY oi.created_at) FROM public.order_items oi WHERE oi.order_id=o.id),'[]'::jsonb) AS items
    FROM public.orders o
    WHERE o.location_id=p_location_id
      AND (
        p_scope='MINE_HISTORY'
        OR (p_scope='ALL' AND (
          o.status IN ('RECEIVED','PREPARING','READY')
          OR (o.status='SERVED' AND NOT EXISTS (
            SELECT 1 FROM public.tickets t WHERE t.order_id=o.id AND t.status='PAID'
          ))
        ))
        OR (p_scope IN ('MINE','KITCHEN') AND o.status IN ('RECEIVED','PREPARING','READY'))
      )
      AND (p_scope NOT IN ('MINE','MINE_HISTORY') OR o.waiter_id=v_operator.user_id)
    ORDER BY o.created_at DESC
    LIMIT CASE WHEN p_scope='MINE_HISTORY' THEN 50 ELSE 500 END
  ) q;
  RETURN v_orders;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_get_orders(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_get_orders(text,uuid,text) TO anon,authenticated;
