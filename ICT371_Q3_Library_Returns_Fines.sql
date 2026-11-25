-- ICT371 Advanced Database - Question 3: Library Returns Fines

-- ==== Setup ====
-- Run top to bottom in psql / pgAdmin (PostgreSQL 11 or later).
-- Scheduling in part (g) needs the pg_cron extension.
-- Seed dates are relative to CURRENT_DATE so the loans are overdue whenever you run this.
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- ==== (a) Database and seed data ====
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at      TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Operating Systems');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    -- 1: open and overdue (16 days late)
    (1, 'Mwila Zulu',     CURRENT_DATE - 30, CURRENT_DATE - 16, NULL, 0),
    -- 2: open, on time (not yet due)
    (1, 'Natasha Lungu',  CURRENT_DATE - 5,  CURRENT_DATE + 9,  NULL, 0),
    -- 3: returned late (6 days late = K12)
    (2, 'Joseph Tembo',   CURRENT_DATE - 40, CURRENT_DATE - 26, CURRENT_DATE - 20, 12.00),
    -- 4: returned on time
    (2, 'Grace Mumba',    CURRENT_DATE - 20, CURRENT_DATE - 6,  CURRENT_DATE - 8,  0),
    -- 5: open and overdue (11 days late)
    (3, 'Peter Sakala',   CURRENT_DATE - 25, CURRENT_DATE - 11, NULL, 0),
    -- 6: open, on time
    (3, 'Ruth Kabwe',     CURRENT_DATE - 3,  CURRENT_DATE + 11, NULL, 0);

-- ==== (b) Function: fn_loan_fine ====
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
    v_days     INTEGER;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
    END IF;

    -- Earlier of p_as_of and returned_on; a returned loan stops accumulating
    v_end  := LEAST(p_as_of, COALESCE(v_returned, p_as_of));
    v_days := GREATEST(v_end - v_due, 0);          -- on the due date: 0 days

    RETURN 2.00 * v_days;                          -- K2 per overdue day
END;
$$ LANGUAGE plpgsql;

SELECT fn_loan_fine(1, CURRENT_DATE);              -- 32.00
SELECT fn_loan_fine(3, CURRENT_DATE);              -- 12.00 (stops at return date)
SELECT fn_loan_fine(2, CURRENT_DATE);              -- 0.00
-- SELECT fn_loan_fine(99, CURRENT_DATE);          -- error: unknown loan

-- ==== (c) Procedure: pr_return_loan ====
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %',
                        p_returned_on, v_borrowed;
    END IF;

    -- returned_on is still NULL here, so the function measures up to p_returned_on
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    -- Return date and final fine are stored together in one statement
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- ==== (d) Trigger: loan audit ====
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)   -- no row if unchanged
EXECUTE FUNCTION trg_fn_loan_audit();

-- Test: return loan 5 today (11 days late = K22)
CALL pr_return_loan(5, CURRENT_DATE);
SELECT loan_id, due_on, returned_on, fine_amount FROM loans WHERE loan_id = 5;
SELECT * FROM loan_audit;                          -- one row: NULL -> today

-- Updating another column leaves returned_on unchanged: no audit row
UPDATE loans SET borrower_name = 'Peter K. Sakala' WHERE loan_id = 5;
SELECT COUNT(*) FROM loan_audit;                   -- still 1

-- CALL pr_return_loan(5, CURRENT_DATE);           -- error: already returned
-- CALL pr_return_loan(99, CURRENT_DATE);          -- error: unknown loan
-- CALL pr_return_loan(1, CURRENT_DATE - 100);     -- error: before borrowed_on

-- ==== (e) View: v_overdue_loans ====
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- ==== (f) Index ====
-- A partial index holds only unreturned loans, so it stays small while most
-- loans are returned, and it serves "this book's unreturned loans" directly.
CREATE INDEX idx_loans_book_unreturned
ON loans (book_id)
WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;   -- demo only: tiny tables would otherwise use a seq scan
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- ==== (g) Scheduled job: pr_refresh_overdue ====
-- Counts loans that were still unreturned on p_as_of and already past due,
-- and sums their fines as of that date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
    v_fine  NUMERIC(12,2);
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date must not be NULL';
    END IF;

    SELECT COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    INTO v_count, v_fine
    FROM loans
    WHERE (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of;

    -- Same snapshot_date on a rerun is replaced, not duplicated
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_fine)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);             -- rerun replaces the row
SELECT * FROM overdue_summary;

-- Schedule daily at 00:10 for CURRENT_DATE (pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_overdue_daily',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE)$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;
