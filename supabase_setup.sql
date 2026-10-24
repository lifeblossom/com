-- ============================================================================
-- LIFE BLOSSOM CARE AND CURE HOSPITAL EMR SYSTEM
-- COMPLETE PRODUCTION SUPABASE DATABASE SETUP SCRIPT
-- ============================================================================
-- Architecture: PostgreSQL 15+ / Supabase
-- Target File: supabase_setup.sql
-- Security Framework: Row Level Security (RLS) + SECURITY DEFINER Helper Functions
-- Compliance Standard: HIPAA / Electronic Medical Record (EMR) Data Governance
-- ============================================================================

-- ============================================================================
-- SECTION 1: EXTENSIONS
-- ============================================================================
-- Enables standard UUID generation algorithms (v1, v4) and cryptographic primitives.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- SECTION 2: CUSTOM ENUM TYPES
-- ============================================================================
-- Using idempotent DO blocks to ensure the script can run repeatedly without errors.

DO $$
BEGIN
    -- Hospital staff roles for RBAC enforcement
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
        CREATE TYPE user_role AS ENUM (
            'admin',
            'doctor',
            'nurse',
            'pharmacist',
            'front_desk',
            'lab_technician'
        );
    END IF;

    -- Staff account lifecycle states
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'account_status') THEN
        CREATE TYPE account_status AS ENUM (
            'active',
            'suspended',
            'deactivated'
        );
    END IF;

    -- Physical/electronic chart transfer statuses between hospital departments
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'transfer_status') THEN
        CREATE TYPE transfer_status AS ENUM (
            'draft',
            'sent',
            'received',
            'in_progress',
            'awaiting_results',
            'awaiting_pharmacy',
            'completed',
            'returned',
            'cancelled'
        );
    END IF;

    -- Clinical encounter lifecycle
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'encounter_status') THEN
        CREATE TYPE encounter_status AS ENUM (
            'open',
            'in_progress',
            'closed',
            'cancelled'
        );
    END IF;

    -- Laboratory order workflow statuses
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lab_order_status') THEN
        CREATE TYPE lab_order_status AS ENUM (
            'pending',
            'assigned',
            'in_progress',
            'completed',
            'cancelled'
        );
    END IF;

    -- Laboratory result review and verification statuses
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lab_result_status') THEN
        CREATE TYPE lab_result_status AS ENUM (
            'draft',
            'finalized',
            'amended'
        );
    END IF;

    -- Medical prescription statuses
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'prescription_status') THEN
        CREATE TYPE prescription_status AS ENUM (
            'draft',
            'active',
            'dispensed',
            'partially_dispensed',
            'cancelled'
        );
    END IF;

    -- Pharmacy dispensing delivery statuses
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'dispensing_status') THEN
        CREATE TYPE dispensing_status AS ENUM (
            'pending',
            'partial',
            'completed',
            'cancelled'
        );
    END IF;

    -- Clinical document categorization
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'document_category') THEN
        CREATE TYPE document_category AS ENUM (
            'xray',
            'lab_report',
            'radiology_report',
            'other_clinical'
        );
    END IF;

    -- Pharmacy inventory audit movement types
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'movement_type') THEN
        CREATE TYPE movement_type AS ENUM (
            'stock_receipt',
            'dispensing',
            'adjustment',
            'expired',
            'damaged',
            'returned',
            'transfer'
        );
    END IF;

    -- Patient biological and demographic sex
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'sex_type') THEN
        CREATE TYPE sex_type AS ENUM (
            'male',
            'female',
            'other'
        );
    END IF;

    -- Clinical priority triage levels
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'priority_type') THEN
        CREATE TYPE priority_type AS ENUM (
            'routine',
            'urgent',
            'stat'
        );
    END IF;

    -- Clinical documentation note classification
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'note_type') THEN
        CREATE TYPE note_type AS ENUM (
            'clinical',
            'nursing',
            'amendment'
        );
    END IF;
END $$;

-- ============================================================================
-- SECTION 3: SEQUENCES FOR IDENTIFIER GENERATION
-- ============================================================================
-- Dedicated monotonic sequences ensuring high-throughput, collision-free human-readable IDs.
CREATE SEQUENCE IF NOT EXISTS seq_hospital_number START WITH 1;
CREATE SEQUENCE IF NOT EXISTS seq_encounter_number START WITH 1;
CREATE SEQUENCE IF NOT EXISTS seq_lab_order_number START WITH 1;
CREATE SEQUENCE IF NOT EXISTS seq_prescription_number START WITH 1;

-- ============================================================================
-- SECTION 4: BASE TRIGGER FUNCTIONS (updated_at)
-- ============================================================================
-- Generic timestamp management function applied across all mutable tables.
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- SECTION 5: TABLES AND SCHEMAS (STRICT DEPENDENCY ORDER)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 5.1 profiles: Staff accounts linked 1:1 with auth.users
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    role user_role NOT NULL,
    staff_id TEXT UNIQUE,
    department TEXT,
    phone TEXT,
    status account_status NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.profiles IS 'Staff metadata and RBAC roles linked to Supabase auth.users.';
COMMENT ON COLUMN public.profiles.id IS 'References the authenticated user in Supabase auth.';
COMMENT ON COLUMN public.profiles.role IS 'Strict role for medical workflow authorization.';

-- ----------------------------------------------------------------------------
-- 5.2 system_settings: Global application and licensing parameters
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.system_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key TEXT UNIQUE NOT NULL,
    value TEXT,
    description TEXT,
    updated_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.system_settings IS 'Hospital configuration limits and system parameters.';

-- ----------------------------------------------------------------------------
-- 5.3 patients: Master Patient Index (MPI)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hospital_number TEXT UNIQUE NOT NULL,
    first_name TEXT NOT NULL,
    middle_name TEXT,
    last_name TEXT NOT NULL,
    date_of_birth DATE NOT NULL,
    sex sex_type NOT NULL,
    phone TEXT NOT NULL,
    alt_phone TEXT,
    email TEXT,
    address TEXT,
    emergency_contact_name TEXT,
    emergency_contact_phone TEXT,
    emergency_contact_relationship TEXT,
    next_of_kin TEXT,
    admin_notes TEXT,
    registered_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.patients IS 'Master Patient Index records with demographic and contact information.';
COMMENT ON COLUMN public.patients.hospital_number IS 'Human readable patient ID in format LBC-YYYYNNNNN.';

-- ----------------------------------------------------------------------------
-- 5.4 patient_encounters: Outpatient/Inpatient/Emergency clinical visits
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patient_encounters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_number TEXT UNIQUE NOT NULL,
    chief_complaint TEXT,
    history_presenting TEXT,
    medical_history TEXT,
    current_medications TEXT,
    known_allergies TEXT,
    examination_findings TEXT,
    assessment TEXT,
    treatment_plan TEXT,
    follow_up TEXT,
    status encounter_status NOT NULL DEFAULT 'open',
    opened_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    closed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.patient_encounters IS 'Patient care episodes documenting clinical findings and plans.';

-- ----------------------------------------------------------------------------
-- 5.5 patient_vitals: Immutable physiological vital signs telemetry
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patient_vitals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    bp_systolic INTEGER,
    bp_diastolic INTEGER,
    pulse_rate INTEGER,
    respiratory_rate INTEGER,
    temperature NUMERIC(5,1),
    oxygen_saturation NUMERIC(5,1),
    weight NUMERIC(6,2),
    height NUMERIC(6,2),
    bmi NUMERIC(5,2),
    pain_score INTEGER CHECK (pain_score >= 0 AND pain_score <= 10),
    blood_glucose NUMERIC(6,1),
    recorded_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.patient_vitals IS 'Immutable vital signs measurements. Updates prohibited to preserve forensic trail.';

-- ----------------------------------------------------------------------------
-- 5.6 clinical_notes: Doctor and Nursing progress notes (with digital signing)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.clinical_notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    note_type note_type NOT NULL DEFAULT 'clinical',
    content TEXT NOT NULL,
    is_signed BOOLEAN NOT NULL DEFAULT false,
    signed_at TIMESTAMPTZ,
    signed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    original_note_id UUID REFERENCES public.clinical_notes(id) ON DELETE SET NULL,
    author UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.clinical_notes IS 'Clinical and nursing notes. Signed notes cannot be altered; amendments reference original_note_id.';

-- ----------------------------------------------------------------------------
-- 5.7 patient_diagnoses: Encounter and problem list diagnoses
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patient_diagnoses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    diagnosis_code TEXT,
    diagnosis_name TEXT NOT NULL,
    notes TEXT,
    recorded_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.patient_diagnoses IS 'Recorded diagnoses linked to encounters and patient history.';

-- ----------------------------------------------------------------------------
-- 5.8 patient_allergies: Adverse reactions and critical drug sensitivities
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patient_allergies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    allergen TEXT NOT NULL,
    reaction TEXT,
    severity TEXT,
    recorded_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.patient_allergies IS 'Known patient allergies and hypersensitivities.';

-- ----------------------------------------------------------------------------
-- 5.9 patient_documents: Metadata for medical files stored in Supabase Storage
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patient_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    category document_category NOT NULL,
    original_filename TEXT NOT NULL,
    storage_path TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    description TEXT,
    uploaded_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.patient_documents IS 'Metadata for clinical documents, scans, and laboratory reports.';

