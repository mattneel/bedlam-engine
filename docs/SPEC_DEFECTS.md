# Bedlam — Specification Defect Register

Findings from a full read of the specification set against Zig 0.16.0 and current platform behaviour, and what was done about each.

**Status: 12 of 13 resolved in the spec. One deferred to measurement.**

These entries touch benchmark parameters and gates, which `AGENTS.md` §5 places under stop-and-ask. They were resolved on the author's instruction to use judgement rather than escalate. §5's purpose is to stop a decision becoming invisible, not to stop it being made, so every change below records the reasoning that produced it and the alternatives rejected. **Reversing any of these should be a matter of disagreeing with the argument, not of reconstructing it.**

Severity is cost-to-discover-late.

---

## 1. iOS resident memory budget exceeded the OS kill threshold ✅

**Was:** `BENCHMARK_CONTRACT.md` §2.2 budgeted iOS at ≤ 2.5 GB, against an A14 / 4 GB reference device (`CONFORMANCE_PROFILES.md` §2) whose jetsam hard limit is ≈ 2,098 MB. Not tight — unreachable, because the OS terminates the process first.

**Now:** ≤ 1.8 GB, with the reasoning stated inline in §2.2.

**Why 1.8 and not 2.0:** headroom below a kill threshold is not optional, and 1.8 GB is already the Web budget. Two targets sharing one number is easier to design content against than two numbers 200 MB apart for no articulable reason.

**Rejected:** raising the reference device to a 6 GB iPhone. That is reference-tier drift, which §6 explicitly forbids and which `CI_TIERS.md` §5 flags as the easiest way to game this contract.

---

## 2. `handoff` was unpassable on Web by construction ✅

**Was:** §5 requires 30 forced network changes per run with no visible interruption, and §12 gates on it. But WebTransport exposes no connection-migration hook and Chrome does not enable QUIC connection migration by default, so a web client can neither rely on migration nor detect it. A relay-mediated web host would drop 32 clients on every change.

**Now:** `ARCHITECTURE.md` §9.2 gains session resumption as a transport-layer requirement — session identity above the transport, resumption re-attaching to the existing acked baseline and interest set, a hold window on the cell, and a 500 ms budget. §5 states that Web satisfies `handoff` by resumption and native targets by QUIC migration.

**Why it is one mechanism on all targets, not a web special case:** a resumption path exercised only by the target that needs it is a resumption path that is broken on that target. Native uses it whenever migration fails, which is often enough to keep it working.

**Deliberately not done:** treating this as an error path. It is a per-90-seconds event on mobile, which makes it normal operation.

---

## 3. The voice budget did not close ✅

**Was:** §8 specified 24 discrete spatialized streams at 24 kbps against a 128 kbps cap — 576 kbps, 4.5× over, with no transcoding mechanism stated. Server-side voice CPU was budgeted nowhere despite 64 clients each needing a distinct positional fold.

**Now:** 6 spatialized at 16 kbps + a 24 kbps stereo fold = 120 kbps, arithmetic shown in §8. Server voice CPU budgeted at ≤ 1.5 ms/tick/cell, outside the §2.1 tick budget but explicitly competing for the same cores.

**Why the count gave way rather than the cap:** §4 names bandwidth the binding constraint. Raising the voice cap to ~600 kbps would exceed the entire game-data budget for a secondary system. Six spatialized speakers is what proximity chat in a 64-player extraction shooter actually uses; the rest fold.

**Rejected:** server-side transcoding of distant speakers. It closes the arithmetic but adds per-client transcode load to the cell, which is the wrong place to spend it.

---

## 4. The host floors — the boldest claim — had no gate ✅

**Was:** hosting on a phone or browser is what `README.md` calls "not done anywhere," is non-negotiable per §18.1, and is in M1's exit criterion. §12's pass/fail never mentioned it. §10 gave player counts with no budgets. No 32-stream fixture existed.

