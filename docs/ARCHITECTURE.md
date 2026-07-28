# Bedlam — Architecture

**v0.4**

Six targets: Windows, Linux, macOS, Android, iOS, Web. Native-class performance on each.
Multiplayer is in the kernel. The editor is a client mode. Every conformant target hosts.

The name states the design condition: 64 players, full destruction, vehicles, on a phone and in a browser. Bedlam, metered. Every hard decision in this document is about bounding chaos rather than avoiding it — the closure ladder with per-frame budgets, four governors that never touch simulation cadence, a byte budget that fails you for passing on frame time, a benchmark you cannot game by shrinking the scene.

**v0.4 changes from v0.3:**

- **§1.1 resolved** — every conformant target must be capable of hosting the authoritative cell. v0.3's provisional "six clients into a server cell" reading is superseded.
- **§9.5 added** — relay-mediated hosting for web hosts, and the relay as an explicit trust boundary with end-to-end payload encryption.
- **§9.3 rewritten** — listen-authoritative promoted to a first-class topology with its own floor.
- **§14.3 added** — host trust classes.
- **§16 expanded** — host-authoritative sessions as the primary new cheat surface.
- Reference workload, entity census, voice budget, and device tiers now fixed in `BENCHMARK_CONTRACT.md`.

---

## 0. Governing principles

Ranked. When two conflict, the lower number wins.

**P0 — The scale envelope is a requirement, not a target.**
See §1. Every subsystem is designed against it. Nothing negotiates it down. Falsifiable only against `BENCHMARK_CONTRACT.md`.

**P1 — Execution semantics and footprint to the floor. GPU capability from the ceiling. Physical layout per target. Schema at the center.**

- *Execution semantics to the floor.* No required `dlopen`, no stack switching, no blocking semantics unavailable on any target.
- *Footprint to the floor.* wasm32 addressability and mobile memory ceilings constrain baseline content and simulation budgets globally. Memory is a hard limit that propagates upward, not a capability that lowers.
- *GPU capability from the ceiling.* High-end features do not constrain lower profiles.
- *Physical layout per target.* Component layouts, chunk sizes, and alignment may differ per target. Semantic schema may not.

**P2 — One derivation, no duplicate definitions.**
Storage layout, wire codec, replication policy, prediction participation, save format, replay format, script binding, authoring permissions, and editor panels all derive from a single schema declaration. Durability across builds is §3's problem, not `comptime`'s.

**P3 — One state model, many projections.**
Rollback, replication, save/load, replay, and editor history share a versioned world model and generated change semantics. They do **not** share a physical representation. See §5.

**P4 — Genre-specific where genre matters.**
No single determinism model, renderer feature set, or netcode topology. Profiles in §7, §4.2, §9.3.

**P5 — One engine program, one world model, one replication layer, one build graph.**
Target- and mode-specialized artifacts may compile out unavailable capabilities. The editor is a client mode semantically even where editor and consumer clients are distinct compiled artifacts.

**P6 — Any conformant target can host.**
Client, dedicated server, editor, and authoritative host are modes of the same program on every platform. A phone hosting 32 players is the same code as a datacenter hosting 64. This is P5 extended to authority, and it is what makes §9.3's topology range real rather than aspirational.

---

## 1. Scale envelope

### 1.1 The floor

| Tier | Count | Scope | Status |
|---|---|---|---|
| **Floor** | **64 concurrent, full tick** | Single authoritative cell, conformant profile, all six targets as clients | **Hard requirement** |
| **Host floor** | **64 desktop / 32 mobile / 32 web** | Same program hosting the authoritative cell | **Hard requirement** |
| Design target | 256 concurrent | Single cell | Architecture must not preclude |
| Ceiling | 1024+ | Cell handoff / sim meshing | Deferred implementation, not deferred design |

64 on desktop is solved. 64 in a browser at full tick and 64 on a thermally-throttled phone at full tick are not. **A phone or a browser tab acting as the authoritative host for 32 players is not done anywhere.**

**Hosting is resolved, not provisional.** Every conformant target must be capable of hosting the authoritative cell. Consequences run through §9.3 (topology), §9.5 (relay and trust boundary), §14.3 (host trust classes), and §16 (anti-cheat). The cost is real and stated rather than hidden: a player-hosted authoritative cell is a cheat vector by construction, and §14.3 is the price.

Reference workload, entity census, content complexity, device tiers, and all budgets: `BENCHMARK_CONTRACT.md`.

### 1.2 Conformance profiles

The floor admits no *platform* exceptions. It admits *environment* classes, and only one is the measurement environment. Full definitions in `CONFORMANCE_PROFILES.md`.

- **Conformant** — meets the floor, measured against the benchmark contract. Web requires Worker + OffscreenCanvas + cross-origin isolation + SharedArrayBuffer + WebGPU + WebTransport.
- **Compatibility** — interoperates fully, guarantees no §1 performance. Single-threaded web, TCP/WebSocket transport, sub-reference devices.
- **Unsupported** — refused with a structured capability-mismatch reason.

