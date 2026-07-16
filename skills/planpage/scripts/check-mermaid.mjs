#!/usr/bin/env node
// check-mermaid.mjs <file.html> — validate every <pre class="mermaid"> block
// with the real mermaid parser before the page is uploaded.
//
// Run from a directory whose node_modules contains mermaid + happy-dom
// (planpage.sh copies this file into its cache dir and installs them there).
//
// Exit codes: 0 = all blocks valid (or none found)
//             1 = at least one block failed to parse (errors on stderr)
//             2 = validator infrastructure problem (missing deps, bad args)
import { readFileSync } from "node:fs";

const file = process.argv[2];
if (!file) {
  console.error("usage: check-mermaid.mjs <file.html>");
  process.exit(2);
}
const html = readFileSync(file, "utf8");

// Entities must be decoded the way a browser's textContent would,
// since that is exactly what mermaid receives at render time.
// &amp; is decoded last so "&amp;lt;" round-trips correctly.
function decode(s) {
  return s
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

const blocks = [];
const re = /<pre\b[^>]*\bclass="[^"]*\bmermaid\b[^"]*"[^>]*>([\s\S]*?)<\/pre>/gi;
let m;
while ((m = re.exec(html))) {
  blocks.push({
    line: html.slice(0, m.index).split("\n").length,
    text: decode(m[1]),
  });
}
if (blocks.length === 0) process.exit(0);

// mermaid's module init needs a DOM (DOMPurify hooks); happy-dom provides one
let mermaid;
try {
  const { Window } = await import("happy-dom");
  const win = new Window();
  globalThis.window = win;
  globalThis.document = win.document;
  globalThis.DOMParser = win.DOMParser;
  ({ default: mermaid } = await import("mermaid"));
} catch (e) {
  console.error(`check-mermaid: cannot load validator: ${e.message}`);
  process.exit(2);
}

let failed = 0;
for (let i = 0; i < blocks.length; i++) {
  const b = blocks[i];
  try {
    await mermaid.parse(b.text);
  } catch (e) {
    failed++;
    console.error(`mermaid block ${i + 1} of ${blocks.length} (starts at line ${b.line} of the fragment) failed to parse:`);
    console.error(String(e.message ?? e).replace(/^/gm, "  "));
    console.error("  block source:");
    console.error(b.text.replace(/^\n+|\s+$/g, "").replace(/^/gm, "  | "));
  }
}
if (failed) process.exit(1);
console.error(`mermaid: ${blocks.length} block(s) parsed OK`);
process.exit(0);
