import { useCallback, useEffect, useState } from 'react';
import { Check, Clock3, Copy, KeyRound, Plus, RefreshCw, Store, Users, X } from 'lucide-react';
import { useAuth, getOperatorToken } from '../lib/auth';
import { supabase } from '../lib/supabase';
import { useNavigate } from 'react-router-dom';

type Branch = { location_id: string; location_name: string; active: boolean; created_at: string };
type TerminalRequest = { request_id: string; device_name: string; location_id: string; location_name: string; requested_at: string };
type BranchUser = { user_id: string; username: string; display_name: string; user_role: string; active: boolean };

export default function BranchAdmin() {
  const { user, locationId, locationName, logout, enterBranch, ownerInspection } = useAuth();
  const navigate = useNavigate();
  const [branches, setBranches] = useState<Branch[]>([]);
  const [requests, setRequests] = useState<TerminalRequest[]>([]);
  const [name, setName] = useState('');
  const [adminPin, setAdminPin] = useState('123456');
  const [cashierPin, setCashierPin] = useState('1234');
  const [expandedBranch, setExpandedBranch] = useState<string | null>(null);
  const [branchUsers, setBranchUsers] = useState<Record<string, BranchUser[]>>({});
  const [resetUser, setResetUser] = useState<string | null>(null);
  const [resetPin, setResetPin] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [pairing, setPairing] = useState<{ locationId: string; code: string; expiresAt: string } | null>(null);

  const load = useCallback(async () => {
    if (!locationId) return;
    setError('');
    const token = getOperatorToken();
    const [branchResult, requestResult] = await Promise.all([
      supabase.rpc('pos_admin_list_business_locations', { p_token: token, p_location_id: locationId }),
      supabase.rpc('pos_admin_list_terminal_requests', { p_token: token, p_location_id: locationId }),
    ]);
    if (branchResult.error) throw branchResult.error;
    if (requestResult.error) throw requestResult.error;
    setBranches((branchResult.data || []) as Branch[]);
    setRequests((requestResult.data || []) as TerminalRequest[]);
  }, [locationId]);

  useEffect(() => {
    let mounted = true;
    const refresh = async () => {
      try { await load(); } catch (e: any) { if (mounted) setError(e?.message || 'No se pudo cargar la administración del negocio.'); }
      finally { if (mounted) setLoading(false); }
    };
    void refresh();
    const timer = window.setInterval(() => void refresh(), 7000);
    return () => { mounted = false; window.clearInterval(timer); };
  }, [load]);

  async function createBranch() {
    if (!locationId || name.trim().length < 2) return;
    setBusy('create'); setError(''); setNotice('');
    try {
      const { data, error: createError } = await supabase.rpc('pos_admin_create_location_with_users', {
        p_token: getOperatorToken(), p_location_id: locationId, p_name: name.trim(),
        p_admin_password: adminPin, p_cashier_password: cashierPin,
      });
      if (createError) throw createError;
      const branch = Array.isArray(data) ? data[0] : data;
      if (!branch?.location_id) throw new Error('No se confirmó la creación de la sucursal.');
      const { data: codeData, error: codeError } = await supabase.rpc('pos_admin_create_location_pairing_code', {
        p_token: getOperatorToken(), p_location_id: locationId, p_target_location_id: branch.location_id,
      });
      if (codeError) throw codeError;
      const codeRow = Array.isArray(codeData) ? codeData[0] : codeData;
      setPairing({ locationId: branch.location_id, code: codeRow.pairing_code, expiresAt: codeRow.expires_at });
      setName(''); setNotice(`Sucursal “${branch.location_name}” creada. Comparte el código con el POS que quieras autorizar.`);
      await load();
    } catch (e: any) { setError(e?.message || 'No se pudo crear la sucursal.'); }
    finally { setBusy(null); }
  }

  async function makeCode(branch: Branch) {
    if (!locationId) return;
    setBusy(`code:${branch.location_id}`); setError(''); setNotice('');
    try {
      const { data, error: rpcError } = await supabase.rpc('pos_admin_create_location_pairing_code', {
        p_token: getOperatorToken(), p_location_id: locationId, p_target_location_id: branch.location_id,
      });
      if (rpcError) throw rpcError;
      const row = Array.isArray(data) ? data[0] : data;
      setPairing({ locationId: branch.location_id, code: row.pairing_code, expiresAt: row.expires_at });
    } catch (e: any) { setError(e?.message || 'No se pudo generar el código.'); }
    finally { setBusy(null); }
  }

  async function openBranch(branch: Branch) {
    setBusy(`open:${branch.location_id}`); setError(''); setNotice('');
    try {
      await enterBranch(branch.location_id);
      navigate('/cocina');
    } catch (e: any) { setError(e?.message || 'No se pudo abrir la sucursal.'); }
    finally { setBusy(null); }
  }

  async function decide(request: TerminalRequest, approve: boolean) {
    if (!locationId) return;
    setBusy(request.request_id); setError(''); setNotice('');
    try {
      const { error: rpcError } = await supabase.rpc('pos_admin_decide_terminal_request', {
        p_token: getOperatorToken(), p_location_id: locationId,
        p_request_id: request.request_id, p_approve: approve,
      });
      if (rpcError) throw rpcError;
      setNotice(approve ? `Equipo aprobado para ${request.location_name}.` : 'Solicitud rechazada.');
      await load();
    } catch (e: any) { setError(e?.message || 'No se pudo procesar la solicitud.'); }
    finally { setBusy(null); }
  }

  async function copyCode() {
    if (!pairing) return;
    try { await navigator.clipboard.writeText(pairing.code); setNotice('Código copiado. Vence en 24 horas y solo se puede usar una vez.'); }
    catch { setNotice('Copia manualmente el código mostrado; vence en 24 horas y solo se usa una vez.'); }
  }

  if (!user || !locationId || user.role !== 'OWNER' || ownerInspection) {
    return <div className="loading"><div className="spinner" /></div>;
  }

  async function loadBranchUsers(branch: Branch) {
    if (!locationId) return;
    setBusy(`users:${branch.location_id}`); setError('');
    try {
      const { data, error: rpcError } = await supabase.rpc('pos_owner_list_location_users', {
        p_token: getOperatorToken(), p_current_location_id: locationId, p_target_location_id: branch.location_id,
      });
      if (rpcError) throw rpcError;
      setBranchUsers(current => ({ ...current, [branch.location_id]: (data || []) as BranchUser[] }));
      setExpandedBranch(branch.location_id);
    } catch (e: any) { setError(e?.message || 'No se pudieron consultar los accesos.'); }
    finally { setBusy(null); }
  }

  async function prepareBranchUsers(branch: Branch) {
    if (!locationId) return;
    setBusy(`prepare:${branch.location_id}`); setError(''); setNotice('');
    try {
      const { data, error: rpcError } = await supabase.rpc('pos_owner_bootstrap_location_users', {
        p_token: getOperatorToken(), p_current_location_id: locationId, p_target_location_id: branch.location_id,
        p_admin_password: adminPin, p_cashier_password: cashierPin,
      });
      if (rpcError) throw rpcError;
      const created = Array.isArray(data?.created) ? data.created : [];
      setNotice(created.length ? `Accesos iniciales creados: ${created.join(', ')}.` : 'Admin y caja ya existían; no se cambiaron sus claves.');
      await loadBranchUsers(branch);
    } catch (e: any) { setError(e?.message || 'No se pudieron preparar los accesos.'); }
    finally { setBusy(null); }
  }

  async function resetBranchUser(branch: Branch, account: BranchUser) {
    if (!locationId || resetPin.length < 4) return;
    setBusy(`reset:${account.user_id}`); setError(''); setNotice('');
    try {
      const { error: rpcError } = await supabase.rpc('pos_owner_save_location_user', {
        p_token: getOperatorToken(), p_current_location_id: locationId, p_target_location_id: branch.location_id,
        p_user_id: account.user_id, p_username: account.username, p_display_name: account.display_name,
        p_role: account.user_role, p_password: resetPin,
      });
      if (rpcError) throw rpcError;
      setResetUser(null); setResetPin(''); setNotice(`Clave de ${account.username} actualizada.`);
      await loadBranchUsers(branch);
    } catch (e: any) { setError(e?.message || 'No se pudo cambiar la clave.'); }
    finally { setBusy(null); }
  }

  return <main className="branch-admin">
    <header className="branch-admin-head">
      <div><div className="branch-kicker">ADMINISTRACIÓN DEL NEGOCIO</div><h1>Sucursales y equipos</h1><p>Propietario global · conectado a {locationName || 'tu negocio'}. Puedes abrir cada sucursal en modo de consulta.</p></div>
      <button className="branch-logout" onClick={() => { logout(); window.location.assign('/login'); }}>Salir</button>
    </header>

    {error && <div className="branch-alert error" role="alert">{error}</div>}
    {notice && <div className="branch-alert success" role="status">{notice}</div>}

    <section className="branch-create">
      <div className="branch-section-title"><span className="branch-icon"><Plus size={19}/></span><div><h2>Crear sucursal</h2><p>Solo administración cloud puede crear sucursales. El POS no tiene esa opción.</p></div></div>
      <div className="branch-create-row branch-create-fields"><input value={name} onChange={e => setName(e.target.value)} maxLength={80} placeholder="Nombre, por ejemplo: Local Centro" onKeyDown={e => e.key === 'Enter' && void createBranch()} /><label>PIN inicial admin<input value={adminPin} onChange={e => setAdminPin(e.target.value)} type="password" inputMode="numeric" minLength={4} maxLength={32} /></label><label>PIN inicial caja<input value={cashierPin} onChange={e => setCashierPin(e.target.value)} type="password" inputMode="numeric" minLength={4} maxLength={32} /></label><button onClick={() => void createBranch()} disabled={busy === 'create' || name.trim().length < 2 || adminPin.length < 4 || cashierPin.length < 4}>{busy === 'create' ? 'Creando…' : 'Crear sucursal'}</button></div>
    </section>

    <section className="branch-section">
      <div className="branch-section-title"><span className="branch-icon"><Clock3 size={19}/></span><div><h2>Solicitudes de acceso</h2><p>Los nuevos POS aparecen aquí; aprobarlos los vincula a la sucursal elegida.</p></div><button className="branch-refresh" onClick={() => void load()} aria-label="Actualizar"><RefreshCw size={17}/></button></div>
      {loading ? <div className="branch-empty">Cargando…</div> : requests.length === 0 ? <div className="branch-empty">No hay solicitudes pendientes.</div> : <div className="branch-request-list">{requests.map(request => <article className="branch-request" key={request.request_id}><div><b>{request.device_name}</b><span>Solicita acceso a <strong>{request.location_name}</strong> · {new Date(request.requested_at).toLocaleString()}</span></div><div className="branch-request-actions"><button className="approve" disabled={busy === request.request_id} onClick={() => void decide(request, true)}><Check size={17}/> Aprobar</button><button className="reject" disabled={busy === request.request_id} onClick={() => void decide(request, false)}><X size={17}/> Rechazar</button></div></article>)}</div>}
    </section>

    <section className="branch-section">
      <div className="branch-section-title"><span className="branch-icon"><Store size={19}/></span><div><h2>Sucursales existentes</h2><p>Administra los accesos, revisa la sucursal o genera un código para autorizar un POS.</p></div></div>
      {loading ? <div className="branch-empty">Cargando…</div> : <div className="branch-list">{branches.map(branch => <article className="branch-row branch-row-expanded" key={branch.location_id}><div><b>{branch.location_name}</b><span>{branch.active ? 'Activa' : 'Inactiva'}</span></div><div className="branch-row-actions"><button className="branch-inspect" disabled={!!busy || !branch.active} onClick={() => void openBranch(branch)}>{busy === `open:${branch.location_id}` ? 'Abriendo…' : 'Entrar y revisar'}</button><button disabled={!!busy || !branch.active} onClick={() => void makeCode(branch)}>{busy === `code:${branch.location_id}` ? 'Generando…' : 'Código para POS'}</button><button className="branch-access-toggle" disabled={!!busy || !branch.active} onClick={() => expandedBranch === branch.location_id ? setExpandedBranch(null) : void loadBranchUsers(branch)}><Users size={16}/> Accesos</button></div>
        {expandedBranch === branch.location_id && <div className="branch-users-panel"><div className="branch-users-head"><div><b>Usuarios de {branch.location_name}</b><span>Las claves existentes no se muestran. Solo dueño o administrador puede restablecerlas.</span></div><button onClick={() => void prepareBranchUsers(branch)} disabled={!!busy}><KeyRound size={15}/>{busy === `prepare:${branch.location_id}` ? 'Preparando…' : 'Crear admin/caja si faltan'}</button></div>
          {(branchUsers[branch.location_id] || []).length === 0 ? <p className="branch-users-empty">No hay usuarios configurados todavía.</p> : <div className="branch-users-list">{branchUsers[branch.location_id].map(account => <div className="branch-user-row" key={account.user_id}><div><b>{account.username}</b><span>{account.display_name} · {account.user_role} · {account.active ? 'Activo' : 'Inactivo'}</span></div>{resetUser === account.user_id ? <div className="branch-reset-form"><input value={resetPin} type="password" inputMode="numeric" minLength={4} placeholder="Nueva clave (4+ caracteres)" onChange={e => setResetPin(e.target.value)} /><button disabled={!!busy || resetPin.length < 4} onClick={() => void resetBranchUser(branch, account)}>{busy === `reset:${account.user_id}` ? 'Guardando…' : 'Guardar'}</button><button className="branch-cancel-reset" onClick={() => { setResetUser(null); setResetPin(''); }}>Cancelar</button></div> : <button className="branch-reset-button" disabled={!!busy || !account.active} onClick={() => { setResetUser(account.user_id); setResetPin(''); }}>Restablecer clave</button>}</div>)}</div>}
        </div>}
      </article>)}</div>}
    </section>

    {pairing && <section className="branch-pairing-code"><div><b>Código de vinculación · {branches.find(b => b.location_id === pairing.locationId)?.location_name || 'sucursal'}</b><span>Uso único · vence {new Date(pairing.expiresAt).toLocaleString()}</span></div><code>{pairing.code}</code><button onClick={() => void copyCode()}><Copy size={17}/> Copiar código</button></section>}
  </main>;
}

