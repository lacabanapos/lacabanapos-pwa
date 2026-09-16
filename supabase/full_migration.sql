-- ============================================
-- MIGRATION COMPLETA: La Cabaña PWA
-- Ejecutar todo de una vez en SQL Editor
-- ============================================

-- ============================================
-- PARTE 1: SCHEMA
-- ============================================

CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT NOT NULL UNIQUE,
  display_name TEXT,
  role TEXT NOT NULL DEFAULT 'MESERO' CHECK (role IN ('OWNER','ADMIN','CAJA','MESERO','COCINA','ASADOR')),
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS businesses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS business_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'MESERO',
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, business_id)
);

CREATE TABLE IF NOT EXISTS locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  location_id UUID REFERENCES locations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  sort_order INTEGER DEFAULT 0,
  active BOOLEAN DEFAULT true,
  UNIQUE(location_id, name)
);

CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  location_id UUID REFERENCES locations(id) ON DELETE CASCADE,
  category_id UUID REFERENCES categories(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  price_cents INTEGER NOT NULL DEFAULT 0,
  active BOOLEAN DEFAULT true,
  sort_order INTEGER DEFAULT 0,
  image_data TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDIENTE' CHECK (status IN ('PENDIENTE','PAGADO','ANULADO','DEVUELTO')),
  payment_method TEXT DEFAULT 'NINGUNO',
  total NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  paid_at TIMESTAMPTZ,
  cashier_user_id UUID REFERENCES profiles(id),
  customer_name TEXT DEFAULT '',
  notes TEXT DEFAULT '',
  printed BOOLEAN DEFAULT false
);

CREATE TABLE IF NOT EXISTS ticket_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID REFERENCES tickets(id) ON DELETE CASCADE,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL,
  unit_price NUMERIC(12,2) NOT NULL,
  total_price NUMERIC(12,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID REFERENCES tickets(id) ON DELETE SET NULL,
  customer_name TEXT DEFAULT '',
  status TEXT NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','PREPARING','READY','SERVED','CANCELLED')),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ,
  notes TEXT DEFAULT '',
  source TEXT DEFAULT 'MOBILE' CHECK (source IN ('POS','MOBILE')),
  waiter_name TEXT DEFAULT '',
  total NUMERIC(12,2) DEFAULT 0
);

CREATE TABLE IF NOT EXISTS order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES orders(id) ON DELETE CASCADE,
  product_id UUID,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL,
  unit_price NUMERIC(12,2) DEFAULT 0,
  notes TEXT DEFAULT '',
  category TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS cash_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id),
  location_id UUID REFERENCES locations(id),
  opened_by UUID REFERENCES profiles(id),
  opened_at TIMESTAMPTZ DEFAULT now(),
  closed_at TIMESTAMPTZ,
  opening_cents INTEGER DEFAULT 0,
  carryover_cents INTEGER DEFAULT 0,
  delivered_cents INTEGER DEFAULT 0,
  cash_sales_cents INTEGER DEFAULT 0,
  card_sales_cents INTEGER DEFAULT 0,
  transfer_sales_cents INTEGER DEFAULT 0,
  expenses_cents INTEGER DEFAULT 0,
  status TEXT DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED')),
  shift TEXT DEFAULT 'OTRO'
);

CREATE TABLE IF NOT EXISTS attendance_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('ENTRY','EXIT')),
  recorded_at TIMESTAMPTZ DEFAULT now(),
  device_id TEXT,
  client_event_id TEXT UNIQUE,
  latitude NUMERIC,
  longitude NUMERIC,
  accuracy NUMERIC,
  source_ip TEXT,
  status TEXT DEFAULT 'SYNCED' CHECK (status IN ('SYNCED','CORRECTED'))
);

CREATE TABLE IF NOT EXISTS attendance_devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  device_id TEXT UNIQUE NOT NULL,
  label TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  active BOOLEAN DEFAULT true
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS table_layout (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  shape TEXT DEFAULT 'square',
  x NUMERIC DEFAULT 0,
  y NUMERIC DEFAULT 0,
  width NUMERIC DEFAULT 100,
  height NUMERIC DEFAULT 100,
  seats INTEGER DEFAULT 4,
  active BOOLEAN DEFAULT true
);

