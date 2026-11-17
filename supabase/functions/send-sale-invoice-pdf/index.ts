import { decodePdfBase64, fetchWithTimeout, isWhatsAppSendEnabled, normalizeEgyptPhone } from "../_shared/whatsapp-validation.ts";
import { createClient } from "npm:@supabase/supabase-js@2.58.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });


Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  if (!isWhatsAppSendEnabled(Deno.env.get("WA_SEND_ENABLED"))) {
    return json({ error: "إرسال واتساب غير مفعّل على الخادم حتى الآن." }, 503);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return json({ error: "يلزم تسجيل الدخول." }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const keyMapRaw = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  const publishableKey = keyMapRaw
    ? (JSON.parse(keyMapRaw) as Record<string, string>).default
    : Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !publishableKey) return json({ error: "إعدادات Supabase للخادم غير مكتملة." }, 503);

  const token = authHeader.slice("Bearer ".length);
  const supabase = createClient(supabaseUrl, publishableKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userResult, error: userError } = await supabase.auth.getUser(token);
  const user = userResult.user;
  if (userError || !user) return json({ error: "جلسة الدخول غير صالحة. سجّل الدخول مرة أخرى." }, 401);

  let body: { invoice_id?: string; pdf_base64?: string };
  try {
    const parsed: unknown = await req.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return json({ error: "بيانات الطلب غير صالحة." }, 400);
    }
    body = parsed as { invoice_id?: string; pdf_base64?: string };
  } catch {
    return json({ error: "بيانات الطلب غير صالحة." }, 400);
  }
  if (typeof body.invoice_id !== "string" || !body.invoice_id ||
      typeof body.pdf_base64 !== "string" || !body.pdf_base64) {
    return json({ error: "بيانات الفاتورة وملف PDF مطلوبة." }, 400);
  }

  let pdfBytes: Uint8Array;
  let to: string;
  let invoice: { id: string; invoice_no: string; customer_phone: string | null; status: string };
  try {
    pdfBytes = decodePdfBase64(body.pdf_base64);
    const { data, error } = await supabase
      .from("erp_sales_invoices")
      .select("id, owner_id, invoice_no, customer_phone, status")
      .eq("id", body.invoice_id)
      .eq("owner_id", user.id)
      .maybeSingle();
    if (error || !data) return json({ error: "الفاتورة غير موجودة أو لا تملك صلاحية إرسالها." }, 404);
    invoice = data;
    if (invoice.status !== "completed") return json({ error: "لا يمكن إرسال فاتورة ملغاة." }, 409);
    if (!invoice.customer_phone) return json({ error: "لا يوجد رقم هاتف محفوظ للعميل في الفاتورة." }, 400);
    to = normalizeEgyptPhone(invoice.customer_phone);

    const { data: items, error: itemsError } = await supabase
      .from("erp_sales_invoice_items")
      .select("id")
      .eq("invoice_id", invoice.id)
      .eq("owner_id", user.id)
      .limit(1);
    if (itemsError || !items?.length) return json({ error: "تعذر التحقق من أصناف الفاتورة." }, 400);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "تعذر التحقق من الفاتورة." }, 400);
  }

  const accessToken = Deno.env.get("WA_ACCESS_TOKEN");
  const phoneNumberId = Deno.env.get("WA_PHONE_NUMBER_ID");
  const templateName = Deno.env.get("WA_DOCUMENT_TEMPLATE_NAME");
  const templateLanguage = Deno.env.get("WA_TEMPLATE_LANGUAGE") || "ar";
  const graphVersion = Deno.env.get("WA_GRAPH_API_VERSION") || "v25.0";
  if (!accessToken || !phoneNumberId || !templateName || !/^v\d+\.\d+$/.test(graphVersion)) {
    return json({ error: "إعدادات WhatsApp Cloud API أو قالب المستند المعتمد غير مكتملة." }, 503);
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceRoleKey) return json({ error: "إعدادات سجل الإرسال على الخادم غير مكتملة." }, 503);

  const ledger = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: claimRows, error: claimError } = await ledger.rpc("erp_wa_claim_invoice_delivery", {
    p_owner_id: user.id,
    p_invoice_id: invoice.id,
  });
  if (claimError || !Array.isArray(claimRows) || !claimRows[0]) {
    return json({ error: "تعذر حجز محاولة إرسال آمنة في السجل." }, 503);
  }
  const claim = claimRows[0] as { delivery_id: string; delivery_status: string; claimed: boolean };
  if (!claim.claimed) {
    return json({
      error: "تم تسجيل محاولة لهذه الفاتورة من قبل؛ لن نكرر الإرسال تلقائيًا.",
      status: claim.delivery_status,
    }, 409);
  }
  const deliveryId = claim.delivery_id;

  const mark = async (
    status: "accepted" | "delivered" | "read" | "failed" | "unknown",
    extra: { provider_message_id?: string; error_code?: string | null; accepted_at?: string } = {},
  ) => {
    const { data, error } = await ledger.rpc("erp_wa_update_invoice_delivery", {
      p_delivery_id: deliveryId,
      p_owner_id: user.id,
      p_status: status,
      p_provider_message_id: extra.provider_message_id ?? null,
      p_error_code: extra.error_code ?? null,
      p_accepted_at: extra.accepted_at ?? null,
    });
    if (error || data !== true) {
      console.error("WhatsApp delivery ledger update failed", error?.message ?? "no row updated");
      return false;
    }
    return true;
  };

  const graphBase = `https://graph.facebook.com/${graphVersion}/`;
  const mediaForm = new FormData();
  mediaForm.append("messaging_product", "whatsapp");
  mediaForm.append("type", "application/pdf");
  const safeInvoiceNo = invoice.invoice_no.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 80) || "invoice";
  const fileName = `sale-invoice-${safeInvoiceNo}.pdf`;
  mediaForm.append("file", new Blob([pdfBytes.buffer as ArrayBuffer], { type: "application/pdf" }), fileName);

  let mediaResponse: Response;
  try {
    mediaResponse = await fetchWithTimeout(`${graphBase}${phoneNumberId}/media`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}` },
      body: mediaForm,
    }, 20_000);
  } catch {
    await mark("failed", { error_code: "MEDIA_UPLOAD_NETWORK_ERROR" });
    return json({ error: "تعذر رفع ملف PDF إلى واتساب. يمكنك المحاولة مرة أخرى." }, 502);
  }

  const mediaPayload = await mediaResponse.json().catch(() => ({}));
  if (!mediaResponse.ok || typeof mediaPayload.id !== "string") {
    await mark("failed", { error_code: String(mediaPayload?.error?.code || "MEDIA_UPLOAD_REJECTED").slice(0, 80) });
    return json({ error: "واتساب رفض رفع ملف PDF للفاتورة. راجع إعدادات حساب WhatsApp Business." }, 502);
  }

  let sendResponse: Response;
  try {
    sendResponse = await fetchWithTimeout(`${graphBase}${phoneNumberId}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to,
        type: "template",
        template: {
          name: templateName,
          language: { code: templateLanguage },
          components: [{
            type: "header",
            parameters: [{ type: "document", document: { id: mediaPayload.id, filename: fileName } }],
          }],
        },
      }),
    }, 20_000);
  } catch {
    await mark("unknown", { error_code: "MESSAGE_RESULT_UNKNOWN" });
    return json({ error: "حالة الإرسال غير مؤكدة بسبب انقطاع الاتصال. أوقفنا إعادة الإرسال التلقائي منعًا لتكرار الفاتورة." }, 202);
  }

  const sendPayload = await sendResponse.json().catch(() => ({}));
  if (!sendResponse.ok) {
    const providerCode = String(sendPayload?.error?.code || "MESSAGE_REJECTED").slice(0, 80);
    if (sendResponse.status >= 500) {
      await mark("unknown", { error_code: providerCode });
      return json({ error: "واتساب لم يؤكد نتيجة الإرسال؛ لن نكررها تلقائيًا." }, 202);
    }
    await mark("failed", { error_code: providerCode });
    return json({ error: "واتساب رفض إرسال الفاتورة. تأكد من اعتماد قالب المستند وصلاحية الرقم." }, 502);
  }

  const messageId = sendPayload?.messages?.[0]?.id;
  if (typeof messageId !== "string") {
    await mark("unknown", { error_code: "MISSING_PROVIDER_MESSAGE_ID" });
    return json({ error: "واتساب لم يرجع رقم تأكيد؛ تم إيقاف إعادة الإرسال التلقائي." }, 202);
  }

  const ledgerUpdated = await mark("accepted", {
    provider_message_id: messageId,
    accepted_at: new Date().toISOString(),
    error_code: null,
  });
  if (!ledgerUpdated) {
    return json({
      ok: false,
      status: "unknown",
      error: "واتساب قبل الطلب لكن تعذر تحديث سجل المحاولات. لا تعِد الإرسال الآن لتجنب تكرار الفاتورة.",
    }, 202);
  }
  return json({ ok: true, status: "accepted", invoice_no: invoice.invoice_no });
});
