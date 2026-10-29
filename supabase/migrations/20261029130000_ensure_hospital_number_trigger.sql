-- ============================================================================
-- Life Blossom Care and Cure Hospital EMR — Database Migration
-- Migration: 20261029130000_ensure_hospital_number_trigger.sql
-- Description:
--   1. Ensures seq_hospital_number exists and is synchronized to the maximum
--      existing patient hospital number suffix for the current year.
--   2. Ensures generate_hospital_number() trigger function generates
--      collision-free hospital numbers in format 'LBC-YYYYNNNNN' on INSERT.
--   3. Auto-populates registered_by with auth.uid() when not provided.
--   4. Attaches trg_generate_hospital_number as a BEFORE INSERT trigger.
--   5. Grants proper sequence and table permissions.
--   6. Ensures robust RLS policies on public.patients.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Ensure Sequence Exists and Synchronize Value
-- ----------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS public.seq_hospital_number START WITH 1;

DO $$
DECLARE
    v_curr_year TEXT := to_char(CURRENT_DATE, 'YYYY');
    v_max_val BIGINT := 0;
BEGIN
    -- Extract highest existing numeric suffix for the current year (e.g. LBC-202600005 -> 5)
    SELECT COALESCE(
        MAX(NULLIF(regexp_replace(hospital_number, '^LBC-' || v_curr_year, ''), '')::BIGINT),
        0
    )
    INTO v_max_val
    FROM public.patients
    WHERE hospital_number ~ ('^LBC-' || v_curr_year || '\d+$');

    IF v_max_val > 0 THEN
        PERFORM setval('public.seq_hospital_number', v_max_val);
        RAISE NOTICE 'Synchronized seq_hospital_number to % for year %', v_max_val, v_curr_year;
    ELSE
        RAISE NOTICE 'seq_hospital_number ready (starting fresh)';
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Sequence Permissions
-- ----------------------------------------------------------------------------
GRANT USAGE, SELECT ON SEQUENCE public.seq_hospital_number TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Trigger Function: generate_hospital_number()
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_hospital_number()
RETURNS TRIGGER AS $$
DECLARE
    v_year TEXT := to_char(CURRENT_DATE, 'YYYY');
    v_seq_val BIGINT;
BEGIN
    -- Auto-generate hospital_number if not supplied or empty
    IF NEW.hospital_number IS NULL OR trim(NEW.hospital_number) = '' THEN
        v_seq_val := nextval('public.seq_hospital_number');
        NEW.hospital_number := 'LBC-' || v_year || lpad(v_seq_val::TEXT, 5, '0');
    END IF;

    -- Auto-populate registered_by with authenticated caller ID if omitted
    IF NEW.registered_by IS NULL THEN
        NEW.registered_by := auth.uid();
    END IF;

    -- Ensure audit timestamps
    IF NEW.created_at IS NULL THEN
        NEW.created_at := now();
    END IF;
    NEW.updated_at := now();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth;

-- Grant execution to authenticated users and service_role
GRANT EXECUTE ON FUNCTION public.generate_hospital_number() TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Attach BEFORE INSERT Trigger on public.patients
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_generate_hospital_number ON public.patients;

CREATE TRIGGER trg_generate_hospital_number
    BEFORE INSERT ON public.patients
    FOR EACH ROW
    EXECUTE FUNCTION public.generate_hospital_number();

-- ----------------------------------------------------------------------------
-- 5. Verify & Enforce Row-Level Security Policies on public.patients
-- ----------------------------------------------------------------------------
ALTER TABLE public.patients ENABLE ROW LEVEL SECURITY;

-- 5.1 SELECT Policy: Universal read for active staff and admins
DROP POLICY IF EXISTS "patients_select_policy" ON public.patients;
CREATE POLICY "patients_select_policy" ON public.patients
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR public.is_active_staff()
    );

-- 5.2 INSERT Policy: Active front_desk or admin can register patients
DROP POLICY IF EXISTS "patients_insert_policy" ON public.patients;
CREATE POLICY "patients_insert_policy" ON public.patients
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'front_desk'::user_role)
    );

-- 5.3 UPDATE Policy: Active front_desk or admin can update demographics
DROP POLICY IF EXISTS "patients_update_policy" ON public.patients;
CREATE POLICY "patients_update_policy" ON public.patients
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'front_desk'::user_role)
    )
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'front_desk'::user_role)
    );

-- ----------------------------------------------------------------------------
-- 6. Grant Table Permissions to authenticated role
-- ----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON TABLE public.patients TO authenticated;

-- ============================================================================
-- VERIFICATION QUERY (Run this after applying to test the trigger)
-- ============================================================================
-- SELECT
--     c.relname AS table_name,
--     t.tgname AS trigger_name,
--     p.proname AS function_name
-- FROM pg_trigger t
-- JOIN pg_class c ON t.tgrelid = c.oid
-- JOIN pg_proc p ON t.tgfoid = p.oid
-- WHERE c.relname = 'patients' AND t.tgname = 'trg_generate_hospital_number';
