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

**Fragments do not collide with gameplay.** They collide with static world geometry and settle; they do not block projectiles, do not provide cover, and do not push characters or vehicles. This is forced rather than chosen: a `derived` component is not replicated, so each client derives its own fragment positions, and any gameplay consequence would mean clients disagreeing about cover — an authority violation, not a fidelity difference. `ARCHITECTURE.md` §5.2's "anything that can't [obey the rules] is cosmetic-only" is the governing rule and fragments are on the cosmetic side of it.

The consequence is that fragments are a *presentation* budget, not a simulation one, and they are budgeted as such in §1.2.

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

### 1.3 Client-side physics budget

Previously unstated, and it inverted the intended cost distribution. §1.2's rigid-body counts are *server* figures; §1.1 additionally gives every client 4,096 sustained / 16,384 peak `derived` destruction fragments to simulate locally. Taken literally that puts more bodies on a thermally-throttled phone than on the 8-core reference server — spending the mobile thermal envelope, which `ARCHITECTURE.md` §1.3 and §17 both name as the binding constraint, in order to save the bandwidth constraint.

The fragments are still `derived` and still not replicated. What changes is that their cost is now bounded per target class rather than assumed free:

| Target class | Concurrent fragments simulated | Fragment sim budget |
|---|---|---|
| Desktop | 4,096 sustained, 16,384 peak | ≤ 1.5 ms/frame |
| Mobile, Web | **1,024 sustained, 4,096 peak** | ≤ 2.0 ms/frame |

Fragments beyond the per-class cap are culled by distance and settle-age, never simulated and then hidden. Because fragments do not affect gameplay (§1.1), a lower cap is a visual difference between clients and not a divergence — which is exactly why the cap is allowed to differ per class while nothing else in the census does.

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
| iOS (reference tier) | 60 | ≤ 16.6 ms | ≤ 22.0 ms | ≤ 1.8 GB | 64 |
| Web (conformant profile) | 60 | ≤ 16.6 ms | ≤ 25.0 ms | ≤ 1.8 GB | 64 |

**Prediction frequency is 64 Hz on every target including Web and mobile.** This is the requirement that does not currently exist anywhere. The render-rate and presentation-rate governors may vary output; the predicted simulation cadence may not.

Web resident memory is stated against the wasm32 linear-memory budget, not browser process RSS.

**iOS resident memory is 1.8 GB, not 2.5 GB.** Jetsam's hard per-process limit on the 4 GB A14 devices named in `CONFORMANCE_PROFILES.md` §2 is approximately 2,098 MB — a budget above it is not tight, it is unreachable, because the OS terminates the process. 1.8 GB leaves headroom below the threshold and happens to equal the Web budget, which makes the two tightest targets share one number.

### What "64 Hz, invariant" means

Cadence is a separate statistic from tick duration, and the percentiles in §11 do not constrain it. A client that stalls 200 ms and then executes 13 catch-up ticks has held 64 Hz *mean* cadence while violating the intent entirely. Therefore:

| Quantity | Requirement |
|---|---|
| Inter-tick interval, P99.9 | ≤ 20 ms |
| Inter-tick interval, worst case | ≤ 31.25 ms (two tick periods) |
| Consecutive catch-up ticks in one frame | ≤ 2 |
| Frames containing any catch-up tick | ≤ 0.5% of a run |

A run violating any of these fails, regardless of mean rate.

### 2.3 Host gate

**The boldest claim in the project previously had no gate.** `README.md` and `ARCHITECTURE.md` §1.1 both identify a phone or browser tab hosting 32 players as the thing "not done anywhere," §18.1 makes host floors non-negotiable, and §19 puts them in M1's exit criterion — yet §12's pass/fail never mentioned hosting, §10 gave player counts with no budgets, and §0/§11 content-address 64 input streams with no 32-stream fixture. By this document's own opening sentence, a scale requirement stated as a number and gated by nothing is decorative.

A conforming host run uses a **separate content-addressed 32-stream input fixture**, hash-verified per §11, on the reference device for its class.

| Host class | Players | Tick P50 | Tick P95 | Tick P99 | Overrun | Resident | Uplink |
|---|---|---|---|---|---|---|---|
| Desktop (consumer) | 64 | ≤ 7.0 ms | ≤ 12.0 ms | ≤ 15.0 ms | 0 | ≤ 6 GB | ≤ 12 Mbps |
| Android / iOS (reference tier) | 32 | ≤ 9.0 ms | ≤ 13.0 ms | ≤ 15.0 ms | 0 | ≤ 1.8 GB | ≤ 6 Mbps |
| Web (relay-mediated) | 32 | ≤ 9.0 ms | ≤ 13.0 ms | ≤ 15.0 ms | 0 | ≤ 1.8 GB | ≤ 6 Mbps |

Additional requirements:

