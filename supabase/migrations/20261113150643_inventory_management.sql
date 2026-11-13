-- Inventory management: branch-scoped stock, receipts, recipes and immutable ledger.
CREATE TABLE public.inventory_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  base_unit text NOT NULL CHECK (base_unit IN ('g','ml','unit')),
  stock_on_hand numeric(14,3) NOT NULL DEFAULT 0 CHECK (stock_on_hand >= 0),
  minimum_stock numeric(14,3) NOT NULL DEFAULT 0 CHECK (minimum_stock >= 0),
  average_cost_cents numeric(14,4) NOT NULL DEFAULT 0 CHECK (average_cost_cents >= 0),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(location_id, name),
  UNIQUE(id, location_id)
);

CREATE TABLE public.inventory_recipes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(location_id, product_id),
  UNIQUE(id, location_id)
);

CREATE TABLE public.inventory_recipe_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_id uuid NOT NULL,
  location_id uuid NOT NULL,
  inventory_item_id uuid NOT NULL,
  quantity_per_product numeric(14,3) NOT NULL CHECK (quantity_per_product > 0),
  UNIQUE(recipe_id, inventory_item_id),
  FOREIGN KEY (recipe_id, location_id) REFERENCES public.inventory_recipes(id, location_id) ON DELETE CASCADE,
  FOREIGN KEY (inventory_item_id, location_id) REFERENCES public.inventory_items(id, location_id) ON DELETE RESTRICT
);

CREATE TABLE public.inventory_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id uuid NOT NULL UNIQUE,
  business_id uuid NOT NULL REFERENCES public.businesses(id),
  location_id uuid NOT NULL REFERENCES public.locations(id),
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  supplier text NOT NULL DEFAULT '',
  reference text NOT NULL DEFAULT '',
  payment_method text NOT NULL DEFAULT 'OTHER' CHECK (payment_method IN ('CASH','TRANSFER','CREDIT','OTHER')),
  total_cost_cents integer NOT NULL CHECK (total_cost_cents >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.inventory_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id uuid NOT NULL,
  business_id uuid NOT NULL REFERENCES public.businesses(id),
  location_id uuid NOT NULL REFERENCES public.locations(id),
  inventory_item_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id),
  movement_type text NOT NULL CHECK (movement_type IN ('PURCHASE','CONSUMPTION','ADJUSTMENT','WASTE')),
  quantity_delta numeric(14,3) NOT NULL CHECK (quantity_delta <> 0),
  value_cents integer NOT NULL DEFAULT 0 CHECK (value_cents >= 0),
  reason text NOT NULL DEFAULT '',
  purchase_id uuid REFERENCES public.inventory_purchases(id),
  order_id uuid REFERENCES public.orders(id),
  order_item_id uuid REFERENCES public.order_items(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (inventory_item_id, location_id) REFERENCES public.inventory_items(id, location_id) ON DELETE RESTRICT,
  UNIQUE(operation_id, inventory_item_id),
  UNIQUE(order_item_id, inventory_item_id)
);

CREATE INDEX inventory_items_location_active_idx ON public.inventory_items(location_id, active, name);
CREATE INDEX inventory_movements_location_date_idx ON public.inventory_movements(location_id, created_at DESC);
CREATE INDEX inventory_movements_type_date_idx ON public.inventory_movements(location_id, movement_type, created_at DESC);
ALTER TABLE public.cash_expenses ADD COLUMN IF NOT EXISTS inventory_purchase_id uuid REFERENCES public.inventory_purchases(id);
CREATE UNIQUE INDEX IF NOT EXISTS cash_expenses_inventory_purchase_uidx ON public.cash_expenses(inventory_purchase_id) WHERE inventory_purchase_id IS NOT NULL;

ALTER TABLE public.inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_recipe_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_items, public.inventory_recipes, public.inventory_recipe_lines,
  public.inventory_purchases, public.inventory_movements FROM anon, authenticated, public;

