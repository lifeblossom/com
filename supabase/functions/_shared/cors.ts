/**
 * Life Blossom Care and Cure Hospital — EMR System
 * Shared CORS Configuration
 *
 * APP_ORIGIN env var = the production HTTPS origin (set in Supabase dashboard secrets).
 * In development, requests from localhost / 127.0.0.1 on any port are also permitted
 * so that Live Server, Vite, or any local dev server can reach the Edge Functions.
 *
 * Do NOT set APP_ORIGIN to a wildcard (*). Keep it as the exact production origin.
 */

const appOrigin = Deno.env.get('APP_ORIGIN')?.trim();

/** Origins that are always allowed (local development). */
const DEV_ORIGINS = new Set([
  'http://localhost',
  'http://127.0.0.1',
]);

function isAllowedOrigin(origin: string | null): boolean {
  if (!origin) return false;
  // Exact match for the configured production origin
  if (appOrigin && origin === appOrigin) return true;
  // Allow any port on localhost / 127.0.0.1 for local development
  try {
    const url = new URL(origin);
    return DEV_ORIGINS.has(`${url.protocol}//${url.hostname}`);
  } catch {
    return false;
  }
}

function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = isAllowedOrigin(origin) ? origin! : (appOrigin ?? '');
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}

/**
 * Handle CORS preflight requests (OPTIONS).
 * Returns a 200 OK response with CORS headers if the request method is OPTIONS.
 * Returns null if the request is not an OPTIONS preflight.
 */
export function handleCors(req: Request): Response | null {
  if (req.method === 'OPTIONS') {
    const origin = req.headers.get('Origin');
    if (!isAllowedOrigin(origin)) {
      return new Response(null, { status: 403 });
    }
    return new Response('ok', {
      status: 200,
      headers: corsHeaders(origin),
    });
  }
  return null;
}

/**
 * Standard JSON response helper with CORS headers.
 * Reads the Origin from the request to echo back the correct allowed origin.
 */
export function jsonResponse(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
  requestOrigin: string | null = null
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(requestOrigin),
      'Content-Type': 'application/json',
      ...extraHeaders,
    },
  });
}

/**
 * Standard safe error response helper with CORS headers.
 * Never leaks internal database schemas or sensitive stack traces.
 */
export function errorResponse(
  message: string,
  status = 400,
  details?: unknown,
  extraHeaders: Record<string, string> = {},
  requestOrigin: string | null = null
): Response {
  return jsonResponse(
    {
      success: false,
      error: message,
      ...(details !== undefined ? { details } : {}),
    },
    status,
    extraHeaders,
    requestOrigin
  );
}
