export function buildMaintenanceReadyTemplate(
  templateName: string,
  language: string,
  customerName: string,
  deviceName: string,
  ticketNo: string,
) {
  const values = [templateName, language, customerName, deviceName, ticketNo];
  if (values.some((value) => typeof value !== "string" || !value.trim())) {
    throw new Error("Maintenance WhatsApp template fields are required.");
  }
  return {
    name: templateName.trim(),
    language: { code: language.trim() },
    components: [{
      type: "body",
      parameters: [
        { type: "text", text: customerName.trim().slice(0, 120) },
        { type: "text", text: deviceName.trim().slice(0, 120) },
        { type: "text", text: ticketNo.trim().slice(0, 80) },
      ],
    }],
  };
}
