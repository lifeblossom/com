-- ============================================================================
-- Migration: 20261108160000_fix_empty_prescriptions.sql
-- Project: Life Blossom Care and Cure Hospital EMR
-- Target Supabase Project Ref: yealxvgednecmwnehfrs
--
-- DESCRIPTION:
--   1. Implements public.create_prescription_atomic:
--      - Authenticates caller as active doctor or administrator.
--      - Validates patient access: Requires caller to be an administrator, OR
--        an active doctor for whom public.can_access_patient(p_patient_id) returns true.
--        Eliminates any role-only access bypass.
--      - Validates that the encounter exists and belongs to the specified patient.
--      - Validates p_items payload using three independent sequential checks:
--        a) Rejects NULL payload.
--        b) Confirms JSON type is an array via jsonb_typeof(p_items) IS DISTINCT FROM 'array'.
--        c) Only calls jsonb_array_length() once confirmed array, rejecting empty array.
--      - Validates all medicine item fields (medicine_name, dosage, frequency, duration, quantity > 0).
--      - Validates medicine_id: If supplied and non-empty, strictly validates UUID format and rejects
--        malformed UUIDs with a clear exception (does not silently convert invalid UUIDs to NULL).
--        Permits NULL when medicine_id is genuinely omitted.
--      - Atomic transaction: Inserts parent prescription and all child items together;
--        rolls back completely if any item insertion fails.
--      - Guarantees no active empty prescription can ever be created.
--
--   2. Implements public.cancel_empty_prescription:
--      - Authenticates caller as active staff.
--      - Restricts cancellation strictly to the prescribing doctor or an administrator.
--      - Acquires row-level exclusive lock (FOR UPDATE) to prevent race conditions.
--      - Validates that the prescription has zero prescription items and no dispensing records.
--      - Restricts cancellation to eligible statuses ('draft', 'active').
--      - Refuses to cancel completed, dispensed, partially dispensed, or already cancelled records.
--      - Preserves original prescription record and records an immutable audit entry in public.audit_logs.
--
--   3. Hardening & Policy Preservation:
--      - Preserves existing prescriptions_update_policy unchanged (no broad doctor update permissions).
--      - Explicitly REVOKES execute privileges from PUBLIC and anon.
--      - GRANTS execute privileges strictly to authenticated.
--      - Uses pinned search_path = public, auth, pg_temp to prevent search-path hijacking.
--      - Uses standard PostgreSQL NULLIF and COALESCE conditional expressions.
--
-- DO NOT RUN REMOTE SQL WITHOUT EXPLICIT APPROVAL.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Atomic Prescription Creation RPC Function
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_prescription_atomic(
    p_patient_id UUID,
    p_encounter_id UUID,
    p_notes TEXT,
    p_items JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role public.user_role;
    v_patient public.patients%ROWTYPE;
    v_encounter public.patient_encounters%ROWTYPE;
    v_item JSONB;
    v_item_count INTEGER := 0;
    v_rx public.prescriptions%ROWTYPE;
    v_med_id UUID;
    v_med_name TEXT;
    v_dosage TEXT;
    v_route TEXT;
    v_frequency TEXT;
    v_duration TEXT;
    v_quantity INTEGER;
    v_strength TEXT;
    v_instructions TEXT;
    v_created_at TIMESTAMPTZ := now();
BEGIN
    -- 1. Authentication & Active Staff Verification
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated: valid session required'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF public.is_active_staff() IS NOT TRUE THEN
        RAISE EXCEPTION 'Not authorized: active staff profile required'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- 2. Role Verification: Must be doctor or administrator (NULL-safe)
    v_caller_role := public.get_my_role();
    IF v_caller_role IS DISTINCT FROM 'doctor'::public.user_role AND public.is_admin() IS NOT TRUE THEN
        RAISE EXCEPTION 'Only doctors and administrators can create prescriptions'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- 3. Patient Existence & Authorization Check
    SELECT * INTO v_patient
    FROM public.patients
    WHERE id = p_patient_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient not found: %', p_patient_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- Strict Patient Access Validation (Explicitly NULL-safe):
    -- Caller must be an administrator, OR an active doctor for whom can_access_patient(p_patient_id) is true.
    -- Prevents role-only access bypass with NULL-safe comparisons throughout.
    IF NOT (
        (public.is_admin() IS TRUE)
        OR (
            (public.is_active_staff() IS TRUE)
            AND (v_caller_role IS NOT DISTINCT FROM 'doctor'::public.user_role)
            AND (public.can_access_patient(p_patient_id) IS TRUE)
        )
    ) THEN
        RAISE EXCEPTION 'Caller is not authorized to access patient %', p_patient_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- 4. Encounter Validation (if supplied)
    IF p_encounter_id IS NOT NULL THEN
        SELECT * INTO v_encounter
        FROM public.patient_encounters
        WHERE id = p_encounter_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Patient encounter not found: %', p_encounter_id
                USING ERRCODE = 'no_data_found';
        END IF;

        IF v_encounter.patient_id IS DISTINCT FROM p_patient_id THEN
            RAISE EXCEPTION 'Encounter % does not belong to patient %', p_encounter_id, p_patient_id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- 5. Items Validation: Three independent sequential checks
    -- Check 5.1: Null input check
    IF p_items IS NULL THEN
        RAISE EXCEPTION 'Prescription items payload is required.'
            USING ERRCODE = 'null_value_not_allowed';
    END IF;

    -- Check 5.2: JSON type check (confirm array before length check)
    IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Prescription items payload must be a JSON array.'
            USING ERRCODE = 'datatype_mismatch';
    END IF;

    -- Check 5.3: Non-empty array check
    IF jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Please add at least one medicine before submitting this prescription.'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Validate all medication items upfront before executing any INSERT
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_item_count := v_item_count + 1;

        v_med_name := NULLIF(trim(v_item->>'medicine_name'), '');
        IF v_med_name IS NULL THEN
            RAISE EXCEPTION 'Item #%: Medicine name is required', v_item_count
                USING ERRCODE = 'check_violation';
        END IF;

        -- Validate medicine_id: If supplied and non-empty, reject malformed UUID. Allow NULL if omitted.
        IF (v_item->>'medicine_id') IS NOT NULL AND trim(v_item->>'medicine_id') != '' THEN
            BEGIN
                v_med_id := (v_item->>'medicine_id')::UUID;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'Item #% (%): Invalid medicine_id UUID: %', v_item_count, v_med_name, v_item->>'medicine_id'
                    USING ERRCODE = 'invalid_text_representation';
            END;
        ELSE
            v_med_id := NULL;
        END IF;

        v_dosage := NULLIF(trim(v_item->>'dosage'), '');
        IF v_dosage IS NULL THEN
            RAISE EXCEPTION 'Item #% (%): Dosage is required', v_item_count, v_med_name
                USING ERRCODE = 'check_violation';
        END IF;

        v_frequency := NULLIF(trim(v_item->>'frequency'), '');
        IF v_frequency IS NULL THEN
            RAISE EXCEPTION 'Item #% (%): Frequency is required', v_item_count, v_med_name
                USING ERRCODE = 'check_violation';
        END IF;

        v_duration := NULLIF(trim(v_item->>'duration'), '');
        IF v_duration IS NULL THEN
            RAISE EXCEPTION 'Item #% (%): Duration is required', v_item_count, v_med_name
                USING ERRCODE = 'check_violation';
        END IF;

        BEGIN
            v_quantity := (v_item->>'quantity')::INTEGER;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'Item #% (%): Prescribed quantity must be a valid integer', v_item_count, v_med_name
                USING ERRCODE = 'check_violation';
        END;

        IF v_quantity IS NULL OR v_quantity <= 0 THEN
            RAISE EXCEPTION 'Item #% (%): Prescribed quantity must be greater than 0', v_item_count, v_med_name
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    -- 6. Atomic Insertion: Insert Parent Prescription
    -- prescription_number is populated by trg_generate_prescription_number trigger if null
    INSERT INTO public.prescriptions (
        patient_id,
        encounter_id,
        prescribing_doctor_id,
        status,
        notes,
        created_at,
        updated_at
    ) VALUES (
        p_patient_id,
        p_encounter_id,
        v_caller_id,
        'active'::public.prescription_status,
        NULLIF(trim(p_notes), ''),
        v_created_at,
        v_created_at
    ) RETURNING * INTO v_rx;

    -- 7. Atomic Insertion: Insert Child Prescription Items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        IF (v_item->>'medicine_id') IS NOT NULL AND trim(v_item->>'medicine_id') != '' THEN
            v_med_id := (v_item->>'medicine_id')::UUID;
        ELSE
            v_med_id := NULL;
        END IF;

        v_med_name     := trim(v_item->>'medicine_name');
        v_strength     := NULLIF(trim(v_item->>'strength'), '');
        v_dosage       := trim(v_item->>'dosage');
        v_route        := COALESCE(NULLIF(trim(v_item->>'route'), ''), 'oral');
        v_frequency    := trim(v_item->>'frequency');
        v_duration     := NULLIF(trim(v_item->>'duration'), '');
        v_quantity     := (v_item->>'quantity')::INTEGER;
        v_instructions := NULLIF(trim(v_item->>'instructions'), '');

        INSERT INTO public.prescription_items (
            prescription_id,
            medicine_id,
            medicine_name,
            strength,
            dosage,
            route,
            frequency,
            duration,
            quantity,
            quantity_dispensed,
            instructions,
            created_at
        ) VALUES (
            v_rx.id,
            v_med_id,
            v_med_name,
            v_strength,
            v_dosage,
            v_route,
            v_frequency,
            v_duration,
            v_quantity,
            0,
            v_instructions,
            v_created_at
        );
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'prescription', to_jsonb(v_rx),
        'item_count', v_item_count
    );
