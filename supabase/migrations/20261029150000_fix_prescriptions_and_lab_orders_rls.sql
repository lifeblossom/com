-- ============================================================================
-- LIFE BLOSSOM CARE AND CURE HOSPITAL EMR
-- MIGRATION: FIX PRESCRIPTIONS AND LAB ORDERS RLS POLICIES
-- Version: 20261029150000
-- Purpose:
--   1. Allow doctors to insert prescription items for active and draft prescriptions
--      they authored (resolves HTTP 403 when creating prescriptions).
--   2. Ensure doctors can order lab tests and create prescriptions for any patient
--      they treat (replaces legacy transfer-gated can_access_patient restrictions).
--   3. Preserve pharmacist dispensing access and lab technician order processing.
--
-- Safety Guarantees:
--   - No tables dropped, truncated, or recreated.
--   - No existing data modified or deleted.
--   - Row Level Security (RLS) remains enabled on all tables.
--   - Doctor insert authorization strictly checks prescribing_doctor_id = auth.uid()
--     and ordering_doctor_id = auth.uid().
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Helper Function: is_active_staff()
-- ----------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------
-- 2. Prescriptions Policies
-- ----------------------------------------------------------------------------
ALTER TABLE public.prescriptions ENABLE ROW LEVEL SECURITY;

-- SELECT: All active staff can view prescriptions (doctors, nurses, pharmacists)
DROP POLICY IF EXISTS "prescriptions_select_policy" ON public.prescriptions;
CREATE POLICY "prescriptions_select_policy" ON public.prescriptions
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Active doctor creating a prescription where they are the prescribing doctor
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

-- UPDATE: Doctor can update own draft; Pharmacist can update status during dispensing
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
            public.is_active_staff()
            AND public.get_my_role() = 'pharmacist'::user_role
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND (
                (public.get_my_role() = 'doctor'::user_role AND prescribing_doctor_id = auth.uid())
                OR public.get_my_role() = 'pharmacist'::user_role
            )
        )
    );

-- ----------------------------------------------------------------------------
-- 3. Prescription Items Policies
-- ----------------------------------------------------------------------------
ALTER TABLE public.prescription_items ENABLE ROW LEVEL SECURITY;

-- SELECT: All active staff can view prescription items
DROP POLICY IF EXISTS "rx_items_select_policy" ON public.prescription_items;
CREATE POLICY "rx_items_select_policy" ON public.prescription_items
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Doctor inserting items for their own prescription (status: draft OR active)
DROP POLICY IF EXISTS "rx_items_insert_policy" ON public.prescription_items;
CREATE POLICY "rx_items_insert_policy" ON public.prescription_items
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'doctor'::user_role
            AND EXISTS (
                SELECT 1 FROM public.prescriptions p
                WHERE p.id = prescription_id
                  AND p.prescribing_doctor_id = auth.uid()
                  AND p.status IN ('draft'::prescription_status, 'active'::prescription_status)
            )
        )
    );

-- UPDATE: Pharmacist can update quantity_dispensed; Doctor can update draft items
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
-- 4. Laboratory Orders Policies
-- ----------------------------------------------------------------------------
ALTER TABLE public.laboratory_orders ENABLE ROW LEVEL SECURITY;

-- SELECT: All active staff can view laboratory orders
DROP POLICY IF EXISTS "lab_orders_select_policy" ON public.laboratory_orders;
CREATE POLICY "lab_orders_select_policy" ON public.laboratory_orders
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Active doctor creating a lab order where they are the ordering doctor
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

-- UPDATE: Ordering doctor or assigned technician
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
-- 5. Laboratory Order Items Policies
-- ----------------------------------------------------------------------------
ALTER TABLE public.laboratory_order_items ENABLE ROW LEVEL SECURITY;

-- SELECT: All active staff can view laboratory order items
DROP POLICY IF EXISTS "lab_order_items_select_policy" ON public.laboratory_order_items;
CREATE POLICY "lab_order_items_select_policy" ON public.laboratory_order_items
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT: Active doctor inserting items for their own order
DROP POLICY IF EXISTS "lab_order_items_insert_policy" ON public.laboratory_order_items;
CREATE POLICY "lab_order_items_insert_policy" ON public.laboratory_order_items
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() = 'doctor'::user_role
            AND EXISTS (
                SELECT 1 FROM public.laboratory_orders o
                WHERE o.id = order_id
                  AND o.ordering_doctor_id = auth.uid()
            )
        )
    );

-- Table Grants
GRANT SELECT, INSERT, UPDATE ON public.prescriptions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.prescription_items TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.laboratory_orders TO authenticated;
GRANT SELECT, INSERT ON public.laboratory_order_items TO authenticated;
