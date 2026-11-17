export type WhatsAppDeliveryStatus = "accepted" | "delivered" | "read" | "failed";

export async function verifyMetaSignature(
  rawBody: Uint8Array,
  signatureHeader: string | null,
  appSecret: string,
): Promise<boolean> {
  if (!signatureHeader || !/^sha256=[0-9a-f]{64}$/i.test(signatureHeader) || !appSecret) return false;
  const signature = new Uint8Array(
    (signatureHeader.slice(7).match(/.{2}/g) ?? []).map((part) => Number.parseInt(part, 16)),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return await crypto.subtle.verify("HMAC", key, signature, rawBody);
}

export function mapMetaStatus(value: unknown): WhatsAppDeliveryStatus | null {
  if (value === "sent") return "accepted";
  if (value === "delivered") return "delivered";
  if (value === "read") return "read";
  if (value === "failed") return "failed";
  return null;
}

export function extractInvoiceStatuses(payload: unknown): Array<{
  messageId: string;
  status: WhatsAppDeliveryStatus;
  errorCode: string | null;
}> {
  if (!payload || typeof payload !== "object") return [];
  const root = payload as Record<string, unknown>;
  if (root.object !== "whatsapp_business_account" || !Array.isArray(root.entry)) return [];
  const updates: Array<{ messageId: string; status: WhatsAppDeliveryStatus; errorCode: string | null }> = [];
  for (const entry of root.entry) {
    if (!entry || typeof entry !== "object" || !Array.isArray((entry as Record<string, unknown>).changes)) continue;
    for (const change of (entry as Record<string, unknown>).changes as unknown[]) {
      if (!change || typeof change !== "object") continue;
      const value = (change as Record<string, unknown>).value;
      if (!value || typeof value !== "object" || !Array.isArray((value as Record<string, unknown>).statuses)) continue;
      for (const statusItem of (value as Record<string, unknown>).statuses as unknown[]) {
        if (!statusItem || typeof statusItem !== "object") continue;
        const item = statusItem as Record<string, unknown>;
        const status = mapMetaStatus(item.status);
        if (typeof item.id !== "string" || !item.id || !status) continue;
        const errors = Array.isArray(item.errors) ? item.errors : [];
        const firstError = errors[0] && typeof errors[0] === "object"
          ? (errors[0] as Record<string, unknown>).code
          : null;
        updates.push({
          messageId: item.id,
          status,
          errorCode: status === "failed" && firstError !== null && firstError !== undefined
            ? String(firstError).slice(0, 80)
            : null,
        });
      }
    }
  }
  return updates;
}
