// Retired legacy endpoint. Payments now use record_payment_atomic with the
// short-lived POS operator token and explicit cash-session validation.
const corsHeaders = {
  "Access-Control-Allow-Origin": "https://lacabanapos-pwa.vercel.app",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

Deno.serve((req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  return new Response(JSON.stringify({
    error: "Endpoint retirado. El POS registra cobros mediante la sesión cloud de caja.",
  }), { status: 410, headers: corsHeaders });
});
