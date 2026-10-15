import { useState, useEffect, FormEvent } from 'react';
import { useAuth } from '../lib/auth';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { Location } from '../types';

export default function Login() {
  const { user, locationId, locationName, locationUsers, login, loginSuperadmin, setLocation } = useAuth();
  const navigate = useNavigate();

  const [step, setStep] = useState<'location' | 'user'>(locationId ? 'user' : 'location');
  const [locations, setLocations] = useState<Location[]>([]);
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [loadingLocations, setLoadingLocations] = useState(true);
  const [locationsError, setLocationsError] = useState('');
  const [ownerLogin, setOwnerLogin] = useState(false);
  const [ownerEmail, setOwnerEmail] = useState('');
  const [ownerPassword, setOwnerPassword] = useState('');

  useEffect(() => {
    if (user) {
      navigate(user.role === 'OWNER' && !locationId ? '/admin/sucursales' : '/');
      return;
    }
    loadLocations();
  }, [user, locationId]);

  async function loadLocations() {
    setLoadingLocations(true);
    setLocationsError('');
    try {
      const { data, error } = await supabase
        .from('locations')
        .select('id,name,business_id,active,created_at')
        .eq('active', true)
        .order('name');
      if (error) throw error;
      setLocations(data || []);
    } catch (err) {
      console.error('Error loading locations:', err);
      setLocationsError('No se pudo consultar la lista de sucursales. Revisa tu conexión y vuelve a intentar.');
    } finally {
      setLoadingLocations(false);
    }
  }

  function selectLocation(loc: Location) {
    setLocation(loc.id, loc.name);
    setStep('user');
    if (navigator.vibrate) navigator.vibrate(30);
  }

  async function handleLogin(e: FormEvent) {
    e.preventDefault();
    const selectedUser = locationUsers.find((u) => u.user_id === selectedUserId);
    if (!selectedUser) {
      setError('Selecciona tu usuario');
      return;
    }
    if (!password.trim()) {
      setError('Ingresa tu contraseña');
      return;
    }

    setLoading(true);
    setError('');
    try {
      await login(selectedUser.user_id, password);
      if (navigator.vibrate) navigator.vibrate([50, 30, 50]);
      navigate('/');
    } catch (err: any) {
      setError(err?.message || 'Credenciales incorrectas');
    } finally {
      setLoading(false);
    }
  }

  async function handleOwnerLogin(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError('');
    try {
      await loginSuperadmin(ownerEmail, ownerPassword);
      navigate('/admin/sucursales');
    } catch (err: any) {
      setError(err?.message || 'No se pudo validar el acceso de propietario.');
    } finally {
      setLoading(false);
    }
  }

  // Location selection step
  if (step === 'location') {
    return (
    <div className="login-screen login-screen-locations">
      <main className="login-locations-shell">
        <header className="login-brand-row">
          <div className="login-logo">
          <svg viewBox="0 0 24 24" fill="none" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
            <path d="M18 8h1a4 4 0 0 1 0 8h-1" />
            <path d="M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8z" />
            <line x1="6" y1="1" x2="6" y2="4" />
            <line x1="10" y1="1" x2="10" y2="4" />
            <line x1="14" y1="1" x2="14" y2="4" />
          </svg>
          </div>
          <div className="login-brand-copy"><div className="login-title">La Cabaña</div><div className="login-sub">Punto de venta · acceso seguro</div></div>
          <span className="login-brand-tag">PUNTO DE VENTA</span>
        </header>

        <section className="login-location-intro">
          <span className="login-overline">ACCESO AL EQUIPO</span>
          <h1>¿Dónde vas a trabajar?</h1>
          <p>Elige una sucursal para entrar al punto de venta. El propietario puede administrar el negocio sin seleccionar una.</p>
        </section>

        {loadingLocations ? (
          <div className="loading login-locations-loading">
            <div className="spinner" />
          </div>
        ) : locationsError ? (
          <section className="login-no-locations login-location-error" role="alert">
            <div className="login-empty-mark">!</div><div><b>No se cargaron las sucursales</b><p>{locationsError}</p><button type="button" onClick={() => void loadLocations()}>Volver a consultar</button></div>
          </section>
        ) : locations.length === 0 ? (
          <section className="login-no-locations">
            <div className="login-empty-mark"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><path d="M3 21h18M5 21V7l7-4 7 4v14M9 21v-6h6v6M9 9h.01M15 9h.01"/></svg></div>
            <div><b>Aún no hay sucursales</b><p>El dueño o SuperAdmin debe crear la primera sucursal desde Administración del negocio. No hay que crear una sucursal inicial.</p></div>
          </section>
        ) : (
          <div className="location-grid login-location-grid">
            {locations.map((loc) => (
              <button
                key={loc.id}
                className="location-card"
                onClick={() => selectLocation(loc)}
              >
                <div className="location-icon">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z" />
                    <circle cx="12" cy="10" r="3" />
                  </svg>
                </div>
                <span className="location-card-copy"><span className="location-name">{loc.name}</span><small>Entrar a esta sucursal</small></span>
                <span className="location-card-arrow">→</span>
              </button>
            ))}
          </div>
        )}
        {!ownerLogin ? (
          <button className="owner-access-link" onClick={() => { setOwnerLogin(true); setError(''); }}>
            <span className="owner-access-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><path d="M3 21h18M5 21V7l7-4 7 4v14M9 21v-6h6v6"/><path d="M9 9h.01M15 9h.01"/></svg></span>
            <span><b>Administrar el negocio</b><small>Dueño o SuperAdmin · crear y gestionar sucursales</small></span>
            <span className="location-card-arrow">→</span>
          </button>
        ) : (
          <form className="owner-login-card" onSubmit={handleOwnerLogin}>
            <div className="owner-login-heading">Acceso de administración</div>
            <p>Entra directamente al negocio. No necesitas una sucursal creada para administrar sucursales.</p>
            <input className="login-input" type="email" autoComplete="username" placeholder="Correo de propietario" value={ownerEmail} onChange={e => setOwnerEmail(e.target.value)} required />
            <input className="login-input" type="password" autoComplete="current-password" placeholder="Contraseña" value={ownerPassword} onChange={e => setOwnerPassword(e.target.value)} required />
            {error && <div className="login-err" role="alert">{error}</div>}
            <button className="login-btn" type="submit" disabled={loading}>{loading ? 'Verificando…' : 'ENTRAR A ADMINISTRACIÓN'}</button>
            <button className="owner-back-link" type="button" onClick={() => { setOwnerLogin(false); setOwnerPassword(''); setError(''); }}>Volver al acceso por sucursal</button>
          </form>
        )}
        <footer className="login-location-footer"><span>LA CABAÑA</span><span>·</span><span>v2.0.0 PWA</span></footer>
      </main>
      </div>
    );
  }

  // User selection + password step
  return (
    <div className="login-screen">
      <div className="login-logo">
        <svg viewBox="0 0 24 24" fill="none" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
          <path d="M18 8h1a4 4 0 0 1 0 8h-1" />
          <path d="M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8z" />
          <line x1="6" y1="1" x2="6" y2="4" />
          <line x1="10" y1="1" x2="10" y2="4" />
          <line x1="14" y1="1" x2="14" y2="4" />
        </svg>
      </div>
      <div className="login-title">{locationName || 'La Cabaña'}</div>
      <div className="login-sub">¿Quién eres?</div>

      <div className="user-avatar-grid">
        {locationUsers.map((u) => (
          <button
            key={u.user_id}
            className={`user-avatar ${selectedUserId === u.user_id ? 'selected' : ''}`}
            onClick={() => { setSelectedUserId(u.user_id); setError(''); }}
          >
            <div className="avatar-circle">
              {u.display_name?.charAt(0).toUpperCase() || '?'}
            </div>
            <span className="avatar-name">{u.display_name}</span>
          </button>
        ))}
      </div>

      {selectedUserId && (
        <form className="login-form" onSubmit={handleLogin}>
          <input
            className="login-input"
            type="password"
            placeholder="Contraseña"
            autoComplete="off"
            autoFocus
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          <div className="login-err">{error}</div>
          <button className="login-btn" type="submit" disabled={loading}>
            {loading ? 'Ingresando...' : 'INGRESAR'}
          </button>
        </form>
      )}

      <button
        className="link-btn"
        onClick={() => { setStep('location'); setSelectedUserId(null); setPassword(''); }}
        style={{ marginTop: 12 }}
      >
        Cambiar terminal
      </button>
      <div className="version">v2.0.0 PWA</div>
    </div>
  );
}
