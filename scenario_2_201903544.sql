-- MULUNGUSHI UNIVERSITY - ICT371 Activity 4
-- Name: Chama Shapi
-- Student number: 201903544
-- Scenario 2: Computer Laboratory Reservations
BEGIN;
CREATE SCHEMA IF NOT EXISTS ict371_scenario_2;
SET LOCAL search_path TO ict371_scenario_2, public;
SET LOCAL client_min_messages TO NOTICE;

-- 1. Create the tables and add three sample lab_sessions.
DROP TABLE IF EXISTS reservations;
DROP TABLE IF EXISTS lab_sessions;

CREATE TABLE lab_sessions (
    session_id INTEGER PRIMARY KEY,
    session_name VARCHAR(100) NOT NULL,
    available_workstations INTEGER NOT NULL CHECK (available_workstations >= 0)
);

CREATE TABLE reservations (
    reservation_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES lab_sessions(session_id),
    lecturer VARCHAR(100) NOT NULL CHECK (btrim(lecturer) <> ''),
    number_of_workstations INTEGER NOT NULL CHECK (number_of_workstations > 0),
    status VARCHAR(20) NOT NULL DEFAULT 'reserved'
        CHECK (status IN ('reserved', 'cancelled'))
);

INSERT INTO lab_sessions (session_id, session_name, available_workstations) VALUES
    (1, 'Morning practical', 30),
    (2, 'Afternoon practical', 10),
    (3, 'Evening practical', 0);

-- 2. IF / ELSIF / ELSE: report availability for item 2.
-- Low availability means available_workstations <= 5; zero has its own message.
DO $$
DECLARE
    v_available INTEGER;
BEGIN
    SELECT available_workstations INTO v_available
    FROM lab_sessions WHERE session_id = 2;

    IF v_available = 0 THEN
        RAISE NOTICE 'Item 2: full';
    ELSIF v_available <= 5 THEN
        RAISE NOTICE 'Item 2: nearly full (%)', v_available;
    ELSE
        RAISE NOTICE 'Item 2: has enough workstations (%)', v_available;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- 3. WHILE and numeric FOR: each loop displays numbers 1, 2 and 3.
DO $$
DECLARE
    v_number INTEGER := 1;
BEGIN
    WHILE v_number <= 3 LOOP
        RAISE NOTICE 'Session preparation reminder %', v_number;
        v_number := v_number + 1;
    END LOOP;

    FOR v_check IN 1..3 LOOP
        RAISE NOTICE 'Workstation check %', v_check;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 4. Validate input, check availability, reduce it and record the action.
-- FOR UPDATE locks the selected row until the transaction ends, so another
-- transaction cannot use the same availability before this change completes.
CREATE OR REPLACE PROCEDURE reserve_workstations(
    p_session_id INTEGER, p_lecturer TEXT, p_quantity INTEGER
)
LANGUAGE plpgsql
SET search_path TO ict371_scenario_2, pg_temp
AS $$
DECLARE
    v_available INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Quantity must be greater than zero.';
    END IF;

    IF p_lecturer IS NULL OR btrim(p_lecturer) = '' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Lecturer must not be blank.';
    END IF;

    SELECT available_workstations INTO v_available
    FROM lab_sessions
    WHERE session_id = p_session_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown session_id: %', p_session_id;
    END IF;

    IF v_available < p_quantity THEN
        RAISE NOTICE 'Request rejected: requested %, available % workstations.',
            p_quantity, v_available;
        RETURN; -- Neither table is changed for an unavailable request.
    END IF;

    UPDATE lab_sessions
    SET available_workstations = available_workstations - p_quantity
    WHERE session_id = p_session_id;

    INSERT INTO reservations (session_id, lecturer, number_of_workstations, status)
    VALUES (p_session_id, btrim(p_lecturer), p_quantity, 'reserved');

    RAISE NOTICE 'Recorded reserved: item %, workstations %.', p_session_id, p_quantity;
END;
$$;

-- 5. Two successful requests and one rejected request.
CALL reserve_workstations(1, 'Dr Banda', 10);
CALL reserve_workstations(2, 'Ms Phiri', 8);
CALL reserve_workstations(1, 'Mr Zulu', 50);

-- Expected availability by ID: 20, 2, 0.
-- Exactly two records exist, both with status 'reserved'.
SELECT * FROM lab_sessions ORDER BY session_id;
SELECT * FROM reservations ORDER BY reservation_id;

-- 6. Restore availability only while the record is still 'reserved'.
-- Locking the record also prevents two simultaneous reversals restoring twice.
CREATE OR REPLACE PROCEDURE cancel_reservation(p_reservation_id INTEGER)
LANGUAGE plpgsql
SET search_path TO ict371_scenario_2, pg_temp
AS $$
DECLARE
    v_record reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_record
    FROM reservations
    WHERE reservation_id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reservation_id: %', p_reservation_id;
    END IF;

    IF v_record.status <> 'reserved' THEN
        RAISE NOTICE 'Record % is already cancelled; availability unchanged.', p_reservation_id;
        RETURN;
    END IF;

    UPDATE lab_sessions
    SET available_workstations = available_workstations + v_record.number_of_workstations
    WHERE session_id = v_record.session_id;

    UPDATE reservations
    SET status = 'cancelled'
    WHERE reservation_id = p_reservation_id;

    RAISE NOTICE 'Record % marked cancelled; restored % workstations.',
        p_reservation_id, v_record.number_of_workstations;
END;
$$;

CALL cancel_reservation(1); -- Restores the first record's availability.
CALL cancel_reservation(1); -- Does not restore it again.

-- 7. Explicit cursor: declare, OPEN, FETCH, check FOUND, and CLOSE.
-- Includes zero availability as well as low availability.
DO $$
DECLARE
    c_low CURSOR FOR
        SELECT session_id, session_name, available_workstations
        FROM lab_sessions
        WHERE available_workstations <= 5
        ORDER BY session_id;
    v_item RECORD;
BEGIN
    OPEN c_low;
    LOOP
        FETCH c_low INTO v_item;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Low availability: ID %, %, remaining % workstations.',
            v_item.session_id, v_item.session_name, v_item.available_workstations;
    END LOOP;
    CLOSE c_low;
END;
$$ LANGUAGE plpgsql;

-- 8. Invalid input: zero quantity.
-- The procedure raises SQLSTATE 22023; this EXCEPTION block handles it.
-- Only that expected error is caught, so unrelated errors are not hidden.
DO $$
BEGIN
    CALL reserve_workstations(1, 'Dr Banda', 0);
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Invalid input handled: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- 9. Final evidence: rejected/invalid requests did not create records.
-- Availability by ID: 30, 2, 0.
-- Record 1: cancelled. Record 2: reserved. Total records: 2.
SELECT * FROM lab_sessions ORDER BY session_id;
SELECT * FROM reservations ORDER BY reservation_id;

COMMIT;