- **Cadence invariance (§2.2) applies to the host**, and the host is the source of every snapshot its clients roll back to. A host cadence violation degrades every participant's prediction simultaneously.
- **The mobile host runs the full §7 thermal soak** with authoritative simulation included, measured on the final 10 minutes.
- **A host is also a client.** It meets §2.2's frame budget for its own class concurrently with the tick budget above. Hosting is additive load, not a mode swap.
- **Host migration (`ARCHITECTURE.md` §14.3) is exercised**: at least one forced migration per run, completing with no state loss and no client disconnect.
- Relay hop latency is counted in the §5 RTT profiles for the web host.

**`SCOPED_ROLLBACK.md` §7's open question is in scope here.** A mobile host at minute 40 forming a 512-body constraint island is the worst case in the corpus, and whether authoritative simulation may degrade island *fidelity* while holding *cadence* is unresolved. The gate as written requires cadence and permits nothing about fidelity, which is deliberately the conservative reading until measurement says otherwise.

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

### 4.1 What the budget actually buys

Stated so it constrains the codec from the start rather than being rediscovered during M1:

```
384 kbps sustained ÷ 8            =  48,000 bytes/sec
48,000 ÷ 32 Hz snapshot rate      =   1,500 bytes per snapshot per client
1,500 ÷ 512 relevant entities     =     2.9 bytes per entity, if all update
```

A quantized transform delta is realistically 6–10 bytes with good bit-packing, so a snapshot affords roughly **180 entity updates** — about 35% of the relevant set, an effective per-entity refresh near 11 Hz against a 64 Hz simulation. §4's aggregate figure is consistent: 24 Mbps ÷ 64 = 375 kbps.

The budget closes, but only if relevance ordering *is* the netcode rather than a layer on top of it, and the interpolation-delay governor absorbs considerably more staleness for the long tail than `ARCHITECTURE.md` §1.3 implies. Priority accumulators decide which ~180 of 512 entities are worth bytes this snapshot; that decision is the design.

### 4.2 Minimum measured relevant set

§1.1 lists the per-client relevant set inside a table headed "Fixed. Verified by content hash." It is not a hashed input — it is a runtime output of interest filtering, and nothing gated it.

That made it the cheapest way to pass this document. Tightening interest filters reduces bandwidth (§4), reduces client frame time (§2.2), leaves every content hash unchanged, and degrades the game in a way no criterion observed. `CONFORMANCE_PROFILES.md` §4 already sanctions the mechanism as a degradation lever, so nothing prevented it being used as an optimization strategy.

| Requirement | Value |
|---|---|
| Measured relevant set, conformant client, P50 | ≥ 512 entities |
| Measured relevant set, conformant client, P05 | ≥ 384 entities |
| Reported per run | Full distribution, per target |

A run whose measured relevant set falls below these fails, whatever its bandwidth and frame numbers say.

---

## 5. Network condition profiles

Every profile runs the full 45-minute soak. Passing requires **all** profiles.

| Profile | RTT | Jitter | Loss | Reorder | Link capacity | Notes |
|---|---|---|---|---|---|---|
| `clean` | 20 ms | 2 ms | 0.1% | 0% | 100 Mbps | Baseline |
| `regional` | 60 ms | 8 ms | 0.5% | 0.2% | 25 Mbps | Typical matchmade |
| `distant` | 140 ms | 20 ms | 1.5% | 1.0% | 25 Mbps | Cross-region |
| `mobile-lte` | 90 ms | 45 ms | 2.5% | 1.5% | **3 Mbps** | Bursty; jitter is the stressor |
| `mobile-degraded` | 180 ms | 80 ms | 6.0% | 3.0% | **1.2 Mbps** | Congested cell |
| `handoff` | Varies | Varies | Varies | Varies | Varies | Forced cell↔wifi migration every 90 s |

**Link capacity is a shaped constraint, not a measurement.** §4 declares bandwidth the binding constraint and then, previously, only ever measured what the engine emitted and compared it to a number — no profile constrained what the link could carry. A congested-cell profile that caps latency and loss but not throughput is not a congested cell. The capacities above are imposed on the path; a run that exceeds them observes real queueing, real loss, and real congestion response.

**Radio requirement.** The mobile soak runs on the cellular modem for `mobile-lte` and `mobile-degraded`, not on Wi-Fi behind a shaper. The modem is a substantial thermal contributor and is the reason the phone claim is interesting; §7 previously pinned ambient temperature, idle time, and battery but said nothing about radio. Wi-Fi with a shaper remains valid for `clean`, `regional`, and `distant`.

The `handoff` profile exercises connection continuity across a network change. A run in which handoff produces a visible session interruption fails.

**Handoff on Web is a reconnect, not a migration.** WebTransport exposes no connection-migration hook and Chrome does not enable QUIC connection migration by default, so a web client cannot rely on the session surviving a network change and cannot detect whether it did. The web target therefore satisfies this profile via session resumption (`ARCHITECTURE.md` §9.2): resume within **≤ 500 ms**, with no state loss, no full resynchronization, and no visible interruption beyond the interpolation buffer. A web *host* additionally resumes without dropping its 32 clients. Native targets continue to satisfy it via QUIC migration proper.