**Compatibility-profile measurements are inadmissible as evidence about P0 in either direction.** A compatibility client may not host.

### 1.3 What the floor forces

**Bandwidth is the binding constraint, not CPU.** Bit-packing, quantization, per-client baselines, delta encoding, and priority accumulators are M1 kernel work. Relevance ordering is how 64 fits down a mobile radio.

**Rollback must be scoped.** §6, and `SCOPED_ROLLBACK.md`.

**Mobile budget is thermal, not peak.** Packet processing, delta decode, interpolation, audio (§17), and rendering compete for one envelope. A mobile *host* adds authoritative simulation to that list, which is why the host floor is 32 rather than 64.

**Web is worker-only in the conformant profile.**

**Adaptive controls, named precisely.** Simulation cadence is invariant. Four governors, none of which touch it:

- *replication-rate governor* — snapshot send frequency per client
- *interpolation-delay governor* — client buffer depth against jitter
- *render-quality governor* — resolution, LOD, effect tiers, fed by ADPF thermal headroom
- *presentation-rate governor* — local frame rate, decoupled from tick rate

**Server cells are the unit of scale.** Design the cell boundary, migration checkpoint, and cross-cell interest queries in M1 even though meshing ships in M4. Migration checkpoint doubles as the host-migration mechanism (§14.3).

---

## 2. Language and toolchain

| Layer | Choice |
|---|---|
| Core, renderer, physics, netcode, sim, tools, servers, editor | **Zig** |
| Apple platform surfaces | Thin **Objective-C** TUs over C ABI, built with `zig cc` |
| Windows COM (D3D12, DXGI, WASAPI, GameInput) | `comptime`-generated vtable wrappers |
| Android lifecycle, input, sensors | **GameActivity + NDK**, JNI only where unavoidable |
| Web bootstrap | **TypeScript**, ~2k lines, generated from `comptime` declarations |
| Gameplay / mods / editor tooling | **QuickJS-NG** via `zig-quickjs-ng` |
| Shaders | **Slang** |
| Control plane | **Elixir / OTP / Phoenix** |
| Build | `zig build` meta-build; `zig cc` for all vendored C/C++ |

**Why Zig:** cross-compilation as a solved problem across six targets and every vendored C/C++ dependency from one CI host — a cost that otherwise recurs on every dependency forever. `comptime` deletes the code-generator tier P2 demands. Allocator-as-parameter is the engine allocator model by default. `@cImport` with no bindgen.

**Accepted costs:** pre-1.0 churn — pin the compiler, budget upgrades, don't build hot paths on `std`. No memory safety by default — §14, whose primary answer is process isolation and is language-independent. No stable ABI — §10.3. `use_llvm = true` required with `zig-quickjs-ng` on 0.16; isolate the script host as a separate artifact so the main binary keeps the fast self-hosted debug backend.

**Reopen condition:** headcount past ~15 engineers, or consoles entering scope.

---

## 3. Schema and evolution

`comptime` gives one declaration and generated implementations. It gives **nothing** about stable identity across builds. IDs derived from source order, declaration order, layout order, or a compiler symbol hash detonate on the first refactor and take save compatibility, replay validation, rolling deploys, and connection negotiation with them.

**Every build emits a canonical, signed schema manifest.** The declaration is authoritative for shape; the manifest is authoritative for identity and policy. IDs are allocated from a checked-in registry, never derived. Removal tombstones permanently. Reuse is a build error with no override.

Manifest carries: stable component/field/event/RPC IDs · wire types and quantization policy · authority, visibility, and script exposure · prediction and rollback participation · save and replay inclusion · authoring lease class and contention key · introduced/deprecated versions · tombstone list · compatibility fingerprint · explicit migration edges.

The fingerprint covers wire-affecting facts only. **Two builds for different targets with different physical layouts produce identical fingerprints.** If they don't, the fingerprint covers something it shouldn't, and cross-platform play breaks in a way that looks like a netcode bug for weeks.

Full specification: `SCHEMA_AND_EVOLUTION.md`.

---

## 4. Platform and renderer

### 4.1 Platform matrix

| Platform | Graphics | Native surfaces | I/O |
|---|---|---|---|
| **Windows** | D3D12 primary, Vulkan for diagnostics | Win32, DXGI, WASAPI, GameInput / Raw Input | IOCP |
| **Linux** | Vulkan | Wayland primary, X11 fallback, PipeWire/ALSA, libinput/evdev | io_uring, epoll fallback |
| **macOS** | Metal | Cocoa, CoreAudio, GameController, Network.framework | kqueue |
| **iOS** | Metal | UIKit, AVAudioSession, GameController, Network.framework | kqueue |
| **Android** | Vulkan | GameActivity, AChoreographer, AAudio/Oboe, ADPF thermal | ALooper |
| **Web** | WebGPU | Worker + OffscreenCanvas, AudioWorklet, WebTransport | Fetch, OPFS |

wasm32 only. memory64 costs real performance — engines lose 32-bit pointer optimizations — and browsers cap it regardless. Streaming budget under 2GB.

### 4.2 Renderer

