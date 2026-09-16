import { useState, useEffect, useRef } from 'react';
import { useAuth } from '../lib/auth';
import { supabase } from '../lib/supabase';
import { Product, Order, CartItem, Category } from '../types';
import { useNavigate } from 'react-router-dom';

const STATUS_LABELS: Record<string, string> = {
  RECEIVED: 'Recibido',
  PREPARING: 'Preparando',
  READY: 'Listo',
  SERVED: 'Servido',
  CANCELLED: 'Anulada',
};

export default function Waiter() {
  const { user, logout } = useAuth();
  const navigate = useNavigate();

  const [tab, setTab] = useState<'menu' | 'orders' | 'history'>('menu');
  const [products, setProducts] = useState<Product[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [selectedCat, setSelectedCat] = useState<string>('all');
  const [searchQuery, setSearchQuery] = useState('');
  const [cart, setCart] = useState<CartItem[]>([]);
  const [customerName, setCustomerName] = useState('');
  const [orderNotes, setOrderNotes] = useState('');
  const [cartOpen, setCartOpen] = useState(false);
  const [successOpen, setSuccessOpen] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');
  const [activeOrders, setActiveOrders] = useState<Order[]>([]);
  const [historyOrders, setHistoryOrders] = useState<Order[]>([]);
  const [showCancelled, setShowCancelled] = useState(false);
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const knownReadyRef = useRef<Record<string, string>>({});

  useEffect(() => {
    if (!user) {
      navigate('/login');
      return;
    }
    loadData();
    const interval = setInterval(() => {
      if (tab === 'orders') loadActiveOrders();
    }, 3000);
    return () => clearInterval(interval);
  }, [user, tab]);

  async function loadData() {
    try {
      const [prodsRes, catsRes] = await Promise.all([
        supabase.from('products').select('*, categories!products_category_id_fkey(name)').eq('active', true).order('sort_order'),
        supabase.from('categories').select('*').eq('active', true).order('sort_order'),
      ]);

      if (prodsRes.error) throw prodsRes.error;
      if (catsRes.error) throw catsRes.error;

      const prods = (prodsRes.data || []).map((p: any) => ({
        ...p,
        category_name: p.categories?.name || '',
      })) as Product[];
      setProducts(prods);
      setCategories(catsRes.data || []);
    } catch (err) {
      console.error('Error loading data:', err);
    } finally {
      setLoading(false);
    }
  }

  async function loadActiveOrders() {
    if (!user) return;
    try {
      const { data, error } = await supabase
        .from('orders')
        .select('*, order_items(*)')
        .eq('waiter_id', user.id)
        .in('status', ['RECEIVED', 'PREPARING', 'READY'])
        .order('created_at', { ascending: false });

      if (error) throw error;
      const orders = (data || []) as Order[];
      checkReadyOrders(orders);
      setActiveOrders(orders);
    } catch (err) {
      console.error('Error loading orders:', err);
    }
  }

  async function loadHistory() {
    if (!user) return;
    try {
      const { data, error } = await supabase
        .from('orders')
        .select('*, order_items(*)')
        .eq('waiter_id', user.id)
        .order('created_at', { ascending: false })
        .limit(50);

      if (error) throw error;
      setHistoryOrders((data || []) as Order[]);
    } catch (err) {
      console.error('Error loading history:', err);
    }
  }

  function checkReadyOrders(orders: Order[]) {
    for (const order of orders) {
      if (order.status === 'READY' && knownReadyRef.current[order.id] !== 'READY') {
        if (Object.keys(knownReadyRef.current).length > 0) {
          playReadySound();
          if (navigator.vibrate) navigator.vibrate([90, 50, 90]);
        }
      }
    }
    const map: Record<string, string> = {};
    orders.forEach((o) => { map[o.id] = o.status; });
    knownReadyRef.current = map;
  }

  function playReadySound() {
    try {
      if (!audioCtxRef.current) audioCtxRef.current = new AudioContext();
      const ctx = audioCtxRef.current;
      const now = ctx.currentTime;
      [784, 1046].forEach((freq, i) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.frequency.value = freq;
        gain.gain.setValueAtTime(0.001, now + i * 0.16);
        gain.gain.exponentialRampToValueAtTime(0.15, now + i * 0.16 + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.001, now + i * 0.16 + 0.2);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(now + i * 0.16);
        osc.stop(now + i * 0.16 + 0.22);
      });
    } catch {}
  }

  function addToCart(product: Product) {
    setCart((prev) => {
      const existing = prev.find((c) => c.id === product.id);
      if (existing) {
        return prev.map((c) => c.id === product.id ? { ...c, qty: c.qty + 1 } : c);
      }
      return [...prev, { id: product.id, name: product.name, price_cents: product.price_cents, qty: 1, notes: '' }];
    });
    if (navigator.vibrate) navigator.vibrate(30);
  }

  function updateQty(idx: number, delta: number) {
    setCart((prev) => {
      const next = [...prev];
      next[idx] = { ...next[idx], qty: next[idx].qty + delta };
      if (next[idx].qty <= 0) next.splice(idx, 1);
      return next;
    });
    if (navigator.vibrate) navigator.vibrate(20);
  }

  function setItemNote(idx: number, note: string) {
    setCart((prev) => prev.map((c, i) => i === idx ? { ...c, notes: note } : c));
  }

  const cartTotal = cart.reduce((sum, c) => sum + c.price_cents * c.qty, 0);
  const cartCount = cart.reduce((sum, c) => sum + c.qty, 0);

  async function sendOrder() {
    if (!cart.length || !user) return;
    setSending(true);
    try {
      const items = cart.map((c) => ({
        product_id: c.id,
        product_name: c.name,
        quantity: c.qty,
        unit_price_cents: c.price_cents,
        notes: c.notes || null,
      }));

      const { data, error } = await supabase.rpc('create_order', {
        p_customer_name: customerName.trim() || 'Sin nombre',
        p_waiter_id: user.id,
        p_notes: orderNotes.trim() || null,
        p_items: items,
      });

      if (error) throw error;

      setCart([]);
      setCustomerName('');
      setOrderNotes('');
      setCartOpen(false);
      setSuccessMsg(`Tu pedido ha sido enviado a cocina.`);
      setSuccessOpen(true);
      if (navigator.vibrate) navigator.vibrate([100, 50, 100]);
    } catch (err: any) {
      alert('Error: ' + (err.message || 'No se pudo enviar la orden'));
    } finally {
      setSending(false);
    }
  }

  function filteredProducts() {
    let filtered = selectedCat === 'all'
      ? products
      : products.filter((p) => p.category_id === selectedCat);
    if (searchQuery) {
      const q = searchQuery.toLowerCase();
      filtered = filtered.filter((p) => p.name.toLowerCase().includes(q));
    }
    return filtered;
  }

  function formatDate(ts: string) {
    if (!ts) return '';
    return new Date(ts).toLocaleDateString('es-EC') + ' ' + new Date(ts).toLocaleTimeString('es-EC', { hour: '2-digit', minute: '2-digit' });
  }

  const statuses = ['RECEIVED', 'PREPARING', 'READY', 'SERVED'];

  return (
    <div className="waiter-app">
      <div className="topbar">
        <div className="topbar-brand">
          <div className="topbar-logo">
            <svg viewBox="0 0 24 24" fill="none" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
              <path d="M18 8h1a4 4 0 0 1 0 8h-1" />
              <path d="M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8z" />
              <line x1="6" y1="1" x2="6" y2="4" />
              <line x1="10" y1="1" x2="10" y2="4" />
              <line x1="14" y1="1" x2="14" y2="4" />
            </svg>
          </div>
          <div>
            <h1>La Cabaña</h1>
            <span className="waiter-badge">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
                <circle cx="12" cy="7" r="4" />
              </svg>
              {user?.username || 'Mesero'}
            </span>
          </div>
        </div>
        <div className="topbar-actions">
          <div className="status-dot" />
          <button className="btn-logout" onClick={() => { logout(); navigate('/login'); }}>Salir</button>
        </div>
      </div>

      <div className="nav-tabs">
        <button className={`nav-tab ${tab === 'menu' ? 'active' : ''}`} onClick={() => setTab('menu')}>Menu</button>
        <button className={`nav-tab ${tab === 'orders' ? 'active' : ''}`} onClick={() => { setTab('orders'); loadActiveOrders(); }}>Ordenes</button>
        <button className={`nav-tab ${tab === 'history' ? 'active' : ''}`} onClick={() => { setTab('history'); loadHistory(); }}>Historial</button>
      </div>

      {tab === 'menu' && (
        <div className="tab-content active">
          <div className="cliente-bar">
            <label>Cliente:</label>
            <input type="text" placeholder="Ej: Mesa 4, Carolina..." value={customerName} onChange={(e) => setCustomerName(e.target.value)} autoComplete="off" />
          </div>
          <div className="search-bar">
            <input type="text" placeholder="Buscar producto..." value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} autoComplete="off" />
          </div>
          <div className="cats">
            <button className={`cat ${selectedCat === 'all' ? 'active' : ''}`} onClick={() => setSelectedCat('all')}>Todos</button>
            {categories.map((c) => (
              <button key={c.id} className={`cat ${c.id === selectedCat ? 'active' : ''}`} onClick={() => setSelectedCat(c.id)}>{c.name}</button>
            ))}
          </div>
          <div className="products">
            {loading ? (
              <div className="loading"><div className="spinner" /></div>
            ) : filteredProducts().length === 0 ? (
              <div className="empty">No hay productos</div>
            ) : (
              filteredProducts().map((p) => (
                <div key={p.id} className="prod" onClick={() => addToCart(p)}>
                  <div className="prod-info">
                    <div className="prod-name">{p.name}</div>
                    <div className="prod-price-container">
                      <span className="prod-price">${(p.price_cents / 100).toFixed(2)}</span>
                    </div>
                  </div>
                </div>
              ))
            )}
          </div>
          {cart.length > 0 && (
            <div className="cart-bar">
              <div className="cart-info">
                <span className="cart-badge">{cartCount}</span>
                <div>
                  <div className="cart-total">${(cartTotal / 100).toFixed(2)}</div>
                  <div className="cart-label">items</div>
                </div>
              </div>
              <button className="btn-cart" onClick={() => { setCartOpen(true); }}>VER PEDIDO</button>
            </div>
          )}
        </div>
      )}

      {tab === 'orders' && (
        <div className="tab-content active">
          <div className="orders-header">
            <span className="title">Mis Ordenes</span>
            <button onClick={loadActiveOrders} style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: '8px', padding: '6px 12px', color: 'var(--text2)', fontSize: '11px', fontWeight: 600, cursor: 'pointer' }}>Refrescar</button>
          </div>
          <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 20 }}>
            {activeOrders.length === 0 ? (
              <div className="empty">No hay órdenes activas</div>
            ) : (
              activeOrders.map((o) => {
                const currentIdx = statuses.indexOf(o.status);
                return (
                  <div key={o.id} className={`order-card card-${o.status}`}>
                    <div className="order-head">
                      <span className="order-id">#{o.id.slice(0, 8)}</span>
                      <span className="order-customer">{o.customer_name}</span>
                      <span className={`order-status ${o.status}`}>{STATUS_LABELS[o.status]}</span>
                    </div>
                    <div className="status-timeline">
                      {statuses.map((s, j) => (
                        <div key={s} style={{ display: 'contents' }}>
                          {j > 0 && <div className={`timeline-line ${j <= currentIdx ? 'done' : ''}`} />}
                          <div className={`timeline-dot ${j < currentIdx ? 'done' : j === currentIdx ? 'active' : ''}`}>
                            {j <= currentIdx && <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3"><polyline points="20 6 9 17 4 12" /></svg>}
                          </div>
                        </div>
                      ))}
                    </div>
                    <div className="order-meta">
                      <span>{o.waiter_name}</span>
                    </div>
                    <div className="order-items-list">
                      {o.items?.map((it) => (
                        <span key={it.id} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, margin: '2px 0', padding: '2px 4px', background: 'var(--surface)', borderRadius: 6 }}>
                          <span style={{ fontWeight: 800, color: '#000', background: 'linear-gradient(135deg,var(--gold),var(--gold-bright))', padding: '1px 7px', borderRadius: 5, fontSize: 11 }}>{it.quantity}x</span>
                          {it.product_name}
                          {it.notes && <i style={{ color: 'var(--gold)', fontSize: 11 }}>({it.notes})</i>}
                        </span>
                      ))}
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>
      )}

      {tab === 'history' && (
        <div className="tab-content active">
          <div className="orders-header">
            <span className="title">Mi Historial</span>
            <button onClick={loadHistory} style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: '8px', padding: '6px 12px', color: 'var(--text2)', fontSize: '11px', fontWeight: 600, cursor: 'pointer' }}>Actualizar</button>
          </div>
          <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 20 }}>
            {historyOrders.length === 0 ? (
              <div className="empty">No tienes pedidos aún</div>
            ) : (
              historyOrders.map((o) => (
                <div key={o.id} className={`order-card card-${o.status}`}>
                  <div className="order-head">
                    <span className="order-id">#{o.id.slice(0, 8)}</span>
                    <span className="order-customer">{o.customer_name}</span>
                    <span className={`order-status ${o.status}`}>{STATUS_LABELS[o.status]}</span>
                  </div>
                  <div className="order-meta">
                    <span className="order-date">{formatDate(o.created_at)}</span>
                  </div>
                  <div className="order-items-list">
                    {o.items?.map((it) => (
                      <span key={it.id} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, margin: '2px 0', padding: '2px 4px', background: 'var(--surface2)', borderRadius: 6 }}>
                        <span style={{ fontWeight: 800, color: '#000', background: 'linear-gradient(135deg,var(--gold),var(--gold-bright))', padding: '1px 7px', borderRadius: 5, fontSize: 11 }}>{it.quantity}x</span>
                        {it.product_name}
                      </span>
                    ))}
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      )}

      {cartOpen && (
        <div className="overlay open" onClick={(e) => { if (e.target === e.currentTarget) setCartOpen(false); }}>
          <div className="sheet">
            <div className="sheet-head">
              <h2>Tu Pedido</h2>
              <button className="sheet-close" onClick={() => setCartOpen(false)}>X</button>
            </div>
            <div className="sheet-body">
              {cart.length === 0 ? (
                <div className="empty">Carrito vacío</div>
              ) : (
                cart.map((item, i) => (
                  <div key={item.id} className="cart-item">
                    <div className="ci-info">
                      <div className="ci-name">{item.name}</div>
                      <div className="ci-price">${(item.price_cents / 100).toFixed(2)} c/u</div>
                      <input
                        className="ci-note-input"
                        type="text"
                        placeholder="Nota (ej: sin cebolla)"
                        value={item.notes}
                        onChange={(e) => setItemNote(i, e.target.value)}
                      />
                    </div>
                    <div className="qty-ctrl">
                      <button className={`qty-btn ${item.qty <= 1 ? 'del' : ''}`} onClick={() => updateQty(i, -1)}>
                        {item.qty <= 1 ? '🗑' : '−'}
                      </button>
                      <span className="qty-val">{item.qty}</span>
                      <button className="qty-btn" onClick={() => updateQty(i, 1)}>+</button>
                    </div>
                  </div>
                ))
              )}
            </div>
            <div className="notes-box">
              <textarea placeholder="Nota general del pedido (opcional)..." value={orderNotes} onChange={(e) => setOrderNotes(e.target.value)} />
            </div>
            <div className="sheet-footer">
              <div className="sheet-total"><span>TOTAL</span><span className="amount">${(cartTotal / 100).toFixed(2)}</span></div>
              <button className="btn-send" onClick={sendOrder} disabled={sending}>
                {sending ? 'Enviando...' : 'ENVIAR ORDEN'}
              </button>
            </div>
            <button className="btn-discard" onClick={() => { if (confirm('Descartar todo?')) { setCart([]); setCartOpen(false); } }}>
              DESCARTAR PEDIDO
            </button>
          </div>
        </div>
      )}

      {successOpen && (
        <div className="success-modal open">
          <div className="success-box">
            <div className="success-icon">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            </div>
            <h3>Orden Enviada!</h3>
            <p>{successMsg}</p>
            <button onClick={() => setSuccessOpen(false)}>NUEVA ORDEN</button>
          </div>
        </div>
      )}
    </div>
  );
}
