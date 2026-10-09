-- The public registration RPC is only a lookup now; cloud locations/businesses
-- must be provisioned through the authenticated administration flow.
CREATE OR REPLACE FUNCTION public.register_pos_location(
  p_location_name text,
  p_business_id uuid DEFAULT NULL
)
RETURNS TABLE(location_id uuid, location_name text, business_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF length(trim(coalesce(p_location_name, ''))) NOT BETWEEN 2 AND 100 THEN
    RAISE EXCEPTION 'Nombre de sucursal inválido';
  END IF;

  RETURN QUERY
  SELECT l.id, l.name, l.business_id
  FROM public.locations l
  WHERE l.active
    AND lower(trim(l.name)) = lower(trim(p_location_name))
    AND (p_business_id IS NULL OR l.business_id = p_business_id)
  ORDER BY l.created_at
  LIMIT 1;
END;
$function$;

-- Unlinking this installation no longer disables a shared branch. Keep the
-- legacy function for auditability but remove its public API execution grant.
REVOKE ALL ON FUNCTION public.deactivate_pos_location(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.register_pos_location(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_pos_location(text, uuid) TO anon, authenticated;
