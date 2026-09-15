-- ============================================
-- MIGRATION 003: RPC Functions
-- ============================================

-- Función para crear orden (mesero -> cocina)
-- Crea ticket + order + items en una transacción
CREATE OR REPLACE FUNCTION create_order(
  p_customer_name TEXT,
  p_waiter_name TEXT,
  p_notes TEXT,
  p_items JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_ticket_id UUID;
  v_order_id UUID;
  v_total NUMERIC(12,2) := 0;
  v_item JSONB;
  v_ticket_code TEXT;
BEGIN
  -- Calcular total
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_total := v_total + ((v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::INTEGER);
  END LOOP;

  -- Generar código de ticket
  v_ticket_code := 'T-' || LPAD(FLOOR(RANDOM() * 9999999)::TEXT, 7, '0');

  -- Crear ticket
  INSERT INTO tickets (code, status, total, customer_name, notes, created_at)
  VALUES (v_ticket_code, 'PENDIENTE', v_total, p_customer_name, p_notes, now())
  RETURNING id INTO v_ticket_id;

  -- Crear order
  INSERT INTO orders (ticket_id, customer_name, status, source, waiter_name, total, notes, created_at)
  VALUES (v_ticket_id, p_customer_name, 'RECEIVED', 'MOBILE', p_waiter_name, v_total, p_notes, now())
  RETURNING id INTO v_order_id;

  -- Crear ticket_items y order_items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO ticket_items (ticket_id, product_name, quantity, unit_price, total_price)
    VALUES (
      v_ticket_id,
      v_item->>'product_name',
      (v_item->>'quantity')::INTEGER,
      (v_item->>'unit_price')::NUMERIC,
      (v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::INTEGER
    );

    INSERT INTO order_items (order_id, product_id, product_name, quantity, unit_price, notes, category)
    VALUES (
      v_order_id,
      (v_item->>'product_id')::UUID,
      v_item->>'product_name',
      (v_item->>'quantity')::INTEGER,
      (v_item->>'unit_price')::NUMERIC,
      v_item->>'notes',
      COALESCE(v_item->>'category', '')
    );
  END LOOP;

  RETURN jsonb_build_object(
    'order_id', v_order_id,
    'ticket_id', v_ticket_id,
    'ticket_code', v_ticket_code,
    'total', v_total,
    'message', 'Orden #' || v_order_id::TEXT || ' enviada a cocina'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Función para cambiar estado de orden
CREATE OR REPLACE FUNCTION update_order_status(
  p_order_id UUID,
  p_status TEXT
)
RETURNS JSONB AS $$
BEGIN
  UPDATE orders
  SET status = p_status, updated_at = now()
  WHERE id = p_order_id;

  -- Si es SERVED, actualizar ticket
  IF p_status = 'SERVED' THEN
    UPDATE tickets SET status = 'PAGADO', paid_at = now()
    WHERE id = (SELECT ticket_id FROM orders WHERE id = p_order_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Función para cancelar orden
CREATE OR REPLACE FUNCTION cancel_order(p_order_id UUID)
RETURNS JSONB AS $$
BEGIN
  UPDATE orders SET status = 'CANCELLED', updated_at = now() WHERE id = p_order_id;

  -- Anular ticket vinculado
  UPDATE tickets SET status = 'ANULADO'
  WHERE id = (SELECT ticket_id FROM orders WHERE id = p_order_id);

  RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Función para agregar items a orden existente
CREATE OR REPLACE FUNCTION add_items_to_order(
  p_order_id UUID,
  p_items JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_item JSONB;
  v_total_add NUMERIC(12,2) := 0;
  v_ticket_id UUID;
BEGIN
  -- Obtener ticket_id
  SELECT ticket_id INTO v_ticket_id FROM orders WHERE id = p_order_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    -- Agregar order_item
    INSERT INTO order_items (order_id, product_id, product_name, quantity, unit_price, notes, category)
    VALUES (
      p_order_id,
      (v_item->>'product_id')::UUID,
      v_item->>'product_name',
      (v_item->>'quantity')::INTEGER,
      (v_item->>'unit_price')::NUMERIC,
      v_item->>'notes',
      COALESCE(v_item->>'category', '')
    );

    -- Agregar ticket_item
    IF v_ticket_id IS NOT NULL THEN
      INSERT INTO ticket_items (ticket_id, product_name, quantity, unit_price, total_price)
      VALUES (
        v_ticket_id,
        v_item->>'product_name',
        (v_item->>'quantity')::INTEGER,
        (v_item->>'unit_price')::NUMERIC,
        (v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::INTEGER
      );
    END IF;

    v_total_add := v_total_add + ((v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::INTEGER);
  END LOOP;

  -- Actualizar totales
  UPDATE orders SET total = total + v_total_add, updated_at = now() WHERE id = p_order_id;
  IF v_ticket_id IS NOT NULL THEN
    UPDATE tickets SET total = total + v_total_add WHERE id = v_ticket_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'added_total', v_total_add);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Función para registrar asistencia
CREATE OR REPLACE FUNCTION mark_attendance(
  p_user_id UUID,
  p_type TEXT,
  p_device_id TEXT,
  p_client_event_id TEXT
)
RETURNS JSONB AS $$
BEGIN
  INSERT INTO attendance_records (user_id, type, device_id, client_event_id, status)
  VALUES (p_user_id, p_type, p_device_id, p_client_event_id, 'SYNCED');

  RETURN jsonb_build_object(
    'type', p_type,
    'recorded_at', now()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Habilitar Realtime en orders
-- ============================================
ALTER PUBLICATION supabase_realtime ADD TABLE orders;
ALTER PUBLICATION supabase_realtime ADD TABLE order_items;
