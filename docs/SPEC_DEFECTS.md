# Bedlam — Specification Defect Register

Findings from a full read of the specification set against Zig 0.16.0 and current platform behaviour.

**Nothing here is resolved.** Every entry below touches a number, a gate, or a claim that `AGENTS.md` §5 places under stop-and-ask — benchmark parameters, conformance boundaries, and items the corpus marks OPEN. They are recorded with evidence so the decision is visible, per §5's own reasoning: an implementation that quietly picks an answer and buries it in code is worse than no implementation.

Severity is cost-to-discover-late, not cost-to-fix.

---

## 1. iOS resident memory budget exceeds the OS kill threshold on its own reference device

**Severity: critical. Cheap now, catastrophic in M1.**

`BENCHMARK_CONTRACT.md` §2.2 budgets iOS resident memory at ≤ 2.5 GB. `CONFORMANCE_PROFILES.md` §2 defines the conformant iOS device as "A14-class or newer" with 4 GB — an iPhone 12.

Jetsam's hard per-process limit on 4 GB iPhones is approximately **2,098 MB**. The budget sits above the point at which iOS terminates the process, so it is not merely tight, it is unreachable on the named device. Allowing headroom below the threshold puts the real figure nearer ≤ 1.8 GB — the same number already assigned to Web.

**Why it costs:** the entity census (§1.1), content complexity (§1.2), and streaming budget (`ARCHITECTURE.md` §4.1) are all sized downstream of this figure. It is unverifiable without Apple hardware, so it will not surface on its own. Fixing the number now costs an edit; discovering it after content is authored against 2.5 GB costs a re-cook of every asset tier.

**Resolution requires:** a benchmark parameter change under `BENCHMARK_CONTRACT.md` §13. Author's call.

---

## 2. The `handoff` profile may be unpassable on Web by construction

**Severity: critical. Architectural, not tuning.**

`BENCHMARK_CONTRACT.md` §5 requires every conformant target to pass a `handoff` profile forcing cell↔wifi migration every 90 s across a 45-minute run — 30 migrations — and states "a run in which handoff produces a visible session interruption fails." §12 item 4 makes all six profiles a hard gate.

`ARCHITECTURE.md` §9.2 lowers the conformant web transport to WebTransport, and §9.5 puts a relay-mediated web *host* on the same path. But **the WebTransport API exposes no connection-migration hook, and Chrome does not enable QUIC connection migration by default.** The application can neither depend on migration nor detect whether it occurred.

Consequence: a web client reconnects roughly 30 times per qualifying run. For a web host at the §10 floor of 32 players, each network change drops the session and fires host migration (`ARCHITECTURE.md` §14.3).

**Why it costs:** this is a missing platform capability, not a performance shortfall. The fix is a session-resumption layer above WebTransport — session identity, state resync, and reconnect budget — which belongs in the M1 transport design (§19) and cannot be bolted on afterwards. It is also fully testable today on Android hardware, which does real cell↔wifi handoff.

**Resolution requires:** an architecture decision in §9.2/§9.5. Author's call.

---

## 3. The voice budget does not close

**Severity: high. Pure arithmetic.**

`BENCHMARK_CONTRACT.md` §8 specifies 24 nearest streams decoded and spatialized client-side, Opus at 24 kbps mono per stream, against a voice downstream cap of ≤ 128 kbps.

24 × 24 kbps = **576 kbps**, which is 4.5× the stated cap. The cap supports roughly four discrete streams plus the server-mixed fold, not twenty-four. Closing the gap requires a mechanism the document does not state — server-side transcoding of distant speakers to a lower rate, which then imposes per-client transcode cost on the reference server.

Related: **server-side voice CPU is budgeted nowhere.** §2.1's tick budget has no voice line, and 64 clients each requiring a distinct positional fold is substantial DSP load on an 8-core host. `ARCHITECTURE.md` §17 budgets client voice CPU and is silent on the server.

**Resolution requires:** correcting one of stream count, per-stream rate, or the cap, and adding a server voice-CPU line to §2.1. Author's call.

---

## 4. The host floors — the project's boldest claim — have no gate

**Severity: critical.**

`README.md` and `ARCHITECTURE.md` §1.1 both identify a phone or browser tab hosting 32 players as the thing "not done anywhere." §18.1 lists host floors as non-negotiable and §19 makes them part of M1's exit criterion.

`BENCHMARK_CONTRACT.md` §12's seven-item pass/fail **never mentions hosting.** §10's host table gives player floors and the note "thermal-bounded; 45-min soak applies," but no tick budget, no P50/P95/P99, no overrun criterion, no resident-memory ceiling, no uplink budget, no host voice-CPU line. There is also no 32-stream input fixture — §0 and §11 content-address 64 streams only.

By the contract's own opening sentence, a scale requirement stated as a number and not gated is decorative. The most novel claim in the corpus is currently the least falsifiable one, and it is absent from `ARCHITECTURE.md` §21's open-questions list.

