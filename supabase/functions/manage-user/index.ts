// Retired endpoint. User management now uses location-scoped, token-validated
// POS RPCs; this legacy service-role function is intentionally fail-closed.
const corsHeaders = {
  "Access-Control-Allow-Origin": "https://lacabanapos-pwa.vercel.app",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

Deno.serve((req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  return new Response(JSON.stringify({
    error: "Endpoint retirado. Use la administración cloud de usuarios del POS.",
  }), { status: 410, headers: corsHeaders });
});
