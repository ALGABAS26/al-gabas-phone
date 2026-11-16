import { buildMaintenanceReadyTemplate } from "../_shared/maintenance-ready.ts";
import { normalizeEgyptPhone } from "../_shared/whatsapp-validation.ts";

Deno.test("builds the approved maintenance-ready template parameters", () => {
  const template = buildMaintenanceReadyTemplate("maintenance_ready", "ar", "أحمد", "iPhone 13", "REP-20261117-12345");
  if (template.name !== "maintenance_ready") throw new Error("Wrong template name");
  const parameters = template.components[0].parameters;
  if (parameters.length !== 3 || parameters[0].text !== "أحمد" || parameters[2].text !== "REP-20261117-12345") {
    throw new Error("Template parameters do not match the repair order");
  }
});

Deno.test("rejects missing maintenance-ready template fields", () => {
  let threw = false;
  try { buildMaintenanceReadyTemplate("maintenance_ready", "ar", "", "iPhone", "REP-1"); } catch { threw = true; }
  if (!threw) throw new Error("Expected missing customer name to be rejected");
});

Deno.test("uses the existing Egyptian phone validation", () => {
  if (normalizeEgyptPhone("01012345678") !== "201012345678") throw new Error("Phone normalization failed");
});
