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

function normalizeEgyptPhone(value: string): string {
  let digits = value.replace(/\D/g, "");
  if (digits.startsWith("00")) digits = digits.slice(2);
  if (digits.startsWith("0")) digits = "20" + digits.slice(1);
  else if (digits.length === 10 && digits.startsWith("1")) digits = "20" + digits;
  if (!/^20(10|11|12|15)\d{8}$/.test(digits)) {
    throw new Error("رقم هاتف العميل غير صالح لواتساب مصر.");
  }
  return digits;
}

function decodePngBase64(value: string): Uint8Array {
  const raw = value.replace(/^data:image\/png;base64,/, "");
  if (!raw || raw.length > 7_000_000) throw new Error("صورة الفاتورة غير صالحة أو أكبر من الحد المسموح.");
  const binary = atob(raw);
  if (binary.length > 5 * 1024 * 1024) throw new Error("حجم صورة الفاتورة يجب ألا يتجاوز 5 ميجابايت.");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (!signature.every((byte, i) => bytes[i] === byte)) throw new Error("يجب إرسال صورة PNG صحيحة.");
  return bytes;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  if (Deno.env.get("WA_SEND_ENABLED") !== "true") {
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

  let body: { invoice_id?: string; image_base64?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "بيانات الطلب غير صالحة." }, 400);
  }
  if (!body.invoice_id || !body.image_base64) return json({ error: "بيانات الفاتورة والصورة مطلوبة." }, 400);

  let imageBytes: Uint8Array;
  let to: string;
  let invoice: { id: string; invoice_no: string; customer_phone: string | null; status: string };
  try {
    imageBytes = decodePngBase64(body.image_base64);
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
  const templateName = Deno.env.get("WA_IMAGE_TEMPLATE_NAME");
  const templateLanguage = Deno.env.get("WA_TEMPLATE_LANGUAGE") || "ar";
  const graphVersion = Deno.env.get("WA_GRAPH_API_VERSION") || "v25.0";
  if (!accessToken || !phoneNumberId || !templateName || !/^v\d+\.\d+$/.test(graphVersion)) {
    return json({ error: "إعدادات WhatsApp Cloud API أو قالب الصورة المعتمد غير مكتملة." }, 503);
  }

  const deliveryTable = "erp_whatsapp_invoice_deliveries";
  let deliveryId: string;
  const { data: existing, error: existingError } = await supabase
    .from(deliveryTable)
    .select("id,status")
    .eq("owner_id", user.id)
    .eq("invoice_id", invoice.id)
    .eq("delivery_type", "sale_invoice_image")
    .maybeSingle();
  if (existingError) return json({ error: "تعذر قراءة سجل إرسال الفاتورة." }, 503);

  if (existing) {
    if (existing.status !== "failed") {
      return json({ error: "تم بدء إرسال هذه الفاتورة من قبل؛ لن نكرر الإرسال تلقائيًا.", status: existing.status }, 409);
    }
    const { data: claimed, error: claimError } = await supabase
      .from(deliveryTable)
      .update({ status: "processing", error_code: null, updated_at: new Date().toISOString() })
      .eq("id", existing.id)
      .eq("status", "failed")
      .select("id")
      .maybeSingle();
    if (claimError || !claimed) return json({ error: "هناك محاولة إرسال أخرى قيد التنفيذ." }, 409);
    deliveryId = claimed.id;
  } else {
    const { data: created, error: createError } = await supabase
      .from(deliveryTable)
      .insert({
        owner_id: user.id,
        invoice_id: invoice.id,
        delivery_type: "sale_invoice_image",
        status: "processing",
      })
      .select("id")
      .single();
    if (createError || !created) {
      return json({ error: createError?.code === "23505" ? "تم طلب إرسال هذه الفاتورة بالفعل." : "تعذر إنشاء سجل إرسال آمن." }, 409);
    }
    deliveryId = created.id;
  }

  const mark = async (status: string, extra: Record<string, unknown> = {}) => {
    await supabase.from(deliveryTable).update({
      status,
      updated_at: new Date().toISOString(),
      ...extra,
    }).eq("id", deliveryId).eq("owner_id", user.id);
  };

  const graphBase = `https://graph.facebook.com/${graphVersion}/`;
  const mediaForm = new FormData();
  mediaForm.append("messaging_product", "whatsapp");
  mediaForm.append("type", "image/png");
  mediaForm.append("file", new Blob([imageBytes], { type: "image/png" }), `invoice-${invoice.invoice_no}.png`);

  let mediaResponse: Response;
  try {
    mediaResponse = await fetch(`${graphBase}${phoneNumberId}/media`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}` },
      body: mediaForm,
    });
  } catch {
    await mark("failed", { error_code: "MEDIA_UPLOAD_NETWORK_ERROR" });
    return json({ error: "تعذر رفع صورة الفاتورة إلى واتساب. يمكنك المحاولة مرة أخرى." }, 502);
  }

  const mediaPayload = await mediaResponse.json().catch(() => ({}));
  if (!mediaResponse.ok || typeof mediaPayload.id !== "string") {
    await mark("failed", { error_code: String(mediaPayload?.error?.code || "MEDIA_UPLOAD_REJECTED").slice(0, 80) });
    return json({ error: "واتساب رفض رفع صورة الفاتورة. راجع إعدادات حساب WhatsApp Business." }, 502);
  }

  let sendResponse: Response;
  try {
    sendResponse = await fetch(`${graphBase}${phoneNumberId}/messages`, {
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
            parameters: [{ type: "image", image: { id: mediaPayload.id } }],
          }],
        },
      }),
    });
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
    return json({ error: "واتساب رفض إرسال الفاتورة. تأكد من اعتماد قالب الصورة وصلاحية الرقم." }, 502);
  }

  const messageId = sendPayload?.messages?.[0]?.id;
  if (typeof messageId !== "string") {
    await mark("unknown", { error_code: "MISSING_PROVIDER_MESSAGE_ID" });
    return json({ error: "واتساب لم يرجع رقم تأكيد؛ تم إيقاف إعادة الإرسال التلقائي." }, 202);
  }

  await mark("accepted", {
    provider_message_id: messageId,
    accepted_at: new Date().toISOString(),
    error_code: null,
  });
  return json({ ok: true, status: "accepted", invoice_no: invoice.invoice_no });
});
