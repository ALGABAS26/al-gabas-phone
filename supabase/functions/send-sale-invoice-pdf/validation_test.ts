import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { decodePdfBase64 } from "../_shared/whatsapp-validation.ts";

Deno.test("PDF upload accepts a valid bounded PDF", () => {
  const bytes = new TextEncoder().encode("%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF");
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const decoded = decodePdfBase64(btoa(binary));
  assertEquals(new TextDecoder().decode(decoded.slice(0, 5)), "%PDF-");
});

Deno.test("PDF upload rejects non-PDF and malformed base64", () => {
  assertThrows(() => decodePdfBase64(btoa("not a pdf")), Error, "PDF");
  assertThrows(() => decodePdfBase64("%%%"), Error, "ترميز");
});

Deno.test("PDF upload rejects oversized payloads", () => {
  assertThrows(() => decodePdfBase64("A".repeat(11_000_001)), Error, "أكبر");
});
