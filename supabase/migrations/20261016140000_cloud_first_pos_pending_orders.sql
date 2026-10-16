-- Let cashiers create the same branch-scoped cloud orders as the PWA.
-- This replaces the old SQLite-only pending-ticket path on cloud-linked POS terminals.
CREATE OR REPLACE FUNCTION public.pos_create_order(
  p_token text, p_location_id uuid, p_operation_id uuid, p_customer_name text,
  p_notes text, p_items jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE
  v_operator record; v_location public.locations%rowtype; v_order_id uuid;
  v_item jsonb; v_product public.products%rowtype; v_qty integer; v_total bigint := 0;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('MESERO','ADMIN','OWNER','CAJA') THEN
    RAISE EXCEPTION 'Sesión o permiso inválido para crear pedidos';
  END IF;
  IF p_operation_id IS NULL OR jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0 THEN
    RAISE EXCEPTION 'Pedido incompleto o sin identificador';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id::text,0));
  SELECT id INTO v_order_id FROM public.orders WHERE client_operation_id=p_operation_id;
  IF v_order_id IS NOT NULL THEN
    IF NOT EXISTS(SELECT 1 FROM public.orders WHERE id=v_order_id AND location_id=p_location_id AND waiter_id=v_operator.user_id) THEN
      RAISE EXCEPTION 'Clave idempotente usada por otro operador o sucursal';
    END IF;
    RETURN v_order_id;
  END IF;

  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sucursal no disponible'; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_qty := (v_item->>'quantity')::integer;
    IF v_qty NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Cantidad inválida'; END IF;
    SELECT * INTO v_product FROM public.products
      WHERE id=(v_item->>'product_id')::uuid AND location_id=p_location_id AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto no disponible en esta sucursal'; END IF;
    v_total := v_total + v_product.price_cents::bigint*v_qty;
    IF v_total>2147483647 THEN RAISE EXCEPTION 'Total excede el límite'; END IF;
  END LOOP;

  INSERT INTO public.orders(waiter_id,customer_name,status,notes,business_id,location_id,waiter_name,client_operation_id)
  VALUES(v_operator.user_id,coalesce(nullif(trim(p_customer_name),''),'Sin nombre'),'RECEIVED',coalesce(trim(p_notes),''),
    v_location.business_id,p_location_id,(SELECT username FROM public.profiles WHERE id=v_operator.user_id),p_operation_id)
  RETURNING id INTO v_order_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_product FROM public.products
      WHERE id=(v_item->>'product_id')::uuid AND location_id=p_location_id AND active;
    INSERT INTO public.order_items(order_id,product_id,product_name,quantity,unit_price_cents,notes)
    VALUES(v_order_id,v_product.id,v_product.name,(v_item->>'quantity')::integer,v_product.price_cents,coalesce(v_item->>'notes',''));
  END LOOP;

  INSERT INTO public.tickets(order_id,code,status,total_cents,business_id,location_id)
  VALUES(v_order_id,'T-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),'PENDING',v_total::integer,v_location.business_id,p_location_id);
  RETURN v_order_id;
END;
$function$;

-- Include the existing cloud ticket identity in order reads. Clients that do not
-- need these fields ignore them; the desktop uses them to print the cloud ticket.
CREATE OR REPLACE FUNCTION public.pos_get_orders(p_token text,p_location_id uuid,p_scope text DEFAULT 'ACTIVE')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
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
      t.id AS ticket_id,t.code AS ticket_code,t.status AS ticket_status,t.total_cents AS ticket_total_cents,
      coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id',oi.id,'order_id',oi.order_id,'product_id',oi.product_id,
        'product_name',oi.product_name,'quantity',oi.quantity,
        'unit_price_cents',oi.unit_price_cents,'notes',oi.notes
      ) ORDER BY oi.created_at) FROM public.order_items oi WHERE oi.order_id=o.id),'[]'::jsonb) AS items
    FROM public.orders o
    LEFT JOIN LATERAL (SELECT tk.id,tk.code,tk.status,tk.total_cents FROM public.tickets tk WHERE tk.order_id=o.id ORDER BY tk.created_at DESC LIMIT 1) t ON true
    WHERE o.location_id=p_location_id
      AND (
        p_scope='MINE_HISTORY'
        OR (p_scope='ALL' AND (
          o.status IN ('RECEIVED','PREPARING','READY')
          OR (o.status='SERVED' AND coalesce(t.status,'PENDING')<>'PAID')
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

REVOKE ALL ON FUNCTION public.pos_create_order(text,uuid,uuid,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_create_order(text,uuid,uuid,text,text,jsonb) TO anon,authenticated;
REVOKE ALL ON FUNCTION public.pos_get_orders(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_get_orders(text,uuid,text) TO anon,authenticated;
