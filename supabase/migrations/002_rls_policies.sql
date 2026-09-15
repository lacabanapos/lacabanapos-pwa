-- ============================================
-- MIGRATION 002: RLS Policies
-- ============================================

-- Profiles: cada usuario ve su propio perfil, admin ve todos
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own profile" ON profiles
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Admin can view all profiles" ON profiles
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN')
  );

CREATE POLICY "Admin can update profiles" ON profiles
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN')
  );

-- Products: todos los autenticados pueden ver, solo admin modifica
ALTER TABLE products ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated can view products" ON products
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Admin can manage products" ON products
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN')
  );

-- Orders: meseros ven las suyas, cocina ve todas, admin ve todas
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Kitchen staff can view all active orders" ON orders
  FOR SELECT USING (
    auth.role() = 'authenticated' AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('COCINA','ASADOR','ADMIN'))
  );

CREATE POLICY "Waiters can view own orders" ON orders
  FOR SELECT USING (
    auth.role() = 'authenticated' AND
    waiter_name = (SELECT username FROM profiles WHERE id = auth.uid())
  );

CREATE POLICY "Authenticated can create orders" ON orders
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Kitchen can update order status" ON orders
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('COCINA','ASADOR','ADMIN'))
  );

CREATE POLICY "Waiters can update own orders" ON orders
  FOR UPDATE USING (
    waiter_name = (SELECT username FROM profiles WHERE id = auth.uid())
  );

-- Order Items: siguen la misma lógica que orders
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated can view order items" ON order_items
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Authenticated can insert order items" ON order_items
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- Tickets: solo admin y caja
ALTER TABLE tickets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin and cashier can view tickets" ON tickets
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','CAJA'))
  );

CREATE POLICY "Authenticated can create tickets" ON tickets
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- Ticket Items
ALTER TABLE ticket_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated can view ticket items" ON ticket_items
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Authenticated can insert ticket items" ON ticket_items
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- Attendance: cada usuario ve sus registros, admin ve todos
ALTER TABLE attendance_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own attendance" ON attendance_records
  FOR SELECT USING (
    user_id = auth.uid() OR
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN')
  );

CREATE POLICY "Authenticated can insert attendance" ON attendance_records
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- Attendance Devices
ALTER TABLE attendance_devices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own devices" ON attendance_devices
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Authenticated can register devices" ON attendance_devices
  FOR INSERT WITH CHECK (user_id = auth.uid());

-- Settings: solo admin
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated can view settings" ON settings
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Admin can manage settings" ON settings
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN')
  );

-- Categories
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated can view categories" ON categories
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Admin can manage categories" ON categories
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN')
  );

-- Cash Sessions
ALTER TABLE cash_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin can view all cash sessions" ON cash_sessions
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'ADMIN')
  );

CREATE POLICY "Authenticated can create cash sessions" ON cash_sessions
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- Table Layout
ALTER TABLE table_layout ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated can view tables" ON table_layout
  FOR SELECT USING (auth.role() = 'authenticated');
