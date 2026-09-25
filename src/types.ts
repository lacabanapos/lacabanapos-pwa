export interface User {
  id: string;
  username: string;
  display_name?: string;
  role: 'OWNER' | 'ADMIN' | 'CAJA' | 'MESERO' | 'COCINA' | 'ASADOR';
}

export interface Location {
  id: string;
  name: string;
  business_id: string;
  active: boolean;
  created_at: string;
}

export interface LocationMembership {
  id: string;
  location_id: string;
  profile_id: string;
  role: string;
  active: boolean;
}

export interface LocationUser {
  user_id: string;
  username: string;
  display_name: string;
  user_role: string;
}

export interface Product {
  id: string;
  name: string;
  price_cents: number;
  category_id: string;
  category_name?: string;
  active: boolean;
  sort_order: number;
  image_data?: string;
  location_id: string;
}

export interface Category {
  id: string;
  name: string;
  sort_order: number;
}

export interface Order {
  id: string;
  ticket_id?: string;
  customer_name: string;
  status: 'RECEIVED' | 'PREPARING' | 'READY' | 'SERVED' | 'CANCELLED';
  created_at: string;
  updated_at?: string;
  notes?: string;
  source: 'POS' | 'MOBILE';
  waiter_id: string;
  waiter_name?: string;
  total?: number;
  items?: OrderItem[];
}

export interface OrderItem {
  id: string;
  order_id: string;
  product_id: string;
  product_name: string;
  quantity: number;
  unit_price_cents?: number;
  unit_price?: number;
  notes?: string;
}

export interface Ticket {
  id: string;
  code: string;
  status: 'PENDING' | 'PAID' | 'CANCELLED';
  payment_method: string;
  total_cents: number;
  created_at: string;
  paid_at?: string;
  cashier_id?: string;
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
