-- Cloud administration for attendance, auditable full refunds, and removal of
-- the remaining unauthenticated username-to-profile lookup. Staging first.

ALTER TABLE public.pos_attendance_settings
  ADD COLUMN IF NOT EXISTS bind_device boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.pos_attendance_employee_settings (
  location_id uuid NOT NULL REFERENCES public.locations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  schedule_start time NOT NULL DEFAULT '08:00',
  schedule_end time NOT NULL DEFAULT '17:00',
  active boolean NOT NULL DEFAULT true,
  updated_by uuid NOT NULL REFERENCES public.profiles(id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(location_id,user_id),
  CHECK(schedule_start <> schedule_end)
);
ALTER TABLE public.pos_attendance_employee_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_attendance_employee_settings FROM PUBLIC,anon,authenticated;

ALTER TABLE public.attendance_records
  ADD COLUMN IF NOT EXISTS correction_reason text,
  ADD COLUMN IF NOT EXISTS corrected_by uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS corrected_at timestamptz;

ALTER TABLE public.cash_sessions
  ADD COLUMN IF NOT EXISTS cash_refunds_cents integer NOT NULL DEFAULT 0 CHECK(cash_refunds_cents >= 0),
  ADD COLUMN IF NOT EXISTS transfer_refunds_cents integer NOT NULL DEFAULT 0 CHECK(transfer_refunds_cents >= 0);

CREATE TABLE IF NOT EXISTS public.pos_refunds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid NOT NULL UNIQUE REFERENCES public.tickets(id),
  order_id uuid REFERENCES public.orders(id),
  location_id uuid NOT NULL REFERENCES public.locations(id),
  business_id uuid NOT NULL REFERENCES public.businesses(id),
  cash_session_id uuid NOT NULL REFERENCES public.cash_sessions(id),
  amount_cents integer NOT NULL CHECK(amount_cents > 0),
  payment_method text NOT NULL CHECK(payment_method IN ('CASH','TRANSFER')),
  reason text NOT NULL CHECK(length(trim(reason)) > 0),
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pos_refunds_location_created ON public.pos_refunds(location_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pos_refunds_session ON public.pos_refunds(cash_session_id);
ALTER TABLE public.pos_refunds ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_refunds FROM PUBLIC,anon,authenticated;

DROP FUNCTION IF EXISTS public.pos_get_attendance_settings(text,uuid);
CREATE FUNCTION public.pos_get_attendance_settings(p_token text,p_location_id uuid)
RETURNS TABLE(latitude numeric,longitude numeric,radius_m integer,max_accuracy_m integer,bind_device boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede ver la configuración de asistencia'; END IF;
  RETURN QUERY SELECT s.latitude,s.longitude,s.radius_m,s.max_accuracy_m,s.bind_device
    FROM public.pos_attendance_settings s WHERE s.location_id=p_location_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_get_attendance_employees(p_token text,p_location_id uuid)
RETURNS TABLE(user_id uuid,username text,role text,active boolean,schedule_start text,schedule_end text,device_id text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede consultar el personal'; END IF;
  RETURN QUERY SELECT p.id,p.username,lm.role,coalesce(es.active,true),
    to_char(coalesce(es.schedule_start,'08:00'::time),'HH24:MI'),to_char(coalesce(es.schedule_end,'17:00'::time),'HH24:MI'),d.device_id
  FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id AND p.active
  LEFT JOIN public.pos_attendance_employee_settings es ON es.location_id=lm.location_id AND es.user_id=p.id
  LEFT JOIN LATERAL (SELECT ad.device_id FROM public.attendance_devices ad WHERE ad.user_id=p.id AND ad.active ORDER BY ad.created_at DESC LIMIT 1) d ON true
  WHERE lm.location_id=p_location_id AND lm.active ORDER BY p.username;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_save_attendance_employee(
  p_token text,p_location_id uuid,p_user_id uuid,p_schedule_start time,p_schedule_end time,p_active boolean
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede editar horarios'; END IF;
  IF p_schedule_start IS NULL OR p_schedule_end IS NULL OR p_schedule_start=p_schedule_end OR p_active IS NULL THEN RAISE EXCEPTION 'Horario o estado inválido'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id WHERE lm.location_id=p_location_id AND lm.profile_id=p_user_id AND lm.active AND p.active) THEN RAISE EXCEPTION 'El trabajador no pertenece a esta sucursal'; END IF;
  INSERT INTO public.pos_attendance_employee_settings(location_id,user_id,schedule_start,schedule_end,active,updated_by,updated_at)
  VALUES(p_location_id,p_user_id,p_schedule_start,p_schedule_end,p_active,v_operator.user_id,now())
  ON CONFLICT(location_id,user_id) DO UPDATE SET schedule_start=excluded.schedule_start,schedule_end=excluded.schedule_end,
    active=excluded.active,updated_by=excluded.updated_by,updated_at=now();
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_admin_reset_attendance_device(p_token text,p_location_id uuid,p_user_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_count integer;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede desvincular celulares'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.location_memberships WHERE location_id=p_location_id AND profile_id=p_user_id AND active) THEN RAISE EXCEPTION 'Trabajador fuera de esta sucursal'; END IF;
  UPDATE public.attendance_devices SET active=false WHERE user_id=p_user_id AND active;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
  VALUES(v_operator.user_id,'attendance_device',p_user_id,'DEVICE_UNLINKED',jsonb_build_object('location_id',p_location_id,'rows',v_count));
  RETURN true;
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.pos_save_attendance_device_policy(p_token text,p_location_id uuid,p_bind_device boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede cambiar esta opción'; END IF;
  IF p_bind_device IS NULL THEN RAISE EXCEPTION 'Opción inválida'; END IF;
  UPDATE public.pos_attendance_settings SET bind_device=p_bind_device,updated_by=v_operator.user_id,updated_at=now() WHERE location_id=p_location_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Primero configure la ubicación de asistencia'; END IF;
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_mark_attendance(
  p_token text,p_location_id uuid,p_type text,p_device_id text,p_client_event_id text,p_code text,
  p_latitude numeric,p_longitude numeric,p_accuracy numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_existing public.attendance_records%rowtype; v_last text; v_record public.attendance_records%rowtype;
  v_settings public.pos_attendance_settings%rowtype; v_distance double precision; v_device public.attendance_devices%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida; vuelve a ingresar'; END IF;
  IF p_type NOT IN ('ENTRY','EXIT') OR nullif(trim(p_client_event_id),'') IS NULL OR length(coalesce(p_device_id,'')) NOT BETWEEN 8 AND 200 THEN RAISE EXCEPTION 'Marcación o dispositivo inválido'; END IF;
  SELECT * INTO v_existing FROM public.attendance_records WHERE client_event_id=p_client_event_id;
  IF FOUND THEN
    IF v_existing.user_id<>v_operator.user_id OR v_existing.location_id<>p_location_id THEN RAISE EXCEPTION 'Identificador de marcación ya utilizado'; END IF;
    RETURN jsonb_build_object('success',true,'type',v_existing.type,'recorded_at',v_existing.recorded_at,'duplicate',true);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pos_attendance_employee_settings es WHERE es.location_id=p_location_id AND es.user_id=v_operator.user_id AND NOT es.active) THEN NULL;
  ELSE RAISE EXCEPTION 'Tu acceso a marcación está desactivado. Consulta al administrador.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pos_attendance_qr_codes q WHERE q.location_id=p_location_id AND q.expires_at>clock_timestamp()
    AND q.code_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex')) THEN RAISE EXCEPTION 'El QR venció. Escanea el código actual del POS.'; END IF;
  IF p_latitude IS NULL OR p_longitude IS NULL OR p_accuracy IS NULL OR p_accuracy<0 THEN RAISE EXCEPTION 'Activa ubicación y vuelve a intentar'; END IF;
  SELECT * INTO v_settings FROM public.pos_attendance_settings WHERE location_id=p_location_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'La ubicación de asistencia aún no está configurada en el POS.'; END IF;
  IF p_accuracy>v_settings.max_accuracy_m THEN RAISE EXCEPTION 'La precisión GPS es insuficiente. Intenta desde un sitio despejado.'; END IF;
  v_distance:=6371000*acos(least(1.0,greatest(-1.0,sin(radians(v_settings.latitude::double precision))*sin(radians(p_latitude::double precision))+
    cos(radians(v_settings.latitude::double precision))*cos(radians(p_latitude::double precision))*cos(radians((p_longitude-v_settings.longitude)::double precision)))));
  IF v_distance>v_settings.radius_m THEN RAISE EXCEPTION 'Estás fuera del área permitida para marcar asistencia.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_operator.user_id::text||p_location_id::text,0));
  IF v_settings.bind_device THEN
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
  RETURN jsonb_build_object('success',true,'type',v_record.type,'recorded_at',v_record.recorded_at,'distance_m',round(v_distance::numeric));
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_refund_ticket(p_token text,p_location_id uuid,p_ticket_id uuid,p_reason text)
RETURNS public.pos_refunds LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_ticket public.tickets%rowtype; v_session public.cash_sessions%rowtype; v_refund public.pos_refunds%rowtype;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión o permiso de caja inválido'; END IF;
  IF length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'El motivo de devolución es obligatorio'; END IF;
  SELECT * INTO v_ticket FROM public.tickets WHERE id=p_ticket_id AND location_id=p_location_id FOR UPDATE;
  IF NOT FOUND OR v_ticket.status<>'PAID' OR v_ticket.payment_method NOT IN ('CASH','TRANSFER') THEN RAISE EXCEPTION 'El ticket no se puede devolver'; END IF;
  IF EXISTS(SELECT 1 FROM public.pos_refunds WHERE ticket_id=p_ticket_id) THEN RAISE EXCEPTION 'Este ticket ya fue devuelto'; END IF;
  SELECT * INTO v_session FROM public.cash_sessions WHERE location_id=p_location_id AND status='OPEN' ORDER BY opened_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abra una caja para registrar la devolución'; END IF;
  INSERT INTO public.pos_refunds(ticket_id,order_id,location_id,business_id,cash_session_id,amount_cents,payment_method,reason,created_by)
  VALUES(v_ticket.id,v_ticket.order_id,p_location_id,v_ticket.business_id,v_session.id,v_ticket.total_cents,v_ticket.payment_method,trim(p_reason),v_operator.user_id)
  RETURNING * INTO v_refund;
  IF v_ticket.payment_method='CASH' THEN UPDATE public.cash_sessions SET cash_refunds_cents=cash_refunds_cents+v_ticket.total_cents WHERE id=v_session.id;
  ELSE UPDATE public.cash_sessions SET transfer_refunds_cents=transfer_refunds_cents+v_ticket.total_cents WHERE id=v_session.id; END IF;
  INSERT INTO public.audit_events(actor_id,entity_type,entity_id,action,payload)
  VALUES(v_operator.user_id,'ticket',v_ticket.id,'TICKET_REFUNDED',jsonb_build_object('refund_id',v_refund.id,'amount_cents',v_ticket.total_cents,'payment_method',v_ticket.payment_method,'reason',trim(p_reason),'cash_session_id',v_session.id));
  RETURN v_refund;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_get_cash_refunds(p_token text,p_location_id uuid,p_limit integer DEFAULT 300)
RETURNS TABLE(id uuid,ticket_id uuid,order_id uuid,code text,cash_session_id uuid,amount_cents integer,payment_method text,reason text,created_by uuid,created_by_username text,created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión sin permiso para consultar devoluciones'; END IF;
  RETURN QUERY SELECT r.id,r.ticket_id,r.order_id,t.code,r.cash_session_id,r.amount_cents,r.payment_method,r.reason,r.created_by,p.username,r.created_at
  FROM public.pos_refunds r JOIN public.tickets t ON t.id=r.ticket_id JOIN public.profiles p ON p.id=r.created_by
  WHERE r.location_id=p_location_id ORDER BY r.created_at DESC LIMIT greatest(1,least(coalesce(p_limit,300),1000));
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_close_cash_session(
  p_token text,p_location_id uuid,p_session_id uuid,p_counted_cents integer,p_carryover_cents integer,p_detail jsonb DEFAULT '{}'::jsonb
) RETURNS public.cash_sessions LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_session public.cash_sessions%rowtype; v_expected integer;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión o permiso de caja inválido'; END IF;
  IF p_counted_cents<0 OR p_carryover_cents<0 OR p_carryover_cents>p_counted_cents THEN RAISE EXCEPTION 'Conteo o fondo dejado inválido'; END IF;
  SELECT * INTO v_session FROM public.cash_sessions WHERE id=p_session_id AND location_id=p_location_id AND status='OPEN' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La caja no existe o ya fue cerrada'; END IF;
  v_expected:=v_session.opening_cents+v_session.cash_sales_cents-v_session.expenses_cents-v_session.cash_refunds_cents;
  UPDATE public.cash_sessions SET status='CLOSED',closed_at=now(),closed_by=v_operator.user_id,counted_cents=p_counted_cents,
    carryover_cents=p_carryover_cents,delivered_cents=p_counted_cents-p_carryover_cents,difference_cents=p_counted_cents-v_expected,
    counted_detail_json=coalesce(p_detail,'{}'::jsonb) WHERE id=p_session_id RETURNING * INTO v_session;
  RETURN v_session;
END;
$function$;

-- Cash session list exposes the exact cent values used to reconcile the drawer.
DROP FUNCTION IF EXISTS public.pos_get_cash_sessions(text,uuid,integer);
CREATE FUNCTION public.pos_get_cash_sessions(p_token text,p_location_id uuid,p_limit integer DEFAULT 100)
RETURNS TABLE(id uuid,business_id uuid,location_id uuid,opened_by uuid,closed_by uuid,opened_at timestamptz,closed_at timestamptz,
  opening_cents integer,counted_cents integer,carryover_cents integer,delivered_cents integer,cash_sales_cents integer,
  card_sales_cents integer,transfer_sales_cents integer,expenses_cents integer,difference_cents integer,status text,
  shift text,counted_detail_json jsonb,opened_by_username text,closed_by_username text,ticket_count bigint,cash_refunds_cents integer,transfer_refunds_cents integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión de caja vencida o no autorizada'; END IF;
  RETURN QUERY SELECT cs.id,cs.business_id,cs.location_id,cs.opened_by,cs.closed_by,cs.opened_at,cs.closed_at,cs.opening_cents,cs.counted_cents,
    cs.carryover_cents,cs.delivered_cents,cs.cash_sales_cents,cs.card_sales_cents,cs.transfer_sales_cents,cs.expenses_cents,cs.difference_cents,
    cs.status,cs.shift,cs.counted_detail_json,op.username,cp.username,count(t.id),cs.cash_refunds_cents,cs.transfer_refunds_cents
  FROM public.cash_sessions cs LEFT JOIN public.profiles op ON op.id=cs.opened_by LEFT JOIN public.profiles cp ON cp.id=cs.closed_by
  LEFT JOIN public.tickets t ON t.cash_session_id=cs.id AND t.status='PAID' WHERE cs.location_id=p_location_id
  GROUP BY cs.id,op.username,cp.username ORDER BY cs.opened_at DESC LIMIT greatest(1,least(coalesce(p_limit,100),500));
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_resolve_cashier(p_token text,p_location_id uuid,p_username text)
RETURNS TABLE(user_id uuid,username text,user_role text) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $function$
DECLARE v_operator record; v_normalized text;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER','CAJA') THEN RAISE EXCEPTION 'Sesión sin permiso para resolver cajero'; END IF;
  v_normalized:=lower(regexp_replace(trim(coalesce(p_username,'')),'\s+','_','g'));
  RETURN QUERY SELECT p.id,p.username,lm.role FROM public.location_memberships lm JOIN public.profiles p ON p.id=lm.profile_id
  WHERE lm.location_id=p_location_id AND lm.active AND p.active AND lower(regexp_replace(trim(p.username),'\s+','_','g'))=v_normalized
  ORDER BY p.username LIMIT 2;
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_admin_get_attendance_employees(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_attendance_settings(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_save_attendance_employee(text,uuid,uuid,time,time,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_reset_attendance_device(text,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_admin_correct_attendance(text,uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_save_attendance_device_policy(text,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_refund_ticket(text,uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_cash_refunds(text,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_get_cash_sessions(text,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_resolve_cashier(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_admin_get_attendance_employees(text,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_attendance_settings(text,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_save_attendance_employee(text,uuid,uuid,time,time,boolean) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_reset_attendance_device(text,uuid,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_admin_correct_attendance(text,uuid,text,text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_save_attendance_device_policy(text,uuid,boolean) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_refund_ticket(text,uuid,uuid,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_cash_refunds(text,uuid,integer) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_get_cash_sessions(text,uuid,integer) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_resolve_cashier(text,uuid,text) TO anon,authenticated;

REVOKE ALL ON FUNCTION public.resolve_pos_user(uuid,text) FROM PUBLIC,anon,authenticated;

-- Newly-created functions also start with no PUBLIC execute unless explicitly granted.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