Capability-aware command and resource model, not an abstraction over four APIs. The shared layer expresses intent: resource descriptions and lifetime classes, passes, queue and dependency information, binding layouts, pipeline descriptions, transient requirements, residency and streaming intent, presentation intent, capture metadata. A frame-graph compiler lowers per-backend — D3D12 resource states and descriptor tables, Vulkan layouts and access masks and timeline semaphores, Metal encoders and argument buffers and tile-memory passes, WebGPU passes and bind groups.

**Capability profiles**, checked at build time: `web-safe` · `mobile-baseline` · `mobile-advanced` · `desktop-baseline` · `desktop-high` · `hw-raytracing` · `mesh-shader` · `virtual-geometry` · `bindless` · `vrs`.

Desktop uses mesh shaders and hardware RT. Mobile uses tile-local techniques. Web uses a separately optimized compute-culling path. Shared: materials, scene representation, lighting semantics, authoring tools. **Not shared: the frame.**

Profiles carry a **character budget**: 64 skinned, animated, networked characters inside `web-safe` and `mobile-baseline` at full tick. That constrains the animation and skinning path harder than anything in the lighting stack.

### 4.3 Shaders

**Slang, used directly. No engine-owned shader IR.** Khronos-hosted, multi-vendor governance, single-source to DXIL / SPIR-V / MSL / WGSL, with a capability system that type-checks feature availability per target before codegen — the exact mechanism §4.2 needs.

Building a normalizing IR to hedge against a staffed multi-year compiler project, by starting a staffed multi-year compiler project, is rejected. **If Slang's WGSL output proves insufficient**, run Tint or SPIRV-Cross over its SPIR-V for the web path — a bounded fallback, not an architecture.

Bedlam owns material semantics, reflection metadata, capability profiles, and binding conventions. It does not own a general shader IR. Shipping shaders compile offline into per-platform, per-feature, per-GPU-family archives.

---

## 5. World database and state projections

A **versioned world database** with a change journal. Entities are generational IDs. Components live in archetype chunks, SoA or AoSoA per family, layout permitted to differ per target. Systems query chunk views and emit commands.

### 5.1 The projection split

One schema (§3), one change journal, **four projections that are not the same bytes**:

| Projection | Representation |
|---|---|
| **Rollback** | Logical fixed-size copy-on-write chunk pages |
| **Replication** | Per-client canonical encoded baseline, after interest filtering, authority filtering, quantization, stable field ordering |
| **Save** | Schema-versioned canonical persistent state |
| **Replay** | Input/event log + seeds + periodic canonical checkpoints, including script-emitted commands (§10.1) |

A replication baseline is **not** a physical world snapshot. After per-client interest filtering, quantization, archetype migration, dormancy transitions, and authority changes, a page XOR against in-memory state is meaningless. Delta is computed against **that client's last-acked canonical baseline**, which means ack tracking, interest set, and baseline live together per connection.

**"Page" means an engine-owned logical block.** Never virtual-memory page protection, never `mprotect`, never remapping. Any design leaning on OS paging dies on Web, and would work on desktop long enough to become load-bearing first.

### 5.2 Mechanics

- **Snapshot** = copy dirty logical pages into a ring
- **Rollback** = swap page pointers, re-simulate the causal closure (§6)
- **Replication** = journal → per-client projection → delta against acked baseline
- **Replay** = input log + seed + periodic checkpoint

Simulation components obey the rules by construction: no pointers, no heap allocation, no non-deterministic iteration order. Anything that can't is cosmetic-only.

**Archetype chunks carry no per-field metadata.** Not CRDT metadata, not undo metadata, not authoring provenance, not replication bookkeeping. Every one is a real pressure; every one is answered by putting metadata beside the database. §18.5.

### 5.3 Component classes

`authoritative` · `predicted` · `interpolated` · `replicated` · `deterministic` · `client-private` · `transient-presentation` · `ephemeral-authoritative` · `authoring` · `derived`

One declaration drives storage layout and snapshot-ring membership, wire codec and channel and priority weighting, prediction participation, editor panels, save and replay inclusion, QuickJS binding surface and visibility, and authoring lease class — via `comptime`, recorded in the §3 manifest.

`derived` is a bandwidth instrument: 16,384 destruction fragments in the reference workload are `derived` and reconstructed client-side from replicated destruction events plus structural state. Replicating them is impossible at the floor.

---

## 6. Causal closure and scoped rollback

Dirty tracking says what changed. It does not say what causally depended on the incorrect prediction. Without provenance, scoped rollback degrades into global rollback with a graph traversal in front of it.

**Provenance sources:** static system read/write sets derived at `comptime` from queries · dynamic entity/component interaction edges per tick · physics contact and constraint islands · event producer/consumer edges · command provenance including script-emitted commands · spawn/despawn dependencies · bounded interaction horizon per system.

**The ladder.** Physics turns local interactions into large connected components — explosions, vehicle constraint chains, destructible structures, AI perception cascades. Scoped rollback is a budget with a ladder, not a promise.

