# Bedlam

A multiplayer game engine for Windows, Linux, macOS, Android, iOS, and Web.

**64 concurrent players at full tick on every one of them** — including a thermally-throttled phone and a browser tab. Any conformant target can host the authoritative simulation. The editor is the engine running in a client mode, so collaborative editing is the replication layer rather than a subsystem, and 64 concurrent editors is the same gate as 64 concurrent players.

The name states the design condition: 64 players, full destruction, vehicles, running on hardware that has no business running it. Bedlam, metered. Every hard decision here is about bounding chaos rather than avoiding it.

**Status: specification. No implementation yet.** First work is M0, the platform spine — see `AGENTS.md` §4.

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
build.zig              (M0)
build.zig.zon          package manifest
src/                   portable engine
platform/              per-target shims
tools/                 content pipeline, schema generator
test/                  including fuzz targets and determinism verification
```

---

## Naming

"Bedlam" is clear in IC 009 (software) and the software-relevant parts of IC 042 in the US as of July 2026 — no live registration covers game or engine software. Residual common-law risk exists from two 2015 games and a suspended esports service mark, all in entertainment services rather than developer tooling. EU/UK search and a formal clearance opinion are outstanding before any public use.

The engine is Bedlam. Games built on it should not be.
