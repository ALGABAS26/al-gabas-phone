import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { extractInvoiceStatuses, mapMetaStatus, verifyMetaSignature } from "../_shared/meta-webhook.ts";

Deno.test("Meta signature accepts the exact signed bytes", async () => {
  const secret = "local-test-secret";
  const body = new TextEncoder().encode('{"object":"whatsapp_business_account"}');
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
  const hex = [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
  assertEquals(await verifyMetaSignature(body, `sha256=${hex}`, secret), true);
  assertEquals(await verifyMetaSignature(new TextEncoder().encode("{}"), `sha256=${hex}`, secret), false);
  assertEquals(await verifyMetaSignature(body, "sha256=bad", secret), false);
});

Deno.test("Meta statuses map to supported ledger states", () => {
  assertEquals(mapMetaStatus("sent"), "accepted");
  assertEquals(mapMetaStatus("delivered"), "delivered");
  assertEquals(mapMetaStatus("read"), "read");
  assertEquals(mapMetaStatus("failed"), "failed");
  assertEquals(mapMetaStatus("deleted"), null);
});

Deno.test("extract only valid WhatsApp status updates", () => {
  const payload = {
    object: "whatsapp_business_account",
    entry: [{ changes: [{ value: { statuses: [
      { id: "wamid.1", status: "delivered" },
      { id: "wamid.2", status: "failed", errors: [{ code: 131026 }] },
      { id: "", status: "read" },
      { id: "wamid.3", status: "unknown" },
    ] } }] }],
  };
  assertEquals(extractInvoiceStatuses(payload), [
    { messageId: "wamid.1", status: "delivered", errorCode: null },
    { messageId: "wamid.2", status: "failed", errorCode: "131026" },
  ]);
  assertEquals(extractInvoiceStatuses({ object: "other", entry: [] }), []);
});