-- ----------------------------------------------------------------------------
-- 5.10 patient_file_transfers: Active chart handover between hospital departments
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patient_file_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    sender_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    recipient_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    sending_department TEXT,
    receiving_department TEXT,
    message TEXT,
    status transfer_status NOT NULL DEFAULT 'sent',
    acknowledged_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.patient_file_transfers IS 'Inter-departmental patient file handoffs governing clinical access boundaries.';

-- ----------------------------------------------------------------------------
-- 5.11 patient_file_transfer_history: Forensic append-only transfer log
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patient_file_transfer_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id UUID NOT NULL REFERENCES public.patient_file_transfers(id) ON DELETE CASCADE,
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    actor_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    previous_status transfer_status,
    new_status transfer_status,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.patient_file_transfer_history IS 'Forensic append-only audit trail of all patient file movements.';

-- ----------------------------------------------------------------------------
-- 5.12 notifications: Direct hospital messaging and task alerts
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    type TEXT NOT NULL,
    reference_type TEXT,
    reference_id UUID,
    is_read BOOLEAN NOT NULL DEFAULT false,
    read_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.notifications IS 'Staff alerts for incoming file transfers, critical lab results, and pharmacy orders.';

-- ----------------------------------------------------------------------------
-- 5.13 laboratory_orders: Clinical laboratory requisitions
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.laboratory_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    order_number TEXT UNIQUE NOT NULL,
    ordering_doctor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    assigned_technician_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    clinical_indication TEXT,
    priority priority_type NOT NULL DEFAULT 'routine',
    status lab_order_status NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.laboratory_orders IS 'Diagnostic laboratory test orders requested by physicians.';

-- ----------------------------------------------------------------------------
-- 5.14 laboratory_order_items: Individual tests requested within an order
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.laboratory_order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.laboratory_orders(id) ON DELETE CASCADE,
    test_name TEXT NOT NULL,
    test_code TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.laboratory_order_items IS 'Line items representing individual lab assays ordered.';

