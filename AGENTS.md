# AGENTS.md

Operating instructions for automated contributors to Bedlam.

Read this before writing code. Read `docs/ARCHITECTURE.md` before making any design decision. The invariants in §2 below are not style preferences — several of them are unretrofittable, and violating one costs a rewrite rather than a refactor.

---

## 1. What Bedlam is

A multiplayer game engine targeting Windows, Linux, macOS, Android, iOS, and Web, built so that **64 concurrent players at full tick works on every one of them, including a phone and a browser**, and so that any of those targets can host the authoritative simulation.

The editor is not a separate application — it is the engine running in a client mode. Multiplayer is not a subsystem — it is the kernel.

Current state: **M0 in progress.** The build spine, schema/identity layer, wire codecs, world database and determinism harness exist; none of the ten M0 platform criteria in §4 are met, because every one of them needs a window, a device, or a network. See §4 for what is and is not done.

---

## 2. Invariants

Each of these is in `docs/ARCHITECTURE.md` §18. They are restated here as things to check before committing.

### Unretrofittable — violating these costs a rewrite

1. **No per-field metadata in archetype chunks.** Not CRDT metadata, not undo metadata, not authoring provenance, not replication bookkeeping. Metadata goes *beside* the database, never inside it. Rollback, replay, and save/load all depend on the packed layout.

   **Enforced, not merely stated** — `src/schema/storable.zig`. A type that belongs beside the database declares `pub const __no_component_store = {};`, and `assertStorable` rejects it recursively wherever component storage is generated. Recursion is the point: `field: UndoStamp` would be caught at review, and a struct three levels down that happens to contain one would not. The same walk rejects pointers (§5.2) and pointer-width integers, which are 64 bits on desktop and 32 on wasm32.

   If you need causality *in* state — §6's provenance sources make that pressure real — use `storable.CauseToken`. It is a pure function of `(tick, system, ordinal)`, so it names a cause without the engine attaching anything, and without depending on whether recording is switched on. A token that varied with instrumentation would make a metered run hash differently from a production one, and §6.3's metering would change what it measures.
2. **No durable ID derived from source order, declaration order, layout order, or symbol hash.** IDs are allocated from the checked-in registry. Removal tombstones permanently. See `docs/SCHEMA_AND_EVOLUTION.md`.
3. **The four state projections are not the same bytes.** Rollback pages, per-client replication baselines, save state, and replay logs derive from one schema and one change journal, and have four different representations. Do not "simplify" them into one.
4. **"Page" means an engine-owned logical block.** Never `mprotect`, never VM page protection, never remapping. It works on desktop and dies on Web.
5. **No editor-only object model.** The editor uses the same world database, replication layer, and transport as the game.

### Correctness and safety

6. **No custom cryptographic construction anywhere**, including the relay path. Standard AEAD, standard key agreement. If a task seems to need bespoke crypto, the design is wrong — stop and ask.
7. **No untrusted parsing or asset import in the engine process.** Out-of-process, hard limits, no network access.
8. **No unification of editor undo and netcode rollback.** They share vocabulary and nothing else.
9. **Simulation and prediction cadence never change.** Four governors exist (replication-rate, interpolation-delay, render-quality, presentation-rate); none of them touches tick rate.
10. **No general or implicit allocation from the engine allocator in the frame loop.**

### Design discipline

11. **No lowest-common-denominator renderer.** Capability profiles lower per-backend; do not flatten to WebGPU's feature set.
12. **No engine-owned shader IR.** Slang is used directly.
13. **No hand-written serializers** for ordinary replicated components. They are generated from the schema.
14. **No per-entity-per-tick script callbacks.** Script defines policy and reacts to events.
15. **No tick loop in a NIF.** Elixir orchestrates; Zig simulates.

---

## 3. Toolchain and conventions

**Zig, pinned.** Do not upgrade the compiler as part of an unrelated task — Zig is pre-1.0 and upgrades are their own scheduled work.

