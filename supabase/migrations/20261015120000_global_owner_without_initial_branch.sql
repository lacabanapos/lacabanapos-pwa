-- Global business-owner session: managing the business must not require a
-- pre-created location. Sessions with a location remain branch-scoped.
ALTER TABLE public.pos_operator_sessions
  ALTER COLUMN location_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS business_id uuid REFERENCES public.businesses(id) ON DELETE CASCADE;

CREATE OR REPLACE FUNCTION public.pos_superadmin_login(p_login text,p_password text)
RETURNS TABLE(session_token text,user_id uuid,username text,display_name text,user_role text,
  location_id uuid,location_name text,business_name text,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,extensions,pg_temp AS $function$
DECLARE v_profile public.profiles%rowtype; v_business record; v_token text; v_exp timestamptz;
BEGIN
  IF length(trim(coalesce(p_login,'')))<3 OR length(coalesce(p_password,''))<1 THEN
    RAISE EXCEPTION 'Correo/usuario o contraseña incorrectos';
  END IF;
  SELECT p.* INTO v_profile FROM public.profiles p
   WHERE p.active AND p.platform_role='SUPERADMIN'
     AND (lower(trim(p.username))=lower(trim(p_login)) OR lower(trim(coalesce(p.recovery_email,'')))=lower(trim(p_login)))
     AND p.password_hash=encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex') LIMIT 1;
  IF v_profile.id IS NULL THEN RAISE EXCEPTION 'Correo/usuario o contraseña incorrectos'; END IF;

  SELECT b.id business_id,b.name business_name INTO v_business
    FROM public.business_memberships bm JOIN public.businesses b ON b.id=bm.business_id AND b.active
   WHERE bm.user_id=v_profile.id AND bm.active AND bm.role IN ('ADMIN','OWNER')
   ORDER BY b.created_at,b.id LIMIT 1;
  IF v_business.business_id IS NULL THEN
    RAISE EXCEPTION 'La cuenta SuperAdmin no está vinculada al negocio. Vincúlala al negocio antes de administrar sucursales.';
  END IF;
  v_token:=encode(extensions.gen_random_bytes(32),'hex'); v_exp:=now()+interval '12 hours';
  INSERT INTO public.pos_operator_sessions(token_hash,profile_id,location_id,business_id,expires_at)
  VALUES(encode(extensions.digest(v_token,'sha256'),'hex'),v_profile.id,NULL,v_business.business_id,v_exp);
  RETURN QUERY SELECT v_token,v_profile.id,v_profile.username,
    coalesce(nullif(v_profile.display_name,''),v_profile.username),'OWNER'::text,
    NULL::uuid,NULL::text,v_business.business_name,v_exp;
END $function$;

CREATE OR REPLACE FUNCTION public.pos_owner_global_context(p_token text)
RETURNS TABLE(user_id uuid,business_id uuid)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path=public,extensions,pg_temp AS $function$
  SELECT p.id,s.business_id FROM public.pos_operator_sessions s
  JOIN public.profiles p ON p.id=s.profile_id AND p.active AND p.platform_role='SUPERADMIN'
  JOIN public.business_memberships bm ON bm.user_id=p.id AND bm.business_id=s.business_id
    AND bm.active AND bm.role IN ('ADMIN','OWNER')
  JOIN public.businesses b ON b.id=s.business_id AND b.active
  WHERE s.token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
    AND s.location_id IS NULL AND s.business_id IS NOT NULL AND s.expires_at>now()
  LIMIT 1
$function$;
REVOKE ALL ON FUNCTION public.pos_owner_global_context(text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.pos_owner_list_business_locations_global(p_token text)
RETURNS TABLE(location_id uuid,location_name text,active boolean,created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record;
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  IF v.user_id IS NULL THEN RAISE EXCEPTION 'Sesión global vencida o sin permisos'; END IF;
  RETURN QUERY SELECT l.id,l.name,l.active,l.created_at FROM public.locations l
    WHERE l.business_id=v.business_id ORDER BY l.created_at,l.name;
END $function$;

CREATE OR REPLACE FUNCTION public.pos_owner_list_terminal_requests_global(p_token text)
RETURNS TABLE(request_id uuid,device_name text,location_id uuid,location_name text,requested_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record;
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  IF v.user_id IS NULL THEN RAISE EXCEPTION 'Sesión global vencida o sin permisos'; END IF;
  RETURN QUERY SELECT r.id,r.device_name,r.location_id,l.name,r.requested_at
    FROM public.pos_terminal_access_requests r JOIN public.locations l ON l.id=r.location_id
   WHERE r.business_id=v.business_id AND r.status='PENDING' AND r.requested_at>now()-interval '24 hours'
   ORDER BY r.requested_at;
END $function$;

CREATE OR REPLACE FUNCTION public.pos_owner_create_location_global(
  p_token text,p_name text,p_admin_password text,p_cashier_password text)
RETURNS TABLE(location_id uuid,location_name text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record; v_location uuid; v_admin uuid; v_cashier uuid; v_name text:=trim(coalesce(p_name,''));
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  IF v.user_id IS NULL THEN RAISE EXCEPTION 'Sesión global vencida o sin permisos'; END IF;
  IF length(v_name) NOT BETWEEN 2 AND 80 THEN RAISE EXCEPTION 'El nombre debe tener entre 2 y 80 caracteres'; END IF;
  IF length(coalesce(p_admin_password,''))<4 OR length(coalesce(p_cashier_password,''))<4 THEN RAISE EXCEPTION 'Las claves iniciales deben tener al menos 4 caracteres'; END IF;
  IF EXISTS(SELECT 1 FROM public.locations l WHERE l.business_id=v.business_id AND lower(trim(l.name))=lower(v_name) AND l.active) THEN
    RAISE EXCEPTION 'Ya existe una sucursal con ese nombre';
  END IF;
  INSERT INTO public.locations(business_id,name,active) VALUES(v.business_id,v_name,true) RETURNING id INTO v_location;
  INSERT INTO public.location_memberships(location_id,profile_id,role,active)
    VALUES(v_location,v.user_id,'ADMIN',true)
    ON CONFLICT ON CONSTRAINT location_memberships_location_id_profile_id_key DO UPDATE SET role='ADMIN',active=true;
  v_admin:=gen_random_uuid(); v_cashier:=gen_random_uuid();
  INSERT INTO public.profiles(id,username,display_name,role,password_hash,active) VALUES
    (v_admin,'admin','Administrador','ADMIN',encode(extensions.digest(p_admin_password||'_cabana_pos_salt','sha256'),'hex'),true),
    (v_cashier,'caja','Caja','CAJA',encode(extensions.digest(p_cashier_password||'_cabana_pos_salt','sha256'),'hex'),true);
  INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES
    (v_location,v_admin,'ADMIN',true),(v_location,v_cashier,'CAJA',true);
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
    VALUES(v.user_id,'LOCATION',v_location,'LOCATION_CREATED_WITH_INITIAL_USERS',jsonb_build_object('business_id',v.business_id));
  RETURN QUERY SELECT v_location,v_name;
END $function$;

CREATE OR REPLACE FUNCTION public.pos_owner_create_pairing_code_global(p_token text,p_target_location_id uuid)
RETURNS TABLE(pairing_code text,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record; v_code text; v_exp timestamptz;
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  IF v.user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.locations l WHERE l.id=p_target_location_id AND l.business_id=v.business_id AND l.active) THEN
    RAISE EXCEPTION 'Sesión o sucursal no autorizada';
  END IF;
  v_code:=upper(encode(extensions.gen_random_bytes(10),'hex')); v_exp:=now()+interval '24 hours';
  INSERT INTO public.pos_location_pairing_codes(code_hash,location_id,business_id,created_by,expires_at)
    VALUES(encode(extensions.digest(v_code,'sha256'),'hex'),p_target_location_id,v.business_id,v.user_id,v_exp);
  RETURN QUERY SELECT v_code,v_exp;
END $function$;

CREATE OR REPLACE FUNCTION public.pos_owner_decide_terminal_request_global(p_token text,p_request_id uuid,p_approve boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record; r public.pos_terminal_access_requests%rowtype;
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  IF v.user_id IS NULL THEN RAISE EXCEPTION 'Sesión global vencida o sin permisos'; END IF;
  SELECT * INTO r FROM public.pos_terminal_access_requests WHERE id=p_request_id AND business_id=v.business_id AND status='PENDING' FOR UPDATE;
  IF r.id IS NULL OR r.requested_at<now()-interval '24 hours' THEN RAISE EXCEPTION 'La solicitud venció o ya fue procesada'; END IF;
  IF p_approve THEN
    IF NOT EXISTS(SELECT 1 FROM public.locations WHERE id=r.location_id AND business_id=v.business_id AND active) THEN RAISE EXCEPTION 'La sucursal de la solicitud ya no está activa'; END IF;
    IF EXISTS(SELECT 1 FROM public.pos_terminal_devices d WHERE d.device_id=r.device_id AND d.active AND d.location_id<>r.location_id) THEN RAISE EXCEPTION 'El equipo ya pertenece a otra sucursal'; END IF;
    INSERT INTO public.pos_terminal_devices(device_id,device_name,location_id,business_id,approved_by)
      VALUES(r.device_id,r.device_name,r.location_id,v.business_id,v.user_id)
      ON CONFLICT(device_id) DO UPDATE SET device_name=excluded.device_name,location_id=excluded.location_id,
        business_id=excluded.business_id,approved_by=excluded.approved_by,approved_at=now(),active=true;
  END IF;
  UPDATE public.pos_terminal_access_requests SET status=CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
    decided_at=now(),decided_by=v.user_id WHERE id=r.id;
  RETURN CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END;
END $function$;

CREATE OR REPLACE FUNCTION public.pos_superadmin_enter_location_global(p_token text,p_target_location_id uuid)
RETURNS TABLE(session_token text,location_id uuid,location_name text,business_name text,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record; l record; t text; exp timestamptz;
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  SELECT x.id,x.name,b.name business_name INTO l FROM public.locations x JOIN public.businesses b ON b.id=x.business_id
   WHERE x.id=p_target_location_id AND x.business_id=v.business_id AND x.active AND b.active;
  IF v.user_id IS NULL OR l.id IS NULL THEN RAISE EXCEPTION 'Sucursal fuera del negocio autorizado o sesión vencida'; END IF;
  INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(l.id,v.user_id,'ADMIN',true)
    ON CONFLICT ON CONSTRAINT location_memberships_location_id_profile_id_key DO UPDATE SET role='ADMIN',active=true;
  t:=encode(extensions.gen_random_bytes(32),'hex'); exp:=now()+interval '12 hours';
  INSERT INTO public.pos_operator_sessions(token_hash,profile_id,location_id,business_id,expires_at)
    VALUES(encode(extensions.digest(t,'sha256'),'hex'),v.user_id,l.id,v.business_id,exp);
  RETURN QUERY SELECT t,l.id,l.name,l.business_name,exp;
END $function$;

CREATE OR REPLACE FUNCTION public.pos_owner_list_location_users_global(p_token text,p_target_location_id uuid)
RETURNS TABLE(user_id uuid,username text,display_name text,user_role text,active boolean)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record;
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  IF v.user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.locations WHERE id=p_target_location_id AND business_id=v.business_id AND active) THEN RAISE EXCEPTION 'Sucursal no autorizada'; END IF;
  RETURN QUERY SELECT p.id,p.username,coalesce(nullif(p.display_name,''),p.username),lm.role,(p.active AND lm.active)
   FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id
   WHERE lm.location_id=p_target_location_id AND coalesce(p.platform_role,'USER')<>'SUPERADMIN' ORDER BY p.username;
END $function$;

CREATE OR REPLACE FUNCTION public.pos_owner_bootstrap_location_users_global(p_token text,p_target_location_id uuid,p_admin_password text,p_cashier_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record; admin_id uuid; cashier_id uuid; created text[]:='{}';
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  IF v.user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.locations WHERE id=p_target_location_id AND business_id=v.business_id AND active) THEN RAISE EXCEPTION 'Sucursal no autorizada'; END IF;
  IF length(coalesce(p_admin_password,''))<4 OR length(coalesce(p_cashier_password,''))<4 THEN RAISE EXCEPTION 'Las claves deben tener al menos 4 caracteres'; END IF;
  SELECT p.id INTO admin_id FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_target_location_id AND lower(p.username)='admin' LIMIT 1;
  IF admin_id IS NULL THEN admin_id:=gen_random_uuid(); INSERT INTO public.profiles(id,username,display_name,role,password_hash,active) VALUES(admin_id,'admin','Administrador','ADMIN',encode(extensions.digest(p_admin_password||'_cabana_pos_salt','sha256'),'hex'),true); INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(p_target_location_id,admin_id,'ADMIN',true); created:=array_append(created,'admin'); END IF;
  SELECT p.id INTO cashier_id FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_target_location_id AND lower(p.username)='caja' LIMIT 1;
  IF cashier_id IS NULL THEN cashier_id:=gen_random_uuid(); INSERT INTO public.profiles(id,username,display_name,role,password_hash,active) VALUES(cashier_id,'caja','Caja','CAJA',encode(extensions.digest(p_cashier_password||'_cabana_pos_salt','sha256'),'hex'),true); INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(p_target_location_id,cashier_id,'CAJA',true); created:=array_append(created,'caja'); END IF;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload) VALUES(v.user_id,'LOCATION',p_target_location_id,'INITIAL_USERS_BOOTSTRAPPED',jsonb_build_object('created_roles',to_jsonb(created)));
  RETURN jsonb_build_object('created',to_jsonb(created),'admin_exists',true,'cashier_exists',true);
END $function$;

CREATE OR REPLACE FUNCTION public.pos_owner_save_location_user_global(p_token text,p_target_location_id uuid,p_user_id uuid,p_username text,p_display_name text,p_role text,p_password text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v record; norm text:=lower(trim(coalesce(p_username,''))); uid uuid:=p_user_id;
BEGIN
  SELECT * INTO v FROM public.pos_owner_global_context(p_token);
  IF v.user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.locations WHERE id=p_target_location_id AND business_id=v.business_id AND active) THEN RAISE EXCEPTION 'Sucursal no autorizada'; END IF;
  IF length(norm) NOT BETWEEN 2 AND 48 OR p_role NOT IN ('ADMIN','CAJA','MESERO','COCINA','ASADOR') THEN RAISE EXCEPTION 'Datos de usuario inválidos'; END IF;
  IF EXISTS(SELECT 1 FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_target_location_id AND lower(trim(p.username))=norm AND p.id IS DISTINCT FROM p_user_id) THEN RAISE EXCEPTION 'Ese usuario ya existe en esta sucursal'; END IF;
  IF p_user_id IS NULL THEN
    IF length(coalesce(p_password,''))<4 THEN RAISE EXCEPTION 'La clave debe tener al menos 4 caracteres'; END IF;
    uid:=gen_random_uuid();
    INSERT INTO public.profiles(id,username,display_name,role,password_hash,active) VALUES(uid,norm,coalesce(nullif(trim(p_display_name),''),norm),p_role,encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex'),true);
  ELSE
    UPDATE public.profiles SET username=norm,display_name=coalesce(nullif(trim(p_display_name),''),norm),role=p_role,active=true,
      password_hash=CASE WHEN coalesce(p_password,'')<>'' THEN encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex') ELSE password_hash END
      WHERE id=p_user_id AND coalesce(platform_role,'USER')<>'SUPERADMIN'
      AND EXISTS(SELECT 1 FROM public.location_memberships WHERE profile_id=p_user_id AND location_id=p_target_location_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado o no editable'; END IF;
  END IF;
  INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(p_target_location_id,uid,p_role,true)
    ON CONFLICT ON CONSTRAINT location_memberships_location_id_profile_id_key DO UPDATE SET role=excluded.role,active=true;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
    VALUES(v.user_id,'PROFILE',uid,CASE WHEN coalesce(p_password,'')<>'' THEN 'OWNER_CREDENTIAL_RESET' ELSE 'OWNER_PROFILE_SAVED' END,
      jsonb_build_object('location_id',p_target_location_id,'username',norm,'role',p_role,'password_changed',coalesce(p_password,'')<>''));
  RETURN uid;
END $function$;

REVOKE ALL ON FUNCTION public.pos_superadmin_login(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_superadmin_login(text,text) TO anon,authenticated;
REVOKE ALL ON FUNCTION public.pos_owner_list_business_locations_global(text),public.pos_owner_list_terminal_requests_global(text),
 public.pos_owner_create_location_global(text,text,text,text),public.pos_owner_create_pairing_code_global(text,uuid),
 public.pos_owner_decide_terminal_request_global(text,uuid,boolean),public.pos_superadmin_enter_location_global(text,uuid),
 public.pos_owner_list_location_users_global(text,uuid),public.pos_owner_bootstrap_location_users_global(text,uuid,text,text),
 public.pos_owner_save_location_user_global(text,uuid,uuid,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_owner_list_business_locations_global(text),public.pos_owner_list_terminal_requests_global(text),
 public.pos_owner_create_location_global(text,text,text,text),public.pos_owner_create_pairing_code_global(text,uuid),
 public.pos_owner_decide_terminal_request_global(text,uuid,boolean),public.pos_superadmin_enter_location_global(text,uuid),
 public.pos_owner_list_location_users_global(text,uuid),public.pos_owner_bootstrap_location_users_global(text,uuid,text,text),
 public.pos_owner_save_location_user_global(text,uuid,uuid,text,text,text,text) TO anon,authenticated;