-- ----------------------------------------------------------------------------
-- 5.15 laboratory_results: Diagnostic test outcomes with amendment tracking
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.laboratory_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.laboratory_orders(id) ON DELETE CASCADE,
    order_item_id UUID REFERENCES public.laboratory_order_items(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    specimen_type TEXT,
    test_name TEXT NOT NULL,
    result_value TEXT,
    unit TEXT,
    reference_range TEXT,
    is_abnormal BOOLEAN,
    comments TEXT,
    status lab_result_status NOT NULL DEFAULT 'draft',
    original_result_id UUID REFERENCES public.laboratory_results(id) ON DELETE SET NULL,
    performed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    finalized_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    finalized_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.laboratory_results IS 'Diagnostic results. Finalized results require amendments to change.';

-- ----------------------------------------------------------------------------
-- 5.16 medicine_catalog: Master formulary and pricing catalog
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.medicine_catalog (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    medicine_name TEXT NOT NULL,
    generic_name TEXT,
    brand_name TEXT,
    strength TEXT,
    dosage_form TEXT NOT NULL,
    unit_of_measure TEXT NOT NULL,
    sku TEXT UNIQUE,
    barcode TEXT,
    purchase_price NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    selling_price NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    available_stock INTEGER NOT NULL DEFAULT 0 CHECK (available_stock >= 0),
    reorder_level INTEGER NOT NULL DEFAULT 10,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.medicine_catalog IS 'Pharmacy formulary, SKU catalog, and cumulative stock levels.';

-- ----------------------------------------------------------------------------
-- 5.17 medicine_batches: Expiry and lot tracking for pharmaceutical supplies
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.medicine_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    medicine_id UUID NOT NULL REFERENCES public.medicine_catalog(id) ON DELETE RESTRICT,
    batch_number TEXT NOT NULL,
    manufacture_date DATE,
    expiry_date DATE NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity >= 0),
    purchase_price NUMERIC(12,2),
    supplier_name TEXT,
    received_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.medicine_batches IS 'Inventory lots with batch numbers, expiration dates, and physical counts.';

-- ----------------------------------------------------------------------------
-- 5.18 prescriptions: Physician medication orders
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.prescriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    prescription_number TEXT UNIQUE NOT NULL,
    prescribing_doctor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    status prescription_status NOT NULL DEFAULT 'draft',
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.prescriptions IS 'Physician medical orders for pharmacy fulfillment.';

-- ----------------------------------------------------------------------------
-- 5.19 prescription_items: Formulated medication line items
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.prescription_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    prescription_id UUID NOT NULL REFERENCES public.prescriptions(id) ON DELETE CASCADE,
    medicine_id UUID REFERENCES public.medicine_catalog(id) ON DELETE RESTRICT,
    medicine_name TEXT NOT NULL,
    strength TEXT,
    dosage TEXT NOT NULL,
    route TEXT NOT NULL,
    frequency TEXT NOT NULL,
    duration TEXT,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    quantity_dispensed INTEGER NOT NULL DEFAULT 0 CHECK (quantity_dispensed >= 0),
    instructions TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.prescription_items IS 'Detailed drug dosage, route, quantity, and fulfillment tracking.';

-- ----------------------------------------------------------------------------
-- 5.20 dispensing_records: Pharmacy dispensing events
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dispensing_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    prescription_id UUID REFERENCES public.prescriptions(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    encounter_id UUID REFERENCES public.patient_encounters(id) ON DELETE SET NULL,
    pharmacist_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    status dispensing_status NOT NULL DEFAULT 'pending',
    notes TEXT,
    dispensed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.dispensing_records IS 'Record of pharmaceutical dispensing sessions.';

-- ----------------------------------------------------------------------------
-- 5.21 dispensing_items: Specific batches and quantities handed to patient
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dispensing_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dispensing_record_id UUID NOT NULL REFERENCES public.dispensing_records(id) ON DELETE CASCADE,
    prescription_item_id UUID REFERENCES public.prescription_items(id) ON DELETE SET NULL,
    medicine_id UUID NOT NULL REFERENCES public.medicine_catalog(id) ON DELETE RESTRICT,
    batch_id UUID REFERENCES public.medicine_batches(id) ON DELETE RESTRICT,
    quantity_dispensed INTEGER NOT NULL CHECK (quantity_dispensed > 0),
    substitution_reason TEXT,
    not_dispensed_reason TEXT,
    unit_selling_price NUMERIC(12,2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.dispensing_items IS 'Line items of dispensed medications including lot attribution.';

-- ----------------------------------------------------------------------------
-- 5.22 inventory_movements: Immutable ledger of stock inflows and outflows
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    medicine_id UUID NOT NULL REFERENCES public.medicine_catalog(id) ON DELETE RESTRICT,
    batch_id UUID REFERENCES public.medicine_batches(id) ON DELETE SET NULL,
    movement_type movement_type NOT NULL,
    quantity INTEGER NOT NULL,
    previous_stock INTEGER NOT NULL,
    resulting_stock INTEGER NOT NULL,
    unit_purchase_cost NUMERIC(12,2),
    reference_id UUID,
    reason TEXT,
    performed_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.inventory_movements IS 'Immutable accounting journal for all stock movements and deductions.';

-- ----------------------------------------------------------------------------
-- 5.23 audit_logs: Comprehensive medical audit trail for compliance
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    table_name TEXT,
    record_id UUID,
    old_data JSONB,
    new_data JSONB,
    ip_address TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.audit_logs IS 'System-wide compliance audit log tracking data modifications.';

-- ============================================================================
-- SECTION 6: COMPREHENSIVE PERFORMANCE AND FOREIGN KEY INDEXES
-- ============================================================================
-- Indexes on all foreign keys, status columns, and search criteria to prevent sequential scans.

CREATE INDEX IF NOT EXISTS idx_profiles_role ON public.profiles(role);
CREATE INDEX IF NOT EXISTS idx_profiles_status ON public.profiles(status);
CREATE INDEX IF NOT EXISTS idx_profiles_staff_id ON public.profiles(staff_id);

CREATE INDEX IF NOT EXISTS idx_patients_hospital_number ON public.patients(hospital_number);
CREATE INDEX IF NOT EXISTS idx_patients_phone ON public.patients(phone);
CREATE INDEX IF NOT EXISTS idx_patients_last_name ON public.patients(last_name);
CREATE INDEX IF NOT EXISTS idx_patients_registered_by ON public.patients(registered_by);

CREATE INDEX IF NOT EXISTS idx_encounters_patient_id ON public.patient_encounters(patient_id);
CREATE INDEX IF NOT EXISTS idx_encounters_status ON public.patient_encounters(status);
CREATE INDEX IF NOT EXISTS idx_encounters_opened_by ON public.patient_encounters(opened_by);

CREATE INDEX IF NOT EXISTS idx_vitals_patient_id ON public.patient_vitals(patient_id);
CREATE INDEX IF NOT EXISTS idx_vitals_encounter_id ON public.patient_vitals(encounter_id);
CREATE INDEX IF NOT EXISTS idx_vitals_recorded_by ON public.patient_vitals(recorded_by);
CREATE INDEX IF NOT EXISTS idx_vitals_created_at ON public.patient_vitals(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notes_patient_id ON public.clinical_notes(patient_id);
CREATE INDEX IF NOT EXISTS idx_notes_encounter_id ON public.clinical_notes(encounter_id);
CREATE INDEX IF NOT EXISTS idx_notes_author ON public.clinical_notes(author);
CREATE INDEX IF NOT EXISTS idx_notes_original_note_id ON public.clinical_notes(original_note_id);

CREATE INDEX IF NOT EXISTS idx_diagnoses_patient_id ON public.patient_diagnoses(patient_id);
CREATE INDEX IF NOT EXISTS idx_diagnoses_encounter_id ON public.patient_diagnoses(encounter_id);

CREATE INDEX IF NOT EXISTS idx_allergies_patient_id ON public.patient_allergies(patient_id);

CREATE INDEX IF NOT EXISTS idx_documents_patient_id ON public.patient_documents(patient_id);
CREATE INDEX IF NOT EXISTS idx_documents_encounter_id ON public.patient_documents(encounter_id);
CREATE INDEX IF NOT EXISTS idx_documents_category ON public.patient_documents(category);

CREATE INDEX IF NOT EXISTS idx_transfers_patient_id ON public.patient_file_transfers(patient_id);
CREATE INDEX IF NOT EXISTS idx_transfers_sender_id ON public.patient_file_transfers(sender_id);
CREATE INDEX IF NOT EXISTS idx_transfers_recipient_id ON public.patient_file_transfers(recipient_id);
CREATE INDEX IF NOT EXISTS idx_transfers_status ON public.patient_file_transfers(status);

CREATE INDEX IF NOT EXISTS idx_transfer_hist_transfer_id ON public.patient_file_transfer_history(transfer_id);
CREATE INDEX IF NOT EXISTS idx_transfer_hist_patient_id ON public.patient_file_transfer_history(patient_id);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient ON public.notifications(recipient_id, is_read);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON public.notifications(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_lab_orders_patient_id ON public.laboratory_orders(patient_id);
CREATE INDEX IF NOT EXISTS idx_lab_orders_doctor ON public.laboratory_orders(ordering_doctor_id);
CREATE INDEX IF NOT EXISTS idx_lab_orders_tech ON public.laboratory_orders(assigned_technician_id);
CREATE INDEX IF NOT EXISTS idx_lab_orders_status ON public.laboratory_orders(status);

CREATE INDEX IF NOT EXISTS idx_lab_order_items_order_id ON public.laboratory_order_items(order_id);

CREATE INDEX IF NOT EXISTS idx_lab_results_order_id ON public.laboratory_results(order_id);
CREATE INDEX IF NOT EXISTS idx_lab_results_patient_id ON public.laboratory_results(patient_id);
CREATE INDEX IF NOT EXISTS idx_lab_results_status ON public.laboratory_results(status);

CREATE INDEX IF NOT EXISTS idx_med_catalog_sku ON public.medicine_catalog(sku);
CREATE INDEX IF NOT EXISTS idx_med_catalog_barcode ON public.medicine_catalog(barcode);
CREATE INDEX IF NOT EXISTS idx_med_catalog_active ON public.medicine_catalog(is_active);
CREATE INDEX IF NOT EXISTS idx_med_catalog_name ON public.medicine_catalog(medicine_name);

CREATE INDEX IF NOT EXISTS idx_med_batches_med_id ON public.medicine_batches(medicine_id);
CREATE INDEX IF NOT EXISTS idx_med_batches_expiry ON public.medicine_batches(expiry_date);
CREATE INDEX IF NOT EXISTS idx_med_batches_number ON public.medicine_batches(batch_number);

CREATE INDEX IF NOT EXISTS idx_prescriptions_patient_id ON public.prescriptions(patient_id);
CREATE INDEX IF NOT EXISTS idx_prescriptions_doctor ON public.prescriptions(prescribing_doctor_id);
CREATE INDEX IF NOT EXISTS idx_prescriptions_status ON public.prescriptions(status);

CREATE INDEX IF NOT EXISTS idx_prescription_items_rx_id ON public.prescription_items(prescription_id);
CREATE INDEX IF NOT EXISTS idx_prescription_items_med_id ON public.prescription_items(medicine_id);

CREATE INDEX IF NOT EXISTS idx_dispensing_rx_id ON public.dispensing_records(prescription_id);
CREATE INDEX IF NOT EXISTS idx_dispensing_patient_id ON public.dispensing_records(patient_id);
CREATE INDEX IF NOT EXISTS idx_dispensing_pharmacist ON public.dispensing_records(pharmacist_id);

CREATE INDEX IF NOT EXISTS idx_dispensing_items_record ON public.dispensing_items(dispensing_record_id);
CREATE INDEX IF NOT EXISTS idx_dispensing_items_batch ON public.dispensing_items(batch_id);

CREATE INDEX IF NOT EXISTS idx_movements_medicine ON public.inventory_movements(medicine_id);
CREATE INDEX IF NOT EXISTS idx_movements_batch ON public.inventory_movements(batch_id);
CREATE INDEX IF NOT EXISTS idx_movements_type ON public.inventory_movements(movement_type);

CREATE INDEX IF NOT EXISTS idx_audit_logs_actor ON public.audit_logs(actor_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_table_rec ON public.audit_logs(table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON public.audit_logs(created_at DESC);

-- ============================================================================
-- SECTION 7: UPDATED_AT TIMESTAMP TRIGGERS
-- ============================================================================
-- Attach auto-update triggers to all entities with an updated_at column.

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_system_settings_updated_at ON public.system_settings;
CREATE TRIGGER trg_system_settings_updated_at
    BEFORE UPDATE ON public.system_settings
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_patients_updated_at ON public.patients;
CREATE TRIGGER trg_patients_updated_at
    BEFORE UPDATE ON public.patients
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_patient_encounters_updated_at ON public.patient_encounters;
CREATE TRIGGER trg_patient_encounters_updated_at
    BEFORE UPDATE ON public.patient_encounters
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_clinical_notes_updated_at ON public.clinical_notes;
CREATE TRIGGER trg_clinical_notes_updated_at
    BEFORE UPDATE ON public.clinical_notes
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_transfers_updated_at ON public.patient_file_transfers;
CREATE TRIGGER trg_transfers_updated_at
    BEFORE UPDATE ON public.patient_file_transfers
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_lab_orders_updated_at ON public.laboratory_orders;
CREATE TRIGGER trg_lab_orders_updated_at
    BEFORE UPDATE ON public.laboratory_orders
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_lab_results_updated_at ON public.laboratory_results;
CREATE TRIGGER trg_lab_results_updated_at
    BEFORE UPDATE ON public.laboratory_results
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_prescriptions_updated_at ON public.prescriptions;
CREATE TRIGGER trg_prescriptions_updated_at
    BEFORE UPDATE ON public.prescriptions
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_medicine_catalog_updated_at ON public.medicine_catalog;
CREATE TRIGGER trg_medicine_catalog_updated_at
    BEFORE UPDATE ON public.medicine_catalog
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_dispensing_records_updated_at ON public.dispensing_records;
CREATE TRIGGER trg_dispensing_records_updated_at
    BEFORE UPDATE ON public.dispensing_records
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================================
-- SECTION 8: IDENTIFIER AUTO-GENERATION TRIGGERS
-- ============================================================================

-- 8.1 Hospital Number Generator: LBC-YYYYNNNNN
CREATE OR REPLACE FUNCTION public.generate_hospital_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.hospital_number IS NULL OR trim(NEW.hospital_number) = '' THEN
        NEW.hospital_number := 'LBC-' || to_char(CURRENT_DATE, 'YYYY') || lpad(nextval('seq_hospital_number')::TEXT, 5, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_generate_hospital_number ON public.patients;
CREATE TRIGGER trg_generate_hospital_number
    BEFORE INSERT ON public.patients
    FOR EACH ROW
    EXECUTE FUNCTION public.generate_hospital_number();

-- 8.2 Encounter Number Generator: ENC-YYYYNNNNN
CREATE OR REPLACE FUNCTION public.generate_encounter_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.encounter_number IS NULL OR trim(NEW.encounter_number) = '' THEN
        NEW.encounter_number := 'ENC-' || to_char(CURRENT_DATE, 'YYYY') || lpad(nextval('seq_encounter_number')::TEXT, 5, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_generate_encounter_number ON public.patient_encounters;
CREATE TRIGGER trg_generate_encounter_number
    BEFORE INSERT ON public.patient_encounters
    FOR EACH ROW
    EXECUTE FUNCTION public.generate_encounter_number();

-- 8.3 Laboratory Order Number Generator: LAB-YYYYNNNNN
CREATE OR REPLACE FUNCTION public.generate_lab_order_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.order_number IS NULL OR trim(NEW.order_number) = '' THEN
        NEW.order_number := 'LAB-' || to_char(CURRENT_DATE, 'YYYY') || lpad(nextval('seq_lab_order_number')::TEXT, 5, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_generate_lab_order_number ON public.laboratory_orders;
CREATE TRIGGER trg_generate_lab_order_number
    BEFORE INSERT ON public.laboratory_orders
    FOR EACH ROW
    EXECUTE FUNCTION public.generate_lab_order_number();

-- 8.4 Prescription Number Generator: RX-YYYYNNNNN
CREATE OR REPLACE FUNCTION public.generate_prescription_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.prescription_number IS NULL OR trim(NEW.prescription_number) = '' THEN
        NEW.prescription_number := 'RX-' || to_char(CURRENT_DATE, 'YYYY') || lpad(nextval('seq_prescription_number')::TEXT, 5, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_generate_prescription_number ON public.prescriptions;
CREATE TRIGGER trg_generate_prescription_number
    BEFORE INSERT ON public.prescriptions
    FOR EACH ROW
    EXECUTE FUNCTION public.generate_prescription_number();

-- ============================================================================
-- SECTION 9: CLINICAL & BUSINESS LOGIC TRIGGERS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 9.1 BMI Calculation Trigger on patient_vitals
-- ----------------------------------------------------------------------------
-- Automatically computes BMI = weight (kg) / [height (m)]^2.
-- Handles height input in both centimeters (e.g. 175) and meters (e.g. 1.75).
CREATE OR REPLACE FUNCTION public.calculate_patient_bmi()
RETURNS TRIGGER AS $$
DECLARE
    v_height_m NUMERIC;
BEGIN
    IF NEW.weight IS NOT NULL AND NEW.height IS NOT NULL AND NEW.weight > 0 AND NEW.height > 0 THEN
        -- If height is entered in cm (height > 3.0), convert to meters
        IF NEW.height > 3.0 THEN
            v_height_m := NEW.height / 100.0;
        ELSE
            v_height_m := NEW.height;
        END IF;

        IF v_height_m > 0 THEN
            NEW.bmi := round((NEW.weight / (v_height_m * v_height_m))::numeric, 2);
        ELSE
            NEW.bmi := NULL;
        END IF;
    ELSE
        NEW.bmi := NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_calculate_patient_bmi ON public.patient_vitals;
CREATE TRIGGER trg_calculate_patient_bmi
    BEFORE INSERT OR UPDATE OF weight, height ON public.patient_vitals
    FOR EACH ROW
    EXECUTE FUNCTION public.calculate_patient_bmi();

-- ----------------------------------------------------------------------------
-- 9.2 Clinical Note Immutability & Signature Trigger
-- ----------------------------------------------------------------------------
-- Enforces that once a note is signed, its clinical content is permanently immutable.
-- Subsequent changes require creating an amendment note referencing original_note_id.
CREATE OR REPLACE FUNCTION public.enforce_clinical_note_immutability()
RETURNS TRIGGER AS $$
BEGIN
    -- Block modifications if note was already signed
    IF OLD.is_signed = true THEN
        RAISE EXCEPTION 'Legally signed clinical notes are immutable. Please create an amendment note referencing note ID: %', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;

    -- If note is being signed in this update, record the timestamp and signing user
    IF NEW.is_signed = true AND OLD.is_signed = false THEN
        NEW.signed_at := COALESCE(NEW.signed_at, now());
        NEW.signed_by := COALESCE(NEW.signed_by, auth.uid());
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth;

DROP TRIGGER IF EXISTS trg_enforce_clinical_note_immutability ON public.clinical_notes;
CREATE TRIGGER trg_enforce_clinical_note_immutability
    BEFORE UPDATE ON public.clinical_notes
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_clinical_note_immutability();

-- ----------------------------------------------------------------------------
-- 9.3 Laboratory Results Finalization Trigger
-- ----------------------------------------------------------------------------
-- Prevents alteration of finalized diagnostic test results.
CREATE OR REPLACE FUNCTION public.enforce_lab_result_finalization()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status = 'finalized'::lab_result_status AND NEW.status != 'amended'::lab_result_status THEN
        RAISE EXCEPTION 'Finalized laboratory results cannot be modified. Issue an amended result record instead.'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.status = 'finalized'::lab_result_status AND OLD.status != 'finalized'::lab_result_status THEN
        NEW.finalized_at := COALESCE(NEW.finalized_at, now());
        NEW.finalized_by := COALESCE(NEW.finalized_by, auth.uid());
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth;

DROP TRIGGER IF EXISTS trg_enforce_lab_result_finalization ON public.laboratory_results;
CREATE TRIGGER trg_enforce_lab_result_finalization
    BEFORE UPDATE ON public.laboratory_results
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_lab_result_finalization();

-- ----------------------------------------------------------------------------
-- 9.4 Transfer Workflow Timestamps & Forensic History Logging
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_transfer_workflow_events()
RETURNS TRIGGER AS $$
BEGIN
    -- Timestamp acknowledgments and completions
    IF TG_OP = 'UPDATE' THEN
        IF NEW.status = 'received'::transfer_status AND (OLD.status IS DISTINCT FROM 'received'::transfer_status) THEN
            NEW.acknowledged_at := COALESCE(NEW.acknowledged_at, now());
        END IF;

        IF NEW.status = 'completed'::transfer_status AND (OLD.status IS DISTINCT FROM 'completed'::transfer_status) THEN
            NEW.completed_at := COALESCE(NEW.completed_at, now());
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_handle_transfer_workflow_events ON public.patient_file_transfers;
CREATE TRIGGER trg_handle_transfer_workflow_events
    BEFORE INSERT OR UPDATE ON public.patient_file_transfers
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_transfer_workflow_events();

-- Append-only transfer history logger
CREATE OR REPLACE FUNCTION public.log_transfer_history()
RETURNS TRIGGER AS $$
DECLARE
    v_actor UUID;
BEGIN
    v_actor := auth.uid();

    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.patient_file_transfer_history (
            transfer_id, patient_id, encounter_id, actor_id,
            action, previous_status, new_status, notes
        ) VALUES (
            NEW.id, NEW.patient_id, NEW.encounter_id, COALESCE(v_actor, NEW.sender_id),
            'transfer_created', NULL, NEW.status, NEW.message
        );
    ELSIF TG_OP = 'UPDATE' AND (OLD.status IS DISTINCT FROM NEW.status) THEN
        INSERT INTO public.patient_file_transfer_history (
            transfer_id, patient_id, encounter_id, actor_id,
            action, previous_status, new_status, notes
        ) VALUES (
            NEW.id, NEW.patient_id, NEW.encounter_id, COALESCE(v_actor, NEW.recipient_id),
            'status_transition', OLD.status, NEW.status, NEW.message
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth;

DROP TRIGGER IF EXISTS trg_log_transfer_history ON public.patient_file_transfers;
CREATE TRIGGER trg_log_transfer_history
    AFTER INSERT OR UPDATE OF status ON public.patient_file_transfers
    FOR EACH ROW
    EXECUTE FUNCTION public.log_transfer_history();

-- ----------------------------------------------------------------------------
-- 9.5 Dispensing Record Completion Timestamp
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_dispensing_completion()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'completed'::dispensing_status AND (OLD.status IS DISTINCT FROM 'completed'::dispensing_status) THEN
        NEW.dispensed_at := COALESCE(NEW.dispensed_at, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_handle_dispensing_completion ON public.dispensing_records;
CREATE TRIGGER trg_handle_dispensing_completion
    BEFORE UPDATE ON public.dispensing_records
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_dispensing_completion();

-- ============================================================================
-- SECTION 10: SECURE HELPER FUNCTIONS (SECURITY DEFINER)
-- ============================================================================
-- Security Decisions:
-- 1. All functions run with SECURITY DEFINER to inspect profiles and active transfers
--    without hitting recursive RLS loops.
-- 2. search_path is strictly pinned to 'public, auth' to prevent malicious schema hijacking.
-- 3. Functions are marked STABLE to allow PostgreSQL query optimizer caching.

-- 10.1 Returns the role of the authenticated caller
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS user_role
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_role user_role;
BEGIN
    SELECT role INTO v_role
    FROM public.profiles
    WHERE id = auth.uid();
    RETURN v_role;
END;
$$;

-- 10.2 Returns the account status of the authenticated caller
CREATE OR REPLACE FUNCTION public.get_my_status()
RETURNS account_status
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_status account_status;
BEGIN
    SELECT status INTO v_status
    FROM public.profiles
    WHERE id = auth.uid();
    RETURN v_status;
END;
$$;

-- 10.3 Returns true if caller is an active system administrator
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE id = auth.uid()
          AND role = 'admin'::user_role
          AND status = 'active'::account_status
    );
END;
$$;

-- 10.4 Returns true if caller is any active staff member
CREATE OR REPLACE FUNCTION public.is_active_user()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE id = auth.uid()
          AND status = 'active'::account_status
    );
END;
$$;

-- 10.5 Returns the caller's profile UUID
CREATE OR REPLACE FUNCTION public.get_profile_id()
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_id UUID;
BEGIN
    SELECT id INTO v_id
    FROM public.profiles
    WHERE id = auth.uid()
      AND status = 'active'::account_status;
    RETURN v_id;
END;
$$;

-- 10.6 Checks if caller has a clinical transfer, encounter, or registration relationship with a patient
CREATE OR REPLACE FUNCTION public.can_access_patient(patient_uuid UUID)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_user_id UUID;
    v_role user_role;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN false;
    END IF;

    -- Administrators have global access
    IF public.is_admin() THEN
        RETURN true;
    END IF;

    -- Must be an active staff member
    IF NOT public.is_active_user() THEN
        RETURN false;
    END IF;

    SELECT role INTO v_role FROM public.profiles WHERE id = v_user_id;

    -- Check if user is recipient or sender of a transfer for this patient
    IF EXISTS (
        SELECT 1 FROM public.patient_file_transfers
        WHERE patient_id = patient_uuid
          AND (recipient_id = v_user_id OR sender_id = v_user_id)
          AND status IN ('sent', 'received', 'in_progress', 'awaiting_results', 'awaiting_pharmacy', 'completed')
    ) THEN
        RETURN true;
    END IF;

    -- Check if user opened or is managing an encounter for this patient
    IF EXISTS (
        SELECT 1 FROM public.patient_encounters
        WHERE patient_id = patient_uuid
          AND (opened_by = v_user_id OR closed_by = v_user_id)
    ) THEN
        RETURN true;
    END IF;

    -- Front desk registration relationship
    IF v_role = 'front_desk'::user_role THEN
        IF EXISTS (
            SELECT 1 FROM public.patients
            WHERE id = patient_uuid AND registered_by = v_user_id
        ) THEN
            RETURN true;
        END IF;
    END IF;

    RETURN false;
END;
$$;

-- 10.7 Returns true if caller is the active recipient of a transfer
CREATE OR REPLACE FUNCTION public.is_transfer_recipient(transfer_uuid UUID)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM public.patient_file_transfers
        WHERE id = transfer_uuid
          AND recipient_id = auth.uid()
          AND public.is_active_user()
    );
END;
$$;

-- 10.8 Returns true if caller is the sender of a transfer
CREATE OR REPLACE FUNCTION public.is_transfer_sender(transfer_uuid UUID)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM public.patient_file_transfers
        WHERE id = transfer_uuid
          AND sender_id = auth.uid()
          AND public.is_active_user()
    );
END;
$$;

-- ============================================================================
-- SECTION 11: STAFF ACCOUNT LIMIT ENFORCEMENT
-- ============================================================================
-- Security & Licensing Policy:
-- Each clinical role (doctor, nurse, pharmacist, front_desk, lab_technician)
-- is strictly limited to 10 active accounts (or the limit defined in system_settings).
-- The admin role is unconstrained.

CREATE OR REPLACE FUNCTION public.check_staff_limit(target_role user_role)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_count INTEGER;
    v_limit INTEGER := 10;
    v_setting_key TEXT;
    v_setting_val TEXT;
BEGIN
    -- Admin role is unlimited
    IF target_role = 'admin'::user_role THEN
        RETURN true;
    END IF;

    -- Map role to system_settings key
    CASE target_role
        WHEN 'doctor' THEN v_setting_key := 'max_doctors';
        WHEN 'nurse' THEN v_setting_key := 'max_nurses';
        WHEN 'pharmacist' THEN v_setting_key := 'max_pharmacists';
        WHEN 'front_desk' THEN v_setting_key := 'max_front_desk';
        WHEN 'lab_technician' THEN v_setting_key := 'max_lab_technicians';
        ELSE v_setting_key := NULL;
    END CASE;

    IF v_setting_key IS NOT NULL THEN
        SELECT value INTO v_setting_val
        FROM public.system_settings
        WHERE key = v_setting_key;

        IF v_setting_val IS NOT NULL AND v_setting_val ~ '^\d+$' THEN
            v_limit := v_setting_val::INTEGER;
        END IF;
    END IF;

    -- Count active profiles currently possessing this role
    SELECT count(*) INTO v_count
    FROM public.profiles
    WHERE role = target_role
      AND status = 'active'::account_status;

    RETURN v_count < v_limit;
END;
$$;

-- Enforce limit before profile insertion or role/status reactivation
CREATE OR REPLACE FUNCTION public.trg_enforce_staff_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
    IF NEW.role != 'admin'::user_role AND NEW.status = 'active'::account_status THEN
        -- If updating an already-active user with unchanged role, bypass count check
        IF TG_OP = 'UPDATE' AND OLD.status = 'active'::account_status AND OLD.role = NEW.role THEN
            RETURN NEW;
        END IF;

        IF NOT public.check_staff_limit(NEW.role) THEN
            RAISE EXCEPTION 'Staff limit reached for role: %. Maximum allowed active accounts reached.', NEW.role
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS before_insert_profile ON public.profiles;
CREATE TRIGGER before_insert_profile
    BEFORE INSERT OR UPDATE OF role, status ON public.profiles
    FOR EACH ROW
    WHEN (NEW.status = 'active')
    EXECUTE FUNCTION public.trg_enforce_staff_limit();

-- Protection of sensitive profile fields by non-administrators
CREATE OR REPLACE FUNCTION public.protect_profile_sensitive_fields()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT public.is_admin() THEN
        IF NEW.role IS DISTINCT FROM OLD.role THEN
            RAISE EXCEPTION 'Only administrators can modify account roles.'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'Only administrators can modify account statuses.'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF NEW.staff_id IS DISTINCT FROM OLD.staff_id THEN
            RAISE EXCEPTION 'Only administrators can modify staff IDs.'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
        IF NEW.id IS DISTINCT FROM OLD.id THEN
            RAISE EXCEPTION 'Account user ID is immutable.'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth;

DROP TRIGGER IF EXISTS trg_protect_profile_sensitive_fields ON public.profiles;
CREATE TRIGGER trg_protect_profile_sensitive_fields
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_profile_sensitive_fields();

-- ============================================================================
-- SECTION 12: ATOMIC INVENTORY STOCK DEDUCTION TRANSACTION
-- ============================================================================
-- Security Decisions:
-- 1. Atomic transaction guarantees zero inventory drift under concurrent dispensing.
-- 2. Uses SELECT ... FOR UPDATE to lock both the medicine catalog row and the specific batch.
-- 3. Verifies stock availability at both catalog and lot levels before performing deductions.
-- 4. Automatically appends a movement log to inventory_movements within the same transaction.
-- 5. Accessible only by authenticated pharmacists or administrators.

CREATE OR REPLACE FUNCTION public.deduct_stock(
    p_medicine_id UUID,
    p_batch_id UUID,
    p_quantity INTEGER,
    p_dispensing_record_id UUID,
    p_performed_by UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_current_catalog_stock INTEGER;
    v_new_catalog_stock INTEGER;
    v_current_batch_stock INTEGER;
    v_new_batch_stock INTEGER;
    v_unit_cost NUMERIC(12,2);
    v_actor UUID;
BEGIN
    -- 1. Role validation
    IF NOT (public.is_admin() OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)) THEN
        RAISE EXCEPTION 'Unauthorized: Only active pharmacists or administrators may perform stock deductions.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- 2. Input validation
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Stock deduction quantity must be strictly greater than zero. Received: %', p_quantity
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_medicine_id IS NULL THEN
        RAISE EXCEPTION 'Medicine ID cannot be NULL.'
            USING ERRCODE = 'not_null_violation';
    END IF;

    v_actor := COALESCE(p_performed_by, auth.uid());

    -- 3. Lock medicine_catalog row to serialize concurrent deductions
    SELECT available_stock, purchase_price
    INTO v_current_catalog_stock, v_unit_cost
    FROM public.medicine_catalog
    WHERE id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine item with ID % not found in catalog.', p_medicine_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_current_catalog_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock in catalog for medicine %. Available: %, Requested: %',
            p_medicine_id, v_current_catalog_stock, p_quantity
            USING ERRCODE = 'check_violation';
    END IF;

    v_new_catalog_stock := v_current_catalog_stock - p_quantity;

    -- 4. If batch is specified, lock batch row and check batch stock
    IF p_batch_id IS NOT NULL THEN
        SELECT quantity, purchase_price
        INTO v_current_batch_stock, v_unit_cost
        FROM public.medicine_batches
        WHERE id = p_batch_id AND medicine_id = p_medicine_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Batch % not found for medicine %.', p_batch_id, p_medicine_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF v_current_batch_stock < p_quantity THEN
            RAISE EXCEPTION 'Insufficient stock in batch %. Available: %, Requested: %',
                p_batch_id, v_current_batch_stock, p_quantity
                USING ERRCODE = 'check_violation';
        END IF;

        v_new_batch_stock := v_current_batch_stock - p_quantity;

        -- Deduct from batch
        UPDATE public.medicine_batches
        SET quantity = v_new_batch_stock
        WHERE id = p_batch_id;
    END IF;

    -- 5. Deduct from medicine_catalog
    UPDATE public.medicine_catalog
    SET available_stock = v_new_catalog_stock,
        updated_at = now()
    WHERE id = p_medicine_id;

    -- 6. Insert audit record in inventory_movements
    INSERT INTO public.inventory_movements (
        medicine_id,
        batch_id,
        movement_type,
        quantity,
        previous_stock,
        resulting_stock,
        unit_purchase_cost,
        reference_id,
        reason,
        performed_by
    ) VALUES (
        p_medicine_id,
        p_batch_id,
        'dispensing'::movement_type,
        -p_quantity,
        v_current_catalog_stock,
        v_new_catalog_stock,
        v_unit_cost,
        p_dispensing_record_id,
        'Prescription dispensing deduction for record ' || COALESCE(p_dispensing_record_id::TEXT, 'N/A'),
        v_actor
    );

    RETURN true;
END;
$$;

-- ============================================================================
-- SECTION 13: AUDIT LOGGING HELPER FUNCTION
-- ============================================================================
-- Provides a secure interface for active administrators to record events.
CREATE OR REPLACE FUNCTION public.log_audit_event(
    p_action TEXT,
    p_table_name TEXT,
    p_record_id UUID,
    p_old_data JSONB DEFAULT NULL,
    p_new_data JSONB DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_log_id UUID;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Only active administrators may write audit events.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    INSERT INTO public.audit_logs (
        actor_id,
        action,
        table_name,
        record_id,
        old_data,
        new_data,
        ip_address
    ) VALUES (
        auth.uid(),
        p_action,
        p_table_name,
        p_record_id,
        p_old_data,
        p_new_data,
        p_ip_address
    ) RETURNING id INTO v_log_id;

    RETURN v_log_id;
END;
$$;

-- ============================================================================
-- SECTION 14: ENABLE ROW LEVEL SECURITY (ALL TABLES)
-- ============================================================================
-- Zero-trust security model: RLS is unconditionally enabled across all 23 tables.

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_encounters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_vitals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinical_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_diagnoses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_allergies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_file_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_file_transfer_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.laboratory_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.laboratory_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.laboratory_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medicine_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medicine_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prescriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prescription_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispensing_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispensing_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- SECTION 15: ROW LEVEL SECURITY POLICIES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 15.1 profiles
-- ----------------------------------------------------------------------------
-- SELECT: Users see their own profile; admins see all; active staff see other active staff (for transfers/dropdowns).
DROP POLICY IF EXISTS "profiles_select_policy" ON public.profiles;
CREATE POLICY "profiles_select_policy" ON public.profiles
    FOR SELECT TO authenticated
    USING (
        id = auth.uid()
        OR public.is_admin()
        OR (public.is_active_user() AND status = 'active'::account_status)
    );

-- INSERT: Only admins can provision accounts directly; otherwise Edge Functions run with service_role.
DROP POLICY IF EXISTS "profiles_insert_policy" ON public.profiles;
CREATE POLICY "profiles_insert_policy" ON public.profiles
    FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());

-- UPDATE: Users can update their own non-role fields; admins can update any profile.
DROP POLICY IF EXISTS "profiles_update_policy" ON public.profiles;
CREATE POLICY "profiles_update_policy" ON public.profiles
    FOR UPDATE TO authenticated
    USING (id = auth.uid() OR public.is_admin())
    WITH CHECK (id = auth.uid() OR public.is_admin());

-- DELETE: Admins only (deactivation via UPDATE status preferred).
DROP POLICY IF EXISTS "profiles_delete_policy" ON public.profiles;
CREATE POLICY "profiles_delete_policy" ON public.profiles
    FOR DELETE TO authenticated
    USING (public.is_admin());

-- ----------------------------------------------------------------------------
-- 15.2 system_settings
-- ----------------------------------------------------------------------------
-- Full management restricted to administrators.
DROP POLICY IF EXISTS "system_settings_select_policy" ON public.system_settings;
CREATE POLICY "system_settings_select_policy" ON public.system_settings
    FOR SELECT TO authenticated
    USING (public.is_admin());

DROP POLICY IF EXISTS "system_settings_admin_all" ON public.system_settings;
CREATE POLICY "system_settings_admin_all" ON public.system_settings
    FOR ALL TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());

-- ----------------------------------------------------------------------------
-- 15.3 patients
-- ----------------------------------------------------------------------------
-- SELECT: Active staff with an active transfer, encounter, or registration for the patient, or admin.
DROP POLICY IF EXISTS "patients_select_policy" ON public.patients;
CREATE POLICY "patients_select_policy" ON public.patients
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_user() AND public.can_access_patient(id))
    );

-- INSERT: Active front_desk or admin.
DROP POLICY IF EXISTS "patients_insert_policy" ON public.patients;
CREATE POLICY "patients_insert_policy" ON public.patients
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'front_desk'::user_role)
    );

-- UPDATE: Active front_desk or admin for demographics management.
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
-- 15.4 patient_encounters
-- ----------------------------------------------------------------------------
-- SELECT: Doctor, nurse, lab technician, pharmacist with transfer access; front_desk who created or registered.
DROP POLICY IF EXISTS "encounters_select_policy" ON public.patient_encounters;
CREATE POLICY "encounters_select_policy" ON public.patient_encounters
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND (public.can_access_patient(patient_id) OR opened_by = auth.uid())
        )
    );

-- INSERT: Front desk opens encounters; doctors can also initiate clinical consultations.
DROP POLICY IF EXISTS "encounters_insert_policy" ON public.patient_encounters;
CREATE POLICY "encounters_insert_policy" ON public.patient_encounters
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('front_desk'::user_role, 'doctor'::user_role)
        )
    );

