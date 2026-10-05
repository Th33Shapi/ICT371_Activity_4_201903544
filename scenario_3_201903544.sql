-- MULUNGUSHI UNIVERSITY - ICT371 Activity 4
-- Name: Chama Shapi
-- Student number: 201903544
-- Scenario 3: Student Hostel Room Allocation
BEGIN;
CREATE SCHEMA IF NOT EXISTS ict371_scenario_3;
SET LOCAL search_path TO ict371_scenario_3, public;
SET LOCAL client_min_messages TO NOTICE;

-- 1. Create the tables and add three sample hostel_rooms.
DROP TABLE IF EXISTS allocations;
DROP TABLE IF EXISTS hostel_rooms;

CREATE TABLE hostel_rooms (
    room_id INTEGER PRIMARY KEY,
    room_number VARCHAR(100) NOT NULL,
    available_bed_spaces INTEGER NOT NULL CHECK (available_bed_spaces >= 0)
);

CREATE TABLE allocations (
    allocation_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_id INTEGER NOT NULL REFERENCES hostel_rooms(room_id),
    student_number VARCHAR(100) NOT NULL CHECK (btrim(student_number) <> ''),
    status VARCHAR(20) NOT NULL DEFAULT 'allocated'
        CHECK (status IN ('allocated', 'complete'))
);

INSERT INTO hostel_rooms (room_id, room_number, available_bed_spaces) VALUES
    (1, 'A101', 2),
    (2, 'A102', 1),
    (3, 'A103', 0);

-- 2. IF / ELSIF / ELSE: report availability for item 2.
-- Low availability means available_bed_spaces <= 1; zero has its own message.
DO $$
DECLARE
    v_available INTEGER;
BEGIN
    SELECT available_bed_spaces INTO v_available
    FROM hostel_rooms WHERE room_id = 2;

    IF v_available = 0 THEN
        RAISE NOTICE 'Item 2: full';
    ELSIF v_available <= 1 THEN
        RAISE NOTICE 'Item 2: has one space left (%)', v_available;
    ELSE
        RAISE NOTICE 'Item 2: has several spaces (%)', v_available;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- 3. WHILE and numeric FOR: each loop displays numbers 1, 2 and 3.
DO $$
DECLARE
    v_number INTEGER := 1;
BEGIN
    WHILE v_number <= 3 LOOP
        RAISE NOTICE 'Hostel inspection day %', v_number;
        v_number := v_number + 1;
    END LOOP;

    FOR v_check IN 1..3 LOOP
        RAISE NOTICE 'Room check %', v_check;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 4. Validate input, check availability, reduce it and record the action.
-- FOR UPDATE locks the selected row until the transaction ends, so another
-- transaction cannot use the same availability before this change completes.
CREATE OR REPLACE PROCEDURE allocate_room(
    p_room_id INTEGER, p_student_number TEXT
)
LANGUAGE plpgsql
SET search_path TO ict371_scenario_3, pg_temp
AS $$
DECLARE
    v_available INTEGER;
BEGIN
    IF p_student_number IS NULL OR btrim(p_student_number) = '' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Student number must not be blank.';
    END IF;

    SELECT available_bed_spaces INTO v_available
    FROM hostel_rooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF v_available < 1 THEN
        RAISE NOTICE 'Request rejected: requested %, available % bed spaces.',
            1, v_available;
        RETURN; -- Neither table is changed for an unavailable request.
    END IF;

    UPDATE hostel_rooms
    SET available_bed_spaces = available_bed_spaces - 1
    WHERE room_id = p_room_id;

    INSERT INTO allocations (room_id, student_number, status)
    VALUES (p_room_id, btrim(p_student_number), 'allocated');

    RAISE NOTICE 'Recorded allocated: item %, bed spaces %.', p_room_id, 1;
END;
$$;

-- 5. Two successful requests and one rejected request.
CALL allocate_room(1, '201903544');
CALL allocate_room(2, '202600002');
CALL allocate_room(3, '202600003');

-- Expected availability by ID: 1, 0, 0.
-- Exactly two records exist, both with status 'allocated'.
SELECT * FROM hostel_rooms ORDER BY room_id;
SELECT * FROM allocations ORDER BY allocation_id;

-- 6. Restore availability only while the record is still 'allocated'.
-- Locking the record also prevents two simultaneous reversals restoring twice.
CREATE OR REPLACE PROCEDURE check_out(p_allocation_id INTEGER)
LANGUAGE plpgsql
SET search_path TO ict371_scenario_3, pg_temp
AS $$
DECLARE
    v_record allocations%ROWTYPE;
BEGIN
    SELECT * INTO v_record
    FROM allocations
    WHERE allocation_id = p_allocation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown allocation_id: %', p_allocation_id;
    END IF;

    IF v_record.status <> 'allocated' THEN
        RAISE NOTICE 'Record % is already complete; availability unchanged.', p_allocation_id;
        RETURN;
    END IF;

    UPDATE hostel_rooms
    SET available_bed_spaces = available_bed_spaces + 1
    WHERE room_id = v_record.room_id;

    UPDATE allocations
    SET status = 'complete'
    WHERE allocation_id = p_allocation_id;

    RAISE NOTICE 'Record % marked complete; restored % bed spaces.',
        p_allocation_id, 1;
END;
$$;

CALL check_out(1); -- Restores the first record's availability.
CALL check_out(1); -- Does not restore it again.

-- 7. Explicit cursor: declare, OPEN, FETCH, check FOUND, and CLOSE.
-- Includes zero availability as well as low availability.
DO $$
DECLARE
    c_low CURSOR FOR
        SELECT room_id, room_number, available_bed_spaces
        FROM hostel_rooms
        WHERE available_bed_spaces <= 1
        ORDER BY room_id;
    v_item RECORD;
BEGIN
    OPEN c_low;
    LOOP
        FETCH c_low INTO v_item;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Low availability: ID %, %, remaining % bed spaces.',
            v_item.room_id, v_item.room_number, v_item.available_bed_spaces;
    END LOOP;
    CLOSE c_low;
END;
$$ LANGUAGE plpgsql;

-- 8. Invalid input: blank student number.
-- The procedure raises SQLSTATE 22023; this EXCEPTION block handles it.
-- Only that expected error is caught, so unrelated errors are not hidden.
DO $$
BEGIN
    CALL allocate_room(1, '   ');
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Invalid input handled: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- 9. Final evidence: rejected/invalid requests did not create records.
-- Availability by ID: 2, 0, 0.
-- Record 1: complete. Record 2: allocated. Total records: 2.
SELECT * FROM hostel_rooms ORDER BY room_id;
SELECT * FROM allocations ORDER BY allocation_id;

COMMIT;