| Step | Mechanism | Trigger |
|---|---|---|
| 1 | Local prediction island | Closure within per-frame budget |
| 2 | Expanded dynamic causal island | Exceeds step 1, within expanded budget |
| 3 | Whole-zone rollback | Exceeds step 2 |
| 4 | Authoritative correction, no local re-simulation | Exceeds step 3, or budget exhausted |

Step is chosen **per frame against a measured budget**, not per game as configuration. Step 4 is a visible snap; the job is to make it rare, not to pretend it never happens.

**Closure size is a first-class profiling metric**, surfaced in the editor's live view and server telemetry. A game whose closure regularly reaches step 3 has a content problem Bedlam should report, not absorb.

Design brief and open research questions: `SCOPED_ROLLBACK.md`.

---

## 7. Determinism profiles

| Profile | Numerics | Use |
|---|---|---|
| **1 — Authoritative** | Free. Only the server's result matters. | MMO, co-op, PvE |
| **2 — Prediction-compatible** | Deterministic subset for predicted systems; reconciliation absorbs drift. | Large-scale shooter, BR |
| **3 — Full rollback** | Fixed-point, fixed tick, stable iteration order, controlled random streams. | Fighting, RTS, lockstep |
| **4 — Presentation** | Nondeterministic GPU work, high-fidelity local effects. | Always active alongside 1–3 |

The reference workload runs **profile 2 with profile-3-grade scoped rollback on the local causal island**. Full profile 3 at 64 with destruction is unfit, not merely hard — every client would deterministically simulate every fragment.

**Profile 3 requirements:** fixed-point inside the rollback boundary · no FMA contraction, no fast-math · own polynomial transcendentals, never platform libm · fixed-tree parallel reductions · `--verify-determinism` running the sim twice at different thread counts and hashing every tick, failing CI on divergence, from day one.

Bit-exact cross-architecture float determinism across x86 / ARM / wasm32 is folklore. Don't design around it.

---

## 8. Frame loop and job system

```
input sample
→ command construction
→ authoring transaction apply (editor mode, §13)
→ fixed simulation tick(s)
→ causal closure evaluation → rollback ladder step (§6)
→ animation, physics
→ visibility
→ render extraction
→ frame-graph compile
→ GPU submit
→ script heap maintenance: bounded release queue + budgeted cycle collection (§10.1)
```

**Explicit task graph with continuation edges, not stackful fibers.** P1 forces it: Wasm stack switching is in origin trial and not bankable. The continuation model is more debuggable and gives deterministic schedule replay for free.

Long-running I/O communicates through bounded queues and immutable completion records. Nothing in the frame loop blocks.

**Allocation rule:** no unbounded or implicit allocation from the engine's general allocator in the frame loop. Script heaps are isolated, capped, metered, and scheduled — not exempt, separately governed (§10.1).

---

## 9. Networking

### 9.1 Engine-facing channels

```
unreliable_unordered      input, snapshots
unreliable_sequenced      cosmetic events, voice frames, awareness (§13.5)
reliable_unordered        one-shot gameplay events
reliable_ordered          state machine transitions, authoring transactions (§13)
reliable_stream           login, inventory, content negotiation, schema negotiation (§3)
voice
bulk_content              streaming assets, patches
```

### 9.2 Transport lowering

**One semantic channel model, one message framing model, one schema protocol, everywhere. Transport-specific reliability is not reimplemented on top of transports that already provide it.**

| Profile | Native | Web |
|---|---|---|
| Conformant | QUIC datagrams + streams | WebTransport datagrams + streams |
| Compatibility | TCP-framed | WebSocket |

**Raw UDP does not exist in Bedlam.** It saves low single-digit percent over QUIC and costs a bespoke handshake, key exchange, replay protection, path validation, and amplification defense — precisely the category that produces catastrophic multiplayer CVEs. §18.13 forbids custom cryptographic construction; deleting the path that would need it is the honest consequence.

**The compatibility fallback is a degraded lowering, not an equivalent one.** TCP and WebSocket cannot faithfully deliver unreliable semantics — head-of-line blocking remains beneath the application. Stale messages can be discarded before enqueue and after receipt; the semantics are not identical and no subsystem may assume they are.

**Ship the fallback from day one.** UDP/443 is filtered on corporate and hotel networks. A WebTransport-only build works on home wifi and goes silent the moment someone opens a laptop in a coworking space.

### 9.3 Topology profiles

Each profile shares schema, channels, framing, encryption identity, and replay machinery, and differs in trust, authority, and migration. **Topology profiles do not inherit the §1 floor.**

| Profile | Authority | Floor | Trust class |
|---|---|---|---|
| **Dedicated authoritative** | Server cell | **64** | Trusted |
| **Listen authoritative** | Host client, migratable | **64 desktop / 32 mobile / 32 web** | Untrusted (§14.3) |
| Peer rollback | Peers + session authority | 8, relay-mediated above 4 | Untrusted |
| Deterministic lockstep | Distributed commands, optional arbiter | 16, bounded by slowest peer | Untrusted |
| Asynchronous authoritative | Durable service state | 256 | Trusted |

Listen-authoritative is **first-class, not reduced**. P6 makes it the same program in a different mode, which is what makes the mobile and web host floors achievable rather than aspirational.

