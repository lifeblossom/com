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

DROP POLICY IF EXISTS "audit_logs_insert_policy" ON public.audit_logs;
CREATE POLICY "audit_logs_insert_policy" ON public.audit_logs
    FOR INSERT TO authenticated
    WITH CHECK (public.is_admin() AND actor_id = auth.uid());

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

REVOKE EXECUTE ON FUNCTION public.log_audit_event(TEXT, TEXT, UUID, JSONB, JSONB, TEXT) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.log_audit_event(TEXT, TEXT, UUID, JSONB, JSONB, TEXT) TO authenticated, service_role;
