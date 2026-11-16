import { cp, mkdir, rm, writeFile } from "node:fs/promises";

const output = new URL("../desktop-dist/", import.meta.url);
const accounting = new URL("../accounting/", import.meta.url);
const config = new URL("../config.js", import.meta.url);

await rm(output, { recursive: true, force: true });
await mkdir(new URL("accounting/", output), { recursive: true });
await cp(accounting, new URL("accounting/", output), { recursive: true });
await cp(config, new URL("config.js", output));
await writeFile(new URL("index.html", output), [
  "<!doctype html>",
  '<html lang="ar" dir="rtl">',
  '<meta charset="utf-8">',
  '<meta http-equiv="refresh" content="0;url=accounting/">',
  "<title>AG System</title>",
  "<body>جاري تشغيل AG System...</body>",
  "</html>",
].join("\n"));
console.log("Prepared desktop-dist with accounting UI and root Supabase config.");