-- UPDATE: Doctors update clinical assessments; front desk updates operational data.
DROP POLICY IF EXISTS "encounters_update_policy" ON public.patient_encounters;
CREATE POLICY "encounters_update_policy" ON public.patient_encounters
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('doctor'::user_role, 'front_desk'::user_role)
            AND (public.can_access_patient(patient_id) OR opened_by = auth.uid())
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('doctor'::user_role, 'front_desk'::user_role)
        )
    );

-- ----------------------------------------------------------------------------
-- 15.5 patient_vitals
-- ----------------------------------------------------------------------------
-- SELECT: Doctors and nurses with active transfer access.
DROP POLICY IF EXISTS "vitals_select_policy" ON public.patient_vitals;
CREATE POLICY "vitals_select_policy" ON public.patient_vitals
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('doctor'::user_role, 'nurse'::user_role)
            AND public.can_access_patient(patient_id)
        )
    );

-- INSERT: Active nurses (and doctors/admins).
DROP POLICY IF EXISTS "vitals_insert_policy" ON public.patient_vitals;
CREATE POLICY "vitals_insert_policy" ON public.patient_vitals
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('nurse'::user_role, 'doctor'::user_role)
            AND public.can_access_patient(patient_id)
        )
    );

-- UPDATE / DELETE: Prohibited. Vitals are immutable clinical measurements.

