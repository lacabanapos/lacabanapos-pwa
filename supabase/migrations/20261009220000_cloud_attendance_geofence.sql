CREATE TABLE IF NOT EXISTS public.pos_attendance_settings(
  location_id uuid PRIMARY KEY REFERENCES public.locations(id) ON DELETE CASCADE,
  latitude numeric NOT NULL CHECK(latitude BETWEEN -90 AND 90),
  longitude numeric NOT NULL CHECK(longitude BETWEEN -180 AND 180),
  radius_m integer NOT NULL DEFAULT 100 CHECK(radius_m BETWEEN 10 AND 1000),
  max_accuracy_m integer NOT NULL DEFAULT 100 CHECK(max_accuracy_m BETWEEN 5 AND 500),
  updated_by uuid NOT NULL REFERENCES public.profiles(id),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pos_attendance_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_attendance_settings FROM anon,authenticated,public;

CREATE OR REPLACE FUNCTION public.pos_get_attendance_settings(p_token text,p_location_id uuid)
RETURNS TABLE(latitude numeric,longitude numeric,radius_m integer,max_accuracy_m integer)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede ver la configuración de asistencia'; END IF;
  RETURN QUERY SELECT s.latitude,s.longitude,s.radius_m,s.max_accuracy_m FROM public.pos_attendance_settings s WHERE s.location_id=p_location_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_save_attendance_settings(
  p_token text,p_location_id uuid,p_latitude numeric,p_longitude numeric,p_radius_m integer,p_max_accuracy_m integer
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL OR v_operator.user_role NOT IN ('ADMIN','OWNER') THEN RAISE EXCEPTION 'Solo administración puede cambiar la geocerca'; END IF;
  IF p_latitude NOT BETWEEN -90 AND 90 OR p_longitude NOT BETWEEN -180 AND 180 OR (p_latitude=0 AND p_longitude=0)
    OR p_radius_m NOT BETWEEN 10 AND 1000 OR p_max_accuracy_m NOT BETWEEN 5 AND 500 THEN RAISE EXCEPTION 'Ubicación o límites GPS inválidos'; END IF;
  INSERT INTO public.pos_attendance_settings(location_id,latitude,longitude,radius_m,max_accuracy_m,updated_by,updated_at)
  VALUES(p_location_id,p_latitude,p_longitude,p_radius_m,p_max_accuracy_m,v_operator.user_id,now())
  ON CONFLICT(location_id) DO UPDATE SET latitude=excluded.latitude,longitude=excluded.longitude,radius_m=excluded.radius_m,
    max_accuracy_m=excluded.max_accuracy_m,updated_by=excluded.updated_by,updated_at=now();
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pos_mark_attendance(
  p_token text,p_location_id uuid,p_type text,p_device_id text,p_client_event_id text,p_code text,
  p_latitude numeric,p_longitude numeric,p_accuracy numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE v_operator record; v_existing public.attendance_records%rowtype; v_last text; v_record public.attendance_records%rowtype;
  v_settings public.pos_attendance_settings%rowtype; v_distance double precision;
BEGIN
  SELECT * INTO v_operator FROM public.pos_operator_for_token(p_token,p_location_id);
  IF v_operator.user_id IS NULL THEN RAISE EXCEPTION 'Sesión vencida; vuelve a ingresar'; END IF;
  IF p_type NOT IN ('ENTRY','EXIT') OR nullif(trim(p_client_event_id),'') IS NULL THEN RAISE EXCEPTION 'Marcación inválida'; END IF;
  -- A committed event must be replayable even after its QR expires or GPS changes.
  SELECT * INTO v_existing FROM public.attendance_records WHERE client_event_id=p_client_event_id;
  IF FOUND THEN
    IF v_existing.user_id<>v_operator.user_id OR v_existing.location_id<>p_location_id THEN RAISE EXCEPTION 'Identificador de marcación ya utilizado'; END IF;
    RETURN jsonb_build_object('success',true,'type',v_existing.type,'recorded_at',v_existing.recorded_at,'duplicate',true);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pos_attendance_qr_codes q WHERE q.location_id=p_location_id
    AND q.expires_at>clock_timestamp() AND q.code_hash=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex')) THEN
    RAISE EXCEPTION 'El QR venció. Escanea el código actual del POS.';
  END IF;
  IF p_latitude IS NULL OR p_longitude IS NULL OR p_accuracy IS NULL OR p_accuracy<0 THEN RAISE EXCEPTION 'Activa ubicación y vuelve a intentar'; END IF;
  SELECT * INTO v_settings FROM public.pos_attendance_settings WHERE location_id=p_location_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'La ubicación de asistencia aún no está configurada en el POS.'; END IF;
  IF p_accuracy>v_settings.max_accuracy_m THEN RAISE EXCEPTION 'La precisión GPS es insuficiente. Intenta desde un sitio despejado.'; END IF;
  v_distance:=6371000*acos(least(1.0,greatest(-1.0,
    sin(radians(v_settings.latitude::double precision))*sin(radians(p_latitude::double precision))+
    cos(radians(v_settings.latitude::double precision))*cos(radians(p_latitude::double precision))*
    cos(radians((p_longitude-v_settings.longitude)::double precision))
  )));
  IF v_distance>v_settings.radius_m THEN RAISE EXCEPTION 'Estás fuera del área permitida para marcar asistencia.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_operator.user_id::text||p_location_id::text,0));
  SELECT ar.type INTO v_last FROM public.attendance_records ar WHERE ar.user_id=v_operator.user_id AND ar.location_id=p_location_id ORDER BY ar.recorded_at DESC,ar.id DESC LIMIT 1;
  IF (p_type='ENTRY' AND v_last='ENTRY') OR (p_type='EXIT' AND coalesce(v_last,'')<>'ENTRY') THEN RAISE EXCEPTION 'La marcación no coincide con el último estado de asistencia'; END IF;
  INSERT INTO public.attendance_records(user_id,location_id,type,device_id,client_event_id,latitude,longitude,accuracy,status,recorded_at)
  VALUES(v_operator.user_id,p_location_id,p_type,p_device_id,p_client_event_id,p_latitude,p_longitude,p_accuracy,'SYNCED',clock_timestamp()) RETURNING * INTO v_record;
  RETURN jsonb_build_object('success',true,'type',v_record.type,'recorded_at',v_record.recorded_at,'distance_m',round(v_distance::numeric));
END;
$function$;

REVOKE ALL ON FUNCTION public.pos_get_attendance_settings(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pos_save_attendance_settings(text,uuid,numeric,numeric,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_get_attendance_settings(text,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pos_save_attendance_settings(text,uuid,numeric,numeric,integer,integer) TO anon,authenticated;
