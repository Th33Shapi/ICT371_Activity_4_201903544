-- MULUNGUSHI UNIVERSITY - ICT371 Activity 4
-- Name: Chama Shapi
-- Student number: 201903544
-- Scenario 1: University Library Book Loans
BEGIN;
CREATE SCHEMA IF NOT EXISTS ict371_scenario_1;
SET LOCAL search_path TO ict371_scenario_1, public;
SET LOCAL client_min_messages TO NOTICE;

-- 1. Create the tables and add three sample books.
DROP TABLE IF EXISTS book_loans;
DROP TABLE IF EXISTS books;

CREATE TABLE books (
    book_id INTEGER PRIMARY KEY,
    title VARCHAR(100) NOT NULL,
    available_copies INTEGER NOT NULL CHECK (available_copies >= 0)
);

CREATE TABLE book_loans (
    loan_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(book_id),
    student_number VARCHAR(100) NOT NULL CHECK (btrim(student_number) <> ''),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    status VARCHAR(20) NOT NULL DEFAULT 'borrowed'
        CHECK (status IN ('borrowed', 'returned'))
);

INSERT INTO books (book_id, title, available_copies) VALUES
    (1, 'Database Systems', 5),
    (2, 'Computer Networks', 3),
    (3, 'Operating Systems', 0);

-- 2. IF / ELSIF / ELSE: report availability for item 2.
-- Low availability means available_copies <= 2; zero has its own message.
DO $$
DECLARE
    v_available INTEGER;
BEGIN
    SELECT available_copies INTO v_available
    FROM books WHERE book_id = 2;

    IF v_available = 0 THEN
        RAISE NOTICE 'Item 2: unavailable';
    ELSIF v_available <= 2 THEN
        RAISE NOTICE 'Item 2: low on copies (%)', v_available;
    ELSE
        RAISE NOTICE 'Item 2: sufficiently stocked (%)', v_available;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- 3. WHILE and numeric FOR: each loop displays numbers 1, 2 and 3.
DO $$
DECLARE
    v_number INTEGER := 1;
BEGIN
    WHILE v_number <= 3 LOOP
        RAISE NOTICE 'Overdue reminder number %', v_number;
        v_number := v_number + 1;
    END LOOP;

    FOR v_check IN 1..3 LOOP
        RAISE NOTICE 'Library shelf number %', v_check;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 4. Validate input, check availability, reduce it and record the action.
-- FOR UPDATE locks the selected row until the transaction ends, so another
-- transaction cannot use the same availability before this change completes.
CREATE OR REPLACE PROCEDURE borrow_book(
    p_book_id INTEGER, p_student_number TEXT, p_quantity INTEGER
)
LANGUAGE plpgsql
SET search_path TO ict371_scenario_1, pg_temp
AS $$
DECLARE
    v_available INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Quantity must be greater than zero.';
    END IF;

    IF p_student_number IS NULL OR btrim(p_student_number) = '' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Student number must not be blank.';
    END IF;

    SELECT available_copies INTO v_available
    FROM books
    WHERE book_id = p_book_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown book_id: %', p_book_id;
    END IF;

    IF v_available < p_quantity THEN
        RAISE NOTICE 'Request rejected: requested %, available % copies.',
            p_quantity, v_available;
        RETURN; -- Neither table is changed for an unavailable request.
    END IF;

    UPDATE books
    SET available_copies = available_copies - p_quantity
    WHERE book_id = p_book_id;

    INSERT INTO book_loans (book_id, student_number, quantity, status)
    VALUES (p_book_id, btrim(p_student_number), p_quantity, 'borrowed');

    RAISE NOTICE 'Recorded borrowed: item %, copies %.', p_book_id, p_quantity;
END;
$$;

-- 5. Two successful requests and one rejected request.
CALL borrow_book(1, '201903544', 2);
CALL borrow_book(2, '202600002', 2);
CALL borrow_book(1, '202600003', 10);

-- Expected availability by ID: 3, 1, 0.
-- Exactly two records exist, both with status 'borrowed'.
SELECT * FROM books ORDER BY book_id;
SELECT * FROM book_loans ORDER BY loan_id;

-- 6. Restore availability only while the record is still 'borrowed'.
-- Locking the record also prevents two simultaneous reversals restoring twice.
CREATE OR REPLACE PROCEDURE return_book(p_loan_id INTEGER)
LANGUAGE plpgsql
SET search_path TO ict371_scenario_1, pg_temp
AS $$
DECLARE
    v_record book_loans%ROWTYPE;
BEGIN
    SELECT * INTO v_record
    FROM book_loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_record.status <> 'borrowed' THEN
        RAISE NOTICE 'Record % is already returned; availability unchanged.', p_loan_id;
        RETURN;
    END IF;

    UPDATE books
    SET available_copies = available_copies + v_record.quantity
    WHERE book_id = v_record.book_id;

    UPDATE book_loans
    SET status = 'returned'
    WHERE loan_id = p_loan_id;

    RAISE NOTICE 'Record % marked returned; restored % copies.',
        p_loan_id, v_record.quantity;
END;
$$;

CALL return_book(1); -- Restores the first record's availability.
CALL return_book(1); -- Does not restore it again.

-- 7. Explicit cursor: declare, OPEN, FETCH, check FOUND, and CLOSE.
-- Includes zero availability as well as low availability.
DO $$
DECLARE
    c_low CURSOR FOR
        SELECT book_id, title, available_copies
        FROM books
        WHERE available_copies <= 2
        ORDER BY book_id;
    v_item RECORD;
BEGIN
    OPEN c_low;
    LOOP
        FETCH c_low INTO v_item;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Low availability: ID %, %, remaining % copies.',
            v_item.book_id, v_item.title, v_item.available_copies;
    END LOOP;
    CLOSE c_low;
END;
$$ LANGUAGE plpgsql;

-- 8. Invalid input: zero quantity.
-- The procedure raises SQLSTATE 22023; this EXCEPTION block handles it.
-- Only that expected error is caught, so unrelated errors are not hidden.
DO $$
BEGIN
    CALL borrow_book(1, '201903544', 0);
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Invalid input handled: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- 9. Final evidence: rejected/invalid requests did not create records.
-- Availability by ID: 5, 1, 0.
-- Record 1: returned. Record 2: borrowed. Total records: 2.
SELECT * FROM books ORDER BY book_id;
SELECT * FROM book_loans ORDER BY loan_id;

COMMIT;
