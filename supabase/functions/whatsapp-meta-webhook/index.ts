import { createClient } from "npm:@supabase/supabase-js@2.58.0";
import { extractInvoiceStatuses, verifyMetaSignature } from "../_shared/meta-webhook.ts";

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function safeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  const verifyToken = Deno.env.get("WA_WEBHOOK_VERIFY_TOKEN");
  if (!verifyToken) return json({ error: "Webhook verification is not configured." }, 503);

  if (req.method === "GET") {
    const url = new URL(req.url);
    const mode = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const challenge = url.searchParams.get("hub.challenge");
    if (mode !== "subscribe" || !token || !challenge || !safeEqual(token, verifyToken)) {
      return new Response("Forbidden", { status: 403 });
    }
    return new Response(challenge, { status: 200, headers: { "Content-Type": "text/plain" } });
  }

  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const appSecret = Deno.env.get("WA_META_APP_SECRET");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!appSecret || !serviceRoleKey || !supabaseUrl) {
    return json({ error: "Webhook server configuration is incomplete." }, 503);
  }

  const declaredLength = Number(req.headers.get("content-length") || 0);
  if (declaredLength > 1_000_000) return json({ error: "Payload too large." }, 413);
  const rawBody = new Uint8Array(await req.arrayBuffer());
  if (rawBody.byteLength > 1_000_000) return json({ error: "Payload too large." }, 413);

  const valid = await verifyMetaSignature(rawBody, req.headers.get("x-hub-signature-256"), appSecret);
  if (!valid) return json({ error: "Invalid webhook signature." }, 401);

  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return json({ error: "Invalid JSON payload." }, 400);
  }

  const updates = extractInvoiceStatuses(payload);
  if (!updates.length) return json({ ok: true, processed: 0 });

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  let processed = 0;
  for (const update of updates) {
    const { data, error } = await admin.rpc("erp_wa_apply_invoice_webhook", {
      p_provider_message_id: update.messageId,
      p_status: update.status,
      p_error_code: update.errorCode,
    });
    if (error) {
      console.error("WhatsApp webhook ledger update failed", error.message);
      return json({ error: "Delivery status could not be recorded; provider should retry." }, 503);
    }
    if (data === true) processed++;
  }
  return json({ ok: true, processed });
});