-- ----------------------------------------------------------------------------
-- 15.6 clinical_notes
-- ----------------------------------------------------------------------------
-- SELECT: Doctors and nurses with transfer access to patient.
DROP POLICY IF EXISTS "notes_select_policy" ON public.clinical_notes;
CREATE POLICY "notes_select_policy" ON public.clinical_notes
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('doctor'::user_role, 'nurse'::user_role)
            AND public.can_access_patient(patient_id)
        )
    );

-- INSERT: Doctors (clinical notes/amendments); Nurses (nursing notes).
DROP POLICY IF EXISTS "notes_insert_policy" ON public.clinical_notes;
CREATE POLICY "notes_insert_policy" ON public.clinical_notes
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.can_access_patient(patient_id)
            AND author = auth.uid()
            AND (
                (public.get_my_role() = 'doctor'::user_role AND note_type IN ('clinical'::note_type, 'amendment'::note_type))
                OR (public.get_my_role() = 'nurse'::user_role AND note_type = 'nursing'::note_type)
            )
        )
    );

-- UPDATE: Authors may edit unsigned notes only. Signed notes trigger amendment workflow.
DROP POLICY IF EXISTS "notes_update_policy" ON public.clinical_notes;
CREATE POLICY "notes_update_policy" ON public.clinical_notes
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND author = auth.uid()
            AND is_signed = false
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND author = auth.uid()
        )
    );

