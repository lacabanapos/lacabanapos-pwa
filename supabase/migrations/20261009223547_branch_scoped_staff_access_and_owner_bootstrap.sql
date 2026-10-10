-- Branch-scoped POS identities, safe first-account provisioning, and owner
-- administration. Passwords keep the existing SHA-256 compatibility format.

DROP INDEX IF EXISTS public.idx_profiles_username;
DROP INDEX IF EXISTS public.profiles_username_unique;

ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_role_check
  CHECK (role = ANY (ARRAY['ADMIN','CAJA','MESERO','COCINA','ASADOR']::text[]));
ALTER TABLE public.location_memberships DROP CONSTRAINT IF EXISTS location_memberships_role_check;
ALTER TABLE public.location_memberships ADD CONSTRAINT location_memberships_role_check
  CHECK (role = ANY (ARRAY['ADMIN','CAJA','MESERO','COCINA','ASADOR']::text[]));

-- Production already uses the privacy-preserving, opaque-ID roster contract.
-- Drop first because PostgreSQL cannot change OUT columns with CREATE OR REPLACE.
DROP FUNCTION IF EXISTS public.get_location_users(uuid);
CREATE FUNCTION public.get_location_users(p_location_id uuid)
RETURNS TABLE(user_id uuid, display_name text)
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT p.id, coalesce(nullif(p.display_name,''),'Personal')
  FROM public.location_memberships lm
  JOIN public.profiles p ON p.id=lm.profile_id
  WHERE lm.location_id=p_location_id AND lm.active AND p.active
  ORDER BY coalesce(nullif(p.display_name,''),'Personal');
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_list_users(p_token text,p_location_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE v_operator record; v_users jsonb;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede consultar usuarios'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('user_id',p.id,'username',p.username,'display_name',p.display_name,
    'user_role',lm.role,'active',p.active AND lm.active) ORDER BY p.username),'[]'::jsonb)
    INTO v_users FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id
   WHERE lm.location_id=p_location_id AND coalesce(p.platform_role,'USER') <> 'SUPERADMIN';
  RETURN v_users;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_save_user(
  p_token text,p_location_id uuid,p_user_id uuid,p_username text,p_display_name text,p_role text,p_password text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_id uuid; v_norm text; v_hash text; v_existing public.profiles%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede editar usuarios'; END IF;
  v_norm:=lower(trim(coalesce(p_username,'')));
  IF length(v_norm) NOT BETWEEN 2 AND 48 OR p_role NOT IN ('ADMIN','CAJA','MESERO','COCINA','ASADOR') THEN RAISE EXCEPTION 'Datos de usuario inválidos'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_location_id::text),hashtext(v_norm));
  IF EXISTS(SELECT 1 FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id
    WHERE lm.location_id=p_location_id AND lower(trim(p.username))=v_norm AND p.id IS DISTINCT FROM p_user_id) THEN
    RAISE EXCEPTION 'Ese nombre de usuario ya existe en esta sucursal';
  END IF;
  IF p_user_id IS NULL THEN
    IF length(coalesce(p_password,''))<4 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 4 caracteres'; END IF;
    v_id:=gen_random_uuid();
    v_hash:=encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex');
    INSERT INTO public.profiles(id,username,display_name,role,password_hash,active)
      VALUES(v_id,v_norm,coalesce(nullif(trim(p_display_name),''),v_norm),p_role,v_hash,true);
  ELSE
    SELECT p.* INTO v_existing FROM public.profiles p JOIN public.location_memberships lm ON lm.profile_id=p.id
      WHERE p.id=p_user_id AND lm.location_id=p_location_id AND coalesce(p.platform_role,'USER') <> 'SUPERADMIN' FOR UPDATE OF p;
    IF v_existing.id IS NULL THEN RAISE EXCEPTION 'Usuario no encontrado en esta sucursal'; END IF;
    IF EXISTS(SELECT 1 FROM public.location_memberships WHERE profile_id=p_user_id AND active AND location_id<>p_location_id) THEN
      RAISE EXCEPTION 'La cuenta se comparte con otra sucursal; no se puede cambiar su identidad o clave desde aquí';
    END IF;
    v_id:=p_user_id;
    IF coalesce(p_password,'')<>'' THEN
      IF length(p_password)<4 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 4 caracteres'; END IF;
      v_hash:=encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex');
      UPDATE public.profiles SET username=v_norm,display_name=coalesce(nullif(trim(p_display_name),''),v_norm),role=p_role,password_hash=v_hash,active=true WHERE id=v_id;
    ELSE
      UPDATE public.profiles SET username=v_norm,display_name=coalesce(nullif(trim(p_display_name),''),v_norm),role=p_role,active=true WHERE id=v_id;
    END IF;
  END IF;
  INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(p_location_id,v_id,p_role,true)
    ON CONFLICT(location_id,profile_id) DO UPDATE SET role=excluded.role,active=true;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
    VALUES(v_operator.user_id,'PROFILE',v_id,CASE WHEN coalesce(p_password,'')<>'' THEN 'CREDENTIAL_OR_PROFILE_UPDATED' ELSE 'PROFILE_UPDATED' END,
      jsonb_build_object('location_id',p_location_id,'username',v_norm,'role',p_role,'password_changed',coalesce(p_password,'')<>''));
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_create_location_with_users(
  p_token text,p_location_id uuid,p_name text,p_admin_password text,p_cashier_password text
) RETURNS TABLE(location_id uuid,location_name text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_business_id uuid; v_new_location uuid; v_admin uuid; v_cashier uuid;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  SELECT l.business_id INTO v_business_id FROM public.locations l WHERE l.id=p_location_id AND l.active;
  IF v_operator.user_id IS NULL OR v_operator.user_role<>'ADMIN' OR NOT EXISTS(
    SELECT 1 FROM public.business_memberships bm WHERE bm.business_id=v_business_id AND bm.user_id=v_operator.user_id AND bm.active AND bm.role='ADMIN'
  ) THEN RAISE EXCEPTION 'Solo el propietario puede crear sucursales'; END IF;
  IF length(trim(coalesce(p_name,''))) NOT BETWEEN 2 AND 80 THEN RAISE EXCEPTION 'El nombre debe tener entre 2 y 80 caracteres'; END IF;
  IF length(coalesce(p_admin_password,''))<4 OR length(coalesce(p_cashier_password,''))<4 THEN RAISE EXCEPTION 'Los PIN deben tener al menos 4 caracteres'; END IF;
  IF EXISTS(SELECT 1 FROM public.locations l WHERE l.business_id=v_business_id AND lower(trim(l.name))=lower(trim(p_name)) AND l.active) THEN RAISE EXCEPTION 'Ya existe una sucursal con ese nombre'; END IF;
  INSERT INTO public.locations(business_id,name,active) VALUES(v_business_id,trim(p_name),true) RETURNING id INTO v_new_location;
  INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(v_new_location,v_operator.user_id,'ADMIN',true)
    ON CONFLICT ON CONSTRAINT location_memberships_location_id_profile_id_key DO UPDATE SET role='ADMIN',active=true;
  v_admin:=gen_random_uuid(); v_cashier:=gen_random_uuid();
  INSERT INTO public.profiles(id,username,display_name,role,password_hash,active) VALUES
    (v_admin,'admin','Administrador','ADMIN',encode(extensions.digest(p_admin_password||'_cabana_pos_salt','sha256'),'hex'),true),
    (v_cashier,'caja','Caja','CAJA',encode(extensions.digest(p_cashier_password||'_cabana_pos_salt','sha256'),'hex'),true);
  INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES
    (v_new_location,v_admin,'ADMIN',true),(v_new_location,v_cashier,'CAJA',true);
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
    VALUES(v_operator.user_id,'LOCATION',v_new_location,'LOCATION_CREATED_WITH_INITIAL_USERS',jsonb_build_object('business_id',v_business_id,'initial_roles',jsonb_build_array('ADMIN','CAJA')));
  RETURN QUERY SELECT v_new_location,trim(p_name);
END;
$function$;

-- Keep the old RPC signature working for already-installed PWA versions.
CREATE OR REPLACE FUNCTION public.pos_admin_create_location(p_token text,p_location_id uuid,p_name text)
RETURNS TABLE(location_id uuid,location_name text)
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
  SELECT * FROM public.pos_admin_create_location_with_users(p_token,p_location_id,p_name,'123456','1234');
$function$;

CREATE OR REPLACE FUNCTION public.pos_owner_list_location_users(p_token text,p_current_location_id uuid,p_target_location_id uuid)
RETURNS TABLE(user_id uuid,username text,display_name text,user_role text,active boolean)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_business uuid;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_current_location_id);
  IF v_operator.user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=v_operator.user_id AND p.active AND p.platform_role='SUPERADMIN') THEN
    RAISE EXCEPTION 'Se requiere la sesión de superadministrador';
  END IF;
  SELECT l.business_id INTO v_business FROM public.locations l JOIN public.business_memberships bm ON bm.business_id=l.business_id
    WHERE l.id=p_current_location_id AND l.active AND bm.user_id=v_operator.user_id AND bm.active AND bm.role IN ('ADMIN','OWNER');
  IF v_business IS NULL OR NOT EXISTS(SELECT 1 FROM public.locations l WHERE l.id=p_target_location_id AND l.business_id=v_business AND l.active) THEN RAISE EXCEPTION 'Sucursal fuera del negocio autorizado'; END IF;
  RETURN QUERY SELECT p.id,p.username,coalesce(nullif(p.display_name,''),p.username),lm.role,(p.active AND lm.active)
    FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id
    WHERE lm.location_id=p_target_location_id AND coalesce(p.platform_role,'USER')<>'SUPERADMIN' ORDER BY p.username;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_owner_bootstrap_location_users(
 p_token text,p_current_location_id uuid,p_target_location_id uuid,p_admin_password text,p_cashier_password text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_business uuid; v_admin uuid; v_cashier uuid; v_created text[]:='{}';
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_current_location_id);
  IF v_operator.user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=v_operator.user_id AND p.active AND p.platform_role='SUPERADMIN') THEN RAISE EXCEPTION 'Se requiere la sesión de superadministrador'; END IF;
  SELECT l.business_id INTO v_business FROM public.locations l JOIN public.business_memberships bm ON bm.business_id=l.business_id
    WHERE l.id=p_current_location_id AND l.active AND bm.user_id=v_operator.user_id AND bm.active AND bm.role IN ('ADMIN','OWNER');
  IF v_business IS NULL OR NOT EXISTS(SELECT 1 FROM public.locations l WHERE l.id=p_target_location_id AND l.business_id=v_business AND l.active) THEN RAISE EXCEPTION 'Sucursal fuera del negocio autorizado'; END IF;
  IF length(coalesce(p_admin_password,''))<4 OR length(coalesce(p_cashier_password,''))<4 THEN RAISE EXCEPTION 'Los PIN deben tener al menos 4 caracteres'; END IF;
  SELECT p.id INTO v_admin FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_target_location_id AND lower(p.username)='admin' LIMIT 1;
  IF v_admin IS NULL THEN
    v_admin:=gen_random_uuid(); INSERT INTO public.profiles(id,username,display_name,role,password_hash,active) VALUES(v_admin,'admin','Administrador','ADMIN',encode(extensions.digest(p_admin_password||'_cabana_pos_salt','sha256'),'hex'),true);
    INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(p_target_location_id,v_admin,'ADMIN',true); v_created:=array_append(v_created,'admin');
  END IF;
  SELECT p.id INTO v_cashier FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_target_location_id AND lower(p.username)='caja' LIMIT 1;
  IF v_cashier IS NULL THEN
    v_cashier:=gen_random_uuid(); INSERT INTO public.profiles(id,username,display_name,role,password_hash,active) VALUES(v_cashier,'caja','Caja','CAJA',encode(extensions.digest(p_cashier_password||'_cabana_pos_salt','sha256'),'hex'),true);
    INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(p_target_location_id,v_cashier,'CAJA',true); v_created:=array_append(v_created,'caja');
  END IF;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload) VALUES(v_operator.user_id,'LOCATION',p_target_location_id,'INITIAL_USERS_BOOTSTRAPPED',jsonb_build_object('created_roles',to_jsonb(v_created)));
  RETURN jsonb_build_object('created',to_jsonb(v_created),'admin_exists',true,'cashier_exists',true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_owner_save_location_user(
 p_token text,p_current_location_id uuid,p_target_location_id uuid,p_user_id uuid,p_username text,p_display_name text,p_role text,p_password text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_business uuid; v_id uuid; v_norm text; v_shared boolean;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_current_location_id);
  IF v_operator.user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=v_operator.user_id AND p.active AND p.platform_role='SUPERADMIN') THEN RAISE EXCEPTION 'Se requiere la sesión de superadministrador'; END IF;
  SELECT l.business_id INTO v_business FROM public.locations l JOIN public.business_memberships bm ON bm.business_id=l.business_id
    WHERE l.id=p_current_location_id AND l.active AND bm.user_id=v_operator.user_id AND bm.active AND bm.role IN ('ADMIN','OWNER');
  IF v_business IS NULL OR NOT EXISTS(SELECT 1 FROM public.locations l WHERE l.id=p_target_location_id AND l.business_id=v_business AND l.active) THEN RAISE EXCEPTION 'Sucursal fuera del negocio autorizado'; END IF;
  v_norm:=lower(trim(coalesce(p_username,'')));
  IF length(v_norm) NOT BETWEEN 2 AND 48 OR p_role NOT IN ('ADMIN','CAJA','MESERO','COCINA','ASADOR') THEN RAISE EXCEPTION 'Datos de usuario inválidos'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_target_location_id::text),hashtext(v_norm));
  IF EXISTS(SELECT 1 FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_target_location_id AND lower(trim(p.username))=v_norm AND p.id IS DISTINCT FROM p_user_id) THEN RAISE EXCEPTION 'Ese usuario ya existe en esta sucursal'; END IF;
  IF p_user_id IS NULL THEN
    IF length(coalesce(p_password,''))<4 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 4 caracteres'; END IF;
    v_id:=gen_random_uuid();
    INSERT INTO public.profiles(id,username,display_name,role,password_hash,active) VALUES(v_id,v_norm,coalesce(nullif(trim(p_display_name),''),v_norm),p_role,encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex'),true);
  ELSE
    SELECT EXISTS(SELECT 1 FROM public.location_memberships WHERE profile_id=p_user_id AND active AND location_id<>p_target_location_id) INTO v_shared;
    IF v_shared THEN RAISE EXCEPTION 'La cuenta se comparte con otra sucursal; primero debe separarse'; END IF;
    UPDATE public.profiles SET username=v_norm,display_name=coalesce(nullif(trim(p_display_name),''),v_norm),role=p_role,active=true,
      password_hash=CASE WHEN coalesce(p_password,'')<>'' THEN encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex') ELSE password_hash END
      WHERE id=p_user_id AND coalesce(platform_role,'USER')<>'SUPERADMIN' AND EXISTS(SELECT 1 FROM public.location_memberships lm WHERE lm.profile_id=profiles.id AND lm.location_id=p_target_location_id);
    IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado o no editable'; END IF;
    v_id:=p_user_id;
  END IF;
  INSERT INTO public.location_memberships(location_id,profile_id,role,active) VALUES(p_target_location_id,v_id,p_role,true)
    ON CONFLICT(location_id,profile_id) DO UPDATE SET role=excluded.role,active=true;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload) VALUES(v_operator.user_id,'PROFILE',v_id,
    CASE WHEN coalesce(p_password,'')<>'' THEN 'OWNER_CREDENTIAL_RESET' ELSE 'OWNER_PROFILE_SAVED' END,
    jsonb_build_object('location_id',p_target_location_id,'username',v_norm,'role',p_role,'password_changed',coalesce(p_password,'')<>''));
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_sync_local_password_hash(p_token text,p_location_id uuid,p_user_id uuid,p_password_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede conservar claves locales'; END IF;
  IF coalesce(p_password_hash,'') !~ '^[0-9a-fA-F]{64}$' THEN RAISE EXCEPTION 'Hash local inválido'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_location_id AND lm.profile_id=p_user_id AND coalesce(p.platform_role,'USER')<>'SUPERADMIN') THEN RAISE EXCEPTION 'Usuario ajeno a esta sucursal'; END IF;
  IF EXISTS(SELECT 1 FROM public.location_memberships WHERE profile_id=p_user_id AND active AND location_id<>p_location_id) THEN RAISE EXCEPTION 'No se puede copiar una clave de una cuenta compartida'; END IF;
  UPDATE public.profiles SET password_hash=lower(p_password_hash) WHERE id=p_user_id AND coalesce(platform_role,'USER')<>'SUPERADMIN';
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload) VALUES(v_operator.user_id,'PROFILE',p_user_id,'LOCAL_CREDENTIAL_HASH_IMPORTED',jsonb_build_object('location_id',p_location_id,'hash_not_recorded',true));
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_get_login_users(p_location_id uuid,p_device_id text)
RETURNS TABLE(user_id uuid,username text,display_name text,user_role text)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.pos_terminal_devices d WHERE d.device_id=trim(coalesce(p_device_id,'')) AND d.location_id=p_location_id AND d.active) THEN
    RAISE EXCEPTION 'Este POS no está aprobado para consultar usuarios de esta sucursal';
  END IF;
  RETURN QUERY SELECT p.id,p.username,coalesce(nullif(p.display_name,''),p.username),lm.role FROM public.location_memberships lm
    JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_location_id AND lm.active AND p.active
      AND coalesce(p.platform_role,'USER')<>'SUPERADMIN'
    ORDER BY CASE lm.role WHEN 'ADMIN' THEN 1 WHEN 'CAJA' THEN 2 WHEN 'MESERO' THEN 3 WHEN 'COCINA' THEN 4 ELSE 5 END,p.username;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_location_users(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_list_users(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_save_user(text,uuid,uuid,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_create_location_with_users(text,uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_create_location(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_owner_list_location_users(text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_owner_bootstrap_location_users(text,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_owner_save_location_user(text,uuid,uuid,uuid,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_sync_local_password_hash(text,uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_login_users(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_location_users(uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_list_users(text,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_save_user(text,uuid,uuid,text,text,text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_create_location_with_users(text,uuid,text,text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_create_location(text,uuid,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_owner_list_location_users(text,uuid,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_owner_bootstrap_location_users(text,uuid,uuid,text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_owner_save_location_user(text,uuid,uuid,uuid,text,text,text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_sync_local_password_hash(text,uuid,uuid,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_login_users(uuid,text) TO anon,authenticated;