END;
$$;

-- Function Execution Permissions
REVOKE EXECUTE ON FUNCTION public.create_prescription_atomic(UUID, UUID, TEXT, JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_prescription_atomic(UUID, UUID, TEXT, JSONB) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_prescription_atomic(UUID, UUID, TEXT, JSONB) TO authenticated;

COMMENT ON FUNCTION public.create_prescription_atomic IS
  'Atomically creates a prescription with all child items in a single transaction. '
  'Enforces patient access authorization via can_access_patient, encounter integrity, non-empty items, and field validation. '
  'Prevents creation of empty active prescriptions.';

-- ----------------------------------------------------------------------------
-- 2. Authorized Empty Prescription Cancellation RPC Function
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_empty_prescription(
    p_prescription_id UUID,
    p_reason TEXT DEFAULT 'Cancelled empty prescription with zero items'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role public.user_role;
    v_rx public.prescriptions%ROWTYPE;
    v_item_count INTEGER;
    v_dispense_count INTEGER;
    v_now TIMESTAMPTZ := now();
    v_cancellation_reason TEXT;
BEGIN
    -- 1. Authentication & Active Staff Verification
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated: valid session required'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF public.is_active_staff() IS NOT TRUE THEN
        RAISE EXCEPTION 'Not authorized: active staff profile required'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- 2. Row Lock & Prescription Retrieval (FOR UPDATE eliminates race conditions)
    SELECT * INTO v_rx
    FROM public.prescriptions
    WHERE id = p_prescription_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Prescription not found: %', p_prescription_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- 3. Authorization: Permitted only for prescribing doctor or active administrator (NULL-safe)
    v_caller_role := public.get_my_role();
    IF NOT (
        (public.is_admin() IS TRUE)
        OR (
            (v_caller_role IS NOT DISTINCT FROM 'doctor'::public.user_role)
            AND ((v_rx.prescribing_doctor_id = v_caller_id) IS TRUE)
        )
    ) THEN
        RAISE EXCEPTION 'Only the prescribing doctor or an administrator can cancel this prescription'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- 4. Status Checks: Restrict cancellation to eligible statuses
    IF v_rx.status = 'cancelled'::public.prescription_status THEN
        RAISE EXCEPTION 'Prescription % is already cancelled', v_rx.prescription_number
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_rx.status IN ('dispensed'::public.prescription_status, 'partially_dispensed'::public.prescription_status) THEN
        RAISE EXCEPTION 'Prescription % cannot be cancelled because its status is %', v_rx.prescription_number, v_rx.status
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_rx.status NOT IN ('draft'::public.prescription_status, 'active'::public.prescription_status) THEN
        RAISE EXCEPTION 'Prescription % with status % is not eligible for cancellation', v_rx.prescription_number, v_rx.status
            USING ERRCODE = 'check_violation';
    END IF;

    -- 5. Empty Items Verification: Must have strictly zero items
    SELECT count(*) INTO v_item_count
    FROM public.prescription_items
    WHERE prescription_id = p_prescription_id;

    IF v_item_count > 0 THEN
        RAISE EXCEPTION 'Cannot cancel prescription % via empty prescription workflow: it contains % medication item(s)', v_rx.prescription_number, v_item_count
            USING ERRCODE = 'check_violation';
    END IF;

    -- 6. Dispensing Records Verification: Must have no dispensing events
    SELECT count(*) INTO v_dispense_count
    FROM public.dispensing_records
    WHERE prescription_id = p_prescription_id;

    IF v_dispense_count > 0 THEN
        RAISE EXCEPTION 'Cannot cancel prescription %: dispensing records exist for this prescription', v_rx.prescription_number
            USING ERRCODE = 'check_violation';
    END IF;

    -- 7. Preserve Record & Update Status to 'cancelled'
    v_cancellation_reason := COALESCE(NULLIF(trim(p_reason), ''), 'Zero items');

    UPDATE public.prescriptions
    SET status = 'cancelled'::public.prescription_status,
        notes = COALESCE(notes || E'\n', '') || '[Cancelled: ' || v_cancellation_reason || ' by ' || v_caller_id::TEXT || ' at ' || v_now::TEXT || ']',
        updated_at = v_now
    WHERE id = p_prescription_id;

    -- 8. Audit Logging: Record immutable event in public.audit_logs
    INSERT INTO public.audit_logs (
        actor_id,
        action,
        table_name,
        record_id,
        old_data,
        new_data,
        ip_address,
        created_at
    ) VALUES (
        v_caller_id,
        'CANCEL_EMPTY_PRESCRIPTION',
        'prescriptions',
        p_prescription_id,
        to_jsonb(v_rx),
        jsonb_build_object(
            'status', 'cancelled',
            'previous_status', v_rx.status,
            'prescription_number', v_rx.prescription_number,
            'reason', v_cancellation_reason
        ),
        NULL,
        v_now
    );

    RETURN jsonb_build_object(
        'success', true,
        'prescription_id', p_prescription_id,
        'prescription_number', v_rx.prescription_number,
        'previous_status', v_rx.status,
        'status', 'cancelled'
    );
END;
$$;

-- Function Execution Permissions
REVOKE EXECUTE ON FUNCTION public.cancel_empty_prescription(UUID, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cancel_empty_prescription(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.cancel_empty_prescription(UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.cancel_empty_prescription IS
  'Safely cancels an empty prescription with zero medication items. '
  'Requires caller to be prescribing doctor or admin. Locks row for update, '
  'refuses cancellation if items or dispensing records exist, preserves record, '
  'and writes audit event to public.audit_logs.';

COMMIT;
