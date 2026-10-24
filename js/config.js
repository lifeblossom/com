/**
 * Life Blossom Care and Cure Hospital — EMR System
 * Public Supabase Configuration
 *
 * These are the PUBLIC (publishable) keys safe for frontend use.
 * They are not secrets. Security is enforced server-side via:
 *  - Row Level Security (RLS) on all database tables
 *  - Supabase Storage policies on all buckets
 *  - Edge Functions using the service-role key (server-side only)
 *
 * NEVER place the service-role key, database password, or any privileged
 * credential in this file or any other frontend/GitHub Pages deployed file.
 */

export const SUPABASE_URL = 'https://yealxvgednecmwnehfrs.supabase.co';
export const SUPABASE_ANON_KEY = 'sb_publishable_VYswUX9VyLcxCRxaEQefxQ_ZXKIQ-eJ';

/**
 * Application configuration constants
 */
export const APP_CONFIG = {
  HOSPITAL_NAME: 'Life Blossom Care and Cure Hospital',
  HOSPITAL_SHORT_NAME: 'Life Blossom Hospital',
  LOGO_PATH: '../images/logo.png',
  LOGO_PATH_ROOT: './images/logo.png',

  // Role definitions
  ROLES: {
    ADMIN: 'admin',
    DOCTOR: 'doctor',
    NURSE: 'nurse',
    PHARMACIST: 'pharmacist',
    FRONT_DESK: 'front_desk',
    LAB_TECHNICIAN: 'lab_technician',
  },

  // Staff role account limits
  ACCOUNT_LIMITS: {
    doctor: 10,
    nurse: 10,
    pharmacist: 10,
    front_desk: 10,
    lab_technician: 10,
  },

  // Dashboard page routes (relative to pages/ directory)
  DASHBOARD_ROUTES: {
    admin: '../pages/admin.html',
    doctor: '../pages/doctor.html',
    nurse: '../pages/nurse.html',
    pharmacist: '../pages/pharmacy.html',
    front_desk: '../pages/frontdesk.html',
    lab_technician: '../pages/laboratory.html',
  },

  // Route from root index.html perspective
  DASHBOARD_ROUTES_FROM_ROOT: {
    admin: './pages/admin.html',
    doctor: './pages/doctor.html',
    nurse: './pages/nurse.html',
    pharmacist: './pages/pharmacy.html',
    front_desk: './pages/frontdesk.html',
    lab_technician: './pages/laboratory.html',
  },

  // Edge Function base URL
  EDGE_FUNCTION_URL: 'https://yealxvgednecmwnehfrs.supabase.co/functions/v1',

  // File upload limits
  MAX_UPLOAD_SIZE_BYTES: 52428800, // 50 MB
  ALLOWED_MIME_TYPES: ['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'image/tiff'],

  // Notification polling interval (ms)
  NOTIFICATION_POLL_INTERVAL: 30000,

  // Pagination defaults
  DEFAULT_PAGE_SIZE: 20,
};
