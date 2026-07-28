// Static server for the wasm32 probe, with cross-origin isolation.
//
// `CONFORMANCE_PROFILES.md` §2: "A build served without COOP/COEP headers is a
// compatibility-profile deployment regardless of the browser's capability. This is the
// case most likely to be measured accidentally and reported as a conformant result."
//
// So the headers are not optional decoration here — without them the page is not testing
// the conformant profile, and §5 makes anything measured on it inadmissible. The probe
// reports `crossOriginIsolated` for the same reason: so the profile is observed rather
// than assumed.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const root = new URL('.', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const port = Number(process.env.PORT ?? 8787);

const types = {
  '.html': 'text/html; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
};

createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);
  const rel = url.pathname === '/' ? '/index.html' : url.pathname;
  const path = join(root, normalize(rel).replace(/^(\.\.[/\\])+/, ''));

  const headers = {
    // The two that decide conformant vs compatibility.
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cache-Control': 'no-store',
    'Content-Type': types[extname(path)] ?? 'application/octet-stream',
  };

  try {
    res.writeHead(200, headers).end(await readFile(path));
  } catch {
    res.writeHead(404, headers).end('not found');
  }
}).listen(port, () => {
  console.log(`serving ${root} on http://localhost:${port} (COOP/COEP set)`);
});
