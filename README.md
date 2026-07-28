# Bedlam

A multiplayer game engine for Windows, Linux, macOS, Android, iOS, and Web.

**64 concurrent players at full tick on every one of them** — including a thermally-throttled phone and a browser tab. Any conformant target can host the authoritative simulation. The editor is the engine running in a client mode, so collaborative editing is the replication layer rather than a subsystem, and 64 concurrent editors is the same gate as 64 concurrent players.

The name states the design condition: 64 players, full destruction, vehicles, running on hardware that has no business running it. Bedlam, metered. Every hard decision here is about bounding chaos rather than avoiding it.

**Status: M0 in progress.** The specification is complete and the platform spine is being
built against it. What follows is what has been *run*, not what compiles — `ARCHITECTURE.md`
§18.20 is explicit that a green build is not a working target, so every claim below has a
command that demonstrates it.

| M0 criterion | Where it holds |
|---|---|
| 1 · window and surface | Windows (Win32) · Linux (X11) · Web (OffscreenCanvas) |
| 2 · input and text | Windows · Linux · Web (forwarded to the worker) |
| 3 · audio device | Windows (WASAPI) · Linux (PulseAudio) · Web (AudioWorklet) |
| 4 · network session | handshake, ack window and UDP transport — **no encryption yet** |
| 5 · filesystem and assets | portable, capability-bounded |
| 6 · suspend and resume | Windows · Linux |
| 7 · device loss | Windows; Linux has no device-loss source until there is a renderer |
| 8 · Worker + OffscreenCanvas | Web, verified in headless Chrome per commit |
| 9 · crash capture | portable capture with build/schema/tick/seed context |
| 10 · package | reproducible archive; **unsigned**, and no installer |

None of the ten is *done*, because done means all six targets on physical devices. macOS,
iOS and Android are compile-only — this machine has no Apple hardware and no NDK.

```
zig build test              # 325 tests
scripts/check.ps1           # Windows + Linux + 8 target rows + browser + qemu + determinism
zig build run -- --window --audio --net-demo --world-digest --crash-report
```

The engine underneath is further along than the platform layer: stable schema identity and
a pinned compatibility fingerprint, generated wire codecs, a generational-entity world with
CoW rollback pages, tick-keyed deterministic simulation, delta replication against
acknowledged baselines, and a canonical world hash that agrees bit-for-bit across x86-64,
aarch64, s390x, arm, mips and wasm32.

First work is M0, the platform spine — see `AGENTS.md` §4.

---

## The short version

| | |
|---|---|
| Core, renderer, netcode, sim, tools, servers, editor | Zig |
| Graphics | D3D12 · Vulkan · Metal · WebGPU, no common denominator |
| Shaders | Slang, single source to all four |
| Gameplay and mods | QuickJS-NG |
| Transport | QUIC datagrams natively, WebTransport in browsers, one protocol |
| Control plane | Elixir / OTP / Phoenix |
| Platform edges | Objective-C, GameActivity/NDK, TypeScript bootstrap |

Rationale for each is in `docs/ARCHITECTURE.md`. Several of these were argued to the opposite conclusion first and changed on evidence; the reasoning is preserved because the reasons will be re-litigated.

---

## What is actually novel here

Not the language, and not the renderer.

**The world database is the netcode.** Rollback, replication, save/load, replay, and editor history are four projections of one schema and one change journal — with four different physical representations, deliberately not unified.

**Scoped rollback at scale.** Rollback netcode is a 2–8 player technology. Bedlam targets rollback-quality prediction at 64 players with destructible physics, on mobile and web, via causal-closure scoping with a metered degradation ladder. This is the hardest problem in the project and it is **unsolved** — `docs/SCOPED_ROLLBACK.md` is a research brief, not a specification.

**Every target hosts.** A phone or a browser tab acting as authoritative host for 32 players is not done anywhere. The cost — a player-controlled process holding authoritative state — is handled by host trust classes and asynchronous replay validation rather than by pretending it away.

**The editor is a client mode.** One world model, one authority mechanism, one replication protocol, one play path. Collaborative editing falls out; it isn't built.

---

## Reading order

1. **`docs/ARCHITECTURE.md`** — the design and the reasoning. Start at §0 (governing principles) and §1 (scale envelope); everything else is downstream of those.
2. **`docs/BENCHMARK_CONTRACT.md`** — how "64" is proven rather than asserted. Read §0 first: the contract's job is to make gaming it harder than passing it.
3. **`docs/SCHEMA_AND_EVOLUTION.md`** — the mechanism that makes one-derivation survive ten years instead of one build.
4. **`docs/CONFORMANCE_PROFILES.md`** — what environment the floor is measured against, and why compatibility-profile numbers are inadmissible as evidence.
5. **`docs/SCOPED_ROLLBACK.md`** — the open research problem. Note the **OPEN** markers.

Contributors, human or automated, should read **`AGENTS.md`** before writing code. It restates the unretrofittable invariants and the stop-and-ask conditions.

---

## The invariants that cost a rewrite if broken

Full list in `docs/ARCHITECTURE.md` §18. The five that cannot be fixed later:

1. No per-field metadata in archetype chunks, from any subsystem, ever.
2. No durable ID derived from source order, layout order, or symbol hash.
3. The four state projections are not the same bytes.
4. "Page" means an engine-owned logical block — never VM page protection or remapping.
5. No editor-only object model.

---

## Repository layout

```
README.md
AGENTS.md              operating instructions for contributors
docs/
  ARCHITECTURE.md      the design
  BENCHMARK_CONTRACT.md
  SCHEMA_AND_EVOLUTION.md
  CONFORMANCE_PROFILES.md
  SCOPED_ROLLBACK.md   research brief, unsolved
  CI_TIERS.md          which tier may make a performance claim
  SPEC_DEFECTS.md      known defects, unresolved
.github/workflows/
  ci.yml               Tier C matrix — one row per target, dark rows included
  SPEC_DEFECTS.md      known defects, and how each was resolved
  UPSTREAM_FINDINGS.md toolchain behaviour the platform code works around
build.zig              targets, cross gate, web and package steps
build.zig.zon          package manifest
src/
  schema/              stable IDs, manifest, compatibility fingerprint
  wire/                bit reader/writer, quantization, generated codecs
  world/               entities, chunks, archetypes, CoW pages, journal, hash
  sim/                 tick-keyed RNG, step loop, determinism harness
  net/                 session, baselines, snapshots, replication frames
  audio/               SPSC command ring and the integer mixer (portable)
platform/              per-target shims — nothing above this line may import them
  windows/ linux/      window, input, audio device
tools/
  web/                 wasm harness, worker, AudioWorklet, browser check
  package.zig          reproducible archive
scripts/               check.ps1, cross.ps1, reproducible.ps1
```

**`src/` never imports `platform/`.** That is §18.9 made structural rather than aspirational,
and it is why the browser can run the same mixer and the same simulation as the desktop
build. The `web` and `ios` build rows exist partly to keep it honest: neither can link a
platform backend at all.

---

## Naming

"Bedlam" is clear in IC 009 (software) and the software-relevant parts of IC 042 in the US as of July 2026 — no live registration covers game or engine software. Residual common-law risk exists from two 2015 games and a suspended esports service mark, all in entertainment services rather than developer tooling. EU/UK search and a formal clearance opinion are outstanding before any public use.

The engine is Bedlam. Games built on it should not be.