### 9.4 Replication

Generated from §5.3 classes and §3 manifest IDs. No hand-maintained serializer for any ordinary replicated component.

Bit-packed codecs · quantized vectors and rotations · per-client canonical baselines · delta against acked baseline · per-connection authority and visibility · spatial, team, ownership, tag interest filters · priority accumulators under per-client byte budget · dormancy · predicted spawning · prediction and reconciliation · scoped rollback (§6) · snapshot interpolation · lag-compensated historical queries · deterministic replay · schema-negotiated compatibility across rolling deploys.

### 9.5 Relay-mediated hosting

**New in v0.4.** A browser cannot accept inbound connections, so a web host connects outbound to a relay and clients connect to the relay. Same wire protocol, one additional hop, counted in the benchmark's RTT profiles.

**The relay is an explicit trust boundary.** It terminates two transport connections and would otherwise see plaintext. Therefore:

- Session payloads are **end-to-end encrypted between host and clients** using standard AEAD primitives with keys the relay does not hold.
- Key exchange is brokered by the Elixir control plane (§12) over `reliable_stream`, not by the relay.
- **Standard constructions only** — HPKE-shaped key agreement, established AEAD. §18.13 applies here with no exception. The temptation to hand-roll a lightweight scheme "because it's just a relay" is exactly the failure this rule exists to prevent.
- The relay performs no simulation, no validation, no state inspection, and structurally **cannot**.
- Relay operators may be third parties. Nothing in the design may assume otherwise.

Relay-mediated transport is also available to native hosts behind symmetric NAT, where it replaces direct QUIC listen with identical semantics.

---

## 10. Scripting and extension

### 10.1 Gameplay VM: QuickJS-NG

Via `zig-quickjs-ng`, pinned to a released Zig.

**Why not Wasm — the accurate version.** The argument is binding ergonomics, and only that. Wasm offers two options for ECS access, both bad: host calls with linear-memory marshaling, expensive at gameplay's access frequency; or mapping ECS memory into the module, which lets it scribble anywhere in world state and requires it to know the exact layout. Every Wasm-scripted engine converges on a chunky batched command API to amortize the wall — worse authoring than what it was escaping.

Narrow determinism claim: Wasm's IEEE-754 mandate is a spec-compliance requirement across three independent browser engines, with divergence surface in relaxed-SIMD lowering and NaN bit patterns. One interpreter binary from one source tree is a stronger *practical* guarantee. Wasm is not inherently less deterministic.

**Handle model — zero-copy, not zero-lookup.** Archetype migration invalidates column and row, so script proxies retain `entity generational handle + stable component ID + borrow epoch` and resolve on access. Per-tick cached views permitted, invalidated on epoch change. **Do not build an elaborate caching layer** — script access is event-driven, so the resolve amortizes over an event, not a tick.

**Script heap governance.** Refcounting produces synchronous destruction cascades; the cycle collector is not the only pause source. Required: custom allocator per shard · hard memory ceiling · per-tick allocation budget · bounded release queue with deferred destruction beyond budget · explicit cycle-collection budget in the §8 slot · telemetry for allocation rate, cascade depth, collector work.

**Concurrency.** `JSRuntime` per thread, `JSContext` within one, no object sharing across runtimes. One runtime per shard/zone/partition, message passing between. Forces actor-style partitioning, isomorphic to the BEAM tier (§12).

**Throughput discipline.** ~30–50× off native for tight loops. Script defines policy and reacts to events; systems do bulk work. **No per-entity-per-tick script callbacks.** `JS_SetInterruptHandler` enforces a per-script instruction budget, doubling as the mod timeout.

**Script is inside the replay boundary, outside the rollback boundary.** Script emits commands into the authoritative input/event log. Rollback **replays recorded commands and never re-invokes JS.** Script policy runs exactly once per logical tick.

The consequence: script determinism is not a correctness requirement. Shadowing `Math` with engine natives, routing `Date.now` to sim clock and `Math.random` to seeded PRNG, and keeping logic out of finalizers remain requirements — for reproducible authoring and replay fidelity, not rollback correctness.

### 10.2 Sandbox tiers

| Tier | Content | Containment |
|---|---|---|
| 1 | First-party and signed | Bare QuickJS — no FFI unless provided, plus memory/stack/interrupt limits |
| 2 | Untrusted UGC | QuickJS compiled to Wasm — same language semantics, same generated object model, structural isolation |

Tier 2 reuses language semantics and the generated object model, minimizing content-porting cost. **Containment is a separate implementation milestone** requiring memory and fuel accounting, host-call design, module lifecycle, debugger integration, error translation, marshaling, and DoS testing.

Cost distribution: **Web is the cheap path** — the engine is already a Wasm module, so a QuickJS-in-Wasm mod is a *sibling* module with an import object, no nesting. **Native is expensive**, requiring an embedded Wasm runtime Bedlam would otherwise never ship.

### 10.3 Native extension ABI

