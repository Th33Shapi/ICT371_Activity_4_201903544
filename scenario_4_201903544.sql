-- MULUNGUSHI UNIVERSITY - ICT371 Activity 4
-- Name: Chama Shapi
-- Student number: 201903544
-- Scenario 4: Campus Clinic Medicine Dispensing
BEGIN;
CREATE SCHEMA IF NOT EXISTS ict371_scenario_4;
SET LOCAL search_path TO ict371_scenario_4, public;
SET LOCAL client_min_messages TO NOTICE;

-- 1. Create the tables and add three sample medicines.
DROP TABLE IF EXISTS dispensing_records;
DROP TABLE IF EXISTS medicines;

CREATE TABLE medicines (
    medicine_id INTEGER PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    stock_quantity INTEGER NOT NULL CHECK (stock_quantity >= 0)
);

CREATE TABLE dispensing_records (
    dispensing_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    student_number VARCHAR(100) NOT NULL CHECK (btrim(student_number) <> ''),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    status VARCHAR(20) NOT NULL DEFAULT 'dispensed'
        CHECK (status IN ('dispensed', 'reversed'))
);

INSERT INTO medicines (medicine_id, medicine_name, stock_quantity) VALUES
    (1, 'Paracetamol', 100),
    (2, 'Oral rehydration salts', 20),
    (3, 'Antiseptic solution', 0);

-- 2. IF / ELSIF / ELSE: report availability for item 2.
-- Low availability means stock_quantity < 10; zero has its own message.
DO $$
DECLARE
    v_available INTEGER;
BEGIN
    SELECT stock_quantity INTO v_available
    FROM medicines WHERE medicine_id = 2;

    IF v_available = 0 THEN
        RAISE NOTICE 'Item 2: out of stock';
    ELSIF v_available < 10 THEN
        RAISE NOTICE 'Item 2: low on stock (%)', v_available;
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
        RAISE NOTICE 'Stock review day %', v_number;
        v_number := v_number + 1;
    END LOOP;

    FOR v_check IN 1..3 LOOP
        RAISE NOTICE 'Shelf inspection %', v_check;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 4. Validate input, check availability, reduce it and record the action.
-- FOR UPDATE locks the selected row until the transaction ends, so another
-- transaction cannot use the same availability before this change completes.
CREATE OR REPLACE PROCEDURE dispense_medicine(
    p_medicine_id INTEGER, p_student_number TEXT, p_quantity INTEGER
)
LANGUAGE plpgsql
SET search_path TO ict371_scenario_4, pg_temp
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

    SELECT stock_quantity INTO v_available
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_available < p_quantity THEN
        RAISE NOTICE 'Request rejected: requested %, available % units.',
            p_quantity, v_available;
        RETURN; -- Neither table is changed for an unavailable request.
    END IF;

    UPDATE medicines
    SET stock_quantity = stock_quantity - p_quantity
    WHERE medicine_id = p_medicine_id;

    INSERT INTO dispensing_records (medicine_id, student_number, quantity, status)
    VALUES (p_medicine_id, btrim(p_student_number), p_quantity, 'dispensed');

    RAISE NOTICE 'Recorded dispensed: item %, units %.', p_medicine_id, p_quantity;
END;
$$;

-- 5. Two successful requests and one rejected request.
CALL dispense_medicine(1, '201903544', 20);
CALL dispense_medicine(2, '202600002', 15);
CALL dispense_medicine(1, '202600003', 200);

-- Expected availability by ID: 80, 5, 0.
-- Exactly two records exist, both with status 'dispensed'.
SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM dispensing_records ORDER BY dispensing_id;

-- 6. Restore availability only while the record is still 'dispensed'.
-- Locking the record also prevents two simultaneous reversals restoring twice.
CREATE OR REPLACE PROCEDURE reverse_dispensing(p_dispensing_id INTEGER)
LANGUAGE plpgsql
SET search_path TO ict371_scenario_4, pg_temp
AS $$
DECLARE
    v_record dispensing_records%ROWTYPE;
BEGIN
    SELECT * INTO v_record
    FROM dispensing_records
    WHERE dispensing_id = p_dispensing_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown dispensing_id: %', p_dispensing_id;
    END IF;

    IF v_record.status <> 'dispensed' THEN
        RAISE NOTICE 'Record % is already reversed; availability unchanged.', p_dispensing_id;
        RETURN;
    END IF;

    UPDATE medicines
    SET stock_quantity = stock_quantity + v_record.quantity
    WHERE medicine_id = v_record.medicine_id;

    UPDATE dispensing_records
    SET status = 'reversed'
    WHERE dispensing_id = p_dispensing_id;

    RAISE NOTICE 'Record % marked reversed; restored % units.',
        p_dispensing_id, v_record.quantity;
END;
$$;

CALL reverse_dispensing(1); -- Restores the first record's availability.
CALL reverse_dispensing(1); -- Does not restore it again.

-- 7. Explicit cursor: declare, OPEN, FETCH, check FOUND, and CLOSE.
-- Includes zero availability as well as low availability.
DO $$
DECLARE
    c_low CURSOR FOR
        SELECT medicine_id, medicine_name, stock_quantity
        FROM medicines
        WHERE stock_quantity < 10
        ORDER BY medicine_id;
    v_item RECORD;
BEGIN
    OPEN c_low;
    LOOP
        FETCH c_low INTO v_item;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Low availability: ID %, %, remaining % units.',
            v_item.medicine_id, v_item.medicine_name, v_item.stock_quantity;
    END LOOP;
    CLOSE c_low;
END;
$$ LANGUAGE plpgsql;

-- 8. Invalid input: negative quantity.
-- The procedure raises SQLSTATE 22023; this EXCEPTION block handles it.
-- Only that expected error is caught, so unrelated errors are not hidden.
DO $$
BEGIN
    CALL dispense_medicine(1, '201903544', -5);
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Invalid input handled: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- 9. Final evidence: rejected/invalid requests did not create records.
-- Availability by ID: 100, 5, 0.
-- Record 1: reversed. Record 2: dispensed. Total records: 2.
SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM dispensing_records ORDER BY dispensing_id;

COMMIT;