-- ----------------------------------------------------------------------------
-- 15.7 patient_diagnoses
-- ----------------------------------------------------------------------------
-- SELECT: Doctors and nurses with transfer access.
DROP POLICY IF EXISTS "diagnoses_select_policy" ON public.patient_diagnoses;
CREATE POLICY "diagnoses_select_policy" ON public.patient_diagnoses
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('doctor'::user_role, 'nurse'::user_role)
            AND public.can_access_patient(patient_id)
        )
    );

-- INSERT & UPDATE: Doctors only.
DROP POLICY IF EXISTS "diagnoses_insert_policy" ON public.patient_diagnoses;
CREATE POLICY "diagnoses_insert_policy" ON public.patient_diagnoses
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND public.can_access_patient(patient_id)
        )
    );

DROP POLICY IF EXISTS "diagnoses_update_policy" ON public.patient_diagnoses;
CREATE POLICY "diagnoses_update_policy" ON public.patient_diagnoses
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND public.can_access_patient(patient_id)
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND public.can_access_patient(patient_id)
        )
    );

-- ----------------------------------------------------------------------------
-- 15.8 patient_allergies
-- ----------------------------------------------------------------------------
-- SELECT: Doctors, nurses, and pharmacists with transfer access.
DROP POLICY IF EXISTS "allergies_select_policy" ON public.patient_allergies;
CREATE POLICY "allergies_select_policy" ON public.patient_allergies
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('doctor'::user_role, 'nurse'::user_role, 'pharmacist'::user_role)
            AND public.can_access_patient(patient_id)
        )
    );

-- INSERT: Doctors only.
DROP POLICY IF EXISTS "allergies_insert_policy" ON public.patient_allergies;
CREATE POLICY "allergies_insert_policy" ON public.patient_allergies
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND public.can_access_patient(patient_id)
        )
    );

-- ----------------------------------------------------------------------------
-- 15.9 patient_documents
-- ----------------------------------------------------------------------------
-- SELECT: Authorized clinical staff with transfer access to patient.
DROP POLICY IF EXISTS "documents_select_policy" ON public.patient_documents;
CREATE POLICY "documents_select_policy" ON public.patient_documents
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_user() AND public.can_access_patient(patient_id))
    );

