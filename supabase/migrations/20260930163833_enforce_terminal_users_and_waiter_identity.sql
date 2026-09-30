-- The POS SQLite database is the authority for the employees of one terminal.
-- Keep the PWA roster scoped to that terminal and persist the sender's name on
-- every order, so kitchen does not depend on an optional embedded relation.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS waiter_name TEXT NOT NULL DEFAULT '';

CREATE OR REPLACE FUNCTION public.set_order_waiter_name()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF COALESCE(NEW.waiter_name, '') = '' AND NEW.waiter_id IS NOT NULL THEN
    SELECT COALESCE(NULLIF(p.display_name, ''), p.username, '')
      INTO NEW.waiter_name
      FROM public.profiles p
     WHERE p.id = NEW.waiter_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_set_waiter_name ON public.orders;
CREATE TRIGGER orders_set_waiter_name
BEFORE INSERT OR UPDATE OF waiter_id, waiter_name ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.set_order_waiter_name();

-- Repair the existing active orders as well.
UPDATE public.orders o
   SET waiter_name = COALESCE(NULLIF(p.display_name, ''), p.username, '')
  FROM public.profiles p
 WHERE o.waiter_id = p.id
   AND COALESCE(o.waiter_name, '') = '';

CREATE OR REPLACE FUNCTION public.sync_pos_users(
  p_location_id UUID,
  p_users JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user JSONB;
  v_username TEXT;
  v_role TEXT;
  v_display_name TEXT;
  v_password_hash TEXT;
  v_active BOOLEAN;
  v_profile_id UUID;
  v_business_id UUID;
  v_count INTEGER := 0;
BEGIN
  SELECT business_id INTO v_business_id FROM locations WHERE id = p_location_id;
  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'Ubicación no encontrada';
  END IF;

  FOR v_user IN SELECT value FROM jsonb_array_elements(COALESCE(p_users, '[]'::jsonb))
  LOOP
    v_username := LOWER(TRIM(v_user->>'username'));
    IF v_username = '' THEN CONTINUE; END IF;
    v_role := COALESCE(v_user->>'role', 'MESERO');
    v_display_name := COALESCE(NULLIF(v_user->>'display_name', ''), v_username);
    v_password_hash := COALESCE(v_user->>'password_hash', '');
    v_active := COALESCE((v_user->>'active')::BOOLEAN, true);
    v_profile_id := NULL;

    -- Prefer the stable cloud id: a renamed local user must not create a
    -- second mobile account.
    IF COALESCE(v_user->>'cloud_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
      SELECT id INTO v_profile_id FROM profiles WHERE id = (v_user->>'cloud_id')::UUID;
    END IF;
    IF v_profile_id IS NULL THEN
      SELECT id INTO v_profile_id FROM profiles WHERE LOWER(TRIM(username)) = v_username LIMIT 1;
    END IF;

    IF v_profile_id IS NULL THEN
      v_profile_id := gen_random_uuid();
      INSERT INTO profiles (id, username, display_name, role, password_hash, active)
      VALUES (v_profile_id, v_username, v_display_name, v_role, v_password_hash, v_active);
    ELSE
      UPDATE profiles
         SET username = v_username,
             display_name = v_display_name,
             role = v_role,
             password_hash = CASE WHEN v_password_hash <> '' THEN v_password_hash ELSE password_hash END,
             active = v_active
       WHERE id = v_profile_id;
    END IF;

    INSERT INTO business_memberships (user_id, business_id, role, active)
    VALUES (v_profile_id, v_business_id, v_role, v_active)
    ON CONFLICT (user_id, business_id) DO UPDATE
      SET role = EXCLUDED.role, active = EXCLUDED.active;

    INSERT INTO location_memberships (location_id, profile_id, role, active)
    VALUES (p_location_id, v_profile_id, v_role, v_active)
    ON CONFLICT (location_id, profile_id) DO UPDATE
      SET role = EXCLUDED.role, active = EXCLUDED.active;

    v_count := v_count + 1;
  END LOOP;

  -- A user removed from SQLite can no longer be selected or log in on this
  -- terminal, while preserving its historical orders and other terminals.
  UPDATE location_memberships lm
     SET active = false
    FROM profiles p
   WHERE lm.location_id = p_location_id
     AND lm.profile_id = p.id
     AND NOT EXISTS (
       SELECT 1
         FROM jsonb_array_elements(COALESCE(p_users, '[]'::jsonb)) item
        WHERE LOWER(TRIM(item->>'username')) = LOWER(TRIM(p.username))
     );

  RETURN jsonb_build_object('success', true, 'synced_count', v_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_location_users(p_location_id UUID)
RETURNS TABLE (user_id UUID, username TEXT, display_name TEXT, user_role TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id,
         p.username,
         COALESCE(NULLIF(p.display_name, ''), p.username),
         lm.role
    FROM location_memberships lm
    JOIN profiles p ON p.id = lm.profile_id
   WHERE lm.location_id = p_location_id
     AND lm.active = true
     AND p.active = true
   ORDER BY CASE lm.role
              WHEN 'ADMIN' THEN 1
              WHEN 'CAJA' THEN 2
              WHEN 'MESERO' THEN 3
              WHEN 'COCINA' THEN 4
              ELSE 5
            END,
            p.username;
$$;

CREATE OR REPLACE FUNCTION public.login_pos_user(
  p_username TEXT,
  p_password TEXT,
  p_location_id UUID
)
RETURNS TABLE (user_id UUID, username TEXT, display_name TEXT, user_role TEXT, location_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_location_name TEXT;
  v_password_hash TEXT;
BEGIN
  SELECT l.name INTO v_location_name FROM locations l WHERE l.id = p_location_id AND l.active = true;
  IF v_location_name IS NULL THEN RAISE EXCEPTION 'Terminal no encontrada'; END IF;

  SELECT p.password_hash INTO v_password_hash
    FROM location_memberships lm
    JOIN profiles p ON p.id = lm.profile_id
   WHERE lm.location_id = p_location_id
     AND LOWER(TRIM(p.username)) = LOWER(TRIM(p_username))
     AND lm.active = true
     AND p.active = true
   LIMIT 1;

  IF v_password_hash IS NULL OR v_password_hash = ''
     OR v_password_hash <> ENCODE(DIGEST(p_password || '_cabana_pos_salt', 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'Usuario o contraseña incorrectos';
  END IF;

  RETURN QUERY
  SELECT p.id, p.username, COALESCE(NULLIF(p.display_name, ''), p.username), lm.role, v_location_name
    FROM location_memberships lm
    JOIN profiles p ON p.id = lm.profile_id
   WHERE lm.location_id = p_location_id
     AND LOWER(TRIM(p.username)) = LOWER(TRIM(p_username))
     AND lm.active = true
     AND p.active = true;
END;
$$;
