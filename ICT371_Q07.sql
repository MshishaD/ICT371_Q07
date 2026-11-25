-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- Name: Nawa Sumbwanyambe | Student number: 202308788
-- DBMS: PostgreSQL (PL/pgSQL; scheduling with the pg_cron extension)

DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- ==== (a) Database: create the tables
CREATE TABLE customers (
    customer_id SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL        PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT uq_reading_cust_month UNIQUE (customer_id, reading_month),
    CONSTRAINT ck_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

CREATE TABLE bills (
    bill_id     SERIAL        PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE          PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

-- ==== (b) Function fn_water_charge: first 10 units K5 each, above 10 units K8 each
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must be zero or more)', p_units;
    END IF;

    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);   -- exact 2 decimals
END;
$$;

-- ==== (d) Trigger first: reject current_reading < previous_reading (also for direct SQL)
CREATE OR REPLACE FUNCTION trg_fn_readings_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;   -- the statement aborts, nothing is stored
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_readings_check();

-- ==== (c) Procedure pr_generate_bill
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(10,2);
    v_curr   NUMERIC(10,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);      -- consumption = current - previous

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- ==== (e) View v_overdue_bills
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- ==== (f) Index for date-based searches on unpaid bills
-- Partial index: only unpaid bills are indexed, and they are sorted by due date,
-- so "unpaid and due before X" is a short range scan; paid bills never bloat it.
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

-- ==== (g) Scheduled job: pr_refresh_receivables
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE          -- same date's total is replaced on a rerun
    SET total_due = EXCLUDED.total_due;
END;
$$;

-- Requires: CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'refresh_receivables_daily',
    '30 0 * * *',                                  -- every day at 00:30
    $$CALL pr_refresh_receivables()$$
);

-- ==== (a) Seed data: 3 customers, 6 readings (0, exactly 10, and above 10 units)
INSERT INTO customers (full_name) VALUES ('Lubuto Mwamba'), ('Chanda Kalaba'), ('Mutinta Hamoonga');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100.00, 100.00),   -- 0 units
    (1, '2026-10-01', 100.00, 110.00),   -- exactly 10 units
    (2, '2026-09-01',  50.00,  65.00),   -- 15 units
    (2, '2026-10-01',  65.00,  70.50),   -- 5.5 units
    (3, '2026-09-01', 200.00, 212.00),   -- 12 units
    (3, '2026-10-01', 212.00, 230.00);   -- 18 units

SELECT * FROM customers ORDER BY customer_id;
SELECT *, current_reading - previous_reading AS units FROM readings ORDER BY reading_id;

-- ==== (b) Function tests (boundaries)
SELECT u AS units, fn_water_charge(u) AS charge
FROM (VALUES (0), (5.5), (10), (10.5), (12), (18)) AS t(u);
DO $$ BEGIN PERFORM fn_water_charge(NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (c) Procedure: generate bills for all six readings, then test rejections
CALL pr_generate_bill(1, CURRENT_DATE - 40);    -- long overdue, zero charge
CALL pr_generate_bill(2, CURRENT_DATE - 20);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(4, CURRENT_DATE - 10);
CALL pr_generate_bill(5, CURRENT_DATE - 25);
CALL pr_generate_bill(6, CURRENT_DATE + 15);    -- not yet due
DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(2,  CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;  -- already billed
SELECT * FROM bills ORDER BY bill_id;

-- ==== (d) Trigger tests
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, '2026-11-01', 110.00, 105.00);
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN UPDATE readings SET current_reading = 40 WHERE reading_id = 3;   -- 40 < previous 50
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
VALUES (1, '2026-11-01', 110.00, 118.00);                                    -- valid
SELECT reading_id, customer_id, reading_month, previous_reading, current_reading
FROM readings ORDER BY reading_id;   -- the rejected rows are not stored; reading 3 is unchanged

-- ==== (e) View: record some payments, then query overdue bills
UPDATE bills SET amount_paid = charge     WHERE bill_id = 3;   -- fully paid -> leaves the view
UPDATE bills SET amount_paid = 20.00      WHERE bill_id = 5;   -- partly paid
SELECT * FROM v_overdue_bills ORDER BY due_on;

-- ==== (f) EXPLAIN for a matching unpaid-bill query
ANALYZE bills;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index plan
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- ==== (g) Run the job, rerun after another payment: same date's total replaced
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;
UPDATE bills SET amount_paid = charge WHERE bill_id = 4;
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_receivables_daily';
