export function isWhatsAppSendEnabled(value: string | undefined): boolean {
  return value === "true";
}

export function normalizeEgyptPhone(value: string): string {
  let digits = value.replace(/\D/g, "");
  if (digits.startsWith("00")) digits = digits.slice(2);
  if (digits.startsWith("0")) digits = "20" + digits.slice(1);
  else if (digits.length === 10 && digits.startsWith("1")) digits = "20" + digits;
  if (!/^20(10|11|12|15)\d{8}$/.test(digits)) {
    throw new Error("رقم هاتف العميل غير صالح لواتساب مصر.");
  }
  return digits;
}

export function decodePngBase64(value: string): Uint8Array {
  const raw = value.replace(/^data:image\/png;base64,/, "");
  if (!raw || raw.length > 7_000_000) throw new Error("صورة الفاتورة غير صالحة أو أكبر من الحد المسموح.");
  let binary: string;
  try {
    binary = atob(raw);
  } catch {
    throw new Error("ترميز صورة الفاتورة غير صالح.");
  }
  if (binary.length > 5 * 1024 * 1024) throw new Error("حجم صورة الفاتورة يجب ألا يتجاوز 5 ميجابايت.");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (!signature.every((byte, i) => bytes[i] === byte)) throw new Error("يجب إرسال صورة PNG صحيحة.");
  return bytes;
}

export async function fetchWithTimeout(
  input: RequestInfo | URL,
  init: RequestInit,
  timeoutMs = 20_000,
): Promise<Response> {
  return await fetch(input, {
    ...init,
    signal: AbortSignal.timeout(timeoutMs),
  });
}

export function decodePdfBase64(value: string): Uint8Array {
  const raw = value.replace(/^data:application\/pdf;base64,/, "");
  if (!raw || raw.length > 11_000_000) throw new Error("ملف PDF غير صالح أو أكبر من الحد المسموح.");
  let binary: string;
  try {
    binary = atob(raw);
  } catch {
    throw new Error("ترميز ملف PDF غير صالح.");
  }
  if (binary.length > 8 * 1024 * 1024) throw new Error("حجم ملف PDF يجب ألا يتجاوز 8 ميجابايت.");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const header = new TextDecoder().decode(bytes.slice(0, 5));
  const tail = new TextDecoder().decode(bytes.slice(Math.max(0, bytes.length - 1024)));
  if (header !== "%PDF-" || !tail.includes("%%EOF")) {
    throw new Error("يجب إرسال ملف PDF صحيح.");
  }
  return bytes;
}