CREATE OR REPLACE FUNCTION cleanup_old_data()
RETURNS void AS 
BEGIN
  DELETE FROM order_items WHERE order_id IN (
    SELECT id FROM orders WHERE created_at < NOW() - INTERVAL '3 months'
  );
  DELETE FROM orders WHERE created_at < NOW() - INTERVAL '3 months';
  DELETE FROM ticket_items WHERE ticket_id IN (
    SELECT id FROM tickets WHERE created_at < NOW() - INTERVAL '3 months'
  );
  DELETE FROM tickets WHERE created_at < NOW() - INTERVAL '3 months';
  DELETE FROM attendance_records WHERE recorded_at < NOW() - INTERVAL '3 months';
END;
 LANGUAGE plpgsql;

CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_waiter ON orders(waiter_name);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);
CREATE INDEX IF NOT EXISTS idx_products_location ON products(location_id);
CREATE INDEX IF NOT EXISTS idx_products_active ON products(active);
CREATE INDEX IF NOT EXISTS idx_attendance_user ON attendance_records(user_id);
CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance_records(recorded_at DESC);

-- ============================================
-- PARTE 2: RLS POLICIES
-- ============================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own profile" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Admin can view all profiles" ON profiles FOR SELECT USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN'));
CREATE POLICY "Admin can update profiles" ON profiles FOR UPDATE USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN'));

ALTER TABLE products ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can view products" ON products FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin can manage products" ON products FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN'));

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Kitchen staff can view all active orders" ON orders FOR SELECT USING (auth.role() = 'authenticated' AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('COCINA','ASADOR','ADMIN')));
CREATE POLICY "Waiters can view own orders" ON orders FOR SELECT USING (auth.role() = 'authenticated' AND waiter_name = (SELECT username FROM profiles WHERE id = auth.uid()));
CREATE POLICY "Authenticated can create orders" ON orders FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Kitchen can update order status" ON orders FOR UPDATE USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('COCINA','ASADOR','ADMIN')));
CREATE POLICY "Waiters can update own orders" ON orders FOR UPDATE USING (waiter_name = (SELECT username FROM profiles WHERE id = auth.uid()));

ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can view order items" ON order_items FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Authenticated can insert order items" ON order_items FOR INSERT WITH CHECK (auth.role() = 'authenticated');

ALTER TABLE tickets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admin and cashier can view tickets" ON tickets FOR SELECT USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','CAJA')));
CREATE POLICY "Authenticated can create tickets" ON tickets FOR INSERT WITH CHECK (auth.role() = 'authenticated');

ALTER TABLE ticket_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can view ticket items" ON ticket_items FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Authenticated can insert ticket items" ON ticket_items FOR INSERT WITH CHECK (auth.role() = 'authenticated');

ALTER TABLE attendance_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own attendance" ON attendance_records FOR SELECT USING (user_id = auth.uid() OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN'));
CREATE POLICY "Authenticated can insert attendance" ON attendance_records FOR INSERT WITH CHECK (auth.role() = 'authenticated');

ALTER TABLE attendance_devices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own devices" ON attendance_devices FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Authenticated can register devices" ON attendance_devices FOR INSERT WITH CHECK (user_id = auth.uid());

ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can view settings" ON settings FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin can manage settings" ON settings FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN'));

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can view categories" ON categories FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin can manage categories" ON categories FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN'));

ALTER TABLE cash_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admin can view all cash sessions" ON cash_sessions FOR SELECT USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN'));
CREATE POLICY "Authenticated can create cash sessions" ON cash_sessions FOR INSERT WITH CHECK (auth.role() = 'authenticated');

ALTER TABLE table_layout ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can view tables" ON table_layout FOR SELECT USING (auth.role() = 'authenticated');

-- ============================================
-- PARTE 3: RPC FUNCTIONS
-- ============================================

