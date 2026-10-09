CREATE OR REPLACE FUNCTION public.pos_resolve_cashier(p_token text,p_location_id uuid,p_username text)
RETURNS TABLE(user_id uuid,username text,user_role text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_normalized text;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión sin permiso para resolver cajero'; END IF;
  v_normalized:=lower(regexp_replace(trim(coalesce(p_username,'')),'\s+','_','g'));
  RETURN QUERY WITH candidates AS MATERIALIZED (
    SELECT p.id,p.username,lm.role
    FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id
    WHERE lm.location_id=p_location_id AND lm.active AND p.active
      AND lower(regexp_replace(trim(p.username),'\s+','_','g'))=v_normalized
  )
  SELECT c.id,c.username,c.role FROM candidates c WHERE (SELECT count(*) FROM candidates)=1;
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_resolve_cashier(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_resolve_cashier(text,uuid,text) TO anon,authenticated;
