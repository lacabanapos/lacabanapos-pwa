-- ============================================
-- MIGRATION 001: Schema base para PWA La Cabaña
-- Ejecutar en Supabase SQL Editor
-- ============================================

-- Tabla de perfiles (extiende auth.users)
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT NOT NULL UNIQUE,
  display_name TEXT,
  role TEXT NOT NULL DEFAULT 'MESERO' CHECK (role IN ('OWNER','ADMIN','CAJA','MESERO','COCINA','ASADOR')),
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Negocio
CREATE TABLE IF NOT EXISTS businesses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Relación usuario-negocio
CREATE TABLE IF NOT EXISTS business_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'MESERO',
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, business_id)
);

-- Sedes
CREATE TABLE IF NOT EXISTS locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Categorías
CREATE TABLE IF NOT EXISTS categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
  location_id UUID REFERENCES locations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  sort_order INTEGER DEFAULT 0,
  active BOOLEAN DEFAULT true,
  UNIQUE(location_id, name)
);

-- Productos
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

-- Tickets (registro financiero)
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

-- Ticket items
CREATE TABLE IF NOT EXISTS ticket_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id UUID REFERENCES tickets(id) ON DELETE CASCADE,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL,
  unit_price NUMERIC(12,2) NOT NULL,
  total_price NUMERIC(12,2) NOT NULL
);

-- Órdenes (display de cocina)
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

-- Order items
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

-- Sesiones de caja
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

-- Asistencia
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

-- Dispositivos de asistencia
CREATE TABLE IF NOT EXISTS attendance_devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  device_id TEXT UNIQUE NOT NULL,
  label TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  active BOOLEAN DEFAULT true
);

-- Configuración del negocio
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT DEFAULT ''
);

-- Layout de mesas
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

-- ============================================
-- DATA RETENTION: Función para limpiar datos > 3 meses
-- ============================================
CREATE OR REPLACE FUNCTION cleanup_old_data()
RETURNS void AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================
-- INDEXES para performance
-- ============================================
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_waiter ON orders(waiter_name);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);
CREATE INDEX IF NOT EXISTS idx_products_location ON products(location_id);
CREATE INDEX IF NOT EXISTS idx_products_active ON products(active);
CREATE INDEX IF NOT EXISTS idx_attendance_user ON attendance_records(user_id);
CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance_records(recorded_at DESC);