**Now:** `BENCHMARK_CONTRACT.md` §2.3 is a full host gate — per-class tick percentiles, overrun, resident memory, uplink, a separate hash-verified 32-stream fixture, cadence invariance, the full thermal soak with authoritative simulation included, a forced host migration per run, and the requirement that a host meets its client frame budget concurrently. §12 gains it as item 4.

**Judgement in the numbers:** host tick budgets are set slightly looser than §2.1's dedicated-server figures (P50 7/9 ms vs 6 ms) because consumer and mobile hardware is not the reference server, but overrun stays at zero because a host overrun degrades every client's prediction simultaneously.

---

## 5. "64 Hz, invariant" had no measurement definition ✅

**Was:** asserted across four documents; §11 defined percentiles of tick *duration*, which is not a cadence statistic. A client stalling 200 ms then running 13 catch-up ticks held 64 Hz mean and passed everything.

**Now:** §2.2 gains explicit cadence bounds — inter-tick P99.9 ≤ 20 ms, worst case ≤ 31.25 ms, ≤ 2 consecutive catch-up ticks, catch-up frames ≤ 0.5% of a run. §12 gains it as item 3.

**Why worst case is two tick periods:** one missed tick is a hitch, a sustained pattern of them is a different simulation. The bound has to permit the former to be falsifiable about the latter.

---

## 6. The input log was the ungoverned anti-gaming lever ✅

**Was:** §0 rests the whole contract on hash-verified input streams; §13 change-controlled the census, complexity, devices, and soak duration but not the recordings. Re-recording gentler input produced a valid hash and failed nothing — cheaper than any engine optimization.

**Now:** §13 lists the recorded input streams as the fifth lever, covering both fixtures.

---

## 7. The relevant set was presented as fixed but was a runtime output ✅

**Was:** §1.1 listed 512 inside a table headed "Fixed. Verified by content hash." Interest-filter output is not a hashed input, and nothing gated it — so tightening filters cut bandwidth *and* frame time, left every hash unchanged, and degraded the game unobserved. The cheapest way to pass the document.

**Now:** §4.2 sets a measured floor — P50 ≥ 512, P05 ≥ 384, full distribution reported per target. §12 gains it as item 6.

---

## 8. Network profiles never constrained bandwidth ✅

**Was:** §4 declared bandwidth binding; §5 shaped only RTT, jitter, loss, and reorder. No run tested whether the link could carry the traffic — the harness measured emission and compared it to a number. `mobile-degraded` capped latency and called itself a congested cell.

**Now:** §5 gains a link-capacity column, shaped on the path: 3 Mbps for `mobile-lte`, 1.2 Mbps for `mobile-degraded`. §7 gains a radio requirement — the mobile soak runs on the cellular modem, not Wi-Fi behind a shaper — and a screen-on requirement, both being substantial thermal contributors that were unpinned while ambient temperature was pinned to ± 2 °C.

---

## 9. Closure-within-budget was near-tautological ✅

**Was:** §5 gated on "closure P99 within step-2 budget" while `SCOPED_ROLLBACK.md` §3 marks budget derivation OPEN and leans adaptive. An adaptive budget makes the criterion satisfiable by the budget moving. Compounding it, §3 also marks step 2's *existence* open.

**Now:** an absolute ceiling — closure P99 ≤ 256 entities under `regional`, ≤ 512 under `mobile-degraded` — flagged inline as provisional and as the first thing `SCOPED_ROLLBACK.md` §8 step 1 should replace with measured data.

**Why provisional-but-absolute beats correct-but-circular:** a provisional absolute number is falsifiable and will be wrong in a visible way. A self-referential one cannot be wrong, which is the problem.

---

## 10. Client physics load exceeded server physics load ✅

**Was:** §1.2 gave the server 2,560 / 8,192 rigid bodies; §1.1 gave every client 4,096 / 16,384 `derived` fragments to simulate. That put more bodies on a thermally-throttled phone than on the 8-core reference server — spending the thermal constraint to save the bandwidth constraint, with the arithmetic never performed. Whether fragments collide with gameplay was unstated and decisive.

