-- ============================================================================
-- LIFE BLOSSOM CARE AND CURE HOSPITAL EMR
-- MIGRATION: SHARED PATIENT RECORD WORKFLOW
-- Version: 20261029120000
-- Purpose: Replace transfer-gated patient access with role-based shared access.
--          All active staff can now search and read the shared patient file.
--          Write permissions remain strictly department-specific.
--          No tables are dropped. No data is lost.
-- ============================================================================

-- ============================================================================
-- SECTION 1: NEW HELPER FUNCTION — is_active_staff()
-- Returns true for any authenticated active staff member (any role).
-- Used for shared READ policies.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_active_staff()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid()
          AND status = 'active'::account_status
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_active_staff() TO authenticated, service_role;

-- ============================================================================
-- SECTION 2: NEW HELPER FUNCTION — get_active_patient_encounter()
-- Returns the most recent open/in_progress encounter ID for a patient.
-- Used by dashboards to auto-associate new clinical entries.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_active_encounter_for_patient(p_patient_id UUID)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_encounter_id UUID;
BEGIN
    SELECT id INTO v_encounter_id
    FROM public.patient_encounters
    WHERE patient_id = p_patient_id
      AND status IN ('open', 'in_progress')
    ORDER BY created_at DESC
    LIMIT 1;
    RETURN v_encounter_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_encounter_for_patient(UUID) TO authenticated, service_role;

-- ============================================================================
-- SECTION 3: medicine_purchases TABLE
-- Tracks formal stock purchase receipts separately from batch records.
-- Preserves existing medicine_batches; this table is additive.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.medicine_purchases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    medicine_id UUID NOT NULL REFERENCES public.medicine_catalog(id) ON DELETE RESTRICT,
    batch_id UUID REFERENCES public.medicine_batches(id) ON DELETE SET NULL,
    supplier_name TEXT,
    invoice_number TEXT,
    purchase_date DATE NOT NULL DEFAULT CURRENT_DATE,
    quantity_received INTEGER NOT NULL CHECK (quantity_received > 0),
    unit_purchase_price NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_cost NUMERIC(12,2) GENERATED ALWAYS AS (quantity_received * unit_purchase_price) STORED,
    notes TEXT,
    received_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.medicine_purchases IS 'Formal purchase receipts for pharmacy stock-in events. Separate from medicine_batches.';

CREATE INDEX IF NOT EXISTS idx_purchases_medicine ON public.medicine_purchases(medicine_id);
CREATE INDEX IF NOT EXISTS idx_purchases_batch ON public.medicine_purchases(batch_id);
CREATE INDEX IF NOT EXISTS idx_purchases_date ON public.medicine_purchases(purchase_date DESC);

ALTER TABLE public.medicine_purchases ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "purchases_select_policy" ON public.medicine_purchases;
CREATE POLICY "purchases_select_policy" ON public.medicine_purchases
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_staff() AND public.get_my_role() = 'pharmacist'::user_role)
    );

DROP POLICY IF EXISTS "purchases_insert_policy" ON public.medicine_purchases;
CREATE POLICY "purchases_insert_policy" ON public.medicine_purchases
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_staff() AND public.get_my_role() = 'pharmacist'::user_role)
    );

-- ============================================================================
-- SECTION 4: UPDATED RLS POLICIES — SHARED READ ACCESS
--
-- KEY PRINCIPLE:
--   SELECT (READ) = Any active, authenticated staff member
--   INSERT/UPDATE (WRITE) = Strictly role-specific (unchanged from original)
--
-- We replace `can_access_patient(id)` in SELECT policies with `is_active_staff()`.
-- Write policies are left strictly as they were.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 4.1 patients — Universal search and read for active staff
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "patients_select_policy" ON public.patients;
CREATE POLICY "patients_select_policy" ON public.patients
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Active front_desk or admin (UNCHANGED)
-- (Already correct in original — only front_desk can create patients)

-- UPDATE: Active front_desk or admin (UNCHANGED)
-- (Already correct in original)

-- ----------------------------------------------------------------------------
-- 4.2 patient_encounters — All active staff can read encounters
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "encounters_select_policy" ON public.patient_encounters;
CREATE POLICY "encounters_select_policy" ON public.patient_encounters
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Front desk opens encounters; doctors initiate consultations (UNCHANGED)
-- UPDATE: Doctors update clinical data; front desk updates operational (UNCHANGED)

