(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.AGInvoicePdf = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  function ascii(value) {
    return new TextEncoder().encode(value);
  }

  function join(parts) {
    const size = parts.reduce((total, part) => total + part.length, 0);
    const output = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) {
      output.set(part, offset);
      offset += part.length;
    }
    return output;
  }

  function dataUrlBytes(dataUrl) {
    const comma = dataUrl.indexOf(",");
    if (comma < 0) throw new Error("Canvas did not return a data URL.");
    const binary = atob(dataUrl.slice(comma + 1));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function buildInvoicePdf(canvas, documentRef) {
    if (!canvas || !Number.isFinite(canvas.width) || !Number.isFinite(canvas.height) ||
        canvas.width < 1 || canvas.height < 1) {
      throw new Error("Invoice canvas is empty.");
    }
    const doc = documentRef || (typeof document !== "undefined" ? document : null);
    if (!doc) throw new Error("Canvas document API is unavailable.");

    const pageWidth = 595.28, pageHeight = 841.89, margin = 28;
    const contentWidth = pageWidth - margin * 2, contentHeight = pageHeight - margin * 2;
    const sourcePageHeight = Math.max(1, Math.floor(canvas.width * contentHeight / contentWidth));
    const pages = [];

    for (let y = 0; y < canvas.height; y += sourcePageHeight) {
      const height = Math.min(sourcePageHeight, canvas.height - y);
      const pageCanvas = doc.createElement("canvas");
      pageCanvas.width = canvas.width;
      pageCanvas.height = height;
      const context = pageCanvas.getContext("2d");
      if (!context) throw new Error("Could not create an invoice PDF page.");
      context.drawImage(canvas, 0, y, canvas.width, height, 0, 0, canvas.width, height);
      pages.push({
        width: canvas.width,
        height,
        jpeg: dataUrlBytes(pageCanvas.toDataURL("image/jpeg", 0.9)),
      });
    }

    const objectCount = 3 + pages.length * 3;
    const objects = new Array(objectCount);
    objects[1] = ascii("<< /Type /Catalog /Pages 2 0 R >>");
    const kids = pages.map((_, index) => `${3 + index * 3} 0 R`).join(" ");
    objects[2] = ascii(`<< /Type /Pages /Kids [${kids}] /Count ${pages.length} >>`);

    pages.forEach((page, index) => {
      const pageId = 3 + index * 3, contentId = pageId + 1, imageId = pageId + 2;
      const drawHeight = contentWidth * page.height / page.width;
      const stream = ascii(
        `q\n${contentWidth} 0 0 ${drawHeight} ${margin} ${pageHeight - margin - drawHeight} cm\n/Im0 Do\nQ`,
      );
      objects[pageId] = ascii(
        `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageWidth} ${pageHeight}] /Resources << /XObject << /Im0 ${imageId} 0 R >> >> /Contents ${contentId} 0 R >>`,
      );
      objects[contentId] = join([
        ascii(`<< /Length ${stream.length} >>\nstream\n`),
        stream,
        ascii("\nendstream"),
      ]);
      objects[imageId] = join([
        ascii(
          `<< /Type /XObject /Subtype /Image /Width ${page.width} /Height ${page.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${page.jpeg.length} >>\nstream\n`,
        ),
        page.jpeg,
        ascii("\nendstream"),
      ]);
    });

    const chunks = [ascii("%PDF-1.4\n%AGINVOICE\n")];
    const offsets = new Array(objectCount).fill(0);
    let position = chunks[0].length;

    for (let id = 1; id < objectCount; id++) {
      const header = ascii(`${id} 0 obj\n`), footer = ascii("\nendobj\n");
      offsets[id] = position;
      chunks.push(header, objects[id], footer);
      position += header.length + objects[id].length + footer.length;
    }

    const xrefOffset = position;
    const xref = [`xref\n0 ${objectCount}\n`, "0000000000 65535 f \n"];
    for (let id = 1; id < objectCount; id++) {
      xref.push(`${String(offsets[id]).padStart(10, "0")} 00000 n \n`);
    }
    chunks.push(
      ascii(xref.join("")),
      ascii(`trailer\n<< /Size ${objectCount} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`),
    );
    return new Blob(chunks, { type: "application/pdf" });
  }

  async function blobToBase64(blob) {
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(i, Math.min(i + 0x8000, bytes.length)));
    }
    return btoa(binary);
  }

  return { buildInvoicePdf, blobToBase64 };
});
