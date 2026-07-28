# Bedlam — Benchmark Contract

Companion to `ARCHITECTURE.md`. Defines the falsifiable test fixture for the §1 scale envelope. Until this document has a passing implementation, §1's floor is a direction, not a gate.

---

## 0. The anti-gaming principle

A scale requirement stated as a number is decorative. "64 concurrent" can be passed by reducing scene complexity, entity counts, tick rate, or network realism until the number is meaningless.

**The contract's job is to make gaming it harder than passing it.**

The mechanism: the workload is a **fixed, versioned, content-addressed scene plus a deterministic replay of 64 recorded input streams**. Content hash and input-log hash are verified before a run is admitted. Reducing complexity changes the hash and invalidates the result. Tuning the engine is the only remaining lever, which is the point.

The benchmark reuses the §5.1 replay projection. It is not separate infrastructure.

---

## 1. Reference workload

**Genre: 64-player extraction shooter with destructible environment and vehicles.**

Chosen because it stresses every subsystem simultaneously rather than one deeply:

| Stressor | Source |
|---|---|
| Player count at the floor | 64 concurrent |
| Worst-case causal closure | Destructible structures, vehicle constraint chains, explosion cascades |
| Bandwidth pressure | High entity count + high event rate |
| Thermal soak | Long-session raid format |
| Anti-cheat surface | Persistent stakes, extraction economy |
| Prediction quality demand | Twitch aiming with hitscan and ballistic weapons |

**Determinism profile: 2 (prediction-compatible) with profile-3-grade scoped rollback on the local causal island.**

Full profile-3 rollback at 64 with destruction is not merely hard, it is unfit — every client would simulate every fragment deterministically, which does not fit a mobile thermal envelope at any optimization level. The ambitious and coherent target is **rollback-quality feel at 64 players on a phone and in a browser**, achieved by scoping. Rollback netcode is a 2–8 player technology today; this is the thing that does not exist.

### 1.1 Entity census

Fixed. Verified by content hash.

| Class | Sustained | Peak | Replicated | Notes |
|---|---|---|---|---|
| Players | 64 | 64 | Yes | All conformant targets represented |
| AI combatants | 128 | 192 | Yes | Server-simulated, full pathing |
| Projectiles in flight | 384 | 1,024 | Yes | Ballistic, not hitscan-only |
| Destructible structural nodes | 2,048 | 2,048 | Yes | Structural state only, not fragments |
| Destruction fragments | 4,096 | 16,384 | **No** | `derived` — client-simulated from replicated destruction events |
| Vehicles | 16 | 16 | Yes | Constraint chains, occupants |
| Persistent world items | 1,024 | 1,536 | Yes | Extraction loot economy |
| Dynamic props, doors, interactables | 512 | 512 | Yes | |
| **Total replicated** | **~4,192** | **~8,192** | | Cell budget |
| **Per-client relevant set** | **512** | **1,024** | | The number that sets bandwidth |

Fragments being `derived` is load-bearing: replicating 16,384 fragments is impossible at the floor, and the design answer is replicating the destruction *event* plus structural state and letting clients derive. If a build replicates fragments to pass a frame-time target, it fails on bandwidth.

### 1.2 Content complexity

| Parameter | Value |
|---|---|
| Player skeleton | 96 joints, 3 LOD tiers |
| AI skeleton | 64 joints, 3 LOD tiers |
| Concurrent animated characters in view | 48 sustained, 64 peak |
| Physics rigid bodies (server) | 2,560 sustained, 8,192 peak |
| Physics contacts (server) | 4,096 sustained, 16,384 peak |
| Constraint islands | ≤ 12 concurrent, largest ≤ 512 bodies |
| Gameplay events per tick | 128 sustained, 512 peak |
| Scene: static geometry | Fixed cooked bundle, per-platform variant |
| Occlusion | Full — no "everything visible" simplification permitted |

---

## 2. Two gates

