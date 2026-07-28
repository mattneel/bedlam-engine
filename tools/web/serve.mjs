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

  // Read BEFORE writing the head.
  //
  // Writing 200 and then discovering the file is missing means the catch tries to set
  // headers already on the wire, which throws ERR_HTTP_HEADERS_SENT — an uncaught
  // exception in a request handler, which kills the whole server. Chrome asks for
  // /favicon.ico on every page load, so this fired on the FIRST request and the next
  // fetch (the worker module) failed with no diagnostic at all. It cost an hour of
  // looking at a worker that was never broken.
  let body = null;
  try {
    body = await readFile(path);
  } catch {
    res.writeHead(404, headers).end('not found');
    return;
  }
  res.writeHead(200, headers).end(body);
}).listen(port, () => {
  console.log(`serving ${root} on http://localhost:${port} (COOP/COEP set)`);
});