CREATE OR REPLACE FUNCTION create_order(p_customer_name TEXT, p_waiter_name TEXT, p_notes TEXT, p_items JSONB)
RETURNS JSONB AS 
DECLARE
  v_ticket_id UUID;
  v_order_id UUID;
  v_total NUMERIC(12,2) := 0;
  v_item JSONB;
  v_ticket_code TEXT;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_total := v_total + ((v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::INTEGER);
  END LOOP;
  v_ticket_code := 'T-' || LPAD(FLOOR(RANDOM() * 9999999)::TEXT, 7, '0');
  INSERT INTO tickets (code, status, total, customer_name, notes, created_at)
  VALUES (v_ticket_code, 'PENDIENTE', v_total, p_customer_name, p_notes, now())
  RETURNING id INTO v_ticket_id;
  INSERT INTO orders (ticket_id, customer_name, status, source, waiter_name, total, notes, created_at)
  VALUES (v_ticket_id, p_customer_name, 'RECEIVED', 'MOBILE', p_waiter_name, v_total, p_notes, now())
  RETURNING id INTO v_order_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO ticket_items (ticket_id, product_name, quantity, unit_price, total_price)
    VALUES (v_ticket_id, v_item->>'product_name', (v_item->>'quantity')::INTEGER, (v_item->>'unit_price')::NUMERIC, (v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::INTEGER);
    INSERT INTO order_items (order_id, product_id, product_name, quantity, unit_price, notes, category)
    VALUES (v_order_id, (v_item->>'product_id')::UUID, v_item->>'product_name', (v_item->>'quantity')::INTEGER, (v_item->>'unit_price')::NUMERIC, v_item->>'notes', COALESCE(v_item->>'category', ''));
  END LOOP;
  RETURN jsonb_build_object('order_id', v_order_id, 'ticket_id', v_ticket_id, 'ticket_code', v_ticket_code, 'total', v_total);
END;
 LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION update_order_status(p_order_id UUID, p_status TEXT)
RETURNS JSONB AS 
BEGIN
  UPDATE orders SET status = p_status, updated_at = now() WHERE id = p_order_id;
  IF p_status = 'SERVED' THEN
    UPDATE tickets SET status = 'PAGADO', paid_at = now() WHERE id = (SELECT ticket_id FROM orders WHERE id = p_order_id);
  END IF;
  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
 LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION cancel_order(p_order_id UUID)
RETURNS JSONB AS 
BEGIN
  UPDATE orders SET status = 'CANCELLED', updated_at = now() WHERE id = p_order_id;
  UPDATE tickets SET status = 'ANULADO' WHERE id = (SELECT ticket_id FROM orders WHERE id = p_order_id);
  RETURN jsonb_build_object('success', true);
END;
 LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION add_items_to_order(p_order_id UUID, p_items JSONB)
RETURNS JSONB AS 
DECLARE
  v_item JSONB;
  v_total_add NUMERIC(12,2) := 0;
  v_ticket_id UUID;
BEGIN
  SELECT ticket_id INTO v_ticket_id FROM orders WHERE id = p_order_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO order_items (order_id, product_id, product_name, quantity, unit_price, notes, category)
    VALUES (p_order_id, (v_item->>'product_id')::UUID, v_item->>'product_name', (v_item->>'quantity')::INTEGER, (v_item->>'unit_price')::NUMERIC, v_item->>'notes', COALESCE(v_item->>'category', ''));
    IF v_ticket_id IS NOT NULL THEN
      INSERT INTO ticket_items (ticket_id, product_name, quantity, unit_price, total_price)
      VALUES (v_ticket_id, v_item->>'product_name', (v_item->>'quantity')::INTEGER, (v_item->>'unit_price')::NUMERIC, (v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::INTEGER);
    END IF;
    v_total_add := v_total_add + ((v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::INTEGER);
  END LOOP;
  UPDATE orders SET total = total + v_total_add, updated_at = now() WHERE id = p_order_id;
  IF v_ticket_id IS NOT NULL THEN
    UPDATE tickets SET total = total + v_total_add WHERE id = v_ticket_id;
  END IF;
  RETURN jsonb_build_object('success', true, 'added_total', v_total_add);
END;
 LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION mark_attendance(p_user_id UUID, p_type TEXT, p_device_id TEXT, p_client_event_id TEXT)
RETURNS JSONB AS 
BEGIN
  INSERT INTO attendance_records (user_id, type, device_id, client_event_id, status)
  VALUES (p_user_id, p_type, p_device_id, p_client_event_id, 'SYNCED');
  RETURN jsonb_build_object('type', p_type, 'recorded_at', now());
END;
 LANGUAGE plpgsql SECURITY DEFINER;

ALTER PUBLICATION supabase_realtime ADD TABLE orders;
ALTER PUBLICATION supabase_realtime ADD TABLE order_items;

SELECT 'Migracion completa exitosa' as result;
