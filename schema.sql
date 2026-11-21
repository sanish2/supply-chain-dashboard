BEGIN;

CREATE SCHEMA supply;
REVOKE ALL ON SCHEMA supply FROM PUBLIC;

CREATE TABLE supply.purchase_order_line (
    order_id text NOT NULL CHECK (btrim(order_id) <> ''),
    line_number integer NOT NULL CHECK (line_number > 0),
    supplier text NOT NULL CHECK (btrim(supplier) <> ''),
    sku text NOT NULL CHECK (btrim(sku) <> ''),
    warehouse text NOT NULL CHECK (btrim(warehouse) <> ''),
    ordered_qty integer NOT NULL CHECK (ordered_qty > 0),
    received_qty integer NOT NULL CHECK (received_qty BETWEEN 0 AND ordered_qty),
    promised_date date NOT NULL,
    completed_date date,
    cancelled boolean NOT NULL,
    source_as_of timestamptz NOT NULL,
    PRIMARY KEY (order_id, line_number),
    CHECK ((completed_date IS NOT NULL) = (received_qty = ordered_qty))
);

CREATE INDEX purchase_order_due_idx
    ON supply.purchase_order_line (promised_date) WHERE NOT cancelled;

CREATE TABLE supply.inventory (
    warehouse text NOT NULL CHECK (btrim(warehouse) <> ''),
    sku text NOT NULL CHECK (btrim(sku) <> ''),
    on_hand_qty integer NOT NULL CHECK (on_hand_qty >= 0),
    reorder_point integer NOT NULL CHECK (reorder_point >= 0),
    source_as_of timestamptz NOT NULL,
    PRIMARY KEY (warehouse, sku)
);

CREATE TABLE supply.ingestion_state (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    source_label text NOT NULL CHECK (btrim(source_label) <> ''),
    source_as_of timestamptz NOT NULL,
    loaded_at timestamptz NOT NULL
);

