import { createClient } from "npm:@supabase/supabase-js@2.58.0";
import { buildMaintenanceReadyTemplate } from "../_shared/maintenance-ready.ts";
import { fetchWithTimeout, normalizeEgyptPhone } from "../_shared/whatsapp-validation.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (Deno.env.get("WA_SEND_ENABLED") !== "true") return json({ error: "إرسال واتساب غير مفعّل على الخادم." }, 503);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return json({ error: "يلزم تسجيل الدخول." }, 401);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publicKey = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const waToken = Deno.env.get("WA_ACCESS_TOKEN");
  const phoneNumberId = Deno.env.get("WA_PHONE_NUMBER_ID");
  const templateName = Deno.env.get("WA_MAINTENANCE_READY_TEMPLATE_NAME");
  const language = Deno.env.get("WA_TEMPLATE_LANGUAGE") || "ar";
  const graphVersion = Deno.env.get("WA_GRAPH_API_VERSION") || "v25.0";
  if (!supabaseUrl || !publicKey || !serviceKey || !waToken || !phoneNumberId || !templateName ||
      !/^v\d+\.\d+$/.test(graphVersion)) {
    return json({ error: "إعدادات خدمة إشعار الصيانة غير مكتملة على الخادم." }, 503);
  }

  let body: { maintenance_order_id?: string };
  try {
    const parsed: unknown = await req.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return json({ error: "بيانات الطلب غير صالحة." }, 400);
    body = parsed as { maintenance_order_id?: string };
  } catch {
    return json({ error: "بيانات الطلب غير صالحة." }, 400);
  }
  if (typeof body.maintenance_order_id !== "string" || !body.maintenance_order_id) {
    return json({ error: "رقم أمر الصيانة مطلوب." }, 400);
  }

  const userClient = createClient(supabaseUrl, publicKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = authHeader.slice("Bearer ".length);
  const { data: auth, error: authError } = await userClient.auth.getUser(token);
  if (authError || !auth.user) return json({ error: "جلسة الدخول غير صالحة." }, 401);

  const { data: order, error: orderError } = await userClient
    .from("erp_maintenance_orders")
    .select("id,owner_id,ticket_no,customer_name,customer_phone,device_name,status")
    .eq("id", body.maintenance_order_id)
    .eq("owner_id", auth.user.id)
    .maybeSingle();
  if (orderError || !order) return json({ error: "أمر الصيانة غير موجود أو لا تملك صلاحية الوصول إليه." }, 404);
  if (order.status !== "ready") return json({ error: "لا يمكن الإشعار قبل تحويل الجهاز إلى جاهز للاستلام." }, 409);
  if (!order.customer_phone) return json({ error: "لا يوجد رقم هاتف للعميل." }, 400);

  let to: string;
  try { to = normalizeEgyptPhone(order.customer_phone); }
  catch (error) { return json({ error: error instanceof Error ? error.message : "رقم العميل غير صالح." }, 400); }

  let template;
  try {
    template = buildMaintenanceReadyTemplate(templateName, language, order.customer_name, order.device_name, order.ticket_no);
  } catch {
    return json({ error: "بيانات قالب إشعار الجاهزية غير مكتملة." }, 400);
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: claim, error: claimError } = await admin
    .from("erp_whatsapp_maintenance_notifications")
    .upsert({
      owner_id: auth.user.id,
      maintenance_order_id: order.id,
      status: "processing",
    }, { onConflict: "owner_id,maintenance_order_id", ignoreDuplicates: true })
    .select("id")
    .maybeSingle();
  if (claimError) return json({ error: "تعذر حجز إشعار آمن في سجل المحاولات." }, 503);
  if (!claim?.id) return json({ status: "duplicate", error: "سبق تسجيل محاولة لهذا الأمر؛ لن نكرر الإرسال تلقائيًا." }, 409);

  const mark = async (status: "accepted" | "failed" | "unknown", code: string | null, messageId: string | null = null) => {
    const { error } = await admin.from("erp_whatsapp_maintenance_notifications").update({
      status,
      error_code: code,
      provider_message_id: messageId,
      accepted_at: status === "accepted" ? new Date().toISOString() : null,
      updated_at: new Date().toISOString(),
    }).eq("id", claim.id);
    if (error) console.error("Maintenance notification ledger update failed", error.message);
    return !error;
  };

  let response: Response;
  try {
    response = await fetchWithTimeout(`https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${waToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ messaging_product: "whatsapp", to, type: "template", template }),
    }, 20_000);
  } catch {
    await mark("unknown", "MESSAGE_RESULT_UNKNOWN");
    return json({ status: "unknown", error: "نتيجة الإرسال غير مؤكدة؛ منعنا إعادة المحاولة تلقائيًا." }, 202);
  }

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const code = String(payload?.error?.code || "MESSAGE_REJECTED").slice(0, 80);
    if (response.status >= 500) {
      await mark("unknown", code);
      return json({ status: "unknown", error: "واتساب لم يؤكد نتيجة الإرسال؛ لن نكررها تلقائيًا." }, 202);
    }
    await mark("failed", code);
    return json({ status: "failed", error: "واتساب رفض إشعار الجاهزية؛ راجع القالب المعتمد." }, 502);
  }

  const messageId = payload?.messages?.[0]?.id;
  if (typeof messageId !== "string") {
    await mark("unknown", "MISSING_PROVIDER_MESSAGE_ID");
    return json({ status: "unknown", error: "واتساب لم يرجع رقم تأكيد؛ تم إيقاف التكرار." }, 202);
  }
  if (!await mark("accepted", null, messageId)) {
    return json({ status: "unknown", error: "واتساب قبل الطلب لكن تعذر تحديث السجل؛ لا تعِد الإرسال." }, 202);
  }
  return json({ ok: true, status: "accepted", ticket_no: order.ticket_no });
});