**Now:** §1.1 declares fragments non-colliding with gameplay — they collide with static geometry and settle, but do not block projectiles, provide cover, or push characters. §1.2 gains a client-side fragment budget: 4,096/16,384 on desktop, **1,024/4,096 on mobile and Web**, with ≤ 1.5–2.0 ms/frame.

**Why non-colliding is forced rather than chosen:** `derived` components are not replicated, so each client derives its own fragment positions. Any gameplay consequence means clients disagreeing about cover, which is an authority violation rather than a fidelity difference. §5.2's "anything that can't obey the rules is cosmetic-only" already decided this; it just was not written down.

**Why the cap may differ per class when nothing else in the census does:** because fragments cannot affect gameplay, a lower cap is a visual difference and not a divergence. That property is exactly what makes it safe to vary, and it would not be safe for any replicated class.

---

## 11. The per-snapshot byte budget was never computed ✅

**Now:** §4.1 states it — 1,500 bytes per snapshot per client, ~180 of 512 relevant entities updated, an effective per-entity refresh near 11 Hz against a 64 Hz simulation. Recorded so it constrains the codec from the start rather than being rediscovered during M1, and so the tension with §1's "twitch aiming" stressor is visible.

---

## 12. Script outside the rollback boundary made script gameplay latency-visible ✅

**Was:** §10.1 places script outside the rollback boundary — elegant, because it removes script determinism from the correctness path. The unstated consequence is that script output is authoritative-only, so anything authored in script displays at full RTT and cannot be predicted. The line between "policy" and "prediction-critical" was drawn nowhere, and it decides what may be written in JS at all.

**Now:** §10.1 gains the boundary as a table on component class — script may not write `predicted` components or participate in the rollback projection. Prediction-critical gameplay is native. For the reference workload: weapon fire, movement, and hit registration native; loadout, objective and extraction logic, scoring, spawn policy, and mission flow script. Enforced by `SCHEMA_AND_EVOLUTION.md` §3's script-exposure field and §10's check 10.

**Why now rather than at M2:** the rule decides the binding surface the M2 generator emits, and getting it wrong is invisible until someone plays at 140 ms — at which point the fix is rewriting gameplay from JS into Zig.

---

## 13. `AGENTS.md` §3 described a toolchain that did not exist ✅

**Was:** claimed pinned and vendored; reality was a `minimum_zig_version` floor, nothing vendored, no `zig-quickjs-ng`, no per-module optimization enforcement, and stock `zig init` output.

**Now:** §3 describes current state and marks the rest as intended. `.github/workflows/ci.yml` pins `ZIG_VERSION`. Whether to vendor the toolchain outright is still open, and is a real question rather than a defect — an unpinned compiler on a pre-1.0 language is a determinism hazard specifically because `--verify-determinism` compares hashes across builds.

---

## Deferred to measurement

**Host island budget** — whether an authoritative host needs an island budget distinct from the client rollback budget, and whether authoritative simulation may degrade island fidelity under thermal pressure while holding cadence. `SCOPED_ROLLBACK.md` §7, promoted to `ARCHITECTURE.md` §21 item 5.

This one is not resolvable by judgement. §2.3 takes the conservative reading — cadence gated, fidelity degradation not permitted — because that is falsifiable now and the permissive reading cannot be evaluated until a mobile host has been measured forming a 512-body island at minute 40. Resolving it by implementation is precisely what `AGENTS.md` §5's last bullet forbids.

---

## Verification notes

Cross-compilation results in `CI_TIERS.md` §4 were produced against Zig 0.16.0 from a Windows host with no platform SDKs installed. External platform behaviour cited above:

- iPhone 12 / 4 GB jetsam limit ≈ 2,098 MB — <https://developer.apple.com/forums/thread/688973>
- Chrome QUIC connection migration not enabled by default — <https://groups.google.com/a/chromium.org/g/proto-quic/c/A4iaM8XW_zw>
- Connection migration not exposed to the Web API — <https://quic-go.net/docs/quic/connection-migration/>
- iOS cross-compilation needs `--libc`, not `--sysroot` — <https://github.com/ziglang/zig/issues/19217>