**Correctness criteria under all profiles:**

- Rollback ladder step 4 (authoritative correction without local re-simulation) occurs in ≤ 0.5% of predicted ticks under `regional`, ≤ 2% under `mobile-degraded`.
- **Causal closure size P99 ≤ 256 entities under `regional`, ≤ 512 under `mobile-degraded`.** Stated as an absolute ceiling rather than "within step-2 budget": `SCOPED_ROLLBACK.md` §3 marks budget derivation OPEN and leans adaptive, and a criterion phrased against an adaptive budget is satisfied by the budget moving rather than by the closure being small. It would have measured nothing. These figures are provisional and are the first thing `SCOPED_ROLLBACK.md` §8 step 1 should replace with measured data — but a provisional absolute number is falsifiable and a self-referential one is not.
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
| **Radio** | **Cellular modem active for `mobile-lte` and `mobile-degraded`; Wi-Fi may not substitute** |
| **Screen** | **Display on at ≥ 50% brightness for the full run** |

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
| Client-side spatialized decode | **6 nearest** |
| Server-mixed positional fold | Remainder, 2 channels |
| Codec | Opus, **16 kbps** mono per discrete stream |
| Fold bitrate | 24 kbps, 2 channels |
| Voice downstream per client | ≤ 128 kbps |
| Voice upstream per client | ≤ 32 kbps |
| Client voice CPU | ≤ 8% of one core (mobile), ≤ 3% (desktop) |
| **Server voice CPU** | **≤ 1.5 ms per tick per cell, outside the §2.1 budget** |

**The arithmetic must close, and previously did not.** 24 discrete streams at 24 kbps is 576 kbps against a 128 kbps cap — 4.5× over, with no transcoding mechanism stated anywhere. Delivering 24 discrete spatialized streams is not achievable inside this cap at any usable Opus bitrate, and §4 names bandwidth as the binding constraint, so the count gives way rather than the cap:

```
6 discrete × 16 kbps  =  96 kbps
positional fold, 2 ch =  24 kbps
                        ---------
                        120 kbps  ≤ 128 kbps  ✓
```

Six spatialized speakers is what proximity chat in a 64-player extraction shooter actually needs; the remainder folds. Opus at 16 kbps mono is solid for speech.

**Server voice CPU is now budgeted.** It previously appeared nowhere: 64 clients each requiring a distinct positional fold is 64 mixes per cell per tick, which is real DSP load on the 8-core reference host. It is stated outside the §2.1 tick budget because it runs off the tick thread, but it competes for the same cores and a run that meets §2.1 by starving the mixer has not passed.

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

**Budgets and pass criteria for these floors are §2.3**, which also defines the 32-stream fixture they are measured against. This table gives the topology; §2.3 gives the gate. Until §2.3 was added these floors were stated here and gated nowhere, which made the project's most novel claim its least falsifiable one.

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
3. **Cadence invariance met (§2.2)** — inter-tick interval and catch-up bounds, not mean rate.
4. **Host gate met (§2.3)** on desktop, both mobile targets, and the relay-mediated web host, against the 32-stream fixture, including one forced host migration.
5. Bandwidth contract met (§4), voice enabled (§8).
6. **Minimum measured relevant set met (§4.2).**
7. All six network profiles passed (§5) under shaped link capacity, including `handoff`.
8. Thermal soak passed on both mobile targets, on the cellular modem, measured on the final 10 minutes (§7).
9. Correctness criteria met (§5), including ladder step-4 rate and the absolute closure ceiling.
10. Fixture hashes verified (§11), for both the 64-stream and 32-stream fixtures.

Anything less is a partial result and must be reported as such. **"Passes on desktop" is not a result. It is the absence of one.**

Items 3, 4 and 6 were added after a full read of this contract found that cadence invariance, the host floors, and the relevant set were each asserted somewhere in the corpus and gated nowhere. Each was passable by a build that violated the intent completely.

---

## 13. Revision policy

This document is versioned with the spec. Changes to §1.1 entity census, §1.2 content complexity, §6 reference devices, §7 soak duration, or **the recorded input streams** require explicit review — these are the levers that make the number 64 mean less than it says.

**The input log is the fifth lever and was previously ungoverned.** §0 rests this contract's entire anti-gaming argument on "a fixed, versioned, content-addressed scene plus a deterministic replay of 64 recorded input streams," concluding that tuning the engine is the only remaining lever. But re-recording 45 minutes of gentler input produces a new and perfectly valid content-addressed hash, invalidates only cross-build comparability — which nothing gated — and fails no criterion. Since the recordings determine firefight density, projectile count, destruction volume, contact count, and closure size, re-recording was strictly cheaper than any engine optimization. Both the 64-stream and 32-stream fixtures are now under this policy.

Loosening any of them is a change to the product's ambition, not a benchmark adjustment, and must be recorded as such.
