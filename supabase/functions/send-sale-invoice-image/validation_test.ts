import { decodePngBase64, normalizeEgyptPhone } from "../_shared/whatsapp-validation.ts";

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) throw new Error(`Expected ${String(expected)}, got ${String(actual)}`);
}
function assertThrows(fn: () => unknown): void {
  let threw = false;
  try { fn(); } catch { threw = true; }
  if (!threw) throw new Error("Expected function to throw");
}

Deno.test("normalizes Egyptian mobile formats", () => {
  assertEquals(normalizeEgyptPhone("01012345678"), "201012345678");
  assertEquals(normalizeEgyptPhone("+20 11 1234 5678"), "201112345678");
  assertEquals(normalizeEgyptPhone("00201212345678"), "201212345678");
  assertEquals(normalizeEgyptPhone("15 1234 5678"), "201512345678");
});

Deno.test("rejects unsupported or malformed Egyptian numbers", () => {
  for (const value of ["0123456789", "02012345678", "0101234567", "abcdefgh", ""]) {
    assertThrows(() => normalizeEgyptPhone(value));
  }
});

Deno.test("accepts a PNG signature with an optional data URL prefix", () => {
  const signature = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
  const encoded = btoa(String.fromCharCode(...signature));
  assertEquals(decodePngBase64(encoded).join(","), signature.join(","));
  assertEquals(decodePngBase64("data:image/png;base64," + encoded).join(","), signature.join(","));
});

Deno.test("rejects non-PNG and invalid base64 payloads", () => {
  assertThrows(() => decodePngBase64(btoa("not a png")));
  assertThrows(() => decodePngBase64("%%%"));
  assertThrows(() => decodePngBase64(""));
});
