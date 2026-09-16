import { useState, useEffect, useRef } from 'react';
import { useAuth } from '../lib/auth';
import { supabase } from '../lib/supabase';
import { Order } from '../types';
import { useNavigate } from 'react-router-dom';

const STATUS_LABELS: Record<string, string> = {
  RECEIVED: 'Recibido',
  PREPARING: 'Preparando',
  READY: 'Listo',
  SERVED: 'Servido',
  CANCELLED: 'Anulado',
};

const STATUS_COLORS: Record<string, string> = {
  RECEIVED: 'var(--accent-received)',
  PREPARING: 'var(--accent-preparing)',
  READY: 'var(--accent-ready)',
  SERVED: 'var(--text3)',
  CANCELLED: 'var(--accent-cancelled)',
};

export default function Kitchen() {
  const { user, locationId, locationName, logout } = useAuth();
  const navigate = useNavigate();
  const [orders, setOrders] = useState<Order[]>([]);
  const [filter, setFilter] = useState('all');
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const knownOrdersRef = useRef<Set<string>>(new Set());
  const audioCtxRef = useRef<AudioContext | null>(null);

  useEffect(() => {
    if (!user || !locationId) {
      navigate('/login');
      return;
    }
    loadOrders();
    const interval = setInterval(loadOrders, 3000);
    return () => clearInterval(interval);
  }, [user, locationId]);

  async function loadOrders() {
    if (!locationId) return;
    try {
      const { data, error } = await supabase
        .from('orders')
        .select('*, order_items(*), profiles!orders_waiter_id_fkey(username)')
        .eq('location_id', locationId)
        .in('status', ['RECEIVED', 'PREPARING', 'READY'])
        .order('created_at', { ascending: true });

      if (error) throw error;

      const newOrders = (data || []).map((o: any) => ({
        ...o,
        waiter_name: o.profiles?.username || '',
        profiles: undefined,
      })) as Order[];

      checkNewOrders(newOrders);
      setOrders(newOrders);
    } catch (err) {
      console.error('Error loading orders:', err);
    } finally {
      setLoading(false);
    }
  }

  function checkNewOrders(newOrders: Order[]) {
    for (const order of newOrders) {
      if (order.status === 'RECEIVED' && !knownOrdersRef.current.has(order.id)) {
        if (knownOrdersRef.current.size > 0) {
          playNotification();
          if (navigator.vibrate) navigator.vibrate([120, 70, 120]);
        }
      }
    }
    knownOrdersRef.current = new Set(newOrders.map((o) => o.id));
  }

  function playNotification() {
    try {
      if (!audioCtxRef.current) {
        audioCtxRef.current = new AudioContext();
      }
      const ctx = audioCtxRef.current;
      const now = ctx.currentTime;
      [523, 783, 1046].forEach((freq, i) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.frequency.value = freq;
        gain.gain.setValueAtTime(0.001, now + i * 0.12);
        gain.gain.exponentialRampToValueAtTime(0.15, now + i * 0.12 + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.001, now + i * 0.12 + 0.14);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(now + i * 0.12);
        osc.stop(now + i * 0.12 + 0.15);
      });
    } catch {}
  }

  async function changeStatus(id: string, status: string) {
    try {
      const { error } = await supabase
        .from('orders')
        .update({ status, updated_at: new Date().toISOString() })
        .eq('id', id);
      if (error) throw error;
      if (navigator.vibrate) navigator.vibrate([50, 30, 50]);
      loadOrders();
    } catch (err: any) {
      alert('Error: ' + err.message);
    }
  }

  async function cancelOrder(id: string) {
    if (!confirm('Anular orden #' + id + '?')) return;
    try {
      const { error } = await supabase
        .from('orders')
        .update({ status: 'CANCELLED', updated_at: new Date().toISOString() })
        .eq('id', id);
      if (error) throw error;
      if (navigator.vibrate) navigator.vibrate([100, 50, 100]);
      loadOrders();
    } catch (err: any) {
      alert('Error: ' + err.message);
    }
  }

  function getTimeAgo(ts: string) {
    if (!ts) return '';
    const diff = Math.floor((Date.now() - new Date(ts).getTime()) / 60000);
    if (diff < 1) return 'ahora';
    if (diff < 60) return diff + 'm';
    return Math.floor(diff / 60) + 'h ' + (diff % 60) + 'm';
  }

  const filtered = filter === 'all'
    ? orders
    : orders.filter((o) => o.status === filter);

  return (
    <div className="kitchen-app">
      <div className="topbar">
        <div className="topbar-brand">
          <div className="topbar-logo">
            <svg viewBox="0 0 24 24" fill="none" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
              <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
              <circle cx="9" cy="7" r="4" />
              <path d="M23 21v-2a4 4 0 0 0-3-3.87" />
              <path d="M16 3.13a4 4 0 0 1 0 7.75" />
            </svg>
          </div>
          <div>
            <h1>{locationName || 'Cocina'}</h1>
            <small>{orders.length} órdenes activas</small>
          </div>
        </div>
        <div className="topbar-actions">
          <span className="order-count-badge">{orders.length}</span>
          <div className="status-dot" />
          <button className="btn-logout" onClick={() => { logout(); navigate('/login'); }}>Salir</button>
        </div>
      </div>

      <div className="filter-bar">
        {['all', 'RECEIVED', 'PREPARING', 'READY'].map((f) => (
          <button
            key={f}
            className={`filter-btn ${filter === f ? 'active' : ''}`}
            onClick={() => setFilter(f)}
          >
            {f === 'all' ? 'Todas' : STATUS_LABELS[f]}
          </button>
        ))}
      </div>

      <div className="orders-list">
        {loading ? (
          <div className="loading"><div className="spinner" /></div>
        ) : filtered.length === 0 ? (
          <div className="empty">No hay órdenes{filter !== 'all' ? ' con este estado' : ''}</div>
        ) : (
          filtered.map((order) => (
            <div key={order.id} className={`order-card status-${order.status}`}>
              <div className="order-header" onClick={() => setExpandedId(expandedId === order.id ? null : order.id)}>
                <span className="order-id">#{order.id.slice(0, 8)}</span>
                <span className="order-customer">{order.customer_name || ''}</span>
                <span className="order-time">{getTimeAgo(order.created_at)}</span>
                <span className={`order-status ${order.status}`}>{STATUS_LABELS[order.status]}</span>
                <span className={`accordion-arrow ${expandedId === order.id ? 'open' : ''}`}>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                    <polyline points="6 9 12 15 18 9" />
                  </svg>
                </span>
              </div>

              <div className={`order-body ${expandedId === order.id ? 'open' : ''}`}>
                <div className="order-inner">
                  <div className="order-waiter">
                    <span className="waiter-name">{order.waiter_name}</span>
                  </div>
                  <div className="order-items">
                    {order.items?.map((item) => (
                      <div key={item.id} className="order-item">
                        <span className="oi-qty">{item.quantity}x</span>
                        <div className="oi-name">
                          {item.product_name}
                          {item.notes && <span className="oi-notes">{item.notes}</span>}
                        </div>
                        <span className="oi-price">${((item.unit_price_cents * item.quantity) / 100).toFixed(2)}</span>
                      </div>
                    ))}
                  </div>
                  <div className="order-actions">
                    {order.status === 'RECEIVED' && (
                      <button className="action-btn receive" onClick={() => changeStatus(order.id, 'PREPARING')}>
                        RECIBIDO
                      </button>
                    )}
                    {order.status === 'PREPARING' && (
                      <button className="action-btn dispatch" onClick={() => changeStatus(order.id, 'READY')}>
                        DESPACHADO
                      </button>
                    )}
                    <button className="action-btn cancel" onClick={() => cancelOrder(order.id)}>
                      ANULAR
                    </button>
                  </div>
                </div>
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
