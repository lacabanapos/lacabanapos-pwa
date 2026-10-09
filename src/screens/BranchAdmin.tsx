import { useCallback, useEffect, useState } from 'react';
import { Check, Clock3, Copy, Plus, RefreshCw, Store, X } from 'lucide-react';
import { useAuth, getOperatorToken } from '../lib/auth';
import { supabase } from '../lib/supabase';

type Branch = { location_id: string; location_name: string; active: boolean; created_at: string };
type TerminalRequest = { request_id: string; device_name: string; location_id: string; location_name: string; requested_at: string };

export default function BranchAdmin() {
  const { user, locationId, locationName, logout } = useAuth();
  const [branches, setBranches] = useState<Branch[]>([]);
  const [requests, setRequests] = useState<TerminalRequest[]>([]);
  const [name, setName] = useState('');
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
      const { data, error: createError } = await supabase.rpc('pos_admin_create_location', {
        p_token: getOperatorToken(), p_location_id: locationId, p_name: name.trim(),
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

  if (!user || !locationId || !['ADMIN', 'OWNER'].includes(user.role)) {
    return <div className="loading"><div className="spinner" /></div>;
  }

  return <main className="branch-admin">
    <header className="branch-admin-head">
      <div><div className="branch-kicker">ADMINISTRACIÓN DEL NEGOCIO</div><h1>Sucursales y equipos</h1><p>Conectado desde {locationName || 'sucursal actual'}. Las sucursales y autorizaciones se guardan en Supabase.</p></div>
      <button className="branch-logout" onClick={() => { logout(); window.location.assign('/login'); }}>Salir</button>
    </header>

    {error && <div className="branch-alert error" role="alert">{error}</div>}
    {notice && <div className="branch-alert success" role="status">{notice}</div>}

    <section className="branch-create">
      <div className="branch-section-title"><span className="branch-icon"><Plus size={19}/></span><div><h2>Crear sucursal</h2><p>Solo administración cloud puede crear sucursales. El POS no tiene esa opción.</p></div></div>
      <div className="branch-create-row"><input value={name} onChange={e => setName(e.target.value)} maxLength={80} placeholder="Nombre, por ejemplo: Local Centro" onKeyDown={e => e.key === 'Enter' && void createBranch()} /><button onClick={() => void createBranch()} disabled={busy === 'create' || name.trim().length < 2}>{busy === 'create' ? 'Creando…' : 'Crear sucursal'}</button></div>
    </section>

    <section className="branch-section">
      <div className="branch-section-title"><span className="branch-icon"><Clock3 size={19}/></span><div><h2>Solicitudes de acceso</h2><p>Los nuevos POS aparecen aquí; aprobarlos los vincula a la sucursal elegida.</p></div><button className="branch-refresh" onClick={() => void load()} aria-label="Actualizar"><RefreshCw size={17}/></button></div>
      {loading ? <div className="branch-empty">Cargando…</div> : requests.length === 0 ? <div className="branch-empty">No hay solicitudes pendientes.</div> : <div className="branch-request-list">{requests.map(request => <article className="branch-request" key={request.request_id}><div><b>{request.device_name}</b><span>Solicita acceso a <strong>{request.location_name}</strong> · {new Date(request.requested_at).toLocaleString()}</span></div><div className="branch-request-actions"><button className="approve" disabled={busy === request.request_id} onClick={() => void decide(request, true)}><Check size={17}/> Aprobar</button><button className="reject" disabled={busy === request.request_id} onClick={() => void decide(request, false)}><X size={17}/> Rechazar</button></div></article>)}</div>}
    </section>

    <section className="branch-section">
      <div className="branch-section-title"><span className="branch-icon"><Store size={19}/></span><div><h2>Sucursales existentes</h2><p>La ubicación actual se conserva; aquí puedes crear otras y generar un código temporal de vinculación.</p></div></div>
      {loading ? <div className="branch-empty">Cargando…</div> : <div className="branch-list">{branches.map(branch => <article className="branch-row" key={branch.location_id}><div><b>{branch.location_name}</b><span>{branch.location_id === locationId ? 'Sucursal desde la que administras' : branch.active ? 'Activa' : 'Inactiva'}</span></div><button disabled={!!busy} onClick={() => void makeCode(branch)}>{busy === `code:${branch.location_id}` ? 'Generando…' : 'Código para nuevo POS'}</button></article>)}</div>}
    </section>

    {pairing && <section className="branch-pairing-code"><div><b>Código de vinculación · {branches.find(b => b.location_id === pairing.locationId)?.location_name || 'sucursal'}</b><span>Uso único · vence {new Date(pairing.expiresAt).toLocaleString()}</span></div><code>{pairing.code}</code><button onClick={() => void copyCode()}><Copy size={17}/> Copiar código</button></section>}
  </main>;
}
