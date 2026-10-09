-- Scoped cloud menu and user administration; no local bulk sync/import.
CREATE OR REPLACE FUNCTION public.pos_get_menu(p_token text,p_location_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_products jsonb; v_categories jsonb;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA','MESERO','COCINA','ASADOR') THEN RAISE EXCEPTION 'Sesión vencida o no autorizada'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'price_cents',p.price_cents,'category_id',p.category_id,
    'category_name',c.name,'active',p.active,'sort_order',p.sort_order,'image_data',p.image_data) ORDER BY p.sort_order,p.name),'[]'::jsonb)
    INTO v_products FROM public.products p LEFT JOIN public.categories c ON c.id=p.category_id
    WHERE p.location_id=p_location_id AND (p.active OR v_operator.user_role IN ('ADMIN','OWNER','CAJA'));
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'sort_order',c.sort_order,'active',c.active) ORDER BY c.sort_order,c.name),'[]'::jsonb)
    INTO v_categories FROM public.categories c WHERE c.location_id=p_location_id AND (c.active OR v_operator.user_role IN ('ADMIN','OWNER','CAJA'));
  RETURN jsonb_build_object('products',v_products,'categories',v_categories);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_save_category(p_token text,p_location_id uuid,p_category_id uuid,p_name text,p_sort_order integer DEFAULT 0)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_location public.locations%rowtype; v_id uuid;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede editar categorías'; END IF;
  IF length(trim(coalesce(p_name,''))) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'Nombre de categoría inválido'; END IF;
  IF EXISTS(SELECT 1 FROM public.categories c WHERE c.location_id=p_location_id AND lower(trim(c.name))=lower(trim(p_name)) AND c.id IS DISTINCT FROM p_category_id) THEN RAISE EXCEPTION 'Ya existe una categoría con ese nombre'; END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF p_category_id IS NULL THEN
    INSERT INTO public.categories(name,sort_order,active,business_id,location_id) VALUES(trim(p_name),greatest(0,p_sort_order),true,v_location.business_id,p_location_id) RETURNING id INTO v_id;
  ELSE
    UPDATE public.categories SET name=trim(p_name),sort_order=greatest(0,p_sort_order),active=true
    WHERE id=p_category_id AND location_id=p_location_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Categoría no encontrada en esta sucursal'; END IF;
  END IF;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_save_product(
  p_token text,p_location_id uuid,p_product_id uuid,p_category_id uuid,p_name text,p_price_cents integer,
  p_active boolean,p_image_data text,p_sort_order integer DEFAULT 0
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_location public.locations%rowtype; v_id uuid;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede editar productos'; END IF;
  IF length(trim(coalesce(p_name,''))) NOT BETWEEN 1 AND 120 OR p_price_cents<0 THEN RAISE EXCEPTION 'Producto o precio inválido'; END IF;
  IF p_image_data IS NOT NULL AND length(p_image_data)>500000 THEN RAISE EXCEPTION 'La imagen supera el tamaño permitido'; END IF;
  IF p_category_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.categories WHERE id=p_category_id AND location_id=p_location_id AND active) THEN RAISE EXCEPTION 'Categoría inválida'; END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF p_product_id IS NULL THEN
    INSERT INTO public.products(name,price_cents,category_id,active,image_data,sort_order,business_id,location_id)
    VALUES(trim(p_name),p_price_cents,p_category_id,coalesce(p_active,true),p_image_data,greatest(0,p_sort_order),v_location.business_id,p_location_id) RETURNING id INTO v_id;
  ELSE
    UPDATE public.products SET name=trim(p_name),price_cents=p_price_cents,category_id=p_category_id,active=coalesce(p_active,true),
      image_data=p_image_data,sort_order=greatest(0,p_sort_order)
    WHERE id=p_product_id AND location_id=p_location_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Producto no encontrado en esta sucursal'; END IF;
  END IF;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_deactivate_menu_item(p_token text,p_location_id uuid,p_item_id uuid,p_item_type text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_rows integer;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede editar el menú'; END IF;
  IF p_item_type='PRODUCT' THEN
    UPDATE public.products SET active=false WHERE id=p_item_id AND location_id=p_location_id;
  ELSIF p_item_type='CATEGORY' THEN
    IF EXISTS(SELECT 1 FROM public.products WHERE category_id=p_item_id AND location_id=p_location_id AND active) THEN RAISE EXCEPTION 'Mueva o desactive primero los productos de esta categoría'; END IF;
    UPDATE public.categories SET active=false WHERE id=p_item_id AND location_id=p_location_id;
  ELSE RAISE EXCEPTION 'Tipo de elemento inválido'; END IF;
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows=0 THEN RAISE EXCEPTION 'Elemento no encontrado en esta sucursal'; END IF;
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_list_users(p_token text,p_location_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_users jsonb;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede consultar usuarios'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('user_id',p.id,'username',p.username,'display_name',p.display_name,
    'user_role',lm.role,'active',p.active AND lm.active) ORDER BY p.username),'[]'::jsonb) INTO v_users
  FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_location_id;
  RETURN v_users;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_save_user(
  p_token text,p_location_id uuid,p_user_id uuid,p_username text,p_display_name text,p_role text,p_password text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_id uuid; v_location public.locations%rowtype; v_hash text;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede editar usuarios'; END IF;
  IF length(trim(coalesce(p_username,''))) NOT BETWEEN 2 AND 48 OR p_role NOT IN ('OWNER','ADMIN','CAJA','MESERO','COCINA','ASADOR') THEN RAISE EXCEPTION 'Datos de usuario inválidos'; END IF;
  IF EXISTS(SELECT 1 FROM public.profiles WHERE lower(username)=lower(trim(p_username)) AND id IS DISTINCT FROM p_user_id) THEN RAISE EXCEPTION 'Ese usuario ya existe'; END IF;
  SELECT * INTO v_location FROM public.locations WHERE id=p_location_id AND active;
  IF p_user_id IS NULL THEN
    IF length(coalesce(p_password,''))<4 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 4 caracteres'; END IF;
    v_hash:=encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex');
    INSERT INTO public.profiles(username,display_name,role,password_hash,active)
    VALUES(lower(trim(p_username)),coalesce(nullif(trim(p_display_name),''),trim(p_username)),p_role,v_hash,true) RETURNING id INTO v_id;
  ELSE
    v_id:=p_user_id;
    IF p_password IS NOT NULL AND p_password<>'' THEN
      IF length(p_password)<4 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 4 caracteres'; END IF;
      v_hash:=encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex');
      UPDATE public.profiles SET username=lower(trim(p_username)),display_name=coalesce(nullif(trim(p_display_name),''),trim(p_username)),role=p_role,password_hash=v_hash,active=true WHERE id=v_id;
    ELSE
      UPDATE public.profiles SET username=lower(trim(p_username)),display_name=coalesce(nullif(trim(p_display_name),''),trim(p_username)),role=p_role,active=true WHERE id=v_id;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
  END IF;
  INSERT INTO public.location_memberships(location_id,profile_id,role,active)
  VALUES(p_location_id,v_id,p_role,true)
  ON CONFLICT(location_id,profile_id) DO UPDATE SET role=excluded.role,active=true;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_deactivate_user(p_token text,p_location_id uuid,p_user_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_role text; v_count integer;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede desactivar usuarios'; END IF;
  SELECT role INTO v_role FROM public.location_memberships WHERE profile_id=p_user_id AND location_id=p_location_id AND active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado en esta sucursal'; END IF;
  IF v_role IN ('ADMIN','OWNER') THEN
    SELECT count(*) INTO v_count FROM public.location_memberships WHERE location_id=p_location_id AND active AND role IN ('ADMIN','OWNER');
    IF v_count<=1 THEN RAISE EXCEPTION 'No se puede desactivar al último administrador'; END IF;
  END IF;
  UPDATE public.location_memberships SET active=false WHERE profile_id=p_user_id AND location_id=p_location_id;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_get_menu(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_save_category(text,uuid,uuid,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_save_product(text,uuid,uuid,uuid,text,integer,boolean,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_deactivate_menu_item(text,uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_list_users(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_save_user(text,uuid,uuid,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_deactivate_user(text,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_get_menu(text,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_save_category(text,uuid,uuid,text,integer) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_save_product(text,uuid,uuid,uuid,text,integer,boolean,text,integer) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_deactivate_menu_item(text,uuid,uuid,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_list_users(text,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_save_user(text,uuid,uuid,text,text,text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_deactivate_user(text,uuid,uuid) TO anon,authenticated;