**Resolution requires:** a host gate in §12 with its own budgets and fixture. Author's call.

---

## 5. "64 Hz, invariant" has no measurement definition

**Severity: critical. It is the load-bearing meaning of "full tick."**

Cadence invariance is asserted across four documents (`BENCHMARK_CONTRACT.md` §3, §7; `CONFORMANCE_PROFILES.md` §4; `ARCHITECTURE.md` §1.3). `BENCHMARK_CONTRACT.md` §11 defines the statistical basis as "P50/P95/P99 over the full 45 minutes" — percentiles of tick *duration*, which is not a cadence statistic.

Nowhere is it stated whether 64 Hz means mean rate over a window, a bound on worst-case inter-tick interval, or a bound on catch-up ticks. §2.1 gives the server a hard zero-overrun bound; §2.2's client column reads "Prediction Hz | 64" with no accompanying statistic. **A client that stalls 200 ms and then executes 13 catch-up ticks has held 64 Hz mean cadence, satisfied every stated criterion, and violated the entire intent.**

**Resolution requires:** a cadence statistic in §11 — worst-case inter-tick interval and a catch-up-tick bound. Author's call.

---

## 6. The input log is the one anti-gaming lever §13 leaves ungoverned

**Severity: high. It is a hole in §0's central mechanism.**

`BENCHMARK_CONTRACT.md` §0 rests the entire anti-gaming argument on "a fixed, versioned, content-addressed scene plus a deterministic replay of 64 recorded input streams," concluding "tuning the engine is the only remaining lever."

§13 then places four things under change control: §1.1 census, §1.2 complexity, §6 devices, §7 soak duration. **The input log is not among them.** Re-recording 45 minutes of gentler 64-player input produces a new, perfectly valid content-addressed hash, invalidates only cross-build comparability — which no criterion gates — and fails nothing. Since the recordings determine firefight density, projectile count, destruction volume, contact count, and closure size, re-recording is strictly cheaper than any engine optimization.

**Resolution requires:** adding the input log to §13's change-control list. Low cost, high value.

---

## 7. The per-client relevant set is presented as fixed but is a runtime output

**Severity: high. Cheapest passing configuration in the contract.**

`BENCHMARK_CONTRACT.md` §1.1 lists "Per-client relevant set | 512 | 1,024 | The number that sets bandwidth" inside a table headed "Fixed. Verified by content hash." Relevant-set size is not a hashed input — it is an output of interest filtering — and no criterion in §4, §5, §11, or §12 requires a minimum *measured* relevant set.

Tightening interest filters therefore reduces bandwidth (passing §4, the declared binding constraint), reduces client frame time (passing §2.2), leaves the content hash unchanged, and degrades the game in a way no gate observes. `CONFORMANCE_PROFILES.md` §4 already sanctions the mechanism as a degradation lever.

This interacts with §11 below: the bandwidth budget is only satisfiable with aggressive relevance ordering, and nothing distinguishes "aggressive" from "gutted."

**Resolution requires:** a measured minimum relevant-set floor as a §12 criterion. Author's call.

---

## 8. The network profiles never constrain bandwidth

**Severity: high.**

`BENCHMARK_CONTRACT.md` §4 declares bandwidth "the binding constraint" and gives per-client and aggregate ceilings. §5's profile table has four columns — RTT, jitter, loss, reorder — and **no bandwidth column.** `mobile-degraded` is described as "congested cell" but caps only latency characteristics.

Consequence: no run ever tests whether the link could carry the traffic. The harness measures what the engine emits and compares it against a number. For mobile this additionally means the 45-minute soak may be run on Wi-Fi behind a latency shaper, never exercising the cellular modem — a substantial thermal contributor, and the reason the phone claim is interesting at all. §7 pins ambient temperature, idle time, and battery, but not radio.

**Resolution requires:** a bandwidth-constraint column in §5 and a radio requirement in §7. Author's call.

---

## 9. Closure-within-budget is near-tautological if the budget is adaptive

**Severity: high. A hard gate resting on an OPEN item.**

`BENCHMARK_CONTRACT.md` §5 makes "causal closure size P99 stays within step-2 budget under `regional`" a correctness criterion, and §12 item 6 makes it a hard gate.

`SCOPED_ROLLBACK.md` §3 marks budget derivation **OPEN** and names "adaptive budget derived from recent frame headroom" as the leading candidate. If the budget adapts to headroom, "closure stays within budget" is satisfied by the budget moving rather than by the closure being small — the criterion measures nothing.

Compounding it, §3 also marks step 2's *existence* OPEN: it "may collapse into step 3 … making it vestigial for the reference workload." A hard gate is therefore stated in terms of a threshold nobody has measured, on a ladder rung that may not exist.