-- Accept one normalized batch per run. Keep the database on a single
-- named feed so that switching from demo to operations cannot mix rows.
CREATE FUNCTION supply.ingest_batch(payload jsonb)
RETURNS TABLE (order_lines_changed bigint, inventory_positions_changed bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $body$
DECLARE
    batch_time timestamptz := (payload->>'source_as_of')::timestamptz;
    feed text := nullif(btrim(payload->>'source_label'), '');
    current_feed text;
BEGIN
    IF jsonb_typeof(payload) IS DISTINCT FROM 'object'
        OR batch_time IS NULL
        OR NOT isfinite(batch_time)
        OR batch_time > now() + interval '5 minutes'
        OR feed IS NULL
        OR jsonb_typeof(payload->'orders') IS DISTINCT FROM 'array'
        OR jsonb_typeof(payload->'inventory') IS DISTINCT FROM 'array'
    THEN
        RAISE EXCEPTION 'Expected source_label, source_as_of, and orders and inventory arrays';
    END IF;

    IF jsonb_array_length(payload->'orders') + jsonb_array_length(payload->'inventory') = 0 THEN
        RAISE EXCEPTION 'Batch has no records';
    END IF;

    INSERT INTO supply.ingestion_state (source_label, source_as_of, loaded_at)
    VALUES (feed, batch_time, clock_timestamp())
    ON CONFLICT (singleton) DO NOTHING;

    SELECT source_label INTO STRICT current_feed
    FROM supply.ingestion_state WHERE singleton FOR UPDATE;
    IF current_feed <> feed THEN
        RAISE EXCEPTION 'This database belongs to the % feed', current_feed;
    END IF;

    INSERT INTO supply.purchase_order_line AS existing (
        order_id, line_number, supplier, sku, warehouse, ordered_qty, received_qty,
        promised_date, completed_date, cancelled, source_as_of
    )
    SELECT o.order_id, o.line_number, o.supplier, o.sku, o.warehouse, o.ordered_qty, o.received_qty,
           o.promised_date, o.completed_date, o.cancelled, batch_time
    FROM jsonb_to_recordset(payload->'orders') AS o (
        order_id text, line_number integer, supplier text, sku text, warehouse text,
        ordered_qty integer, received_qty integer, promised_date date, completed_date date, cancelled boolean
    )
    ON CONFLICT (order_id, line_number) DO UPDATE SET
        supplier = EXCLUDED.supplier,
        sku = EXCLUDED.sku,
        warehouse = EXCLUDED.warehouse,
        ordered_qty = EXCLUDED.ordered_qty,
        received_qty = EXCLUDED.received_qty,
        promised_date = EXCLUDED.promised_date,
        completed_date = EXCLUDED.completed_date,
        cancelled = EXCLUDED.cancelled,
        source_as_of = EXCLUDED.source_as_of
    WHERE existing.source_as_of < EXCLUDED.source_as_of;
    GET DIAGNOSTICS order_lines_changed = ROW_COUNT;

    INSERT INTO supply.inventory AS existing (warehouse, sku, on_hand_qty, reorder_point, source_as_of)
    SELECT i.warehouse, i.sku, i.on_hand_qty, i.reorder_point, batch_time
    FROM jsonb_to_recordset(payload->'inventory') AS i (
        warehouse text, sku text, on_hand_qty integer, reorder_point integer
    )
    ON CONFLICT (warehouse, sku) DO UPDATE SET
        on_hand_qty = EXCLUDED.on_hand_qty,
        reorder_point = EXCLUDED.reorder_point,
        source_as_of = EXCLUDED.source_as_of
    WHERE existing.source_as_of < EXCLUDED.source_as_of;
    GET DIAGNOSTICS inventory_positions_changed = ROW_COUNT;

    UPDATE supply.ingestion_state
    SET source_as_of = batch_time, loaded_at = clock_timestamp()
    WHERE singleton AND source_as_of < batch_time;

    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION supply.ingest_batch(jsonb) FROM PUBLIC;

CREATE VIEW supply.dashboard_summary AS
WITH calendar AS (
    SELECT (now() AT TIME ZONE 'UTC')::date AS today
), orders AS (
    SELECT
        count(*) FILTER (WHERE completed_date IS NULL AND promised_date < today) AS overdue_po_lines,
        count(*) FILTER (
            WHERE promised_date >= today - 30 AND promised_date < today
        ) AS lines_due_30d,
        count(*) FILTER (
            WHERE promised_date >= today - 30 AND promised_date < today AND completed_date <= promised_date
        ) AS lines_on_time_30d
    FROM supply.purchase_order_line CROSS JOIN calendar
    WHERE NOT cancelled
), stock AS (
    SELECT
        count(*) FILTER (WHERE on_hand_qty < reorder_point) AS low_stock_positions,
        count(*) AS tracked_positions
    FROM supply.inventory
)
SELECT
    state.source_label,
    state.source_as_of,
    state.loaded_at,
    orders.overdue_po_lines,
    orders.lines_due_30d,
    orders.lines_on_time_30d,
    round(100.0 * orders.lines_on_time_30d / nullif(orders.lines_due_30d, 0), 1) AS on_time_delivery_pct,
    stock.low_stock_positions,
    stock.tracked_positions
FROM orders CROSS JOIN stock
LEFT JOIN supply.ingestion_state AS state ON state.singleton;

CREATE VIEW supply.delivery_trend AS
WITH days AS (
    SELECT (now() AT TIME ZONE 'UTC')::date - offset_days AS promised_day
    FROM generate_series(1, 30) AS offset_days
)
SELECT days.promised_day,
       count(o.order_id) AS lines_due,
       count(o.order_id) FILTER (WHERE o.completed_date <= o.promised_date) AS lines_on_time,
       round(100.0 * count(o.order_id) FILTER (WHERE o.completed_date <= o.promised_date)
            / nullif(count(o.order_id), 0), 1) AS on_time_delivery_pct
FROM days
LEFT JOIN supply.purchase_order_line AS o
    ON o.promised_date = days.promised_day AND NOT o.cancelled
GROUP BY days.promised_day;

CREATE VIEW supply.overdue_orders AS
SELECT order_id, line_number, supplier, sku, warehouse, promised_date,
       (now() AT TIME ZONE 'UTC')::date - promised_date AS days_overdue,
       ordered_qty - received_qty AS outstanding_qty,
       source_as_of
FROM supply.purchase_order_line
WHERE NOT cancelled AND completed_date IS NULL
  AND promised_date < (now() AT TIME ZONE 'UTC')::date;

CREATE VIEW supply.low_stock AS
SELECT warehouse, sku, on_hand_qty, reorder_point,
       reorder_point - on_hand_qty AS units_below_reorder,
       source_as_of
FROM supply.inventory
WHERE on_hand_qty < reorder_point;

COMMIT;
