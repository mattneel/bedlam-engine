// The simulation worker. `ARCHITECTURE.md` §4.1, M0 criterion 8.
//
// The main thread owns nothing but the DOM. The simulation runs here, and the canvas is
// transferred here as an `OffscreenCanvas`, so a slow frame on the main thread cannot
// stall a tick and a slow tick cannot stall the page. `CONFORMANCE_PROFILES.md` §4 says
// simulation cadence does not degrade in any profile, and on the Web that is not a
// scheduling policy — it is a thread-ownership decision, because the main thread is shared
// with layout, GC, and whatever else the embedding page is doing.
//
// **Nothing here converts fixed-point to float on the engine's behalf.** `bedlamPositions`
// hands over raw i64 halves and the conversion happens at the point of drawing, which is
// the only place a rounding difference cannot reach the simulation (§7).

let wasm = null;
let canvas = null;
let ctx = null;
let ticks = 0;

// M0 criterion 2 on the Web. Input events reach the MAIN thread — the DOM owns them and
// an OffscreenCanvas cannot listen — so they are forwarded here and queued.
//
// **Queued, not applied on arrival.** A message can land at any point in the worker's
// event loop, including between two ticks of the same frame. Applying it immediately would
// make the tick at which an input takes effect depend on message-delivery timing, and §7's
// determinism claim is that a tick is a function of its inputs — which requires the input
// set for a tick to be decided by the tick boundary, not by the scheduler.
const input_queue = [];
const input_seen = { keys: 0, text: 0, pointer: 0, wheel: 0 };

function drainInput() {
  // Drained whole at a tick boundary. The counts are what the harness checks: an input
  // path that silently drops events is indistinguishable from one nobody exercised.
  while (input_queue.length > 0) {
    const e = input_queue.shift();
    switch (e.kind) {
      case 'key_down': case 'key_up': input_seen.keys += 1; break;
      case 'text': input_seen.text += 1; break;
      case 'pointer': input_seen.pointer += 1; break;
      case 'wheel': input_seen.wheel += 1; break;
    }
  }
}

const ONE = 2 ** 24; // Q40.24

function post(type, extra) {
  self.postMessage({ type, ...extra });
}

async function boot(url) {
  const bytes = await (await fetch(url)).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {});
  wasm = instance.exports;
  return wasm;
}

function digestHex() {
  // `bedlamWorldDigest` returns a pointer to the digest ALREADY RENDERED as 64 hex
  // characters — the same convention `bedlamFingerprint` uses. Hex-encoding those bytes
  // again produces 128 characters that look almost right, which is exactly the kind of
  // mismatch that reads as a determinism failure rather than a decoding one.
  const ptr = wasm.bedlamWorldDigest();
  const len = wasm.bedlamDigestLen();
  return new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, ptr, len));
}

function fingerprintHex() {
  const ptr = wasm.bedlamFingerprint();
  if (ptr === 0) return '';
  return new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, ptr, 64));
}

function draw() {
  if (!ctx) return;
  const ptr = wasm.bedlamPositions();
  const words = wasm.bedlamPositionWords();
  if (ptr === 0 || words === 0) return;

  // A fresh view every frame: the wasm memory can be resized by a growth in the module,
  // and a cached view over a detached buffer reads zeros silently rather than throwing.
  const raw = new Int32Array(wasm.memory.buffer, ptr, words);

  const w = canvas.width;
  const h = canvas.height;
  ctx.fillStyle = '#0b0d10';
  ctx.fillRect(0, 0, w, h);
  ctx.fillStyle = '#7fd1ff';

  for (let i = 0; i < words; i += 4) {
    // Reassemble the i64 from its halves, then convert here — not in the engine.
    const x = (raw[i] >>> 0) / ONE + raw[i + 1] * (2 ** 32 / ONE);
    const y = (raw[i + 2] >>> 0) / ONE + raw[i + 3] * (2 ** 32 / ONE);
    const px = w / 2 + x * 4;
    const py = h / 2 + y * 4;
    if (px >= 0 && px < w && py >= 0 && py < h) ctx.fillRect(px - 1.5, py - 1.5, 3, 3);
  }
}

// An exception inside an async message handler is an unhandled REJECTION, which does not
// fire the page's `worker.onerror`. Without these the page simply waits forever and the
// harness reports a timeout — a symptom that points at the network or the browser rather
// than at the three lines that actually threw.
self.onerror = (e) => post('failed', { error: `onerror: ${e.message ?? e}` });
self.onunhandledrejection = (e) => post('failed', { error: `rejection: ${e.reason}` });

self.onmessage = async (e) => {
  const msg = e.data;

  if (msg.type === 'input') {
    input_queue.push(msg.event);
    return;
  }

  if (msg.type === 'start') {
    try {
      await start(msg);
    } catch (err) {
      post('failed', { error: `${err}
${err?.stack ?? ''}` });
    }
  }
};

async function start(msg) {
  {
    try {
      await boot(msg.wasmUrl);
    } catch (err) {
      post('failed', { error: String(err) });
      return;
    }

    if (msg.canvas) {
      canvas = msg.canvas;
      ctx = canvas.getContext('2d');
    }

    const ok = wasm.bedlamInit(msg.seedLo >>> 0, msg.seedHi >>> 0, msg.entities);
    if (ok !== 0) {
      post('failed', { error: `bedlamInit returned ${ok}` });
      return;
    }

    post('ready', {
      fingerprint: fingerprintHex(),
      entities: wasm.bedlamLiveCount(),
      // Reported, not assumed: a worker that got no canvas is a worker that is not
      // testing criterion 8, and the harness must be able to tell.
      offscreen: ctx !== null,
    });

    const budget = msg.ticks;
    const perFrame = 8;
    const loop = () => {
      if (ticks >= budget) {
        post('done', {
          ticks: wasm.bedlamTick(),
          live: wasm.bedlamLiveCount(),
          digest: digestHex(),
          frames: framesDrawn,
          input: { ...input_seen },
        });
        return;
      }
      // Inputs are consumed at the tick boundary, before the step that will observe them.
      drainInput();
      wasm.bedlamStep(msg.seedLo >>> 0, msg.seedHi >>> 0, perFrame);
      ticks += perFrame;
      draw();
      framesDrawn += 1;
      // `requestAnimationFrame` does not exist in a worker without an OffscreenCanvas
      // presenting to a visible surface, and in a headless run it may never fire at all.
      // `setTimeout(0)` yields to the event loop without depending on a frame callback,
      // which is what makes this harness work headless as well as on screen.
      setTimeout(loop, 0);
    };
    let framesDrawn = 0;
    loop();
  }
}
