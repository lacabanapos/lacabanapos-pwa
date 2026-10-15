-- A business OWNER may use the same global branch-management flow as a
-- platform SuperAdmin, while ordinary location admins remain branch-scoped.
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
   WHERE p.active
     AND (lower(trim(p.username))=lower(trim(p_login)) OR lower(trim(coalesce(p.recovery_email,'')))=lower(trim(p_login)))
     AND p.password_hash=encode(extensions.digest(p_password||'_cabana_pos_salt','sha256'),'hex')
     AND (p.platform_role='SUPERADMIN' OR EXISTS(
       SELECT 1 FROM public.business_memberships bm WHERE bm.user_id=p.id AND bm.active AND bm.role='OWNER'
     ))
  LIMIT 1;
  IF v_profile.id IS NULL THEN RAISE EXCEPTION 'Correo/usuario o contraseña incorrectos'; END IF;

  SELECT b.id business_id,b.name business_name INTO v_business
    FROM public.business_memberships bm JOIN public.businesses b ON b.id=bm.business_id AND b.active
   WHERE bm.user_id=v_profile.id AND bm.active AND bm.role IN ('ADMIN','OWNER')
   ORDER BY CASE WHEN bm.role='OWNER' THEN 0 ELSE 1 END,b.created_at,b.id LIMIT 1;
  IF v_business.business_id IS NULL THEN RAISE EXCEPTION 'La cuenta no está vinculada a un negocio activo.'; END IF;
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
  JOIN public.profiles p ON p.id=s.profile_id AND p.active
  JOIN public.business_memberships bm ON bm.user_id=p.id AND bm.business_id=s.business_id
    AND bm.active AND bm.role IN ('ADMIN','OWNER')
  JOIN public.businesses b ON b.id=s.business_id AND b.active
  WHERE s.token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex')
    AND s.location_id IS NULL AND s.business_id IS NOT NULL AND s.expires_at>now()
    AND (p.platform_role='SUPERADMIN' OR bm.role='OWNER')
  LIMIT 1
$function$;

REVOKE ALL ON FUNCTION public.pos_superadmin_login(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_superadmin_login(text,text) TO anon,authenticated;
REVOKE ALL ON FUNCTION public.pos_owner_global_context(text) FROM PUBLIC,anon,authenticated;