CREATE OR REPLACE FUNCTION public.pos_inventory_get(p_token text, p_location_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN
    RAISE EXCEPTION 'No tienes permiso para administrar el inventario';
  END IF;
  RETURN jsonb_build_object(
    'items', coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.name) FROM public.inventory_items i WHERE i.location_id=p_location_id AND i.active),'[]'::jsonb),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'category_id',p.category_id) ORDER BY p.sort_order,p.name) FROM public.products p WHERE p.location_id=p_location_id AND p.active),'[]'::jsonb),
    'recipes', coalesce((SELECT jsonb_agg(jsonb_build_object('product_id',r.product_id,'active',r.active,'items',coalesce((SELECT jsonb_agg(jsonb_build_object('inventory_item_id',rl.inventory_item_id,'quantity_per_product',rl.quantity_per_product) ORDER BY i.name) FROM public.inventory_recipe_lines rl JOIN public.inventory_items i ON i.id=rl.inventory_item_id WHERE rl.recipe_id=r.id),'[]'::jsonb))) FROM public.inventory_recipes r WHERE r.location_id=p_location_id),'[]'::jsonb),
    'movements', coalesce((SELECT jsonb_agg(jsonb_build_object('id',m.id,'movement_type',m.movement_type,'quantity_delta',m.quantity_delta,'value_cents',m.value_cents,'reason',m.reason,'created_at',m.created_at,'item_name',i.name) ORDER BY m.created_at DESC) FROM (SELECT * FROM public.inventory_movements WHERE location_id=p_location_id ORDER BY created_at DESC LIMIT 100) m JOIN public.inventory_items i ON i.id=m.inventory_item_id),'[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_inventory_save_item(
  p_token text,p_location_id uuid,p_item_id uuid,p_name text,p_base_unit text,p_minimum_stock numeric
) RETURNS public.inventory_items LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_location public.locations%rowtype; v_item public.inventory_items%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso'; END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sucursal no disponible'; END IF;
  IF p_base_unit NOT IN ('g','ml','unit') OR p_minimum_stock<0 THEN RAISE EXCEPTION 'Unidad o mínimo inválido'; END IF;
  IF p_item_id IS NULL THEN
    INSERT INTO public.inventory_items(business_id,location_id,name,base_unit,minimum_stock)
    VALUES(v_location.business_id,p_location_id,btrim(p_name),p_base_unit,p_minimum_stock) RETURNING * INTO v_item;
  ELSE
    SELECT * INTO v_item FROM public.inventory_items WHERE id=p_item_id AND location_id=p_location_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insumo no encontrado'; END IF;
    IF v_item.base_unit<>p_base_unit THEN RAISE EXCEPTION 'La unidad base no se puede cambiar después de crear el insumo'; END IF;
    UPDATE public.inventory_items SET name=btrim(p_name),minimum_stock=p_minimum_stock,updated_at=now()
    WHERE id=p_item_id AND location_id=p_location_id RETURNING * INTO v_item;
  END IF;
  RETURN v_item;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_inventory_save_recipe(
  p_token text,p_location_id uuid,p_product_id uuid,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_location public.locations%rowtype; v_recipe public.inventory_recipes%rowtype; v_line jsonb;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso'; END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF NOT EXISTS(SELECT 1 FROM public.products WHERE id=p_product_id AND location_id=p_location_id AND business_id=v_location.business_id AND active) THEN RAISE EXCEPTION 'Producto no disponible'; END IF;
  IF jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)>100 THEN RAISE EXCEPTION 'Receta inválida'; END IF;
  INSERT INTO public.inventory_recipes(business_id,location_id,product_id,active)
  VALUES(v_location.business_id,p_location_id,p_product_id,jsonb_array_length(p_lines)>0)
  ON CONFLICT(location_id,product_id) DO UPDATE SET active=EXCLUDED.active,updated_at=now() RETURNING * INTO v_recipe;
  DELETE FROM public.inventory_recipe_lines WHERE recipe_id=v_recipe.id;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    IF (v_line->>'quantity_per_product')::numeric<=0 OR NOT EXISTS(
      SELECT 1 FROM public.inventory_items WHERE id=(v_line->>'inventory_item_id')::uuid AND location_id=p_location_id AND active
    ) THEN RAISE EXCEPTION 'Insumo o cantidad de receta inválidos'; END IF;
    INSERT INTO public.inventory_recipe_lines(recipe_id,location_id,inventory_item_id,quantity_per_product)
    VALUES(v_recipe.id,p_location_id,(v_line->>'inventory_item_id')::uuid,(v_line->>'quantity_per_product')::numeric);
  END LOOP;
  RETURN jsonb_build_object('success',true,'product_id',p_product_id,'active',v_recipe.active);
