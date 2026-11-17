const test = require("node:test");
const assert = require("node:assert/strict");
const { buildInvoicePdf, blobToBase64 } = require("../../accounting/pdf-builder.js");

const tinyJpeg = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD6pooooA//2Q==";

function fakeDocument() {
  let drawn = 0;
  return {
    get drawnPages() { return drawn; },
    createElement(name) {
      assert.equal(name, "canvas");
      return {
        width: 0,
        height: 0,
        getContext() {
          return { drawImage() { drawn++; } };
        },
        toDataURL(type) {
          assert.equal(type, "image/jpeg");
          return `data:image/jpeg;base64,${tinyJpeg}`;
        },
      };
    },
  };
}

test("builds a valid multi-page A4 PDF with correct xref offsets", async () => {
  const doc = fakeDocument();
  const pdf = buildInvoicePdf({ width: 1200, height: 4000 }, doc);
  assert.equal(pdf.type, "application/pdf");
  const bytes = Buffer.from(await pdf.arrayBuffer());
  const source = bytes.toString("latin1");
  assert.ok(source.startsWith("%PDF-1.4"));
  assert.match(source, /\/Count 3\b/);
  assert.equal((source.match(/\/Type \/Page\b/g) || []).length, 3);
  assert.equal(doc.drawnPages, 3);
  const start = Number(source.match(/startxref\n(\d+)\n%%EOF/)[1]);
  assert.equal(source.slice(start, start + 4), "xref");
  const encoded = await blobToBase64(pdf);
  assert.ok(Buffer.from(encoded, "base64").equals(bytes));
});

test("rejects an empty invoice canvas", () => {
  assert.throws(() => buildInvoicePdf({ width: 0, height: 0 }, fakeDocument()), /empty/i);
});