Zig has no stable ABI. Generated **C ABI** with opaque handles, versioned function tables, explicit ownership, validated against the §3 manifest. Statically linked Zig modules for first-party maximum-performance gameplay. QuickJS for everything else.

Hot reload works because persistent state lives in engine-owned component storage.

---

## 11. The editor is a client mode

**No editor application. No throwaway editor. No editor-only object model.**

The editor is Bedlam running with an authority filter granting write access to `authoring` components, a UI and gizmo overlay, `authoring` and `derived` components resident, and QuickJS contexts with the tooling API bound. Everything else is identical.

**What this buys structurally:** collaborative editing is the replication layer with a different authority filter and consistency model (§13), not a subsystem. Play-in-editor is playing. The §1 floor applies to editing — 64 concurrent editors is the same gate as 64 concurrent players. Remote device editing is free. Time-travel inspection, live world diffing, prediction visualization, causal-closure metering, and frame-graph views are consequences of §5 and §4 being present in the running client.

**UI:** retained-mode with an immediate-mode debug layer, rendered by Bedlam's own renderer. Schema-generated property panels from §3. Starts in M1 as a debug overlay and grows continuously. **Never thrown away and rewritten.**

**Content pipeline:** content-addressed DAG, every transformation deterministic and cacheable.

```
source → import → normalize → dependency analysis → platform cook
→ compression → bundle layout → sign → publish
```

Desktop BC7 and high-res geometry; mobile ASTC and reduced LOD chains; web KTX2/UASTC universal transcode; server collision and navigation packages with no render data.

**Cooking is a service the editor requests, not a mode it enters.** That makes it work identically when the editor runs on a phone, and per §14 it means importers execute only on hosts where process isolation exists. Web and iOS editor clients never run an importer — and neither does a mobile or web *authoritative host*, which runs cooked content only.

---

## 12. Servers and online

### Simulation

The same Zig program, headless, renderer and audio and editor UI compiled out. **Not a reimplementation** — separate server sim and client prediction codebases make reconciliation divergence an unfindable bug class. Per P6, the same simulation core runs in a datacenter cell, a desktop listen server, and a phone.

Per cell: bounded memory, no GC, serializable migration checkpoint, deterministic replay log, live introspection without pausing the tick.

Edge relays (§9.5), packet termination, DDoS admission, session encryption, realtime routing: also Zig.

### Control plane: Elixir / OTP / Phoenix

Accounts, sessions, presence, parties, lobbies, matchmaking, server allocation, region selection, chat, social, tournaments, fleet health, rolling deployments, editor session brokering, schema manifest registry (§3), **relay allocation and E2E key brokering (§9.5)**, and **host trust class assignment and replay-validation scheduling (§14.3)**.

Massively concurrent, stateful, fault-tolerant, hot code upgrade during a live season, none of it on the sub-millisecond path.

> **Elixir decides where a session runs. Bedlam runs the session.**

Never put the tick loop in a NIF. Zigler is for hot *pure* functions — bit-packing, delta compression, replay validation, anti-cheat hashing.

### Storage

PostgreSQL for durable transactional state. Content-addressed object storage for cooked content, replays, authoring history, signed schema manifests. Telemetry to a separate analytical store.

---

## 13. Authoring consistency

| Domain | Model | Mechanism |
|---|---|---|
| **Simulation** | Server-authoritative | Snapshot + delta, prediction, scoped rollback |
| **Authoring** | Server-ordered transaction log with leases | §13.1–13.6 |

**13.1 The log is beside the database.** CRDT approaches attach origin, left-origin, client ID, and clock per item — fine for text, fatal to packed SoA columns. The authoring layer is a transaction log over the world database; the world database is the materialized view.

**13.2 Leases** are the existing per-connection authority filter with a timeout. State is `ephemeral-authoritative` — server-authoritative, security-relevant, excluded from saves. **Contention keys are schema-declared**: `entity` · `subtree` · `component-group` · `asset` · `graph` · `document-range`. Acquired implicitly on first edit, released on idle timeout. Contended acquisition is a server decision — total order, no consensus protocol.

CRDTs guarantee convergence, not intent preservation. Converged text is visibly wrong and fixable; a silently merged level layout is a broken scene that surfaces in QA weeks later.

**13.3 CRDT types only where merge is wanted:** text buffers, unordered sets, spline point lists. Everything else is lease-plus-ordered-log.

**13.4 Transaction envelope:** transaction ID · actor and authority domain · base world revision · required lease keys · touched semantic paths · preconditions · operations · inverse intent · idempotency key · schema fingerprint · server-assigned order timestamp.

**Scoped undo** pops from the originating authority domain's stack only. **Undo emits a new forward transaction with preconditions** — a stored inverse may be invalid after intervening edits, and that must surface as a conflict, never blindly overwrite newer work.

> Editor undo and netcode rollback both mean "go back," are entirely different mechanisms, and must never be unified. Sharing the vocabulary is how someone merges them in eighteen months and destroys both.

**13.5 Awareness:** cursors, selections, camera positions, gizmo drags, lease indicators. `transient-presentation` on `unreliable_sequenced`, timeout-expired, never persisted.

