CREATE OR REPLACE FUNCTION public.pos_admin_correct_attendance(
  p_token text,p_location_id uuid,p_record_id text,p_new_type text,p_reason text
) RETURNS public.attendance_records LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_record public.attendance_records%rowtype; v_previous text; v_next text; v_old_type text;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede corregir asistencia'; END IF;
  IF p_new_type NOT IN ('ENTRY','EXIT') OR length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Tipo o motivo de corrección inválido'; END IF;
  SELECT * INTO v_record FROM public.attendance_records WHERE (id::text=p_record_id OR client_event_id=p_record_id) AND location_id=p_location_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe esa marcación en esta sucursal'; END IF;
  SELECT ar.type INTO v_previous FROM public.attendance_records ar WHERE ar.user_id=v_record.user_id AND ar.location_id=p_location_id
    AND (ar.recorded_at,ar.id)<(v_record.recorded_at,v_record.id) ORDER BY ar.recorded_at DESC,ar.id DESC LIMIT 1;
  SELECT ar.type INTO v_next FROM public.attendance_records ar WHERE ar.user_id=v_record.user_id AND ar.location_id=p_location_id
    AND (ar.recorded_at,ar.id)>(v_record.recorded_at,v_record.id) ORDER BY ar.recorded_at,ar.id LIMIT 1;
  IF (p_new_type='ENTRY' AND v_previous='ENTRY') OR (p_new_type='EXIT' AND coalesce(v_previous,'')<>'ENTRY')
    OR (p_new_type='ENTRY' AND v_next='ENTRY') OR (p_new_type='EXIT' AND v_next='EXIT') THEN RAISE EXCEPTION 'La corrección dejaría una secuencia de entrada/salida inconsistente'; END IF;
  v_old_type:=v_record.type;
  UPDATE public.attendance_records SET type=p_new_type,status='CORRECTED',correction_reason=trim(p_reason),corrected_by=v_operator.user_id,corrected_at=now()
  WHERE id=v_record.id RETURNING * INTO v_record;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
  VALUES(v_operator.user_id,'attendance_record',v_record.id,'ATTENDANCE_CORRECTED',jsonb_build_object('location_id',p_location_id,'from',v_old_type,'to',p_new_type,'reason',trim(p_reason),'recorded_at',v_record.recorded_at));
  RETURN v_record;
END;
$function$;