Passing requires both. They are measured separately and neither substitutes for the other.

### 2.1 Server gate

64 connections in one authoritative cell, running the reference workload replay, on the reference server class.

| Requirement | Value |
|---|---|
| Reference server class | 8 dedicated cores, 32 GB, no GPU |
| Authoritative simulation frequency | **64 Hz, invariant** |
| Tick budget P50 | ≤ 6.0 ms |
| Tick budget P95 | ≤ 11.0 ms |
| Tick budget P99 | ≤ 14.0 ms |
| Tick overrun (> 15.6 ms) | 0 in a 45-minute run |
| Resident memory | ≤ 6 GB |
| Peak transient allocation per tick | ≤ 2 MB |
| Cells per reference host | ≥ 4 concurrent, all meeting the above |

### 2.2 Client gate

**Every conformant target participates in the same session**, predicting and interpolating its full relevant set, under target-specific budgets. Not a desktop client with five ports watching.

A conforming run requires **at least one live client of each of the six targets** in the 64. The remaining slots may be replay-driven.

| Target | Render Hz | Frame P95 | Frame P99 | Resident memory | Prediction Hz |
|---|---|---|---|---|---|
| Windows / Linux / macOS | 120 | ≤ 8.3 ms | ≤ 11.0 ms | ≤ 6 GB | 64 |
| Android (reference tier) | 60 | ≤ 16.6 ms | ≤ 22.0 ms | ≤ 2.5 GB | 64 |
| iOS (reference tier) | 60 | ≤ 16.6 ms | ≤ 22.0 ms | ≤ 2.5 GB | 64 |
| Web (conformant profile) | 60 | ≤ 16.6 ms | ≤ 25.0 ms | ≤ 1.8 GB | 64 |

**Prediction frequency is 64 Hz on every target including Web and mobile.** This is the requirement that does not currently exist anywhere. The render-rate and presentation-rate governors may vary output; the predicted simulation cadence may not.

Web resident memory is stated against the wasm32 linear-memory budget, not browser process RSS.

---

## 3. Frequency contract

| Quantity | Value | Governed? |
|---|---|---|
| Authoritative simulation | 64 Hz | **Never** |
| Client predicted simulation | 64 Hz | **Never** |
| Snapshot transmission | 32 Hz nominal, 16 Hz floor | Yes — replication-rate governor |
| Client input transmission | 64 Hz nominal, 32 Hz floor | Yes — replication-rate governor |
| Interpolation delay | 2 snapshots nominal | Yes — interpolation-delay governor |
| Render | Per §2.2 | Yes — presentation-rate governor |
| Render quality tier | Per capability profile | Yes — render-quality governor |

A run in which any governor drives snapshot transmission below 16 Hz, or input below 32 Hz, for more than 2% of wall time **fails**. Governors exist to absorb transients, not to define a lower steady state.

---

## 4. Bandwidth contract

Measured at the client, application payload plus transport overhead.

| Direction | Sustained | Peak (5 s window) | Hard ceiling |
|---|---|---|---|
| Downstream per client | ≤ 384 kbps | ≤ 768 kbps | 1 Mbps |
| Upstream per client | ≤ 96 kbps | ≤ 192 kbps | 256 kbps |
| Server aggregate downstream | ≤ 24 Mbps | ≤ 48 Mbps | 64 Mbps |

Voice is **excluded** from these figures and budgeted separately (§8).

Exceeding the hard ceiling at any point fails the run. Exceeding sustained for more than 5% of wall time fails the run.

This is the binding constraint. A build that meets every frame-time target and exceeds downstream sustained has not passed.

---

## 5. Network condition profiles

Every profile runs the full 45-minute soak. Passing requires **all** profiles.

