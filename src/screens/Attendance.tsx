import { useState } from 'react';
import { supabase } from '../lib/supabase';

function getDeviceId(): string {
  let id = localStorage.getItem('attendance_device_id');
  if (!id) {
    id = crypto.randomUUID ? crypto.randomUUID() : Date.now() + '-' + Math.random();
    localStorage.setItem('attendance_device_id', id);
  }
  return id;
}

export default function Attendance() {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [loginStatus, setLoginStatus] = useState('');
  const [loginLoading, setLoginLoading] = useState(false);
  const [session, setSession] = useState<any>(null);
  const [nextType, setNextType] = useState<'ENTRY' | 'EXIT'>('ENTRY');
  const [markStatus, setMarkStatus] = useState('');
  const [markLoading, setMarkLoading] = useState(false);
  const [workerName, setWorkerName] = useState('');

  async function handleLogin() {
    if (!username.trim() || !password.trim()) {
      setLoginStatus('Ingresa usuario y contraseña');
      return;
    }
    setLoginLoading(true);
    setLoginStatus('Verificando...');
    try {
      const { data, error } = await supabase.auth.signInWithPassword({
        email: `${username.trim().toLowerCase()}@users.lacabanapos.invalid`,
        password,
      });
      if (error) throw error;

      const { data: profile } = await supabase
        .from('profiles')
        .select('id, username, role')
        .eq('id', data.user.id)
        .single();

      if (!profile) throw new Error('Perfil no encontrado');

      setSession({ id: profile.id, username: profile.username, token: data.session.access_token });
      setWorkerName(profile.username);

      const { data: lastRecord } = await supabase
        .from('attendance_records')
        .select('type')
        .eq('user_id', profile.id)
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
    if (!session) return;
    setMarkLoading(true);
    setMarkStatus('Guardando marcación...');
    try {
      const clientEventId = crypto.randomUUID ? crypto.randomUUID() : Date.now().toString();
      const { error } = await supabase.from('attendance_records').insert({
        user_id: session.id,
        type: nextType,
        device_id: getDeviceId(),
        client_event_id: clientEventId,
        status: 'SYNCED',
      });
      if (error) throw error;

      setMarkStatus(`${nextType === 'ENTRY' ? 'Entrada' : 'Salida'} registrada`);
      setNextType(nextType === 'ENTRY' ? 'EXIT' : 'ENTRY');
    } catch (err: any) {
      setMarkStatus(err?.message || 'Error al registrar');
    } finally {
      setMarkLoading(false);
    }
  }

  if (session) {
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
            <button onClick={handleMark} disabled={markLoading}>
              {markLoading ? 'Guardando...' : nextType === 'ENTRY' ? 'Registrar entrada' : 'Registrar salida'}
            </button>
            <button className="secondary" onClick={() => { setSession(null); setMarkStatus(''); }}>Cerrar sesión</button>
            <div className={`status ${markStatus.includes('registrada') ? 'ok' : markStatus.includes('Error') ? 'error' : ''}`}>{markStatus}</div>
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
          <button onClick={handleLogin} disabled={loginLoading}>{loginLoading ? 'Verificando...' : 'Ingresar'}</button>
          <div className={`status ${loginStatus.includes('incorrecta') || loginStatus.includes('Error') ? 'error' : ''}`}>{loginStatus}</div>
        </section>
      </main>
    </div>
  );
}
