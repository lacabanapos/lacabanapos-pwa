import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';
import { useSearchParams } from 'react-router-dom';

function getDeviceId(): string {
  let id = localStorage.getItem('attendance_device_id');
  if (!id) {
    id = crypto.randomUUID ? crypto.randomUUID() : Date.now() + '-' + Math.random();
    localStorage.setItem('attendance_device_id', id);
  }
  return id;
}

function getGeo(): Promise<{ lat: number; lng: number; accuracy: number } | null> {
  return new Promise((resolve) => {
    if (!navigator.geolocation) { resolve(null); return; }
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ lat: pos.coords.latitude, lng: pos.coords.longitude, accuracy: pos.coords.accuracy }),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 0 }
    );
  });
}

export default function Attendance() {
  const [searchParams] = useSearchParams();
  const locationId = searchParams.get('loc');
  const urlCode = searchParams.get('code');

  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState(urlCode || '');
  const [loginStatus, setLoginStatus] = useState('');
  const [loginLoading, setLoginLoading] = useState(false);
  const [profile, setProfile] = useState<any>(null);
  const [nextType, setNextType] = useState<'ENTRY' | 'EXIT'>('ENTRY');
  const [markStatus, setMarkStatus] = useState('');
  const [markLoading, setMarkLoading] = useState(false);
  const [workerName, setWorkerName] = useState('');
  const [geoStatus, setGeoStatus] = useState<'pending' | 'ok' | 'fail'>('pending');
  const [geoData, setGeoData] = useState<{ lat: number; lng: number; accuracy: number } | null>(null);

  useEffect(() => {
    getGeo().then((g) => {
      setGeoData(g);
      setGeoStatus(g ? 'ok' : 'fail');
    });
  }, []);

  async function handleLogin() {
    if (!username.trim() || !password.trim()) {
      setLoginStatus('Ingresa usuario y contraseña');
      return;
    }
    setLoginLoading(true);
    setLoginStatus('Verificando...');
    try {
      // Use login_pos_user RPC for POS-synced users
      const { data, error } = await supabase.rpc('login_pos_user', {
        p_username: username.trim().toLowerCase(),
        p_password: password,
        p_location_id: locationId || null,
      });
      if (error) throw error;
      if (!data || data.error) throw new Error(data?.error || 'Credenciales incorrectas');

      setProfile({ id: data.user_id, username: data.username, role: data.role });
      setWorkerName(data.username);

      // Check last attendance record
      const { data: lastRecord } = await supabase
        .from('attendance_records')
        .select('type')
        .eq('user_id', data.user_id)
        .order('recorded_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      setNextType(lastRecord?.type === 'ENTRY' ? 'EXIT' : 'ENTRY');
      setLoginStatus('');
    } catch (err: any) {
      setLoginStatus(err?.message || 'Credenciales incorrectas');
    } finally {
      setLoginLoading(false);
    }
  }

  async function handleMark() {
    if (!profile) return;
    setMarkLoading(true);
    setMarkStatus('Registrando...');
    try {
      // Re-fetch geolocation at mark time
      const geo = await getGeo();
      const geoToUse = geo || geoData;

      const clientEventId = crypto.randomUUID ? crypto.randomUUID() : Date.now().toString();

      const { data, error } = await supabase.rpc('mark_attendance', {
        p_user_id: profile.id,
        p_type: nextType,
        p_device_id: getDeviceId(),
        p_client_event_id: clientEventId,
        p_code: code || null,
        p_latitude: geoToUse?.lat || null,
        p_longitude: geoToUse?.lng || null,
        p_accuracy: geoToUse?.accuracy || null,
      });
      if (error) throw error;
      if (data?.error) throw new Error(data.error);

      setMarkStatus(`${nextType === 'ENTRY' ? 'Entrada' : 'Salida'} registrada a las ${new Date().toLocaleTimeString('es-EC', { hour: '2-digit', minute: '2-digit' })}`);
      setNextType(nextType === 'ENTRY' ? 'EXIT' : 'ENTRY');
    } catch (err: any) {
      setMarkStatus(err?.message || 'Error al registrar');
    } finally {
      setMarkLoading(false);
    }
  }

  if (profile) {
    return (
      <div className="attendance-app">
        <main>
          <div className="brand">La Cabaña</div>
          <h1>Control de asistencia</h1>
          <div className="card">
            <div className="worker">
              <div><small>Trabajador</small><br /><strong>{workerName}</strong></div>
              <span>{nextType === 'ENTRY' ? 'Próximo: entrada' : 'Próximo: salida'}</span>
            </div>
            <div className="geo-status" style={{ fontSize: 12, color: geoStatus === 'ok' ? '#10b981' : '#ef4444', marginBottom: 12, textAlign: 'center' }}>
              {geoStatus === 'ok' ? '📍 Ubicación detectada' : geoStatus === 'fail' ? '⚠️ No se pudo obtener ubicación' : '📍 Obteniendo ubicación...'}
              {geoData && <div style={{ fontSize: 11, color: '#888' }}>Precisión: {Math.round(geoData.accuracy)}m</div>}
            </div>
            {urlCode && (
              <div style={{ fontSize: 12, color: '#888', textAlign: 'center', marginBottom: 12 }}>
                Código de acceso verificado
              </div>
            )}
            <button onClick={handleMark} disabled={markLoading}>
              {markLoading ? 'Guardando...' : nextType === 'ENTRY' ? 'Registrar entrada' : 'Registrar salida'}
            </button>
            <button className="secondary" onClick={() => { setProfile(null); setMarkStatus(''); }}>Cerrar sesión</button>
            <div className={`status ${markStatus.includes('registrada') ? 'ok' : markStatus.includes('Error') || markStatus.includes('invalido') ? 'error' : ''}`}>{markStatus}</div>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="attendance-app">
      <main>
        <div className="brand">La Cabaña</div>
        <h1>Control de asistencia</h1>
        <p>Registra tu llegada o salida desde tu celular.</p>
        <section className="card">
          <label>Usuario<input type="text" placeholder="Tu usuario" value={username} onChange={(e) => setUsername(e.target.value)} autoComplete="username" /></label>
          <label>Contraseña<input type="password" placeholder="••••" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" /></label>
          {urlCode && (
            <label>Código de acceso<input type="text" placeholder="Código numérico" value={code} onChange={(e) => setCode(e.target.value)} maxLength={12} style={{ fontFamily: 'monospace', letterSpacing: 2 }} /></label>
          )}
          <button onClick={handleLogin} disabled={loginLoading}>{loginLoading ? 'Verificando...' : 'Ingresar'}</button>
          <div className={`status ${loginStatus.includes('incorrecta') || loginStatus.includes('Error') ? 'error' : ''}`}>{loginStatus}</div>
        </section>
      </main>
    </div>
  );
}