| Profile | RTT | Jitter | Loss | Reorder | Notes |
|---|---|---|---|---|---|
| `clean` | 20 ms | 2 ms | 0.1% | 0% | Baseline |
| `regional` | 60 ms | 8 ms | 0.5% | 0.2% | Typical matchmade |
| `distant` | 140 ms | 20 ms | 1.5% | 1.0% | Cross-region |
| `mobile-lte` | 90 ms | 45 ms | 2.5% | 1.5% | Bursty; jitter is the stressor |
| `mobile-degraded` | 180 ms | 80 ms | 6.0% | 3.0% | Congested cell |
| `handoff` | Varies | Varies | Varies | Varies | Forced cell↔wifi migration every 90 s |

The `handoff` profile exercises QUIC connection migration. A run in which handoff produces a visible session interruption fails.

**Correctness criteria under all profiles:**

- Rollback ladder step 4 (authoritative correction without local re-simulation) occurs in ≤ 0.5% of predicted ticks under `regional`, ≤ 2% under `mobile-degraded`.
- Causal closure size P99 stays within step-2 budget under `regional`.
- No desynchronization requiring full state resynchronization in a 45-minute run under any profile except `mobile-degraded`, where ≤ 1 is permitted.

---

## 6. Reference device and browser matrix

Ambition here means the floor holds on hardware people actually own, not on flagships.

| Class | Reference | Rationale |
|---|---|---|
| Android | Mid-tier 2022–2023 SoC: Adreno 6xx or Mali-G57-class GPU, 6 GB RAM, Android 12+ | Modal device, not flagship |
| iOS | A14-class (iPhone 12 generation) | Widely deployed, ~6 years old |
| Desktop GPU floor | Integrated Intel Xe / AMD RDNA2 iGPU | Not discrete |
| Desktop GPU ceiling | Current discrete, for `desktop-high` profile verification only |
| Chrome | Current stable | |
| Firefox | Current stable | |
| Safari | 26.4+ | WebTransport Baseline requirement |

Exact SKUs are pinned in the CI matrix definition and revised annually. **Revising the reference tier upward requires the same review as changing §1's floor.** Drifting the reference device is the easiest way to game this contract and it is explicitly forbidden.

---

## 7. Thermal soak

**45 minutes continuous, matching raid session length.**

| Requirement | Value |
|---|---|
| Duration | 45 min uninterrupted |
| Start condition | Device at ambient, ≥ 20 min idle since prior run |
| Ambient | 22 °C ± 2 °C, documented |
| Battery | ≥ 80% at start, not charging |

**Pass criteria:**

- All §2.2 frame budgets met for the **final 10 minutes**, not the first.
- Simulation and prediction cadence at 64 Hz throughout — no thermal condition may reduce it.
- Render-quality governor may reduce output tier. Reduction below `mobile-baseline` fails.
- No thermal shutdown, no OS-level throttle to a state where the render-quality governor cannot recover within 60 s.

Measuring the first two minutes of a mobile run and reporting it as a pass is the single most common form of this benchmark being faked. The final ten minutes are the measurement.

---

## 8. Voice budget

Separate from §4 bandwidth and §2 frame budgets.

| Parameter | Value |
|---|---|
| Concurrent transmitting | 64 (all players) |
| Client-side spatialized decode | 24 nearest |
| Server-mixed positional fold | Remainder, 2 channels |
| Codec | Opus, 24 kbps mono per stream |
| Voice downstream per client | ≤ 128 kbps |
| Voice upstream per client | ≤ 32 kbps |
| Client voice CPU | ≤ 8% of one core (mobile), ≤ 3% (desktop) |

Voice CPU counts against the same thermal envelope as sim, render, and networking (§17 of the spec). A run passing frame budgets with voice disabled has not passed.

---

## 9. Per-topology envelopes

§9.3 topology profiles do not inherit the §1 floor. Each carries its own contract.

