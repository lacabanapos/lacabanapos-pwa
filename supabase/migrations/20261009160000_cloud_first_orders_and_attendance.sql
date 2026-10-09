-- Cloud-first waiter, kitchen and attendance APIs. Additive; existing sales and attendance stay intact.
ALTER TABLE public.attendance_records ADD COLUMN IF NOT EXISTS location_id uuid REFERENCES public.locations(id);
CREATE INDEX IF NOT EXISTS idx_attendance_location_recorded ON public.attendance_records(location_id, recorded_at DESC);
CREATE TABLE IF NOT EXISTS public.pos_attendance_qr_codes(
  location_id uuid PRIMARY KEY REFERENCES public.locations(id) ON DELETE CASCADE,
  code_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pos_attendance_qr_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_attendance_qr_codes FROM anon,authenticated,public;

CREATE OR REPLACE FUNCTION public.pos_register_attendance_qr(p_token text,p_location_id uuid,p_code text,p_expires_at timestamptz)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede activar el QR de asistencia'; END IF;
  IF length(coalesce(p_code,''))<16 OR p_expires_at<=now() OR p_expires_at>now()+interval '2 minutes' THEN RAISE EXCEPTION 'Código QR o vencimiento inválido'; END IF;
  INSERT INTO public.pos_attendance_qr_codes(location_id,code_hash,expires_at,updated_at)
  VALUES(p_location_id,encode(extensions.digest(p_code,'sha256'),'hex'),p_expires_at,now())
  ON CONFLICT(location_id) DO UPDATE SET code_hash=excluded.code_hash,expires_at=excluded.expires_at,updated_at=now();
  RETURN true;
END;
$function$;

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
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('MESERO','ADMIN','OWNER') THEN RAISE EXCEPTION 'Sesión o permiso de mesero inválido'; END IF;
  IF p_operation_id IS NULL OR jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0 THEN RAISE EXCEPTION 'Pedido incompleto o sin identificador'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_operation_id::text,0));
  SELECT id INTO v_order_id FROM public.orders WHERE client_operation_id=p_operation_id;
  IF v_order_id IS NOT NULL THEN
    IF NOT EXISTS(SELECT 1 FROM public.orders WHERE id=v_order_id AND location_id=p_location_id AND waiter_id=v_operator.user_id) THEN RAISE EXCEPTION 'Clave idempotente usada por otro operador'; END IF;
    RETURN v_order_id;
  END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sucursal no disponible'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_qty := (v_item->>'quantity')::integer;
    IF v_qty NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Cantidad inválida'; END IF;
    SELECT * INTO v_product FROM public.products WHERE id=(v_item->>'product_id')::uuid AND location_id=p_location_id AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto no disponible en esta sucursal'; END IF;
    v_total := v_total + v_product.price_cents::bigint*v_qty;
    IF v_total>2147483647 THEN RAISE EXCEPTION 'Total excede el límite'; END IF;
  END LOOP;
  INSERT INTO public.orders(waiter_id,customer_name,status,notes,business_id,location_id,waiter_name,client_operation_id)
  VALUES(v_operator.user_id,coalesce(nullif(trim(p_customer_name),''),'Sin nombre'),'RECEIVED',coalesce(trim(p_notes),''),
    v_location.business_id,p_location_id,(SELECT username FROM public.profiles WHERE id=v_operator.user_id),p_operation_id)
  RETURNING id INTO v_order_id;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_product FROM public.products WHERE id=(v_item->>'product_id')::uuid AND location_id=p_location_id AND active;
    INSERT INTO public.order_items(order_id,product_id,product_name,quantity,unit_price_cents,notes)
    VALUES(v_order_id,v_product.id,v_product.name,(v_item->>'quantity')::integer,v_product.price_cents,coalesce(v_item->>'notes',''));
  END LOOP;
  INSERT INTO public.tickets(order_id,code,status,total_cents,business_id,location_id)
  VALUES(v_order_id,'T-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),'PENDING',v_total::integer,v_location.business_id,p_location_id);
  RETURN v_order_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_update_order_status(p_token text,p_order_id uuid,p_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_order public.orders%rowtype; v_operator record; v_next text;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,v_order.location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida o no autorizada'; END IF;
  IF v_operator.user_role IN ('COCINA','ASADOR') THEN
    v_next := CASE v_order.status WHEN 'RECEIVED' THEN 'PREPARING' WHEN 'PREPARING' THEN 'READY' ELSE NULL END;
    IF p_status<>v_next THEN RAISE EXCEPTION 'Transición de cocina inválida'; END IF;
  ELSIF v_operator.user_role IN ('ADMIN','OWNER','CAJA') THEN
    IF p_status NOT IN ('RECEIVED','PREPARING','READY','SERVED') THEN RAISE EXCEPTION 'Estado inválido'; END IF;
  ELSE
    RAISE EXCEPTION 'Este usuario no puede cambiar el estado';
  END IF;
  UPDATE public.orders SET status=p_status,updated_at=now() WHERE id=p_order_id;
  RETURN jsonb_build_object('success',true,'status',p_status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_cancel_order(p_token text,p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_order public.orders%rowtype; v_operator record;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,v_order.location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida o no autorizada'; END IF;
  IF v_order.status NOT IN ('RECEIVED','PREPARING') THEN RAISE EXCEPTION 'No se puede anular un pedido en este estado'; END IF;
  IF v_operator.user_role='MESERO' AND v_order.waiter_id<>v_operator.user_id THEN RAISE EXCEPTION 'Solo puede anular sus propios pedidos'; END IF;
  IF v_operator.user_role NOT IN ('MESERO','COCINA','ASADOR','ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sin permiso para anular'; END IF;
  UPDATE public.orders SET status='CANCELLED',updated_at=now() WHERE id=p_order_id;
  UPDATE public.tickets SET status='CANCELLED' WHERE order_id=p_order_id AND status='PENDING';
  RETURN jsonb_build_object('success',true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_get_last_attendance(p_token text,p_location_id uuid,p_user_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_type text;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_id<>p_user_id THEN RAISE EXCEPTION 'Sesión inválida para consultar asistencia'; END IF;
  SELECT ar.type INTO v_type FROM public.attendance_records ar WHERE ar.user_id=p_user_id AND ar.location_id=p_location_id ORDER BY ar.recorded_at DESC LIMIT 1;
  RETURN v_type;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_get_orders(p_token text,p_location_id uuid,p_scope text DEFAULT 'ACTIVE')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_orders jsonb;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida o no autorizada'; END IF;
  IF p_scope='MINE' AND v_operator.user_role NOT IN ('MESERO','ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso para consultar pedidos'; END IF;
  IF p_scope='KITCHEN' AND v_operator.user_role NOT IN ('COCINA','ASADOR','ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso para consultar cocina'; END IF;
  IF p_scope='ALL' AND v_operator.user_role NOT IN ('CAJA','ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso para consultar todos los pedidos'; END IF;
  IF p_scope NOT IN ('MINE','KITCHEN','ALL') THEN RAISE EXCEPTION 'Consulta de pedidos inválida'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at), '[]'::jsonb) INTO v_orders
  FROM (
    SELECT o.id,o.waiter_id,o.customer_name,o.status,o.notes,o.created_at,o.updated_at,o.business_id,o.location_id,
      o.waiter_name,coalesce((SELECT jsonb_agg(jsonb_build_object('id',oi.id,'order_id',oi.order_id,'product_id',oi.product_id,
        'product_name',oi.product_name,'quantity',oi.quantity,'unit_price_cents',oi.unit_price_cents,'notes',oi.notes)
        ORDER BY oi.created_at) FROM public.order_items oi WHERE oi.order_id=o.id),'[]'::jsonb) AS items
    FROM public.orders o
    WHERE o.location_id=p_location_id AND o.status IN ('RECEIVED','PREPARING','READY')
      AND (p_scope<>'MINE' OR o.waiter_id=v_operator.user_id)
    ORDER BY o.created_at
    LIMIT 500
  ) q;
  RETURN v_orders;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_get_attendance_records(p_token text,p_location_id uuid,p_limit integer DEFAULT 1000)
RETURNS TABLE(id uuid,user_id uuid,username text,type text,recorded_at timestamptz,latitude numeric,longitude numeric,
  accuracy numeric,status text,client_event_id text,device_id text,source_ip text)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo un administrador puede consultar asistencia'; END IF;
  RETURN QUERY SELECT ar.id,ar.user_id,p.username,ar.type,ar.recorded_at,ar.latitude,ar.longitude,ar.accuracy,ar.status,
    ar.client_event_id,ar.device_id,ar.source_ip
  FROM public.attendance_records ar JOIN public.profiles p ON p.id=ar.user_id
  WHERE ar.location_id=p_location_id ORDER BY ar.recorded_at DESC LIMIT greatest(1,least(coalesce(p_limit,1000),5000));
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_mark_attendance(
  p_token text,p_location_id uuid,p_type text,p_device_id text,p_client_event_id text,p_code text,
  p_latitude numeric,p_longitude numeric,p_accuracy numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_existing public.attendance_records%rowtype; v_last text; v_record public.attendance_records%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida; vuelve a ingresar'; END IF;
  IF p_type NOT IN ('ENTRY','EXIT') OR nullif(trim(p_client_event_id),'') IS NULL THEN RAISE EXCEPTION 'Marcación inválida'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pos_attendance_qr_codes q WHERE q.location_id=p_location_id
    AND q.expires_at>now() AND q.code_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex')) THEN
    RAISE EXCEPTION 'El QR venció. Escanea el código actual del POS.';
  END IF;
  IF p_latitude IS NULL OR p_longitude IS NULL OR p_accuracy IS NULL THEN RAISE EXCEPTION 'Activa ubicación y vuelve a intentar'; END IF;
  SELECT * INTO v_existing FROM public.attendance_records WHERE client_event_id=p_client_event_id;
  IF FOUND THEN
    IF v_existing.user_id<>v_operator.user_id OR v_existing.location_id<>p_location_id THEN RAISE EXCEPTION 'Identificador de marcación ya utilizado'; END IF;
    RETURN jsonb_build_object('success',true,'type',v_existing.type,'recorded_at',v_existing.recorded_at,'duplicate',true);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_operator.user_id::text||p_location_id::text,0));
  SELECT ar.type INTO v_last FROM public.attendance_records ar WHERE ar.user_id=v_operator.user_id AND ar.location_id=p_location_id ORDER BY ar.recorded_at DESC LIMIT 1;
  IF (p_type='ENTRY' AND v_last='ENTRY') OR (p_type='EXIT' AND coalesce(v_last,'')<>'ENTRY') THEN RAISE EXCEPTION 'La marcación no coincide con el último estado de asistencia'; END IF;
  INSERT INTO public.attendance_records(user_id,location_id,type,device_id,client_event_id,latitude,longitude,accuracy,status)
  VALUES(v_operator.user_id,p_location_id,p_type,p_device_id,p_client_event_id,p_latitude,p_longitude,p_accuracy,'SYNCED') RETURNING * INTO v_record;
  RETURN jsonb_build_object('success',true,'type',v_record.type,'recorded_at',v_record.recorded_at);
END;
$function$;

-- Remove anonymous direct writes that bypass the token-validated RPCs. Reads remain compatible during staged rollout.
DROP POLICY IF EXISTS "POS anon write products" ON public.products;
DROP POLICY IF EXISTS "POS anon write categories" ON public.categories;
DROP POLICY IF EXISTS "Allow anon all on orders" ON public.orders;
DROP POLICY IF EXISTS "Allow anon all on order_items" ON public.order_items;
DROP POLICY IF EXISTS "Authenticated can insert attendance" ON public.attendance_records;
DROP POLICY IF EXISTS "Allow anon read attendance_records" ON public.attendance_records;

REVOKE ALL ON FUNCTION public.pos_create_order(text,uuid,uuid,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_update_order_status(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_cancel_order(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_last_attendance(text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_orders(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_attendance_records(text,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_register_attendance_qr(text,uuid,text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_mark_attendance(text,uuid,text,text,text,text,numeric,numeric,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_create_order(text,uuid,uuid,text,text,jsonb) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_update_order_status(text,uuid,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_cancel_order(text,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_last_attendance(text,uuid,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_orders(text,uuid,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_attendance_records(text,uuid,integer) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_register_attendance_qr(text,uuid,text,timestamptz) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_mark_attendance(text,uuid,text,text,text,text,numeric,numeric,numeric) TO anon,authenticated;
