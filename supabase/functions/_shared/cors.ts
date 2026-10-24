/**
 * Life Blossom Care and Cure Hospital — EMR System
 * Shared CORS Configuration
 *
 * Configure APP_ORIGIN to the exact HTTPS origin hosting the staff application.
 * Requests from other origins receive no permissive CORS response.
 */

const appOrigin = Deno.env.get('APP_ORIGIN')?.trim();

export const corsHeaders: Record<string, string> = {
  ...(appOrigin ? { 'Access-Control-Allow-Origin': appOrigin } : {}),
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};

/**
 * Handle CORS preflight requests (OPTIONS).
 * Returns a 200 OK response with CORS headers if the request method is OPTIONS.
 * Returns null if the request is not an OPTIONS preflight.
 */
export function handleCors(req: Request): Response | null {
  if (req.method === 'OPTIONS') {
    const requestOrigin = req.headers.get('Origin');
    if (appOrigin && requestOrigin && requestOrigin !== appOrigin) {
      return new Response(null, { status: 403 });
    }
    return new Response('ok', {
      status: 200,
      headers: corsHeaders,
    });
  }
  return null;
}

/**
 * Standard JSON response helper with CORS headers
 */
export function jsonResponse(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {}
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
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
  extraHeaders: Record<string, string> = {}
): Response {
  return jsonResponse(
    {
      success: false,
      error: message,
      ...(details !== undefined ? { details } : {}),
    },
    status,
    extraHeaders
  );
}
