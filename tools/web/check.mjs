// wasm32 conformance probe: does the browser build agree with the native one?
//
// `ARCHITECTURE.md` §7: "Bit-exact cross-architecture float determinism across
// x86 / ARM / wasm32 is folklore. Don't design around it." The engine's answer is to
// design so that agreement is *constructed* — fixed point inside the rollback boundary,
// integer-only quantization, explicit little-endian hashing. This is the check that says
// whether the construction worked on the target where it is hardest: 32-bit, a different
// ISA, and a different compiler backend.
//
// Usage:  node check.mjs <path-to-native-binary>
// Exits non-zero on disagreement.

import { readFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);

const SEED = 0xbed1a3;
const ENTITIES = 64;
const TICKS = 128;

async function wasmDigest(path) {
  const bytes = await readFile(path);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const e = instance.exports;
  const hex = (p, l) =>
    new TextDecoder().decode(new Uint8Array(e.memory.buffer).subarray(p, p + l));

  if (e.bedlamInit(SEED, 0, ENTITIES) !== 0) throw new Error('bedlamInit failed');
  if (e.bedlamStep(SEED, 0, TICKS) !== 0) throw new Error('bedlamStep failed');

  return {
    fingerprint: hex(e.bedlamFingerprint(), 64),
    digest: hex(e.bedlamWorldDigest(), e.bedlamDigestLen()),
    ticks: e.bedlamTick(),
    live: e.bedlamLiveCount(),
    bytes: bytes.length,
  };
}

async function nativeDigest(bin) {
  const { stdout } = await run(bin, ['--world-digest']);
  // Anchored to the start of a line and to a whole word. An unanchored /digest\s+(\S+)/
  // matches inside the "world-digest" heading and captures the next token instead —
  // which reports a mismatch between two identical digests and sends you looking for an
  // endianness bug that is not there.
  const field = (name) => {
    const m = stdout.match(new RegExp(`^\\s*${name}\\s+(\\S+)\\s*$`, 'm'));
    if (!m) throw new Error(`native output missing '${name}':\n${stdout}`);
    return m[1];
  };
  return {
    fingerprint: field('fingerprint'),
    digest: field('digest'),
    ticks: Number(field('ticks')),
    live: Number(field('live')),
  };
}

const nativeBin = process.argv[2];
if (!nativeBin) {
  console.error('usage: node check.mjs <path-to-native-binary>');
  process.exit(2);
}

const wasm = await wasmDigest(new URL('./bedlam_engine.wasm', import.meta.url));
const native = await nativeDigest(nativeBin);

const rows = [
  ['schema fingerprint', native.fingerprint, wasm.fingerprint],
  ['world digest', native.digest, wasm.digest],
  ['ticks', String(native.ticks), String(wasm.ticks)],
  ['live entities', String(native.live), String(wasm.live)],
];

let failed = false;
console.log(`wasm module: ${wasm.bytes} bytes, ${TICKS} ticks, ${ENTITIES} entities\n`);
for (const [label, a, b] of rows) {
  const ok = a === b;
  if (!ok) failed = true;
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${label.padEnd(20)} ${a}`);
  if (!ok) console.log(`     ${''.padEnd(20)} ${b}  <- wasm32`);
}

if (failed) {
  console.error(
    '\nwasm32 disagrees with native. ARCHITECTURE.md §7 says cross-architecture agreement\n' +
    'is constructed rather than assumed — something in the construction is host-dependent.\n' +
    'Look first at: a float that reached hashed state, a @bitCast that inherited host byte\n' +
    'order, or a usize whose width differs at 32 bits.',
  );
  process.exit(1);
}
console.log('\nwasm32 and native agree bit-for-bit.');
