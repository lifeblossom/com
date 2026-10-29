-- ============================================================================
-- LIFE BLOSSOM CARE AND CURE HOSPITAL EMR
-- MIGRATION: FIX PATIENT VITALS RLS SHARED ACCESS
-- Version: 20261029140000
-- Purpose: Allow active clinical staff (doctors and nurses) to read and record
--          vital signs across shared patient records without requiring prior
--          file transfer records.
--
-- Safety Guarantees:
--   - No tables dropped.
--   - No data deleted or modified.
--   - Preserves patient_vitals immutability (no UPDATE/DELETE policies).
--   - Enforces strict role checks: read for active staff, insert for nurse/doctor.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Ensure helper function is_active_staff() exists
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
-- 2. Update RLS policies on public.patient_vitals
-- ----------------------------------------------------------------------------
ALTER TABLE public.patient_vitals ENABLE ROW LEVEL SECURITY;

-- SELECT Policy: Any active staff member (or admin) can view patient vitals
DROP POLICY IF EXISTS "vitals_select_policy" ON public.patient_vitals;
CREATE POLICY "vitals_select_policy" ON public.patient_vitals
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- INSERT Policy: Active nurses and doctors (and admins) can record patient vitals
DROP POLICY IF EXISTS "vitals_insert_policy" ON public.patient_vitals;
CREATE POLICY "vitals_insert_policy" ON public.patient_vitals
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_staff()
            AND public.get_my_role() IN ('nurse'::user_role, 'doctor'::user_role)
        )
    );

-- Ensure authenticated role has necessary table privileges
GRANT SELECT, INSERT ON public.patient_vitals TO authenticated;

-- Comment for schema documentation
COMMENT ON POLICY "vitals_select_policy" ON public.patient_vitals IS
    'Allows all active hospital staff to view vital signs on shared patient records.';
COMMENT ON POLICY "vitals_insert_policy" ON public.patient_vitals IS
    'Allows active nurses and doctors to record immutable vital signs.';