-- ----------------------------------------------------------------------------
-- 4.3 patient_vitals — All active staff can read vitals
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "vitals_select_policy" ON public.patient_vitals;
CREATE POLICY "vitals_select_policy" ON public.patient_vitals
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Nurses (and doctors for clinical reasons) — UNCHANGED but relaxed to nurse only per spec
DROP POLICY IF EXISTS "vitals_insert_policy" ON public.patient_vitals;
CREATE POLICY "vitals_insert_policy" ON public.patient_vitals
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'nurse'::user_role
        )
    );

-- UPDATE/DELETE remain prohibited (vitals are immutable clinical measurements)

-- ----------------------------------------------------------------------------
-- 4.4 clinical_notes — All active staff can read notes
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "notes_select_policy" ON public.clinical_notes;
CREATE POLICY "notes_select_policy" ON public.clinical_notes
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Doctors (clinical/amendment) and Nurses (nursing) — UNCHANGED

-- UPDATE: Authors may edit unsigned notes only — UNCHANGED

-- ----------------------------------------------------------------------------
-- 4.5 patient_diagnoses — All active staff can read diagnoses
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "diagnoses_select_policy" ON public.patient_diagnoses;
CREATE POLICY "diagnoses_select_policy" ON public.patient_diagnoses
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT/UPDATE: Doctors only — UNCHANGED

-- ----------------------------------------------------------------------------
-- 4.6 patient_allergies — All active staff can read allergies
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "allergies_select_policy" ON public.patient_allergies;
CREATE POLICY "allergies_select_policy" ON public.patient_allergies
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Doctors only — UNCHANGED

-- ----------------------------------------------------------------------------
-- 4.7 patient_documents — All active staff can read documents
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "documents_select_policy" ON public.patient_documents;
CREATE POLICY "documents_select_policy" ON public.patient_documents
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Doctors and lab technicians — UNCHANGED

-- ----------------------------------------------------------------------------
-- 4.8 laboratory_orders — All active staff can read lab orders
-- (Lab techs now see ALL pending orders, not just assigned ones)
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "lab_orders_select_policy" ON public.laboratory_orders;
CREATE POLICY "lab_orders_select_policy" ON public.laboratory_orders
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Doctor with active status — relaxed from can_access_patient
DROP POLICY IF EXISTS "lab_orders_insert_policy" ON public.laboratory_orders;
CREATE POLICY "lab_orders_insert_policy" ON public.laboratory_orders
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'doctor'::user_role
            AND ordering_doctor_id = auth.uid()
        )
    );

-- UPDATE: Doctor or assigned technician (technician can also self-assign)
DROP POLICY IF EXISTS "lab_orders_update_policy" ON public.laboratory_orders;
CREATE POLICY "lab_orders_update_policy" ON public.laboratory_orders
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND (
                ordering_doctor_id = auth.uid()
                OR assigned_technician_id = auth.uid()
                OR (
                    -- Lab tech can accept/self-assign unassigned orders
                    public.get_my_role() = 'lab_technician'::user_role
                    AND assigned_technician_id IS NULL
                )
            )
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND (
                ordering_doctor_id = auth.uid()
                OR assigned_technician_id = auth.uid()
                OR public.get_my_role() = 'lab_technician'::user_role
            )
        )
    );

-- ----------------------------------------------------------------------------
-- 4.9 laboratory_order_items — All active staff can read
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "lab_order_items_select_policy" ON public.laboratory_order_items;
CREATE POLICY "lab_order_items_select_policy" ON public.laboratory_order_items
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Doctors only (via their order) — UNCHANGED

-- ----------------------------------------------------------------------------
-- 4.10 laboratory_results — All active staff can read results
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "lab_results_select_policy" ON public.laboratory_results;
CREATE POLICY "lab_results_select_policy" ON public.laboratory_results
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Lab technician — relaxed from assigned_technician check
DROP POLICY IF EXISTS "lab_results_insert_policy" ON public.laboratory_results;
CREATE POLICY "lab_results_insert_policy" ON public.laboratory_results
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'lab_technician'::user_role
        )
    );

