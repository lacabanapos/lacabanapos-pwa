CREATE OR REPLACE FUNCTION public.pos_get_last_attendance(p_token text,p_location_id uuid,p_user_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_type text;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_id<>p_user_id THEN RAISE EXCEPTION 'Sesión inválida para consultar asistencia'; END IF;
  SELECT ar.type INTO v_type FROM public.attendance_records ar WHERE ar.user_id=p_user_id AND ar.location_id=p_location_id
    ORDER BY ar.recorded_at DESC,ar.id DESC LIMIT 1;
  RETURN v_type;
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
    AND q.expires_at>clock_timestamp() AND q.code_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex')) THEN
    RAISE EXCEPTION 'El QR venció. Escanea el código actual del POS.';
  END IF;
  IF p_latitude IS NULL OR p_longitude IS NULL OR p_accuracy IS NULL OR p_accuracy<0 THEN RAISE EXCEPTION 'Activa ubicación y vuelve a intentar'; END IF;
  SELECT * INTO v_existing FROM public.attendance_records WHERE client_event_id=p_client_event_id;
  IF FOUND THEN
    IF v_existing.user_id<>v_operator.user_id OR v_existing.location_id<>p_location_id THEN RAISE EXCEPTION 'Identificador de marcación ya utilizado'; END IF;
    RETURN jsonb_build_object('success',true,'type',v_existing.type,'recorded_at',v_existing.recorded_at,'duplicate',true);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_operator.user_id::text||p_location_id::text,0));
  SELECT ar.type INTO v_last FROM public.attendance_records ar WHERE ar.user_id=v_operator.user_id AND ar.location_id=p_location_id
    ORDER BY ar.recorded_at DESC,ar.id DESC LIMIT 1;
  IF (p_type='ENTRY' AND v_last='ENTRY') OR (p_type='EXIT' AND coalesce(v_last,'')<>'ENTRY') THEN RAISE EXCEPTION 'La marcación no coincide con el último estado de asistencia'; END IF;
  INSERT INTO public.attendance_records(user_id,location_id,type,device_id,client_event_id,latitude,longitude,accuracy,status,recorded_at)
  VALUES(v_operator.user_id,p_location_id,p_type,p_device_id,p_client_event_id,p_latitude,p_longitude,p_accuracy,'SYNCED',clock_timestamp()) RETURNING * INTO v_record;
  RETURN jsonb_build_object('success',true,'type',v_record.type,'recorded_at',v_record.recorded_at);
END;
$function$;