**13.6 Log lifecycle:** compaction · materialized checkpoints · branch and session identity · publish and merge semantics · audit retention · source-asset versioning. **Offline default: rebase with surfaced conflict, not silent merge.**

---

## 14. Security posture

### 14.1 Why optimization modes are not the answer

`ReleaseSafe` plus fuzzing preserves checks Zig knows how to emit. It does not prevent use-after-free, stale generational assumptions outside the handle layer, uninitialized memory, aliasing errors, logic bombs, decompression bombs, or parser resource exhaustion.

**And most asset importers are third-party C or C++, where Zig's safety mode provides exactly zero protection.** No language choice fixes that.

### 14.2 Primary posture — process isolation and capability-shaped APIs

Both language-independent.

| Requirement | Detail |
|---|---|
| **Importers out of process** | Asset import and untrusted cooking in separate sandboxed processes. Hard CPU, memory, FD, and output-size limits. **No network access.** |
| **Bounded reader API** | Capability-based, length-checked reader for every packet, save, replay, and authoring-transaction parser. No ad-hoc byte walking at any trust boundary. |
| **No raw pointers at trust boundaries** | Handles and slices only, except tiny audited adapters. |
| **Server-side authoring validation** | Client-side validation is UX, never enforcement. |
| **Reproducible builds** | Toolchain and content reproducible. Cooked packages and schema manifests signed. |
| **Stateless admission** | Retry tokens before expensive transport or session establishment. |
| **No custom cryptography** | No bespoke handshake, key exchange, or replay protection anywhere — including the §9.5 relay path. |

Because cooking is a requested service (§11), importers execute only on hosts where process isolation exists. Mobile and web hosts run cooked content only.

### 14.3 Host trust classes

**New in v0.4.** P6 puts an authoritative cell on a player-controlled device. That is a cheat vector by construction — the host can observe and mutate authoritative state — and the mitigation is to classify rather than pretend.

| Class | Authority | Permitted |
|---|---|---|
| **Trusted** | Operator-controlled dedicated cell | Everything, including ranked and economy-affecting play |
| **Untrusted** | Player-hosted listen-authoritative | Casual, private, community, and editor sessions |

Rules:

- Trust class is assigned by the control plane at session creation and recorded immutably in the session record.
- **Ranked, competitive, and economy-affecting play requires a trusted cell. No exceptions, no configuration flag.**
- Untrusted sessions submit their replay log for asynchronous server-side validation. Divergence flags the **host**, not the participants.
- Host migration mid-session without state loss, via the §1.3 migration checkpoint. A host that fails validation is migrated away from, not merely banned.
- Clients are told the trust class before joining. Concealing it is a product-integrity failure, not a UX decision.
- The §9.5 relay is untrusted regardless of session trust class.

This is the price of P6. It is worth paying because listen-authoritative on mobile and web unlocks session topologies nothing currently supports, and because the mitigation reuses replay validation machinery Bedlam already has.

---

## 15. *(reserved)*

---

## 16. Anti-cheat

Structurally coupled to netcode and replay, impossible to bolt on. The determinism and replay machinery already specified is what makes it tractable — the argument for designing it in now, not the reason to defer.

- **Server-side replay validation.** The §5.1 replay projection lets an authority re-execute a client's input stream and compare. Profile 3 makes this exact; profile 2 makes it bounded.
- **Untrusted-host validation (§14.3).** The primary new surface in v0.4. Untrusted sessions submit replay logs for asynchronous re-execution against a trusted validator. Divergence flags the host. This is the same machinery as client validation pointed at a different party.
- **Input-stream anomaly detection.** Statistical analysis over the authoritative input log — the same artifact used for replay and bug reporting. No separate pipeline.
- **No client-side trust, ever.** `client-private` (§5.3) exists so the client is never sent information it should not have. Information never received cannot be extracted.
- **Relay cannot observe (§9.5).** E2E payload encryption means a compromised or malicious relay yields traffic analysis at most.
- **Mod surface.** Tier-1 content is signed; tier-2 UGC is structurally contained (§10.2). Neither may reach `authoritative` components.
- **Lag-compensation bounds.** Historical query windows budgeted and audited; unbounded rewind is an exploit surface.

Detailed design deferred; the hooks are in §5.1, §9.4, §12, and §14.3. Nothing may be architected later in a way that requires changing those.

---

## 17. Audio budget

At the §1 floor, a sustained CPU consumer competing with networking and rendering for one mobile thermal envelope — and on a mobile host, with authoritative simulation as well.

- Own mixer and DSP graph, HRTF spatialization, convolution reverb, sample-accurate scheduling.
- Lock-free command queue from game thread to audio thread. Neither blocks on the other.
- Output: WASAPI · CoreAudio · AAudio/Oboe · PipeWire/ALSA · AudioWorklet (128-sample quantum, DSP compiled to Wasm).
- **Voice at 64 is a distinct budget line.** 64 concurrent transmitting, 24 client-side spatialized, remainder server-mixed positional fold. Full numbers in `BENCHMARK_CONTRACT.md` §8.
- Mobile audio CPU counts against the same ADPF headroom feeding the render-quality governor. **The governors must be aware of each other** or a render reduction gets immediately consumed by a voice increase and accomplishes nothing.