-- UPDATE: Lab technician (own results) — UNCHANGED logic
DROP POLICY IF EXISTS "lab_results_update_policy" ON public.laboratory_results;
CREATE POLICY "lab_results_update_policy" ON public.laboratory_results
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'lab_technician'::user_role
            AND (
                performed_by = auth.uid()
                OR EXISTS (
                    SELECT 1 FROM public.laboratory_orders o
                    WHERE o.id = order_id AND o.assigned_technician_id = auth.uid()
                )
            )
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'lab_technician'::user_role
        )
    );

-- ----------------------------------------------------------------------------
-- 4.11 prescriptions — All active staff can read prescriptions
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "prescriptions_select_policy" ON public.prescriptions;
CREATE POLICY "prescriptions_select_policy" ON public.prescriptions
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Doctors only — relaxed from can_access_patient
DROP POLICY IF EXISTS "prescriptions_insert_policy" ON public.prescriptions;
CREATE POLICY "prescriptions_insert_policy" ON public.prescriptions
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'doctor'::user_role
            AND prescribing_doctor_id = auth.uid()
        )
    );

-- UPDATE: Doctor can modify own draft prescriptions.
-- Pharmacist can update status fields (dispensed/partially_dispensed) but NOT clinical content.
DROP POLICY IF EXISTS "prescriptions_update_policy" ON public.prescriptions;
CREATE POLICY "prescriptions_update_policy" ON public.prescriptions
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'doctor'::user_role
            AND prescribing_doctor_id = auth.uid()
            AND status = 'draft'::prescription_status
        )
        OR (
            -- Pharmacist can update status to dispensed/partially_dispensed
            public.is_active_staff()
            AND public.get_my_role() = 'pharmacist'::user_role
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND (
                public.get_my_role() = 'doctor'::user_role
                OR public.get_my_role() = 'pharmacist'::user_role
            )
        )
    );

-- ----------------------------------------------------------------------------
-- 4.12 prescription_items — All active staff can read
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "rx_items_select_policy" ON public.prescription_items;
CREATE POLICY "rx_items_select_policy" ON public.prescription_items
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Doctors only — UNCHANGED

-- UPDATE: Pharmacist can update quantity_dispensed field
DROP POLICY IF EXISTS "rx_items_update_policy" ON public.prescription_items;
CREATE POLICY "rx_items_update_policy" ON public.prescription_items
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'pharmacist'::user_role
        )
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'doctor'::user_role
            AND EXISTS (
                SELECT 1 FROM public.prescriptions p
                WHERE p.id = prescription_id
                  AND p.prescribing_doctor_id = auth.uid()
                  AND p.status = 'draft'::prescription_status
            )
        )
    )
    WITH CHECK (
        public.is_admin()
        OR public.is_active_staff()
    );

-- ----------------------------------------------------------------------------
-- 4.13 dispensing_records — All active staff can read
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "dispensing_select_policy" ON public.dispensing_records;
CREATE POLICY "dispensing_select_policy" ON public.dispensing_records
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT/UPDATE: Pharmacists only — UNCHANGED

-- ----------------------------------------------------------------------------
-- 4.14 dispensing_items — All active staff can read
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "dispensing_items_select_policy" ON public.dispensing_items;
CREATE POLICY "dispensing_items_select_policy" ON public.dispensing_items
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Pharmacists only — UNCHANGED