**Resolution requires:** either an absolute closure ceiling in §5, or removing the criterion from §12 until `SCOPED_ROLLBACK.md` §8 step 1 has produced a measured distribution. Explicitly an `AGENTS.md` §5 stop-and-ask item.

---

## 10. Client physics load exceeds server physics load

**Severity: high. The largest un-computed number in the contract.**

`BENCHMARK_CONTRACT.md` §1.2 gives the server 2,560 sustained / 8,192 peak rigid bodies. §1.1 gives clients an additional 4,096 sustained / **16,384 peak** `derived` destruction fragments, client-simulated from replicated destruction events.

The mobile client — identified by `ARCHITECTURE.md` §1.3 and §17 as the binding thermal constraint — therefore carries more physics bodies than the 8-core/32 GB reference server. The `derived` classification correctly solves the bandwidth constraint by spending the other binding constraint, and the arithmetic is never performed.

Unstated and consequential: **whether fragments collide with players.** If they do, they are gameplay-relevant but unreplicated, so clients disagree about cover. If they do not, the design is simulating 16,384 non-interacting bodies on a phone. `ARCHITECTURE.md` §5.2's "anything that can't [obey the rules] is cosmetic-only" implies the latter, while §1.1 lists fragments in a census whose stated purpose includes worst-case causal closure.

**Resolution requires:** a stated fragment collision class and a client-side physics budget in §2.2. Author's call.

---

## 11. The bandwidth budget implies a design constraint the documents never state

**Severity: medium. Not a defect — an unstated consequence worth writing down.**

`BENCHMARK_CONTRACT.md` §4's 384 kbps sustained downstream, at §3's nominal 32 Hz snapshot rate, is **1,500 bytes per snapshot per client**, against §1.1's 512-entity relevant set — about 2.9 bytes per entity if all update.

At a realistic 8-byte quantized transform delta, that affords roughly **180 entity updates per snapshot**: about 35% of the relevant set, an effective per-entity refresh near 11 Hz against a 64 Hz simulation. §4's aggregate figure is consistent (24 Mbps ÷ 64 = 375 kbps).

The budget closes, but only if relevance ordering *is* the netcode rather than an optimization layered on it, and the interpolation-delay governor absorbs far more staleness than `ARCHITECTURE.md` §1.3 implies. This sits in tension with §1's stressor table, which lists "twitch aiming with hitscan and ballistic weapons" at 64 players.

**Suggested:** state the per-snapshot byte budget in §4 so it constrains the codec design from the start.

---

## 12. Script outside the rollback boundary makes script-authored gameplay latency-visible

**Severity: medium. Determines the M2 binding surface, decidable only in M1.**

`ARCHITECTURE.md` §10.1 places script inside the replay boundary and outside the rollback boundary: rollback "replays recorded commands and never re-invokes JS," and script policy "runs exactly once per logical tick." This is an elegant result — it removes script determinism from the correctness-critical path entirely.

The unstated consequence is that **anything authored in script is unpredicted, and therefore displays at full RTT.** §10.1's "script defines policy and reacts to events" and §18.14's ban on per-entity-per-tick callbacks together imply script is not on the prediction path at all, but the line between "policy" and "prediction-critical" is drawn nowhere. For the reference workload — a 64-player extraction shooter where weapon behaviour is plausibly script policy — that line determines what gameplay can live in JS.

**Resolution requires:** classifying which component classes and event paths script may drive, in §10.1 or `SCHEMA_AND_EVOLUTION.md` §3's script-exposure field. Needed before M2's binding generator, decidable during M1.

---

## 13. `AGENTS.md` §3 describes a toolchain that does not exist

**Severity: medium. Actively misleads automated contributors.**

§3 states "Zig, pinned. The version is in `build.zig.zon` and the toolchain is vendored." In fact `build.zig.zon` sets `minimum_zig_version = "0.16.0"`, which is a floor rather than a pin; nothing is vendored; there is no `zig-quickjs-ng` dependency; per-module optimization modes are not enforced in the build graph; and `build.zig` and `src/` are unmodified `zig init` output.

An unpinned compiler on a pre-1.0 language is a determinism hazard specifically because `--verify-determinism` (§7) compares hashes across builds.

**Partially addressed:** `.github/workflows/ci.yml` pins `ZIG_VERSION: 0.16.0`, and §3 has been corrected to describe current state. Whether to vendor the toolchain outright remains open.

---

## Verification notes

Cross-compilation results in `CI_TIERS.md` §4 were produced against Zig 0.16.0 from a Windows host with no platform SDKs installed. External platform behaviour cited in §1 and §2:

- iPhone 12 / 4 GB jetsam limit — <https://developer.apple.com/forums/thread/688973>
- Chrome QUIC connection migration not enabled by default — <https://groups.google.com/a/chromium.org/g/proto-quic/c/A4iaM8XW_zw>
- Connection migration not exposed to the Web API — <https://quic-go.net/docs/quic/connection-migration/>
