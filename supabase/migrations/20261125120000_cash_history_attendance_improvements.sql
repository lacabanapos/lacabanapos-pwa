-- Cash reconciliation, audited payment corrections, history archiving, optional receipt identity,
-- and GPS-based attendance without a fixed store geofence.
ALTER TABLE public.cash_sessions
  ADD COLUMN IF NOT EXISTS counted_transfer_cents integer,
  ADD COLUMN IF NOT EXISTS transfer_difference_cents integer;
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS customer_document_type text,
  ADD COLUMN IF NOT EXISTS customer_document_number text;

CREATE TABLE IF NOT EXISTS public.history_day_archives (
  location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE CASCADE,
  business_date date NOT NULL,
  archived_by uuid NOT NULL REFERENCES public.profiles(id),
  archived_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(location_id,business_date)
);
ALTER TABLE public.history_day_archives ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.history_day_archives FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.pos_close_cash_session_reconciled(
  p_token text,p_location_id uuid,p_session_id uuid,p_counted_cash_cents integer,
  p_counted_transfer_cents integer,p_carryover_cents integer,p_detail jsonb DEFAULT '{}'::jsonb
) RETURNS public.cash_sessions
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_session public.cash_sessions%rowtype; v_expected_cash integer; v_expected_transfer integer;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión o permiso de caja inválido'; END IF;
  IF p_counted_cash_cents<0 OR p_counted_transfer_cents<0 OR p_carryover_cents<0 OR p_carryover_cents>p_counted_cash_cents THEN RAISE EXCEPTION 'Conteo o fondo dejado inválido'; END IF;
  SELECT * INTO v_session FROM public.cash_sessions WHERE id=p_session_id AND location_id=p_location_id AND status='OPEN' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La caja no existe o ya fue cerrada'; END IF;
  v_expected_cash:=v_session.opening_cents+v_session.cash_sales_cents-v_session.expenses_cents-v_session.cash_refunds_cents;
  v_expected_transfer:=v_session.transfer_sales_cents-v_session.transfer_refunds_cents;
  UPDATE public.cash_sessions SET status='CLOSED',closed_at=now(),closed_by=v_operator.user_id,counted_cents=p_counted_cash_cents,
    counted_transfer_cents=p_counted_transfer_cents,transfer_difference_cents=p_counted_transfer_cents-v_expected_transfer,
    carryover_cents=p_carryover_cents,delivered_cents=p_counted_cash_cents-p_carryover_cents,
    difference_cents=(p_counted_cash_cents-v_expected_cash)+(p_counted_transfer_cents-v_expected_transfer),
    counted_detail_json=coalesce(p_detail,'{}'::jsonb) WHERE id=p_session_id RETURNING * INTO v_session;
  RETURN v_session;
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_close_cash_session_reconciled(text,uuid,uuid,integer,integer,integer,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_close_cash_session_reconciled(text,uuid,uuid,integer,integer,integer,jsonb) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.pos_correct_ticket_payment_method(
  p_token text,p_location_id uuid,p_ticket_id uuid,p_payment_method text,p_reason text
) RETURNS public.tickets LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_ticket public.tickets%rowtype; v_old text; v_session_id uuid;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede corregir pagos'; END IF;
  IF p_payment_method NOT IN ('CASH','TRANSFER') OR length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Método o motivo de corrección inválido'; END IF;
  SELECT * INTO v_ticket FROM public.tickets WHERE id=p_ticket_id AND location_id=p_location_id FOR UPDATE;
  IF NOT FOUND OR v_ticket.status<>'PAID' OR v_ticket.cash_session_id IS NULL THEN RAISE EXCEPTION 'No se encontró un cobro válido'; END IF;
  IF EXISTS(SELECT 1 FROM public.pos_refunds WHERE ticket_id=v_ticket.id) THEN RAISE EXCEPTION 'No se puede corregir un ticket devuelto'; END IF;
  v_old:=v_ticket.payment_method; v_session_id:=v_ticket.cash_session_id;
  IF v_old=p_payment_method THEN RETURN v_ticket; END IF;
  IF v_old NOT IN ('CASH','TRANSFER') THEN RAISE EXCEPTION 'El método original no puede conciliarse automáticamente'; END IF;
  IF v_old='CASH' THEN
    UPDATE public.cash_sessions SET cash_sales_cents=cash_sales_cents-v_ticket.total_cents,transfer_sales_cents=transfer_sales_cents+v_ticket.total_cents WHERE id=v_session_id;
  ELSE
    UPDATE public.cash_sessions SET transfer_sales_cents=transfer_sales_cents-v_ticket.total_cents,cash_sales_cents=cash_sales_cents+v_ticket.total_cents WHERE id=v_session_id;
  END IF;
  UPDATE public.tickets SET payment_method=p_payment_method WHERE id=v_ticket.id RETURNING * INTO v_ticket;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
  VALUES(v_operator.user_id,'ticket',v_ticket.id,'PAYMENT_METHOD_CORRECTED',jsonb_build_object('from',v_old,'to',p_payment_method,'reason',trim(p_reason),'cash_session_id',v_session_id,'total_cents',v_ticket.total_cents));
  RETURN v_ticket;
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_correct_ticket_payment_method(text,uuid,uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_correct_ticket_payment_method(text,uuid,uuid,text,text) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.pos_save_ticket_customer_details(
  p_token text,p_location_id uuid,p_ticket_id uuid,p_customer_name text,p_document_type text,p_document_number text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión o permiso de caja inválido'; END IF;
  IF coalesce(length(trim(p_customer_name)),0)>120 OR coalesce(length(trim(p_document_number)),0)>30 OR coalesce(p_document_type,'') NOT IN ('','CEDULA','RUC','PASAPORTE') THEN RAISE EXCEPTION 'Datos de cliente inválidos'; END IF;
  UPDATE public.tickets SET customer_document_type=nullif(trim(p_document_type),''),customer_document_number=nullif(trim(p_document_number),'')
  WHERE id=p_ticket_id AND location_id=p_location_id AND status='PAID';
  IF NOT FOUND THEN RAISE EXCEPTION 'El cobro no existe en esta sucursal'; END IF;
  IF nullif(trim(p_customer_name),'') IS NOT NULL THEN UPDATE public.orders SET customer_name=trim(p_customer_name) WHERE id=(SELECT order_id FROM public.tickets WHERE id=p_ticket_id); END IF;
  RETURN true;
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_save_ticket_customer_details(text,uuid,uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_save_ticket_customer_details(text,uuid,uuid,text,text,text) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.pos_archive_history_day(p_token text,p_location_id uuid,p_business_date date)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede archivar historial'; END IF;
  IF p_business_date IS NULL OR p_business_date>=((now() AT TIME ZONE 'America/Guayaquil')::date) THEN RAISE EXCEPTION 'Solo se pueden archivar días anteriores'; END IF;
  INSERT INTO public.history_day_archives(location_id,business_date,archived_by) VALUES(p_location_id,p_business_date,v_operator.user_id)
  ON CONFLICT(location_id,business_date) DO UPDATE SET archived_by=excluded.archived_by,archived_at=now();
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
  VALUES(v_operator.user_id,'history_day',p_location_id,'HISTORY_DAY_ARCHIVED',jsonb_build_object('business_date',p_business_date));
  RETURN true;
END;
$function$;
CREATE OR REPLACE FUNCTION public.pos_get_archived_history_days(p_token text,p_location_id uuid)
RETURNS TABLE(business_date date,archived_at timestamptz,archived_by_username text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA','MESERO') THEN RAISE EXCEPTION 'Sesión sin acceso al historial'; END IF;
  RETURN QUERY SELECT a.business_date,a.archived_at,p.username FROM public.history_day_archives a JOIN public.profiles p ON p.id=a.archived_by
  WHERE a.location_id=p_location_id ORDER BY a.business_date DESC;
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_archive_history_day(text,uuid,date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_archived_history_days(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_archive_history_day(text,uuid,date) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_archived_history_days(text,uuid) TO anon,authenticated;

-- Fixed business geofences are no longer part of attendance. GPS and QR remain required;
-- optional device binding and accuracy check remain active.
CREATE OR REPLACE FUNCTION public.pos_get_attendance_settings(p_token text,p_location_id uuid)
RETURNS TABLE(latitude numeric,longitude numeric,radius_m integer,max_accuracy_m integer,bind_device boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede ver las opciones de asistencia'; END IF;
  RETURN QUERY SELECT NULL::numeric,NULL::numeric,0,1000,coalesce(s.bind_device,false)
  FROM (SELECT 1) x LEFT JOIN public.pos_attendance_settings s ON s.location_id=p_location_id;
END;
$function$;
CREATE OR REPLACE FUNCTION public.pos_save_attendance_device_policy(p_token text,p_location_id uuid,p_bind_device boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede cambiar esta opción'; END IF;
  IF p_bind_device IS NULL THEN RAISE EXCEPTION 'Opción inválida'; END IF;
  INSERT INTO public.pos_attendance_settings(location_id,latitude,longitude,radius_m,max_accuracy_m,bind_device,updated_by,updated_at)
  VALUES(p_location_id,0,0,1,1000,p_bind_device,v_operator.user_id,now())
  ON CONFLICT(location_id) DO UPDATE SET bind_device=excluded.bind_device,max_accuracy_m=1000,updated_by=excluded.updated_by,updated_at=now();
  RETURN true;
END;
$function$;
CREATE OR REPLACE FUNCTION public.pos_mark_attendance(
  p_token text,p_location_id uuid,p_type text,p_device_id text,p_client_event_id text,p_code text,
  p_latitude numeric,p_longitude numeric,p_accuracy numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_existing public.attendance_records%rowtype; v_last text; v_record public.attendance_records%rowtype;
  v_settings public.pos_attendance_settings%rowtype; v_device public.attendance_devices%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida; vuelve a ingresar'; END IF;
  IF p_type NOT IN ('ENTRY','EXIT') OR nullif(trim(p_client_event_id),'') IS NULL OR length(coalesce(p_device_id,'')) NOT BETWEEN 8 AND 200 THEN RAISE EXCEPTION 'Marcación o dispositivo inválido'; END IF;
  SELECT * INTO v_existing FROM public.attendance_records WHERE client_event_id=p_client_event_id;
  IF FOUND THEN
    IF v_existing.user_id<>v_operator.user_id OR v_existing.location_id<>p_location_id THEN RAISE EXCEPTION 'Identificador de marcación ya utilizado'; END IF;
    RETURN jsonb_build_object('success',true,'type',v_existing.type,'recorded_at',v_existing.recorded_at,'duplicate',true);
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_attendance_employee_settings es WHERE es.location_id=p_location_id AND es.user_id=v_operator.user_id AND NOT es.active) THEN RAISE EXCEPTION 'Tu acceso a marcación está desactivado. Consulta al administrador.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pos_attendance_qr_codes q WHERE q.location_id=p_location_id AND q.expires_at>clock_timestamp()
    AND q.code_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex')) THEN RAISE EXCEPTION 'El QR venció. Escanea el código actual del POS.'; END IF;
  IF p_latitude IS NULL OR p_longitude IS NULL OR p_latitude NOT BETWEEN -90 AND 90 OR p_longitude NOT BETWEEN -180 AND 180 OR p_accuracy IS NULL OR p_accuracy<0 THEN RAISE EXCEPTION 'Activa ubicación y vuelve a intentar'; END IF;
  IF p_accuracy>1000 THEN RAISE EXCEPTION 'La precisión GPS es insuficiente. Intenta desde un sitio despejado.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_operator.user_id::text||p_location_id::text,0));
  SELECT * INTO v_settings FROM public.pos_attendance_settings WHERE location_id=p_location_id;
  IF coalesce(v_settings.bind_device,false) THEN
    SELECT * INTO v_device FROM public.attendance_devices WHERE user_id=v_operator.user_id AND active FOR UPDATE;
    IF FOUND AND v_device.device_id<>p_device_id THEN RAISE EXCEPTION 'Este usuario ya tiene otro celular vinculado. Solicita al administrador desvincularlo.'; END IF;
    IF NOT FOUND THEN
      IF EXISTS(SELECT 1 FROM public.attendance_devices WHERE device_id=p_device_id AND user_id<>v_operator.user_id AND active) THEN RAISE EXCEPTION 'Este celular ya está vinculado a otro usuario.'; END IF;
      UPDATE public.attendance_devices SET active=true WHERE device_id=p_device_id AND user_id=v_operator.user_id;
      IF NOT FOUND THEN INSERT INTO public.attendance_devices(user_id,device_id,label,active) VALUES(v_operator.user_id,p_device_id,'PWA asistencia',true); END IF;
    END IF;
  END IF;
  SELECT ar.type INTO v_last FROM public.attendance_records ar WHERE ar.user_id=v_operator.user_id AND ar.location_id=p_location_id ORDER BY ar.recorded_at DESC,ar.id DESC LIMIT 1;
  IF (p_type='ENTRY' AND v_last='ENTRY') OR (p_type='EXIT' AND coalesce(v_last,'')<>'ENTRY') THEN RAISE EXCEPTION 'La marcación no coincide con el último estado de asistencia'; END IF;
  INSERT INTO public.attendance_records(user_id,location_id,type,device_id,client_event_id,latitude,longitude,accuracy,status,recorded_at)
  VALUES(v_operator.user_id,p_location_id,p_type,p_device_id,p_client_event_id,p_latitude,p_longitude,p_accuracy,'SYNCED',clock_timestamp()) RETURNING * INTO v_record;
  RETURN jsonb_build_object('success',true,'type',v_record.type,'recorded_at',v_record.recorded_at,'location_saved',true);
END;
$function$;
REVOKE ALL ON FUNCTION public.pos_get_attendance_settings(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_save_attendance_device_policy(text,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_mark_attendance(text,uuid,text,text,text,text,numeric,numeric,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_get_attendance_settings(text,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_save_attendance_device_policy(text,uuid,boolean) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_mark_attendance(text,uuid,text,text,text,text,numeric,numeric,numeric) TO anon,authenticated;