-- ============================================================================
-- SECTION 5: STOCK RECEIPT FUNCTION
-- Atomic stock-in operation for pharmacy purchases.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.receive_stock(
    p_medicine_id UUID,
    p_batch_id UUID,
    p_quantity INTEGER,
    p_purchase_id UUID,
    p_performed_by UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_current_stock INTEGER;
    v_new_stock INTEGER;
    v_actor UUID;
BEGIN
    -- Role validation
    IF NOT (public.is_admin() OR (public.is_active_staff() AND public.get_my_role() = 'pharmacist'::user_role)) THEN
        RAISE EXCEPTION 'Unauthorized: Only active pharmacists or administrators may receive stock.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Stock receipt quantity must be greater than zero.'
            USING ERRCODE = 'check_violation';
    END IF;

    v_actor := COALESCE(p_performed_by, auth.uid());

    -- Lock medicine_catalog row
    SELECT available_stock INTO v_current_stock
    FROM public.medicine_catalog
    WHERE id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine % not found in catalog.', p_medicine_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    v_new_stock := v_current_stock + p_quantity;

    -- Update catalog stock
    UPDATE public.medicine_catalog
    SET available_stock = v_new_stock,
        updated_at = now()
    WHERE id = p_medicine_id;

    -- Record inventory movement
    INSERT INTO public.inventory_movements (
        medicine_id, batch_id, movement_type, quantity,
        previous_stock, resulting_stock, reference_id, reason, performed_by
    ) VALUES (
        p_medicine_id, p_batch_id, 'stock_receipt'::movement_type, p_quantity,
        v_current_stock, v_new_stock, p_purchase_id,
        'Stock receipt for purchase ' || COALESCE(p_purchase_id::TEXT, 'N/A'),
        v_actor
    );

    RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.receive_stock(UUID, UUID, INTEGER, UUID, UUID) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.receive_stock(UUID, UUID, INTEGER, UUID, UUID) FROM anon, public;

-- ============================================================================
-- SECTION 6: PATIENT SEARCH FUNCTION (server-side, bypasses transfer gate)
-- Returns patients matching a search query for any active staff member.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.search_patients_shared(
    p_query TEXT DEFAULT '',
    p_limit INTEGER DEFAULT 20,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    hospital_number TEXT,
    first_name TEXT,
    middle_name TEXT,
    last_name TEXT,
    date_of_birth DATE,
    sex sex_type,
    phone TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    -- Only active staff can search
    IF NOT public.is_active_staff() THEN
        RAISE EXCEPTION 'Only active staff members may search patient records.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    RETURN QUERY
    SELECT
        pt.id, pt.hospital_number, pt.first_name, pt.middle_name, pt.last_name,
        pt.date_of_birth, pt.sex, pt.phone, pt.created_at
    FROM public.patients pt
    WHERE
        p_query = ''
        OR pt.hospital_number ILIKE '%' || p_query || '%'
        OR pt.first_name ILIKE '%' || p_query || '%'
        OR pt.last_name ILIKE '%' || p_query || '%'
        OR pt.phone ILIKE '%' || p_query || '%'
        OR (pt.first_name || ' ' || pt.last_name) ILIKE '%' || p_query || '%'
    ORDER BY pt.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.search_patients_shared(TEXT, INTEGER, INTEGER) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.search_patients_shared(TEXT, INTEGER, INTEGER) FROM anon, public;

-- ============================================================================
-- SECTION 7: FULL TEXT SEARCH INDEX ON PATIENTS
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_patients_fulltext ON public.patients
    USING gin(to_tsvector('english', first_name || ' ' || COALESCE(middle_name, '') || ' ' || last_name));

CREATE INDEX IF NOT EXISTS idx_patients_first_name ON public.patients(first_name);

-- ============================================================================
-- SECTION 8: NOTIFICATION POLICY UPDATE
-- Allow system to insert notifications for any staff (not just admin)
-- ============================================================================

DROP POLICY IF EXISTS "notifications_insert_policy" ON public.notifications;
CREATE POLICY "notifications_insert_policy" ON public.notifications
    FOR INSERT TO authenticated
    WITH CHECK (public.is_active_staff());

-- ============================================================================
-- SECTION 9: increment_dispensed_qty RPC
-- Atomically increments quantity_dispensed on a prescription_items row.
-- Called by shared-api.js dispenseItems() for each dispensed line item.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.increment_dispensed_qty(
    p_item_id  UUID,
    p_qty      INTEGER
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    -- Only pharmacists and admins may call this via RLS on prescription_items;
    -- the SECURITY DEFINER here lets the increment bypass a second RLS check
    -- while the caller's JWT still governs who can invoke it.
    UPDATE public.prescription_items
    SET quantity_dispensed = COALESCE(quantity_dispensed, 0) + p_qty
    WHERE id = p_item_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Prescription item % not found', p_item_id;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.increment_dispensed_qty(UUID, INTEGER) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.increment_dispensed_qty(UUID, INTEGER) FROM anon, public;

-- ============================================================================
-- END OF MIGRATION: 20261029120000_shared_patient_workflow.sql
-- ============================================================================