-- INSERT: Lab technicians and doctors with transfer access.
DROP POLICY IF EXISTS "documents_insert_policy" ON public.patient_documents;
CREATE POLICY "documents_insert_policy" ON public.patient_documents
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('doctor'::user_role, 'lab_technician'::user_role)
            AND public.can_access_patient(patient_id)
        )
    );

-- ----------------------------------------------------------------------------
-- 15.10 patient_file_transfers
-- ----------------------------------------------------------------------------
-- SELECT: Sender or recipient only (plus admin).
DROP POLICY IF EXISTS "transfers_select_policy" ON public.patient_file_transfers;
CREATE POLICY "transfers_select_policy" ON public.patient_file_transfers
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND (sender_id = auth.uid() OR recipient_id = auth.uid())
        )
    );

-- INSERT: Any active hospital staff member initiating a transfer.
DROP POLICY IF EXISTS "transfers_insert_policy" ON public.patient_file_transfers;
CREATE POLICY "transfers_insert_policy" ON public.patient_file_transfers
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND sender_id = auth.uid()
        )
    );

-- UPDATE: Recipient updates workflow statuses; sender may cancel/recall.
DROP POLICY IF EXISTS "transfers_update_policy" ON public.patient_file_transfers;
CREATE POLICY "transfers_update_policy" ON public.patient_file_transfers
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND (recipient_id = auth.uid() OR sender_id = auth.uid())
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND (recipient_id = auth.uid() OR sender_id = auth.uid())
        )
    );

-- ----------------------------------------------------------------------------
-- 15.11 patient_file_transfer_history
-- ----------------------------------------------------------------------------
-- SELECT: Sender or recipient of related transfer.
DROP POLICY IF EXISTS "transfer_history_select_policy" ON public.patient_file_transfer_history;
CREATE POLICY "transfer_history_select_policy" ON public.patient_file_transfer_history
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR EXISTS (
            SELECT 1 FROM public.patient_file_transfers t
            WHERE t.id = transfer_id
              AND (t.sender_id = auth.uid() OR t.recipient_id = auth.uid())
        )
    );

-- INSERT / UPDATE: Append-only via trigger log_transfer_history(). No direct client modification.

-- ----------------------------------------------------------------------------
-- 15.12 notifications
-- ----------------------------------------------------------------------------
-- SELECT: Recipient staff member only.
DROP POLICY IF EXISTS "notifications_select_policy" ON public.notifications;
CREATE POLICY "notifications_select_policy" ON public.notifications
    FOR SELECT TO authenticated
    USING (public.is_admin() OR recipient_id = auth.uid());

-- INSERT: Any active staff member.
DROP POLICY IF EXISTS "notifications_insert_policy" ON public.notifications;
CREATE POLICY "notifications_insert_policy" ON public.notifications
    FOR INSERT TO authenticated
    WITH CHECK (public.is_admin() OR public.is_active_user());

-- UPDATE: Only recipient can mark notification as read.
DROP POLICY IF EXISTS "notifications_update_policy" ON public.notifications;
CREATE POLICY "notifications_update_policy" ON public.notifications
    FOR UPDATE TO authenticated
    USING (recipient_id = auth.uid())
    WITH CHECK (recipient_id = auth.uid());

-- ----------------------------------------------------------------------------
-- 15.13 laboratory_orders
-- ----------------------------------------------------------------------------
-- SELECT: Ordering doctor, assigned technician, or admin.
DROP POLICY IF EXISTS "lab_orders_select_policy" ON public.laboratory_orders;
CREATE POLICY "lab_orders_select_policy" ON public.laboratory_orders
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR ordering_doctor_id = auth.uid()
        OR assigned_technician_id = auth.uid()
    );

-- INSERT: Doctor with transfer access to patient.
DROP POLICY IF EXISTS "lab_orders_insert_policy" ON public.laboratory_orders;
CREATE POLICY "lab_orders_insert_policy" ON public.laboratory_orders
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND ordering_doctor_id = auth.uid()
            AND public.can_access_patient(patient_id)
        )
    );

-- UPDATE: Assigned technician updates status; doctor manages technician assignment.
DROP POLICY IF EXISTS "lab_orders_update_policy" ON public.laboratory_orders;
CREATE POLICY "lab_orders_update_policy" ON public.laboratory_orders
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND (ordering_doctor_id = auth.uid() OR assigned_technician_id = auth.uid())
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND (ordering_doctor_id = auth.uid() OR assigned_technician_id = auth.uid())
        )
    );

-- ----------------------------------------------------------------------------
-- 15.14 laboratory_order_items
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "lab_order_items_select_policy" ON public.laboratory_order_items;
CREATE POLICY "lab_order_items_select_policy" ON public.laboratory_order_items
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR EXISTS (
            SELECT 1 FROM public.laboratory_orders o
            WHERE o.id = order_id
              AND (o.ordering_doctor_id = auth.uid() OR o.assigned_technician_id = auth.uid())
        )
    );

DROP POLICY IF EXISTS "lab_order_items_insert_policy" ON public.laboratory_order_items;
CREATE POLICY "lab_order_items_insert_policy" ON public.laboratory_order_items
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND EXISTS (
                SELECT 1 FROM public.laboratory_orders o
                WHERE o.id = order_id AND o.ordering_doctor_id = auth.uid()
            )
        )
    );

-- ----------------------------------------------------------------------------
-- 15.15 laboratory_results
-- ----------------------------------------------------------------------------
-- SELECT: Ordering doctor or assigned technician.
DROP POLICY IF EXISTS "lab_results_select_policy" ON public.laboratory_results;
CREATE POLICY "lab_results_select_policy" ON public.laboratory_results
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR performed_by = auth.uid()
        OR finalized_by = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.laboratory_orders o
            WHERE o.id = order_id
              AND (o.ordering_doctor_id = auth.uid() OR o.assigned_technician_id = auth.uid())
        )
    );

-- INSERT & UPDATE: Assigned lab technician. Finalization locks record.
DROP POLICY IF EXISTS "lab_results_insert_policy" ON public.laboratory_results;
CREATE POLICY "lab_results_insert_policy" ON public.laboratory_results
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'lab_technician'::user_role
            AND EXISTS (
                SELECT 1 FROM public.laboratory_orders o
                WHERE o.id = order_id
                  AND (o.assigned_technician_id = auth.uid() OR o.assigned_technician_id IS NULL)
            )
        )
    );

DROP POLICY IF EXISTS "lab_results_update_policy" ON public.laboratory_results;
CREATE POLICY "lab_results_update_policy" ON public.laboratory_results
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
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
            public.is_active_user()
            AND public.get_my_role() = 'lab_technician'::user_role
        )
    );

-- ----------------------------------------------------------------------------
-- 15.16 medicine_catalog
-- ----------------------------------------------------------------------------
-- SELECT: All active hospital staff (physicians prescribe, pharmacists dispense).
DROP POLICY IF EXISTS "med_catalog_select_policy" ON public.medicine_catalog;
CREATE POLICY "med_catalog_select_policy" ON public.medicine_catalog
    FOR SELECT TO authenticated
    USING (public.is_active_user());

-- INSERT / UPDATE / DELETE: Pharmacists or administrators.
DROP POLICY IF EXISTS "med_catalog_insert_policy" ON public.medicine_catalog;
CREATE POLICY "med_catalog_insert_policy" ON public.medicine_catalog
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

DROP POLICY IF EXISTS "med_catalog_update_policy" ON public.medicine_catalog;
CREATE POLICY "med_catalog_update_policy" ON public.medicine_catalog
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    )
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

DROP POLICY IF EXISTS "med_catalog_delete_policy" ON public.medicine_catalog;
CREATE POLICY "med_catalog_delete_policy" ON public.medicine_catalog
    FOR DELETE TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

-- ----------------------------------------------------------------------------
-- 15.17 medicine_batches
-- ----------------------------------------------------------------------------
-- SELECT / INSERT / UPDATE: Pharmacists and administrators.
DROP POLICY IF EXISTS "med_batches_select_policy" ON public.medicine_batches;
CREATE POLICY "med_batches_select_policy" ON public.medicine_batches
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

DROP POLICY IF EXISTS "med_batches_insert_policy" ON public.medicine_batches;
CREATE POLICY "med_batches_insert_policy" ON public.medicine_batches
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

DROP POLICY IF EXISTS "med_batches_update_policy" ON public.medicine_batches;
CREATE POLICY "med_batches_update_policy" ON public.medicine_batches
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    )
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

-- ----------------------------------------------------------------------------
-- 15.18 prescriptions
-- ----------------------------------------------------------------------------
-- SELECT: Prescribing doctor, or pharmacist with transfer access to patient.
DROP POLICY IF EXISTS "prescriptions_select_policy" ON public.prescriptions;
CREATE POLICY "prescriptions_select_policy" ON public.prescriptions
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR prescribing_doctor_id = auth.uid()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'pharmacist'::user_role
            AND public.can_access_patient(patient_id)
        )
    );

-- INSERT: Doctors only.
DROP POLICY IF EXISTS "prescriptions_insert_policy" ON public.prescriptions;
CREATE POLICY "prescriptions_insert_policy" ON public.prescriptions
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND prescribing_doctor_id = auth.uid()
            AND public.can_access_patient(patient_id)
        )
    );

