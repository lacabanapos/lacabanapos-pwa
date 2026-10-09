-- profiles.id has no database default; allocate it explicitly when creating an operator.
CREATE OR REPLACE FUNCTION public.pos_admin_save_user(
  p_token text,p_location_id uuid,p_user_id uuid,p_username text,p_display_name text,p_role text,p_password text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_id uuid; v_hash text;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede editar usuarios'; END IF;
  IF length(trim(coalesce(p_username,''))) NOT BETWEEN 2 AND 48 OR p_role NOT IN ('OWNER','ADMIN','CAJA','MESERO','COCINA','ASADOR') THEN RAISE EXCEPTION 'Datos de usuario inválidos'; END IF;
  IF EXISTS(SELECT 1 FROM public.profiles WHERE lower(username)=lower(trim(p_username)) AND id IS DISTINCT FROM p_user_id) THEN RAISE EXCEPTION 'Ese usuario ya existe'; END IF;
  IF p_user_id IS NULL THEN
    IF length(coalesce(p_password,''))<4 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 4 caracteres'; END IF;
    v_id:=gen_random_uuid();
    v_hash:=encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex');
    INSERT INTO public.profiles(id,username,display_name,role,password_hash,active)
    VALUES(v_id,lower(trim(p_username)),coalesce(nullif(trim(p_display_name),''),trim(p_username)),p_role,v_hash,true);
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
