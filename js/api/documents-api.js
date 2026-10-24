/**
 * Patient clinical document storage.
 *
 * Storage and document-row policies enforce access independently of this client.
 */

import { supabase } from '../supabase-client.js';
import { APP_CONFIG } from '../config.js';

export async function listPatientDocuments(patientId) {
  const { data, error } = await supabase
    .from('patient_documents')
    .select('id, category, original_filename, storage_path, mime_type, file_size, description, created_at')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false });
  return { data, error };
}

export async function uploadPatientDocument(file, { patientId, encounterId, category, description }) {
  if (!(file instanceof File)) {
    return { data: null, error: new Error('Choose a document to upload.') };
  }
  if (file.size <= 0 || file.size > APP_CONFIG.MAX_UPLOAD_SIZE_BYTES) {
    return { data: null, error: new Error('The document must be no larger than 50 MB.') };
  }
  if (!APP_CONFIG.ALLOWED_MIME_TYPES.includes(file.type)) {
    return { data: null, error: new Error('This document type is not allowed.') };
  }

  const { data: { user }, error: userError } = await supabase.auth.getUser();
  if (userError || !user) {
    return { data: null, error: userError || new Error('Sign in again before uploading documents.') };
  }

  const safeFilename = file.name.replace(/[^\w.-]+/g, '_').slice(-120) || 'clinical-document';
  const storagePath = `${user.id}/${patientId}/${crypto.randomUUID()}-${safeFilename}`;
  const { error: uploadError } = await supabase.storage
    .from('medical-images')
    .upload(storagePath, file, { contentType: file.type, cacheControl: '0', upsert: false });

  if (uploadError) return { data: null, error: uploadError };

  const { data, error } = await supabase
    .from('patient_documents')
    .insert([{
      patient_id: patientId,
      encounter_id: encounterId || null,
      category,
      original_filename: file.name,
      storage_path: storagePath,
      mime_type: file.type,
      file_size: file.size,
      description: description?.trim() || null,
      uploaded_by: user.id,
    }])
    .select()
    .single();

  if (error) {
    const { error: cleanupError } = await supabase.storage
      .from('medical-images')
      .remove([storagePath]);
    if (cleanupError) {
      console.error('Failed to remove orphaned clinical document:', cleanupError.message);
    }
    return { data: null, error };
  }
  return { data, error: null };
}

export async function createPatientDocumentUrl(storagePath) {
  const { data, error } = await supabase.storage
    .from('medical-images')
    .createSignedUrl(storagePath, 60);
  return { data, error };
}