END;
$function$;

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
CREATE OR REPLACE FUNCTION public.pos_inventory_adjust(
  p_token text,p_location_id uuid,p_operation_id uuid,p_item_id uuid,p_delta numeric,p_movement_type text,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_item public.inventory_items%rowtype; v_cost integer; v_existing public.inventory_movements%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso'; END IF;
  IF p_operation_id IS NULL OR p_delta=0 OR p_movement_type NOT IN ('ADJUSTMENT','WASTE') OR (p_movement_type='WASTE' AND p_delta>=0) OR length(btrim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Movimiento o motivo inválido'; END IF;
  SELECT * INTO v_existing FROM public.inventory_movements WHERE operation_id=p_operation_id LIMIT 1;
  IF FOUND THEN
    IF v_existing.location_id<>p_location_id OR v_existing.actor_id<>v_operator.user_id OR v_existing.inventory_item_id<>p_item_id THEN RAISE EXCEPTION 'Identificador de operación ya utilizado'; END IF;
    RETURN jsonb_build_object('success',true,'duplicate',true);
  END IF;
  SELECT * INTO v_item FROM public.inventory_items WHERE id=p_item_id AND location_id=p_location_id AND active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insumo no encontrado'; END IF;
  IF v_item.stock_on_hand+p_delta<0 THEN RAISE EXCEPTION 'La existencia no puede quedar negativa'; END IF;
  v_cost:=round(abs(p_delta)*v_item.average_cost_cents)::integer;
  UPDATE public.inventory_items SET stock_on_hand=stock_on_hand+p_delta,updated_at=now() WHERE id=p_item_id;
  INSERT INTO public.inventory_movements(operation_id,business_id,location_id,inventory_item_id,actor_id,movement_type,quantity_delta,value_cents,reason)
  VALUES(p_operation_id,v_item.business_id,p_location_id,p_item_id,v_operator.user_id,p_movement_type,p_delta,v_cost,left(btrim(p_reason),240));
  RETURN jsonb_build_object('success',true,'stock_on_hand',v_item.stock_on_hand+p_delta);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_inventory_monthly_report(p_token text,p_location_id uuid,p_month date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_start timestamptz; v_end timestamptz;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Sin permiso'; END IF;
  v_start:=date_trunc('month',p_month::timestamp) AT TIME ZONE 'America/Guayaquil';
  v_end:=(date_trunc('month',p_month::timestamp)+interval '1 month') AT TIME ZONE 'America/Guayaquil';
  RETURN jsonb_build_object(
    'month',to_char(p_month,'YYYY-MM'),
    'sales_cents',coalesce((SELECT sum(t.total_cents) FROM public.tickets t WHERE t.location_id=p_location_id AND t.status='PAID' AND t.paid_at>=v_start AND t.paid_at<v_end),0),
    'cash_expenses_cents',coalesce((SELECT sum(e.amount_cents) FROM public.cash_expenses e WHERE e.location_id=p_location_id AND e.created_at>=v_start AND e.created_at<v_end),0),
    'operating_expenses_cents',coalesce((SELECT sum(e.amount_cents) FROM public.cash_expenses e WHERE e.location_id=p_location_id AND e.inventory_purchase_id IS NULL AND e.created_at>=v_start AND e.created_at<v_end),0),
    'purchases_cents',coalesce((SELECT sum(m.value_cents) FROM public.inventory_movements m WHERE m.location_id=p_location_id AND m.movement_type='PURCHASE' AND m.created_at>=v_start AND m.created_at<v_end),0),
    'consumption_cents',coalesce((SELECT sum(m.value_cents) FROM public.inventory_movements m WHERE m.location_id=p_location_id AND m.movement_type='CONSUMPTION' AND m.created_at>=v_start AND m.created_at<v_end),0),
    'waste_cents',coalesce((SELECT sum(m.value_cents) FROM public.inventory_movements m WHERE m.location_id=p_location_id AND m.movement_type='WASTE' AND m.created_at>=v_start AND m.created_at<v_end),0),
    'stock_value_cents',coalesce((SELECT sum(round(i.stock_on_hand*i.average_cost_cents)) FROM public.inventory_items i WHERE i.location_id=p_location_id AND i.active),0),
    'profit_before_refunds_and_other_costs_cents',coalesce((SELECT sum(t.total_cents) FROM public.tickets t WHERE t.location_id=p_location_id AND t.status='PAID' AND t.paid_at>=v_start AND t.paid_at<v_end),0)
      -coalesce((SELECT sum(m.value_cents) FROM public.inventory_movements m WHERE m.location_id=p_location_id AND m.movement_type='CONSUMPTION' AND m.created_at>=v_start AND m.created_at<v_end),0)
      -coalesce((SELECT sum(e.amount_cents) FROM public.cash_expenses e WHERE e.location_id=p_location_id AND e.inventory_purchase_id IS NULL AND e.created_at>=v_start AND e.created_at<v_end),0)
  );
END;
$function$;

-- Kitchen start consumes only lines that are still RECEIVED. Existing prepared
-- lines remain untouched when a waiter adds more items later.
CREATE OR REPLACE FUNCTION public.pos_update_order_status(p_token text,p_order_id uuid,p_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_order public.orders%rowtype; v_operator record; v_next text; v_line record; v_component record; v_needed numeric; v_cost integer;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido no encontrado'; END IF;
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,v_order.location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida o no autorizada'; END IF;
  IF v_operator.user_role IN ('COCINA','ASADOR') THEN
    v_next:=CASE v_order.status WHEN 'RECEIVED' THEN 'PREPARING' WHEN 'PREPARING' THEN 'READY' ELSE NULL END;
    IF p_status IS DISTINCT FROM v_next THEN RAISE EXCEPTION 'Transición de cocina inválida'; END IF;
  ELSIF v_operator.user_role='MESERO' THEN
    IF v_order.waiter_id<>v_operator.user_id OR v_order.status<>'READY' OR p_status<>'SERVED' THEN RAISE EXCEPTION 'Solo puedes marcar como servido tu pedido que ya está listo'; END IF;
  ELSIF v_operator.user_role IN ('ADMIN','OWNER','CAJA') THEN
    IF p_status NOT IN ('RECEIVED','PREPARING','READY','SERVED') THEN RAISE EXCEPTION 'Estado inválido'; END IF;
    IF p_status='SERVED' AND v_order.status<>'READY' THEN RAISE EXCEPTION 'Solo se puede servir un pedido que ya está listo'; END IF;
  ELSE RAISE EXCEPTION 'Este usuario no puede cambiar el estado'; END IF;

  IF p_status='PREPARING' AND v_order.status='RECEIVED' THEN
    FOR v_line IN SELECT oi.id,oi.product_id,oi.quantity FROM public.order_items oi WHERE oi.order_id=p_order_id AND oi.prep_status='RECEIVED' ORDER BY oi.id LOOP
      FOR v_component IN
        SELECT rl.inventory_item_id,rl.quantity_per_product,i.name,i.average_cost_cents
        FROM public.inventory_recipes r JOIN public.inventory_recipe_lines rl ON rl.recipe_id=r.id
        JOIN public.inventory_items i ON i.id=rl.inventory_item_id
        WHERE r.location_id=v_order.location_id AND r.product_id=v_line.product_id AND r.active AND i.active
        ORDER BY rl.inventory_item_id
      LOOP
        v_needed:=v_component.quantity_per_product*v_line.quantity;
        UPDATE public.inventory_items SET stock_on_hand=stock_on_hand-v_needed,updated_at=now()
        WHERE id=v_component.inventory_item_id AND location_id=v_order.location_id AND stock_on_hand>=v_needed;
        IF NOT FOUND THEN RAISE EXCEPTION 'Existencia insuficiente de % para preparar el pedido',v_component.name; END IF;
        v_cost:=round(v_needed*v_component.average_cost_cents)::integer;
        INSERT INTO public.inventory_movements(operation_id,business_id,location_id,inventory_item_id,actor_id,movement_type,quantity_delta,value_cents,reason,order_id,order_item_id)
        VALUES(v_line.id,v_order.business_id,v_order.location_id,v_component.inventory_item_id,v_operator.user_id,'CONSUMPTION',-v_needed,v_cost,'Consumo de receta',p_order_id,v_line.id);
      END LOOP;
    END LOOP;
  END IF;
  UPDATE public.order_items SET prep_status=p_status WHERE order_id=p_order_id AND prep_status=v_order.status;
  UPDATE public.orders SET status=p_status,updated_at=now() WHERE id=p_order_id;
  RETURN jsonb_build_object('success',true,'status',p_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_inventory_get(text,uuid), public.pos_inventory_save_item(text,uuid,uuid,text,text,numeric),
  public.pos_inventory_save_recipe(text,uuid,uuid,jsonb), public.pos_inventory_receive(text,uuid,uuid,text,text,text,jsonb),
  public.pos_inventory_adjust(text,uuid,uuid,uuid,numeric,text,text), public.pos_inventory_monthly_report(text,uuid,date),
  public.pos_update_order_status(text,uuid,text) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_inventory_get(text,uuid), public.pos_inventory_save_item(text,uuid,uuid,text,text,numeric),
  public.pos_inventory_save_recipe(text,uuid,uuid,jsonb), public.pos_inventory_receive(text,uuid,uuid,text,text,text,jsonb),
  public.pos_inventory_adjust(text,uuid,uuid,uuid,numeric,text,text), public.pos_inventory_monthly_report(text,uuid,date),
  public.pos_update_order_status(text,uuid,text) TO anon, authenticated;
