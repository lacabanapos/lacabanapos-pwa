import { useCallback, useEffect, useState } from 'react';
import { ArrowLeft, Boxes, ClipboardList, PackagePlus, RefreshCw, Save, AlertTriangle, Store, Trash2 } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { useAuth, getOperatorToken } from '../lib/auth';
import { supabase } from '../lib/supabase';

type Ingredient = { id: string; name: string; base_unit: 'g' | 'ml' | 'unit'; stock_on_hand: number; minimum_stock: number; average_cost_cents: number };
type Product = { id: string; name: string; category_id: string | null };
type Recipe = { product_id: string; active: boolean; items: { inventory_item_id: string; quantity_per_product: number }[] };
type Movement = { id: string; movement_type: string; quantity_delta: number; value_cents: number; reason: string; created_at: string; item_name: string };
type InventoryData = { items: Ingredient[]; products: Product[]; recipes: Recipe[]; movements: Movement[] };
type Report = { sales_cents: number; cash_expenses_cents: number; operating_expenses_cents: number; purchases_cents: number; consumption_cents: number; waste_cents: number; stock_value_cents: number; profit_before_refunds_and_other_costs_cents: number };

const emptyData: InventoryData = { items: [], products: [], recipes: [], movements: [] };
const money = (cents: number) => `$${(Number(cents || 0) / 100).toFixed(2)}`;
const localMonth = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`; };

export default function Inventory() {
  const { user, locationId, locationName, enterBranch, ownerInspection, returnToBranches } = useAuth();
  const navigate = useNavigate();
  const [data, setData] = useState<InventoryData>(emptyData);
  const [report, setReport] = useState<Report | null>(null);
  const [month, setMonth] = useState(localMonth());
  const [tab, setTab] = useState<'overview' | 'items' | 'purchase' | 'recipes' | 'moves' | 'report'>('overview');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [itemName, setItemName] = useState('');
  const [itemUnit, setItemUnit] = useState<'g' | 'ml' | 'unit'>('g');
  const [minimum, setMinimum] = useState('');
  const [purchaseItem, setPurchaseItem] = useState('');
  const [purchaseQty, setPurchaseQty] = useState('');
  const [purchaseCost, setPurchaseCost] = useState('');
  const [purchasePayment, setPurchasePayment] = useState<'CASH'|'TRANSFER'|'CREDIT'|'OTHER'>('OTHER');
  const [supplier, setSupplier] = useState('');
  const [reference, setReference] = useState('');
  const [recipeProduct, setRecipeProduct] = useState('');
  const [recipeLines, setRecipeLines] = useState<{ inventory_item_id: string; quantity_per_product: string }[]>([]);
  const [moveItem, setMoveItem] = useState('');
  const [moveQty, setMoveQty] = useState('');
  const [moveType, setMoveType] = useState<'ADJUSTMENT' | 'WASTE'>('ADJUSTMENT');
  const [moveReason, setMoveReason] = useState('');
  const [branches, setBranches] = useState<{ location_id: string; location_name: string }[]>([]);

  const load = useCallback(async () => {
    if (!locationId) return;
    setError('');
    const [inventory, monthly] = await Promise.all([
      supabase.rpc('pos_inventory_get', { p_token: getOperatorToken(), p_location_id: locationId }),
      supabase.rpc('pos_inventory_monthly_report', { p_token: getOperatorToken(), p_location_id: locationId, p_month: month }),
    ]);
    if (inventory.error) throw inventory.error;
    if (monthly.error) throw monthly.error;
    setData({ ...emptyData, ...(inventory.data || {}) });
    setReport(monthly.data as Report);
  }, [locationId, month]);

  useEffect(() => {
    if (!user) { navigate('/login'); return; }
    if (locationId) void load().catch(e => setError(e?.message || 'No se pudo cargar el inventario.'));
    else if (user.role === 'OWNER') {
      void supabase.rpc('pos_owner_list_business_locations_global', { p_token: getOperatorToken() })
        .then(({ data: rows, error: rpcError }) => rpcError ? setError(rpcError.message) : setBranches(rows || []));
    }
  }, [user, locationId, load, navigate]);

  async function run(action: () => Promise<void>, success: string) {
    setBusy(true); setError(''); setNotice('');
    try { await action(); await load(); setNotice(success); }
    catch (e: any) { setError(e?.message || 'No se pudo guardar.'); }
    finally { setBusy(false); }
  }

  async function saveItem() {
    if (!locationId || !itemName.trim()) return;
    await run(async () => {
      const { error } = await supabase.rpc('pos_inventory_save_item', { p_token: getOperatorToken(), p_location_id: locationId, p_item_id: null, p_name: itemName.trim(), p_base_unit: itemUnit, p_minimum_stock: Number(minimum || 0) });
      if (error) throw error;
      setItemName(''); setMinimum('');
    }, 'Insumo guardado.');
  }

  async function receivePurchase() {
    if (!locationId || !purchaseItem || Number(purchaseQty) <= 0 || Number(purchaseCost) < 0) return;
    await run(async () => {
      const { error } = await supabase.rpc('pos_inventory_receive', { p_token: getOperatorToken(), p_location_id: locationId, p_operation_id: crypto.randomUUID(), p_supplier: supplier.trim(), p_reference: reference.trim(), p_payment_method: purchasePayment, p_lines: [{ inventory_item_id: purchaseItem, quantity: Number(purchaseQty), total_cost_cents: Math.round(Number(purchaseCost) * 100) }] });
      if (error) throw error;
      setPurchaseQty(''); setPurchaseCost(''); setSupplier(''); setReference(''); setPurchasePayment('OTHER');
    }, 'Compra registrada y existencias actualizadas.');
  }

  async function saveRecipe() {
    if (!locationId || !recipeProduct || recipeLines.length === 0) return;
    await run(async () => {
      const { error } = await supabase.rpc('pos_inventory_save_recipe', { p_token: getOperatorToken(), p_location_id: locationId, p_product_id: recipeProduct, p_lines: recipeLines.map(line => ({ inventory_item_id: line.inventory_item_id, quantity_per_product: Number(line.quantity_per_product) })) });
      if (error) throw error;
    }, 'Receta guardada. El consumo se registrará cuando cocina inicie la preparación.');
  }

  async function saveMovement() {
    if (!locationId || !moveItem || !Number(moveQty) || moveReason.trim().length < 3) return;
    const delta = moveType === 'WASTE' ? -Math.abs(Number(moveQty)) : Number(moveQty);
    await run(async () => {
      const { error } = await supabase.rpc('pos_inventory_adjust', { p_token: getOperatorToken(), p_location_id: locationId, p_operation_id: crypto.randomUUID(), p_item_id: moveItem, p_delta: delta, p_movement_type: moveType, p_reason: moveReason.trim() });
      if (error) throw error;
      setMoveQty(''); setMoveReason('');
    }, 'Movimiento guardado.');
  }

  const lowStock = data.items.filter(item => Number(item.stock_on_hand) <= Number(item.minimum_stock));
  const recipeForProduct = (id: string) => data.recipes.find(recipe => recipe.product_id === id);

  if (!user || (user.role !== 'ADMIN' && user.role !== 'OWNER')) return <main className="inventory-shell"><p>Esta sección es para administración.</p></main>;
  if (!locationId && user.role === 'OWNER') return <main className="inventory-shell"><header className="inventory-header"><div><span>ADMINISTRACIÓN DEL NEGOCIO</span><h1>Inventario por sucursal</h1><p>Elige la sucursal que quieres administrar.</p></div><button onClick={() => navigate('/admin/sucursales')}>Volver a sucursales</button></header>{error && <div className="inventory-alert error">{error}</div>}<div className="inventory-branch-grid">{branches.map(branch => <button key={branch.location_id} onClick={async () => { try { await enterBranch(branch.location_id); navigate('/inventario'); } catch (e: any) { setError(e.message); } }}><Store/><b>{branch.location_name}</b><span>Abrir inventario</span></button>)}</div></main>;

  return <main className="inventory-shell">
    <header className="inventory-header"><div><span>CONTROL DE EXISTENCIAS · {locationName || 'SUCURSAL'}</span><h1>Inventario</h1><p>Insumos, compras, recetas y consumo de cocina en un solo registro.</p></div><div className="inventory-head-actions">{ownerInspection && <button onClick={() => { returnToBranches(); navigate('/admin/sucursales'); }}><ArrowLeft size={17}/> Sucursales</button>}<button onClick={() => void load().catch(e => setError(e.message))}><RefreshCw size={17}/> Actualizar</button></div></header>
    {error && <div className="inventory-alert error" role="alert">{error}</div>}{notice && <div className="inventory-alert success" role="status">{notice}</div>}
    <nav className="inventory-tabs">{([['overview','Resumen'],['items','Insumos'],['purchase','Registrar compra'],['recipes','Recetas'],['moves','Ajustes y desperdicio'],['report','Reporte mensual']] as const).map(([key,label]) => <button className={tab===key?'active':''} key={key} onClick={() => setTab(key)}>{label}</button>)}</nav>
    {tab==='overview' && <><section className="inventory-stat-grid"><article><span>Insumos activos</span><b>{data.items.length}</b></article><article className={lowStock.length?'warning':''}><span>Por reponer</span><b>{lowStock.length}</b></article><article><span>Valor estimado del stock</span><b>{money(report?.stock_value_cents || 0)}</b></article><article><span>Consumo este mes</span><b>{money(report?.consumption_cents || 0)}</b></article></section><section className="inventory-section"><div className="inventory-section-heading"><div><h2>Revisar existencias</h2><p>El mínimo se define por insumo y sucursal.</p></div><button onClick={() => setTab('items')}><Boxes size={17}/> Insumos</button></div>{data.items.length===0?<div className="inventory-empty">Agrega los insumos que compras y usas en cocina.</div>:<div className="inventory-table-wrap"><table className="inventory-table"><thead><tr><th>Insumo</th><th>Existencia</th><th>Mínimo</th><th>Costo promedio / unidad</th><th>Estado</th></tr></thead><tbody>{data.items.map(item=><tr key={item.id}><td>{item.name}</td><td>{Number(item.stock_on_hand).toLocaleString()} {item.base_unit}</td><td>{Number(item.minimum_stock).toLocaleString()} {item.base_unit}</td><td>{money(Number(item.average_cost_cents))} / {item.base_unit}</td><td>{Number(item.stock_on_hand)<=Number(item.minimum_stock)?<b className="stock-low">BAJO</b>:<b className="stock-ok">DISPONIBLE</b>}</td></tr>)}</tbody></table></div>}</section>{lowStock.length>0&&<div className="inventory-alert warning"><AlertTriangle size={18}/> Hay {lowStock.length} insumo(s) en su nivel mínimo o por debajo.</div>}</>}
    {tab==='items' && <section className="inventory-section"><div className="inventory-section-heading"><div><h2>Catálogo de insumos</h2><p>Usa gramos, mililitros o unidades como unidad base para recetas.</p></div></div><form className="inventory-form" onSubmit={e=>{e.preventDefault();void saveItem();}}><label>Nombre<input value={itemName} onChange={e=>setItemName(e.target.value)} placeholder="Ej. Carne de res" maxLength={120} required/></label><label>Unidad base<select value={itemUnit} onChange={e=>setItemUnit(e.target.value as any)}><option value="g">Gramos (g)</option><option value="ml">Mililitros (ml)</option><option value="unit">Unidad</option></select></label><label>Alerta de mínimo<input value={minimum} onChange={e=>setMinimum(e.target.value)} type="number" min="0" step="0.001" placeholder="0"/></label><button disabled={busy}><Save size={17}/>{busy?'Guardando…':'Crear insumo'}</button></form><div className="inventory-item-list">{data.items.map(item=><div key={item.id}><span><b>{item.name}</b><small>{item.base_unit} · mínimo {item.minimum_stock}</small></span><strong>{Number(item.stock_on_hand).toLocaleString()} {item.base_unit}</strong></div>)}</div></section>}
    {tab==='purchase' && <section className="inventory-section"><div className="inventory-section-heading"><div><h2>Recibir compra</h2><p>Ingresa la cantidad expresada en unidad base y el costo total pagado por esa cantidad.</p></div><PackagePlus/></div><form className="inventory-form" onSubmit={e=>{e.preventDefault();void receivePurchase();}}><label>Insumo<select value={purchaseItem} onChange={e=>setPurchaseItem(e.target.value)} required><option value="">Selecciona…</option>{data.items.map(item=><option key={item.id} value={item.id}>{item.name} ({item.base_unit})</option>)}</select></label><label>Cantidad recibida<input value={purchaseQty} onChange={e=>setPurchaseQty(e.target.value)} type="number" min="0.001" step="0.001" required/></label><label>Costo total ($)<input value={purchaseCost} onChange={e=>setPurchaseCost(e.target.value)} type="number" min="0" step="0.01" required/></label><label>Forma de pago<select value={purchasePayment} onChange={e=>setPurchasePayment(e.target.value as any)}><option value="OTHER">Otro / no registrado en caja</option><option value="CASH">Efectivo de caja abierta</option><option value="TRANSFER">Transferencia</option><option value="CREDIT">Crédito / pendiente</option></select></label><label>Proveedor<input value={supplier} onChange={e=>setSupplier(e.target.value)} maxLength={160} placeholder="Opcional"/></label><label>Factura / referencia<input value={reference} onChange={e=>setReference(e.target.value)} maxLength={120} placeholder="Opcional"/></label><button disabled={busy}><PackagePlus size={17}/>{busy?'Guardando…':'Registrar entrada'}</button></form>{purchasePayment==='CASH'&&<p className="inventory-report-note">El pago en efectivo se registrará también como egreso de la caja abierta para que cuadre el efectivo.</p>}</section>}
    {tab==='recipes' && <section className="inventory-section"><div className="inventory-section-heading"><div><h2>Recetas y consumo</h2><p>Define cuánto insumo utiliza cada producto. Cocina descuenta solo al iniciar preparación.</p></div><ClipboardList/></div><form className="inventory-form recipe-form" onSubmit={e=>{e.preventDefault();void saveRecipe();}}><label>Producto del menú<select value={recipeProduct} onChange={e=>{setRecipeProduct(e.target.value);const recipe=recipeForProduct(e.target.value);setRecipeLines((recipe?.items||[]).map(line=>({inventory_item_id:line.inventory_item_id,quantity_per_product:String(line.quantity_per_product)})));}} required><option value="">Selecciona…</option>{data.products.map(product=><option key={product.id} value={product.id}>{product.name}</option>)}</select></label><div className="recipe-lines">{recipeLines.map((line,index)=><div className="recipe-line" key={index}><select value={line.inventory_item_id} onChange={e=>setRecipeLines(lines=>lines.map((x,i)=>i===index?{...x,inventory_item_id:e.target.value}:x))}><option value="">Insumo…</option>{data.items.map(item=><option key={item.id} value={item.id}>{item.name} ({item.base_unit})</option>)}</select><input aria-label="Cantidad por producto" type="number" min="0.001" step="0.001" value={line.quantity_per_product} onChange={e=>setRecipeLines(lines=>lines.map((x,i)=>i===index?{...x,quantity_per_product:e.target.value}:x))}/><button type="button" className="icon-danger" onClick={()=>setRecipeLines(lines=>lines.filter((_,i)=>i!==index))} aria-label="Quitar insumo"><Trash2 size={16}/></button></div>)}</div><div className="inventory-form-actions"><button type="button" className="secondary" onClick={()=>setRecipeLines(lines=>[...lines,{inventory_item_id:'',quantity_per_product:''}])}>＋ Agregar insumo</button><button disabled={busy||!recipeProduct||recipeLines.length===0}><Save size={17}/>{busy?'Guardando…':'Guardar receta'}</button></div></form><div className="inventory-item-list">{data.products.map(product=>{const recipe=recipeForProduct(product.id);return <div key={product.id}><span><b>{product.name}</b><small>{recipe?.active?`${recipe.items.length} insumo(s) en receta`:'Sin receta de inventario'}</small></span><button className="secondary" onClick={()=>{setRecipeProduct(product.id);setRecipeLines((recipe?.items||[]).map(line=>({inventory_item_id:line.inventory_item_id,quantity_per_product:String(line.quantity_per_product)})));setError('');}}>Editar receta</button></div>;})}</div></section>}
    {tab==='moves' && <section className="inventory-section"><div className="inventory-section-heading"><div><h2>Ajuste o desperdicio</h2><p>Registra conteos físicos o insumos que se dañaron. Se exige motivo y queda auditoría.</p></div></div><form className="inventory-form" onSubmit={e=>{e.preventDefault();void saveMovement();}}><label>Tipo<select value={moveType} onChange={e=>setMoveType(e.target.value as any)}><option value="ADJUSTMENT">Ajuste de conteo (+ o −)</option><option value="WASTE">Desperdicio (−)</option></select></label><label>Insumo<select value={moveItem} onChange={e=>setMoveItem(e.target.value)} required><option value="">Selecciona…</option>{data.items.map(item=><option key={item.id} value={item.id}>{item.name} · stock {item.stock_on_hand} {item.base_unit}</option>)}</select></label><label>{moveType==='WASTE'?'Cantidad perdida':'Cambio (+ o −)'}<input value={moveQty} onChange={e=>setMoveQty(e.target.value)} type="number" min={moveType==='WASTE'?'0.001':undefined} step="0.001" required/></label><label>Motivo<input value={moveReason} onChange={e=>setMoveReason(e.target.value)} minLength={3} maxLength={240} placeholder="Ej. Conteo físico / producto dañado" required/></label><button disabled={busy}><Save size={17}/>{busy?'Guardando…':'Registrar movimiento'}</button></form></section>}
    {tab==='report' && <section className="inventory-section"><div className="inventory-section-heading"><div><h2>Resumen mensual</h2><p>Estimación basada en tickets pagados, recetas, compras y egresos registrados.</p></div><input aria-label="Mes del reporte" type="month" value={month.slice(0,7)} onChange={e=>setMonth(`${e.target.value}-01`)}/></div>{report&&<><div className="inventory-stat-grid"><article><span>Ventas cobradas</span><b>{money(report.sales_cents)}</b></article><article><span>Compras de insumos</span><b>{money(report.purchases_cents)}</b></article><article><span>Costo consumido según recetas</span><b>{money(report.consumption_cents)}</b></article><article><span>Egresos de caja · total</span><b>{money(report.cash_expenses_cents)}</b></article><article><span>Otros egresos operativos</span><b>{money(report.operating_expenses_cents)}</b></article><article><span>Desperdicio registrado</span><b>{money(report.waste_cents)}</b></article><article className="warning"><span>Margen estimado</span><b>{money(report.profit_before_refunds_and_other_costs_cents)}</b></article></div><p className="inventory-report-note">El margen mostrado todavía no descuenta devoluciones ni costos que no estén registrados en recetas o egresos. No equivale a utilidad contable final. Las compras en efectivo aparecen en caja, pero no se vuelven a contar como egreso operativo para evitar duplicarlas con el costo consumido.</p></>}</section>}
    {tab==='overview' && <section className="inventory-section"><div className="inventory-section-heading"><div><h2>Movimientos recientes</h2><p>Entradas, consumos y ajustes cloud.</p></div></div>{data.movements.length===0?<div className="inventory-empty">Todavía no hay movimientos.</div>:<div className="inventory-item-list">{data.movements.slice(0,12).map(move=><div key={move.id}><span><b>{move.item_name} · {move.movement_type}</b><small>{new Date(move.created_at).toLocaleString()} · {move.reason||'Sin nota'}</small></span><strong className={move.quantity_delta<0?'stock-low':'stock-ok'}>{move.quantity_delta>0?'+':''}{move.quantity_delta}</strong></div>)}</div>}</section>}
  </main>;
}