> **Current state.** `build.zig.zon` sets `minimum_zig_version = "0.16.0"`, which is a floor rather than a pin; the real pin is `ZIG_VERSION` in `.github/workflows/ci.yml`. The toolchain is **not** vendored and there is no `zig-quickjs-ng` dependency yet. Per-module optimization mode **is** enforced for the wire module (`ReleaseSafe`, since packet parse is the untrusted side of a trust boundary) and not yet for the rest. One dependency exists: [`fpz`](https://github.com/mattneel/fpz), pinned by commit, providing §7's fixed-point contract. See `docs/SPEC_DEFECTS.md` §13.

- **Allocator as parameter.** Every subsystem takes an allocator. No global allocator use, no hidden allocation.
- **Do not build hot paths on `std`.** `std` containers are fine for tooling and setup; simulation and rendering use engine containers.
- **`comptime` over codegen.** Serializers, bindings, archetype tables, and manifests are compile-time functions, not external generators.
- **Vendored C/C++ builds with `zig cc`** for every target. If a dependency cannot cross-compile this way, that is a reason to reconsider the dependency.
- **`use_llvm = true`** is required on any artifact linking `zig-quickjs-ng` under Zig 0.16. Keep the script host in its own artifact so the main binary keeps the fast self-hosted debug backend.

**Per-module optimization mode.** This is enforced in the build graph, not by convention:

| Module class | Mode |
|---|---|
| Packet parse, asset import, shader load, save/replay parse, mod payload, authoring transaction decode | `ReleaseSafe` |
| Simulation inner loops, render extraction, job scheduling | `ReleaseFast` |

**Testing.** Every parser gets a fuzz target. `--verify-determinism` runs in CI from the first tick loop. Cross-platform CI is not optional — a green build on one target proves nothing about the other five.

> **Both exist.** `zig build verify-determinism` runs on every native CI host; `zig build cross` re-runs the schema, wire, world and simulation suites on aarch64, s390x, arm and mips under qemu. The second is not redundant: all six shipping targets are little-endian and every one that executes tests is 64-bit, so the hosted matrix *structurally cannot* falsify a byte-order or word-size bug.

**Two CI tiers, and only one may speak about the floor.** Tier C (correctness) runs on every commit on hosted runners and is **inadmissible as evidence about P0 in either direction**. Tier M (measurement) runs on physical devices on a schedule and is the only tier `docs/BENCHMARK_CONTRACT.md` recognizes. Never cite a green matrix as a performance result. See `docs/CI_TIERS.md`.

---

## 4. Where to start

**M0 — platform spine.** Not a triangle. Exit criteria, all six targets, on physical devices, in CI:

- [ ] window and surface creation
- [ ] input and text forwarding
- [ ] audio callback and AudioWorklet ring
- [ ] network session establishment
- [ ] filesystem and asset read
- [ ] suspend and resume
- [ ] device loss and recovery
- [ ] Worker + OffscreenCanvas (Web)
- [ ] crash capture and symbolication
- [ ] package, sign, install, launch

Build the CI matrix before the second target. Six-platform CI added late is six-platform CI that never gets added.

**None of the ten are done.** Every one needs a window, an audio device, a socket or a package, and none of that exists yet. What exists is underneath them:

| Landed | Where |
|---|---|
| Build spine, eight target rows, cross gate | `build.zig`, `.github/workflows/ci.yml` |
| Stable identity, manifest, fingerprint, §10 checks 1–5/9/10 | `src/schema/` |
| Bounded reader, quantization, generated codecs | `src/wire/` |
| Generational entities, chunks, tables, CoW pages, journal | `src/world/` |
| Tick-keyed RNG, canonical hash, `--verify-determinism` | `src/sim/`, `src/world/hash.zig` |

Read that as "the kernel M1 needs is being built early because it can be verified without hardware", not as M0 progress.

The matrix exists: `.github/workflows/ci.yml` carries one row per target family, **including rows that do not yet pass.** Dark rows are expected-failing with a named blocker rather than absent, so lighting one is a build-graph change and not a CI restructure. Do not delete a dark row to make the matrix green — that is a scope change. Current row status and the reachability constraints on physical-device criteria are in `docs/CI_TIERS.md` §4–§6.

**M1 begins only after M0 is green on all six.** M1's exit gate is the §1 floor measured against `docs/BENCHMARK_CONTRACT.md`, and no renderer depth work happens before it passes.

---

## 5. Stop and ask

Open a discussion rather than proceeding when a task would:

- Require violating any invariant in §2, for any reason including "temporarily"
- Add a dependency that cannot cross-compile with `zig cc` to all six targets
- Introduce a second consistency model, a second world model, or a second serialization path
- Require custom cryptography, or weaken the relay trust boundary
- Change a benchmark parameter — entity census, content complexity, reference device tier, soak duration. These are the four levers that make "64" mean less than it says, and loosening one is a change to the product's ambition, not a benchmark adjustment.
- Move a requirement from the conformant profile to the compatibility profile
- Resolve an item marked **OPEN** in `docs/SCOPED_ROLLBACK.md` by implementation rather than by measurement

The last one matters most. `SCOPED_ROLLBACK.md` is a research brief, not a spec. An implementation that quietly picks an answer to an open question and buries it in code is worse than no implementation, because the decision becomes invisible.

---

## 6. Document map

| Question | Document |
|---|---|
| What is the design, and why | `docs/ARCHITECTURE.md` |
| Does it actually hit 64, and how is that proven | `docs/BENCHMARK_CONTRACT.md` |
| How do component IDs, wire formats, and migrations work | `docs/SCHEMA_AND_EVOLUTION.md` |
| What environment counts as conformant | `docs/CONFORMANCE_PROFILES.md` |
| How does scoped rollback work | `docs/SCOPED_ROLLBACK.md` — **unsolved, read the OPEN markers** |
| Which CI tier may make a performance claim | `docs/CI_TIERS.md` |
| What is known to be wrong with the spec | `docs/SPEC_DEFECTS.md` — **read before trusting a number** |

`ARCHITECTURE.md` §21 lists open questions at the architecture level. If a task touches one, say so in the PR rather than resolving it silently.

---

## 7. Commit and PR conventions

- One invariant-relevant change per PR. If a PR touches §2 material, say which invariant and why it holds.
- Benchmark-affecting changes report before/after numbers from `BENCHMARK_CONTRACT.md` measurement, not from a local micro-benchmark.
- Schema changes include the registry diff.
- No PR merges on a single-platform green build.
