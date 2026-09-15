export interface User {
  id: string;
  username: string;
  display_name?: string;
  role: 'ADMIN' | 'CAJA' | 'MESERO' | 'COCINA' | 'ASADOR';
}

export interface Product {
  id: string;
  name: string;
  price_cents: number;
  category: string;
  active: boolean;
  sort_order: number;
  image_data?: string;
  location_id: string;
}

export interface Order {
  id: string;
  ticket_id: string;
  table_id?: string;
  table_name?: string;
  customer_name: string;
  status: 'RECEIVED' | 'PREPARING' | 'READY' | 'SERVED' | 'CANCELLED';
  created_at: string;
  updated_at?: string;
  notes?: string;
  source: 'POS' | 'MOBILE';
  waiter_name: string;
  table_label?: string;
  total?: number;
  items?: OrderItem[];
}

export interface OrderItem {
  id: string;
  order_id: string;
  product_id: string;
  product_name: string;
  quantity: number;
  unit_price: number;
  notes?: string;
  category?: string;
}

export interface Ticket {
  id: string;
  code: string;
  status: 'PENDIENTE' | 'PAGADO' | 'ANULADO' | 'DEVUELTO';
  payment_method: string;
  total: number;
  created_at: string;
  paid_at?: string;
  cashier_user_id?: string;
  customer_name?: string;
  notes?: string;
}

export interface AttendanceRecord {
  id: string;
  user_id: string;
  type: 'ENTRY' | 'EXIT';
  recorded_at: string;
  device_id?: string;
  client_event_id: string;
  status: 'SYNCED' | 'CORRECTED';
}

export interface CartItem {
  id: string;
  name: string;
  price_cents: number;
  qty: number;
  notes: string;
}
