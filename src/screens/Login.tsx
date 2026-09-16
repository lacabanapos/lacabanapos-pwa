import { useState, useEffect, FormEvent } from 'react';
import { useAuth } from '../lib/auth';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { Location } from '../types';

export default function Login() {
  const { user, locationId, locationName, locationUsers, login, setLocation } = useAuth();
  const navigate = useNavigate();

  const [step, setStep] = useState<'location' | 'user'>(locationId ? 'user' : 'location');
  const [locations, setLocations] = useState<Location[]>([]);
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [loadingLocations, setLoadingLocations] = useState(true);

  useEffect(() => {
    if (user && locationId) {
      navigate('/');
      return;
    }
    loadLocations();
  }, [user, locationId]);

  async function loadLocations() {
    try {
      const { data, error } = await supabase
        .from('locations')
        .select('*')
        .eq('active', true)
        .order('name');
      if (error) throw error;
      setLocations(data || []);
    } catch (err) {
      console.error('Error loading locations:', err);
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
      await login(selectedUser.username, password);
      if (navigator.vibrate) navigator.vibrate([50, 30, 50]);
      navigate('/');
    } catch (err: any) {
      setError(err?.message || 'Credenciales incorrectas');
    } finally {
      setLoading(false);
    }
  }

  // Location selection step
  if (step === 'location') {
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
        <div className="login-title">La Cabaña</div>
        <div className="login-sub">Selecciona tu terminal</div>

        {loadingLocations ? (
          <div className="loading" style={{ marginTop: 24 }}>
            <div className="spinner" />
          </div>
        ) : locations.length === 0 ? (
          <div className="empty" style={{ marginTop: 24, color: 'var(--text2)' }}>
            No hay terminales registradas
          </div>
        ) : (
          <div className="location-grid">
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
                <span className="location-name">{loc.name}</span>
              </button>
            ))}
          </div>
        )}
        <div className="version">v2.0.0 PWA</div>
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
              {u.display_name?.charAt(0).toUpperCase() || u.username.charAt(0).toUpperCase()}
            </div>
            <span className="avatar-name">{u.display_name || u.username}</span>
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
