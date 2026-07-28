// Verify the Web target in a real browser. `AGENTS.md` §4, M0 criterion 8.
//
// `check.mjs` runs the wasm module under Node and compares its digest to the native
// binary's. That is worth having and it is not criterion 8: Node has no Worker-with-
// OffscreenCanvas, no cross-origin isolation, and no browser event loop. §18.20's rule
// applies with full force here — a module that instantiates under Node is not a working
// Web target.
//
// So this launches Chrome headless against the COOP/COEP server and reads the verdict out
// of the DOM. `--dump-dom` is the only output channel a plain headless run gives, which is
// why the page writes its result into an element rather than to the console.
//
// Usage:  node tools/web/browser-check.mjs [path-to-native-binary]
//
// With a native binary, the browser digest is also compared against the native one — the
// same cross-architecture claim `check.mjs` makes, but measured on the target that
// actually ships.

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const root = new URL('.', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');

const CHROME_CANDIDATES = [
  process.env.CHROME,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
].filter(Boolean);

function findChrome() {
  for (const c of CHROME_CANDIDATES) if (existsSync(c)) return c;
  return null;
}

const types = {
  '.html': 'text/html; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
};

// Same headers as serve.mjs, inlined so the harness is one process. Without COOP/COEP the
// page is a COMPATIBILITY-profile deployment (CONFORMANCE_PROFILES.md §2) and anything
// measured on it is inadmissible — so a harness that forgot them would be reporting a
// result about the wrong profile.
function serve(port, onResult) {
  return new Promise((resolve) => {
    const server = createServer(async (req, res) => {
      const url = new URL(req.url, `http://localhost:${port}`);
      if (process.env.BC_DEBUG) console.log('REQ', req.method, url.pathname);

      // The page posts its verdict here when it has actually finished. See index.html for
      // why this is a POST rather than a DOM scrape.
      if (req.method === 'POST' && url.pathname === '/result') {
        let body = '';
        req.on('data', (d) => (body += d));
        req.on('end', () => {
          res.writeHead(204, { 'Cross-Origin-Opener-Policy': 'same-origin' }).end();
          try {
            onResult(JSON.parse(body));
          } catch (e) {
            onResult({ parseError: String(e), raw: body.slice(0, 400) });
          }
        });
        return;
      }

      const rel = url.pathname === '/' ? '/index.html' : url.pathname;
      const path = join(root, normalize(rel).replace(/^(\.\.[/\\])+/, ''));
      const headers = {
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp',
        'Cache-Control': 'no-store',
        'Content-Type': types[extname(path)] ?? 'application/octet-stream',
      };
      // Read BEFORE writing the head. Writing 200 and then discovering the file is
      // missing means the 404 path tries to set headers that are already on the wire.
      let body = null;
      try {
        body = await readFile(path);
      } catch {
        res.writeHead(404, headers).end('not found');
        return;
      }
      res.writeHead(200, headers).end(body);
    });
    server.listen(port, () => resolve(server));
  });
}

function runChrome(chrome, url) {
  // No `--virtual-time-budget`. It is the usual way to make a headless run deterministic,
  // and it does not fast-forward timers inside a WORKER — so the page gets cut off
  // mid-simulation and the harness reports its own impatience as a failure. Chrome instead
  // stays open until the page POSTs its verdict and the caller kills it.
  const args = [
    '--headless=new',
    '--disable-gpu',
    '--no-sandbox',
    '--disable-dev-shm-usage',
    '--no-first-run',
    '--disable-extensions',
    // Without this an AudioContext stays suspended until a user gesture, and a headless
    // run has no user — the worklet would never be asked for a quantum and criterion 3
    // would report "unsupported" on a browser that supports it perfectly well.
    '--autoplay-policy=no-user-gesture-required',
    `--user-data-dir=${join(root, '.chrome-profile')}`,
    url,
  ];
  const p = spawn(chrome, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  if (process.env.BC_DEBUG) p.stderr.on('data', (d) => process.stderr.write('CHROME ' + d));
  return p;
}

async function nativeDigest(bin) {
  return new Promise((resolve) => {
    const p = spawn(bin, ['--world-digest'], { stdio: ['ignore', 'pipe', 'ignore'] });
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.on('close', () => {
      const m = out.match(/digest\s+([0-9a-f]{64})/);
      resolve(m ? m[1] : null);
    });
    p.on('error', () => resolve(null));
  });
}

const chrome = findChrome();
if (!chrome) {
  // Not a failure: a machine with no browser cannot run this check, and pretending
  // otherwise would make the harness report a pass it did not earn.
  console.log('SKIP no Chrome or Edge found; set CHROME to a browser executable');
  process.exit(0);
}

const port = 8788 + Math.floor(process.hrtime()[1] % 200);

let resolveResult;
const resultPromise = new Promise((res) => (resolveResult = res));
const server = await serve(port, (r) => resolveResult(r));

let failed = false;
let child = null;

try {
  console.log(`browser: ${chrome}`);
  child = runChrome(chrome, `http://localhost:${port}/`);

  const timeout = new Promise((_, rej) =>
    setTimeout(() => rej(new Error('page did not report within 60s')), 60_000));
  const r = await Promise.race([resultPromise, timeout]);
  if (r.parseError) throw new Error(`${r.parseError}: ${r.raw}`);

  const check = (name, ok, detail) => {
    console.log(`${ok ? 'OK  ' : 'FAIL'} ${name.padEnd(28)} ${detail ?? ''}`);
    if (!ok) failed = true;
  };

  check('cross-origin isolated', r.isolated === true, String(r.isolated));

  if (!r.worker?.supported) {
    check('OffscreenCanvas', false, 'unsupported in this browser');
  } else if (r.worker.error) {
    check('worker', false, r.worker.error);
  } else {
    check('worker owns canvas', r.worker.offscreen === true, String(r.worker.offscreen));
    check('worker drew frames', r.worker.frames > 0, `${r.worker.frames} frames`);
    check('worker ticks', r.worker.ticks === 128, String(r.worker.ticks));
    check('worker live entities', r.worker.live === 64, String(r.worker.live));
    // Criterion 2: input crossed from the DOM into the worker and was consumed at a tick
    // boundary. Synthetic events, because a headless run has no user -- and an input path
    // nobody exercises is one that can be broken for months.
    const ink = r.worker.input ?? {};
    check('input reached the worker', (ink.keys ?? 0) >= 8, `keys=${ink.keys} text=${ink.text} wheel=${ink.wheel}`);

    // The real claim: two wasm instances in two JS realms, same digest.
    check('worker == main thread', r.worker.agrees === true, r.worker.digest);
  }

  // Criterion 3 on the Web. The worklet runs the same mixer as the native devices, so what
  // is verified here is the DEVICE: a real graph, a real 128-frame quantum, and audio that
  // is actually non-silent. "The worklet ran" and "the worklet produced audio" are
  // different claims and only the second one is the criterion.
  const au = r.audio ?? {};
  if (!au.supported) {
    check('AudioWorklet', false, 'unsupported in this browser');
  } else if (au.error) {
    check('audio worklet', false, au.error);
  } else {
    check('audio context running', au.state === 'running', String(au.state));
    check('worklet rendered blocks', (au.blocks ?? 0) > 0, `${au.blocks} blocks`);
    check('no silent blocks', (au.silentBlocks ?? 1) === 0, `${au.silentBlocks} silent`);
    check('voice active in worklet', (au.voices ?? 0) > 0, String(au.voices));
    check('mix did not clip', (au.clipped ?? 1) === 0, String(au.clipped));
  }

  const bin = process.argv[2];
  if (bin) {
    const nd = await nativeDigest(bin);
    check('browser == native', nd !== null && nd === r.digest, nd ?? 'native digest unreadable');
  } else {
    console.log('note: pass a native binary path to also compare against native');
  }

  console.log('');
  console.log(failed
    ? 'browser check FAILED'
    : 'Web target verified in a real browser: worker, canvas, input, audio worklet.');
} catch (e) {
  console.error(`browser check FAILED: ${e.message}`);
  failed = true;
} finally {
  if (child) child.kill();
  server.close();
}

process.exit(failed ? 1 : 0);