-- UPDATE: Doctor can modify own draft prescriptions. Pharmacists cannot alter prescriptions.
DROP POLICY IF EXISTS "prescriptions_update_policy" ON public.prescriptions;
CREATE POLICY "prescriptions_update_policy" ON public.prescriptions
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND prescribing_doctor_id = auth.uid()
            AND status = 'draft'::prescription_status
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND prescribing_doctor_id = auth.uid()
        )
    );

-- ----------------------------------------------------------------------------
-- 15.19 prescription_items
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "rx_items_select_policy" ON public.prescription_items;
CREATE POLICY "rx_items_select_policy" ON public.prescription_items
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR EXISTS (
            SELECT 1 FROM public.prescriptions p
            WHERE p.id = prescription_id
              AND (
                  p.prescribing_doctor_id = auth.uid()
                  OR (
                      public.is_active_user()
                      AND public.get_my_role() = 'pharmacist'::user_role
                      AND public.can_access_patient(p.patient_id)
                  )
              )
        )
    );

DROP POLICY IF EXISTS "rx_items_insert_policy" ON public.prescription_items;
CREATE POLICY "rx_items_insert_policy" ON public.prescription_items
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'doctor'::user_role
            AND EXISTS (
                SELECT 1 FROM public.prescriptions p
                WHERE p.id = prescription_id
                  AND p.prescribing_doctor_id = auth.uid()
                  AND p.status = 'draft'::prescription_status
            )
        )
    );

-- ----------------------------------------------------------------------------
-- 15.20 dispensing_records
-- ----------------------------------------------------------------------------
-- SELECT: Assigned pharmacist or prescribing doctor.
DROP POLICY IF EXISTS "dispensing_select_policy" ON public.dispensing_records;
CREATE POLICY "dispensing_select_policy" ON public.dispensing_records
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR pharmacist_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.prescriptions p
            WHERE p.id = prescription_id AND p.prescribing_doctor_id = auth.uid()
        )
    );

-- INSERT & UPDATE: Assigned pharmacist or admin.
DROP POLICY IF EXISTS "dispensing_insert_policy" ON public.dispensing_records;
CREATE POLICY "dispensing_insert_policy" ON public.dispensing_records
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

DROP POLICY IF EXISTS "dispensing_update_policy" ON public.dispensing_records;
CREATE POLICY "dispensing_update_policy" ON public.dispensing_records
    FOR UPDATE TO authenticated
    USING (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'pharmacist'::user_role
            AND (pharmacist_id = auth.uid() OR pharmacist_id IS NULL)
        )
    )
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

-- ----------------------------------------------------------------------------
-- 15.21 dispensing_items
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "dispensing_items_select_policy" ON public.dispensing_items;
CREATE POLICY "dispensing_items_select_policy" ON public.dispensing_items
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR EXISTS (
            SELECT 1 FROM public.dispensing_records d
            WHERE d.id = dispensing_record_id
              AND (
                  d.pharmacist_id = auth.uid()
                  OR EXISTS (
                      SELECT 1 FROM public.prescriptions p
                      WHERE p.id = d.prescription_id AND p.prescribing_doctor_id = auth.uid()
                  )
              )
        )
    );

DROP POLICY IF EXISTS "dispensing_items_insert_policy" ON public.dispensing_items;
CREATE POLICY "dispensing_items_insert_policy" ON public.dispensing_items
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() = 'pharmacist'::user_role
            AND EXISTS (
                SELECT 1 FROM public.dispensing_records d
                WHERE d.id = dispensing_record_id
                  AND (d.pharmacist_id = auth.uid() OR d.pharmacist_id IS NULL)
            )
        )
    );

-- ----------------------------------------------------------------------------
-- 15.22 inventory_movements
-- ----------------------------------------------------------------------------
-- SELECT: Pharmacists and administrators.
DROP POLICY IF EXISTS "movements_select_policy" ON public.inventory_movements;
CREATE POLICY "movements_select_policy" ON public.inventory_movements
    FOR SELECT TO authenticated
    USING (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

-- INSERT: Pharmacists, administrators, or via atomic deduct_stock function.
DROP POLICY IF EXISTS "movements_insert_policy" ON public.inventory_movements;
CREATE POLICY "movements_insert_policy" ON public.inventory_movements
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_admin()
        OR (public.is_active_user() AND public.get_my_role() = 'pharmacist'::user_role)
    );

-- ----------------------------------------------------------------------------
-- 15.23 audit_logs
-- ----------------------------------------------------------------------------
-- SELECT: Strictly administrators.
DROP POLICY IF EXISTS "audit_logs_select_policy" ON public.audit_logs;
CREATE POLICY "audit_logs_select_policy" ON public.audit_logs
    FOR SELECT TO authenticated
    USING (public.is_admin());

-- INSERT: Inserted via SECURITY DEFINER log_audit_event() function or admin.
DROP POLICY IF EXISTS "audit_logs_insert_policy" ON public.audit_logs;
CREATE POLICY "audit_logs_insert_policy" ON public.audit_logs
    FOR INSERT TO authenticated
    WITH CHECK (public.is_admin() AND actor_id = auth.uid());

-- ============================================================================
-- SECTION 16: SUPABASE STORAGE BUCKET & STORAGE POLICIES
-- ============================================================================
-- Configuration for medical-images bucket (radiology, lab scans, PDF reports).
-- Security Decisions:
-- 1. Bucket is private (public = false).
-- 2. File size limit is 50MB (52,428,800 bytes).
-- 3. Allowed MIME types are restricted to clinical imaging formats and PDF.
-- 4. INSERT is restricted to active doctors and lab technicians.
-- 5. SELECT is restricted to staff with active transfer access to the patient linked to the file.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'storage') THEN
        INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
        VALUES (
            'medical-images',
            'medical-images',
            false,
            52428800,
            ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'image/tiff']::text[]
        )
        ON CONFLICT (id) DO UPDATE SET
            public = EXCLUDED.public,
            file_size_limit = EXCLUDED.file_size_limit,
            allowed_mime_types = EXCLUDED.allowed_mime_types;
    END IF;
END $$;

-- Storage object policies for medical-images
DROP POLICY IF EXISTS "medical_images_insert_policy" ON storage.objects;
CREATE POLICY "medical_images_insert_policy"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'medical-images'
    AND public.is_active_user()
    AND public.get_my_role() IN ('doctor'::user_role, 'lab_technician'::user_role)
    AND (storage.foldername(name))[1] = auth.uid()::TEXT
);

DROP POLICY IF EXISTS "medical_images_select_policy" ON storage.objects;
CREATE POLICY "medical_images_select_policy"
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'medical-images'
    AND (
        public.is_admin()
        OR EXISTS (
            SELECT 1 FROM public.patient_documents d
            WHERE d.storage_path = storage.objects.name
              AND public.can_access_patient(d.patient_id)
        )
    )
);

DROP POLICY IF EXISTS "medical_images_delete_policy" ON storage.objects;
CREATE POLICY "medical_images_delete_policy"
ON storage.objects
FOR DELETE
TO authenticated
USING (
    bucket_id = 'medical-images'
    AND NOT EXISTS (
        SELECT 1
        FROM public.patient_documents d
        WHERE d.storage_path = storage.objects.name
    )
    AND (
        public.is_admin()
        OR (
            public.is_active_user()
            AND public.get_my_role() IN ('doctor'::user_role, 'lab_technician'::user_role)
            AND (storage.foldername(name))[1] = auth.uid()::TEXT
        )
    )
);

-- ============================================================================
-- SECTION 17: INITIAL SYSTEM SETTINGS SEED DATA
-- ============================================================================
-- Seed baseline role headcount quotas (10 staff members per role limit).
INSERT INTO public.system_settings (key, value, description)
VALUES
    ('max_doctors', '10', 'Maximum allowed active doctor accounts in the hospital system'),
    ('max_nurses', '10', 'Maximum allowed active nurse accounts in the hospital system'),
    ('max_pharmacists', '10', 'Maximum allowed active pharmacist accounts in the hospital system'),
    ('max_front_desk', '10', 'Maximum allowed active front desk accounts in the hospital system'),
    ('max_lab_technicians', '10', 'Maximum allowed active lab technician accounts in the hospital system')
ON CONFLICT (key) DO NOTHING;

-- ============================================================================
-- SECTION 18: PERMISSIONS AND EXECUTE GRANTS
-- ============================================================================
-- Grant schema usage and table privileges to Supabase authenticated and service_role.
-- Row Level Security enforces all row-specific authorization.

GRANT USAGE ON SCHEMA public TO authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;

-- Function Execution Grants
GRANT EXECUTE ON FUNCTION public.get_my_role() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_status() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_active_user() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_profile_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_access_patient(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_transfer_recipient(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_transfer_sender(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.check_staff_limit(user_role) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.deduct_stock(UUID, UUID, INTEGER, UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.log_audit_event(TEXT, TEXT, UUID, JSONB, JSONB, TEXT) TO authenticated, service_role;

-- Revoke dangerous permissions from public and anonymous users
REVOKE EXECUTE ON FUNCTION public.deduct_stock(UUID, UUID, INTEGER, UUID, UUID) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.check_staff_limit(user_role) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.log_audit_event(TEXT, TEXT, UUID, JSONB, JSONB, TEXT) FROM anon, public;

-- ============================================================================
-- END OF SUPABASE EMR DATABASE SETUP SCRIPT
-- ============================================================================