| Topology | Player floor | Notes |
|---|---|---|
| Dedicated authoritative | **64** | This document's primary contract |
| Listen authoritative | **64 on desktop, 32 on mobile/web host** | See §10 |
| Peer rollback | 8 | O(n²) fan-out; relay-mediated above 4 |
| Deterministic lockstep | 16 | Bounded by slowest participant |
| Asynchronous authoritative | 256 | Latency-insensitive |

---

## 10. Cell hosting — every target hosts

**Every conformant target must be capable of hosting the authoritative cell.** Resolved in `ARCHITECTURE.md` v0.4 §1.1; see §9.3 (topology), §9.5 (relay), §14.3 (host trust), and §16 (anti-cheat) there.

| Host target | Player floor | Transport | Notes |
|---|---|---|---|
| Desktop | 64 | Direct QUIC listen | Full §2.1 budgets on consumer hardware, relaxed to 12 ms P95 |
| Android / iOS | 32 | Direct QUIC listen | Thermal-bounded; 45-min soak applies |
| Web | 32 | **Relay-mediated** | Browsers cannot accept inbound connections |

**The web host is a transport lowering, not an exception.** A browser cannot listen, so a browser-hosted cell connects outbound to a relay and clients connect to the relay. The relay forwards datagrams and performs no simulation, no validation, and no state inspection — and cannot, because payloads are end-to-end encrypted with keys it does not hold (`ARCHITECTURE.md` §9.5). Same wire protocol, one additional hop, counted in the §5 RTT profiles.

**Honest cost, stated rather than hidden:** a player-hosted authoritative cell is a cheat vector by construction. The host can observe and mutate authoritative state. Consequences, specified in `ARCHITECTURE.md` §14.3 and §16:

- Host-authoritative sessions carry a **trust class** attached to the session record.
- Ranked, competitive, and economy-affecting play requires a dedicated cell. No exceptions.
- Host-authoritative sessions submit their replay log for asynchronous server-side validation; divergence flags the host, not the participants.
- Host migration must be possible mid-session without state loss, using the §12 migration checkpoint.

This is the price of the ambitious answer. It is worth paying because listen-server on mobile and web unlocks session topologies nothing currently supports, and because the mitigation — trust classes plus asynchronous replay validation — is machinery the engine already has.

---

## 11. Measurement methodology

- **Deterministic replay.** All 64 input streams are recorded once, content-addressed, and replayed. Runs are comparable across builds, devices, and dates.
- **Verified fixture.** Content bundle hash and input-log hash checked before admission. Mismatch invalidates the run.
- **Live client requirement.** At least one live client per target per §2.2. Replay-driven clients fill remaining slots.
- **Instrumentation overhead.** Measured and subtracted; must be ≤ 3% of frame budget or the run is invalid.
- **Statistical basis.** P50/P95/P99 over the full 45 minutes, plus a separate final-10-minute window for mobile.
- **Run count.** 3 runs per configuration. Median run reported. Any run failing a hard ceiling fails the configuration.
- **Publication.** Every CI run publishes full traces to the telemetry store. Regressions are bisectable.

---

## 12. Pass/fail

A build **passes the §1 floor** when, on the same commit:

1. Server gate met (§2.1) on the reference server class.
2. Client gate met (§2.2) on all six conformant targets, with live clients of each in-session.
3. Bandwidth contract met (§4), voice enabled (§8).
4. All six network profiles passed (§5), including `handoff`.
5. Thermal soak passed on both mobile targets, measured on the final 10 minutes (§7).
6. Correctness criteria met (§5), including ladder step-4 rate and closure P99.
7. Fixture hashes verified (§11).

Anything less is a partial result and must be reported as such. **"Passes on desktop" is not a result. It is the absence of one.**

---

## 13. Revision policy

This document is versioned with the spec. Changes to §1.1 entity census, §1.2 content complexity, §6 reference devices, or §7 soak duration require explicit review — these are the four levers that make the number 64 mean less than it says.

Loosening any of them is a change to the product's ambition, not a benchmark adjustment, and must be recorded as such.
