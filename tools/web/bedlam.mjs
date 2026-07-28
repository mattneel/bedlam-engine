// Bootstrap for the wasm32 build.
//
// `ARCHITECTURE.md` §2 budgets ~2k lines of TypeScript "generated from comptime
// declarations" for this. This is the hand-written seed of that: it reads sizes from the
// module rather than duplicating them, because §18.4 forbids duplicated definitions and a
// hand-copied constant in JavaScript is exactly that.
//
// Deliberately no imports supplied to the module. The engine is freestanding — if it ever
// needs a host function, instantiation fails loudly here rather than the module silently
// acquiring a dependency on the browser.

export async function boot(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`fetch ${url}: ${res.status}`);
  const bytes = await res.arrayBuffer();

  const { instance } = await WebAssembly.instantiate(bytes, {});
  const e = instance.exports;
  const mem = () => new Uint8Array(e.memory.buffer);

  // Read a hex string the module left in linear memory. Zero-copy in the sense that
  // matters: the engine never allocates a copy to hand out, the page reads the bytes.
  const readHex = (ptr, len) => {
    if (ptr === 0) throw new Error('engine returned a null pointer');
    return new TextDecoder().decode(mem().subarray(ptr, ptr + len));
  };

  const check = (code, what) => {
    if (code !== 0) throw new Error(`${what} failed with ${code}`);
  };

  return {
    componentCount: () => e.bedlamComponentCount(),
    transformBits: () => e.bedlamTransformBits(),
    fingerprint: () => readHex(e.bedlamFingerprint(), 64),

    init(seed, entities) {
      const lo = Number(seed & 0xffffffffn);
      const hi = Number((seed >> 32n) & 0xffffffffn);
      check(e.bedlamInit(lo, hi, entities), 'bedlamInit');
    },

    step(seed, ticks) {
      const lo = Number(seed & 0xffffffffn);
      const hi = Number((seed >> 32n) & 0xffffffffn);
      check(e.bedlamStep(lo, hi, ticks), 'bedlamStep');
    },

    digest: () => readHex(e.bedlamWorldDigest(), e.bedlamDigestLen()),
    tick: () => e.bedlamTick(),
    liveCount: () => e.bedlamLiveCount(),
  };
}