---

## 18. Non-negotiables

1. **64 concurrent at full tick on all six conformant targets; host floors per §1.1.**
2. No lowest-common-denominator renderer.
3. No network code as an optional layer.
4. No duplicated definitions for component fields, serialization, replication, reflection, script binding, authoring permissions, and editor properties.
5. **No per-field metadata in archetype chunks, from any subsystem, ever.**
6. **No durable ID derived from source order, layout order, or compiler symbol hash.**
7. **No unification of the four state projections.**
8. No general or implicit allocation from the engine allocator in the frame loop.
9. No platform SDK types leaking into portable simulation code.
10. No unstable language ABI as the plugin contract.
11. **No editor application separate from the runtime.**
12. No unification of editor undo and netcode rollback.
13. **No custom cryptographic construction anywhere, including the relay path.**
14. **No untrusted parsing or asset import in the engine process.**
15. **No ranked or economy-affecting play on an untrusted host.**
16. No design depending on virtual-memory page protection or remapping.
17. No browser target as an afterthought.
18. No single determinism claim covering every genre.
19. No control-plane language in the realtime packet or simulation path.
20. No compiler green check treated as a working target — physical device, GPU, browser, network-condition, and thermal-soak matrix on every commit, at 64.

---

## 19. Sequencing

**No calendar estimates.** M1 is the novel core and is a research program, not an ordinary milestone. Exit criteria only.

**What eats time, ranked:** content pipeline > editor > platform layer > renderer > netcode.

### M0 — Platform spine

A triangle proves graphics API reachability, not platform architecture. Exit criteria, all six targets, physical devices, in CI:

window and surface creation · input and text forwarding · audio callback and AudioWorklet ring · network session establishment · filesystem and asset read · suspend and resume · device loss and recovery · Worker + OffscreenCanvas · crash capture and symbolication · package, sign, install, launch.

### M1 — The kernel

Transport (channels, QUIC/WebTransport, TCP/WebSocket lowering, relay path) · schema manifest and generation pipeline · world database with logical-page dirty tracking · four state projections · causal provenance and rollback ladder · bit-packing, quantization, per-client baselines, priority accumulators · headless cell with boundary and migration checkpoint · listen-authoritative mode on all six targets · debug renderer · debug overlay that becomes the editor · `--verify-determinism` · out-of-process importer harness.

**Exit criterion: the §1 floor met against `BENCHMARK_CONTRACT.md` on all six conformant targets, including host floors, with closure metered and the ladder exercised.** No visibility buffer work before this passes.

### M2 — Authoring loop

QuickJS host, `comptime` bindings, script heap governance · authoring domain: transaction log, leases, contention keys, scoped undo, awareness · editor mode grown from the M1 overlay · content pipeline v1 · hot reload.

**Exit criterion: 64 concurrent editors in one world, and someone outside the engine team ships a small multiplayer game.**

### M3 — Renderer depth *(parallel with M4)*

Frame graph, four backends, capability profiles, Slang pipeline and offline cooking, GPU-driven culling, meshlets, virtual geometry, virtual texturing.

### M4 — Scale and platform *(parallel with M3)*

Elixir control plane · fleet orchestration · matchmaking, editor session brokering, relay allocation, key brokering · host trust classes and replay-validation scheduling · schema registry and rolling-deploy negotiation · cell handoff and sim meshing · anti-cheat against §16 hooks.

---

## 20. Companion documents

| Document | Role |
|---|---|
| `BENCHMARK_CONTRACT.md` | The falsifiable test fixture. Can invalidate the others. |
| `SCHEMA_AND_EVOLUTION.md` | Manifest, ID allocation, migration, negotiation. Everything depends on it. |
| `CONFORMANCE_PROFILES.md` | What the floor is measured against. |
| `SCOPED_ROLLBACK.md` | Design brief for the hardest problem. Research, not settled spec. |
| `CI_TIERS.md` | Which tier of automated verification may speak about §1, and which may not. |
| `SPEC_DEFECTS.md` | Known defects in this corpus. Unresolved by design — read before trusting a number. |
| `../AGENTS.md` | Operating instructions for automated contributors. |

---

## 21. Open questions

1. **Rollback ladder budgets.** Step thresholds are stated as a mechanism; the actual per-frame budgets are unknown until M1 measurement. `SCOPED_ROLLBACK.md`.
2. **Physics island decomposition.** Whether constraint islands can be split for partial rollback, or must be re-simulated whole. Determines whether step 2 is useful or vestigial.
3. **Offline authoring merge.** §13.6 defaults to rebase-with-surfaced-conflict. Revisit with usage data.
4. **Relay economics.** Whether relays are operator-run only, or a third-party/community tier exists. §9.5 assumes untrusted either way, so this is a product question, not an architecture one.
5. **Trademark clearance.** "Bedlam" is clear in IC 009 and the software-relevant parts of IC 042 in the US. EU/UK search and common-law investigation outstanding before public use.
