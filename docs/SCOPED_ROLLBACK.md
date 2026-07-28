# Bedlam — Scoped Rollback

Companion to `ARCHITECTURE.md` §6. **This is a design brief, not settled specification.** It states the problem precisely, enumerates the mechanisms worth evaluating, and defines how they will be measured. It does not claim a solution, because there isn't one yet.

Treat every section marked **OPEN** as a genuine research question. Do not let an implementation quietly pick an answer and bury it.

---

## 0. The problem

Client-side prediction requires that a mispredicted tick can be corrected. The standard correction is rollback: restore world state to the last authoritative snapshot, replay inputs forward.

At Bedlam's floor — 64 players, 4,192 replicated entities, destructible structures, vehicle constraint chains, on a phone and in a browser — **full-world rollback does not fit.** Re-simulating everything for a 6-tick correction at 64 Hz is not a tuning problem.

The requirement is therefore to re-simulate **only what causally depended on the mispredicted state**. That subset is the *causal closure* of the misprediction.

The danger is stated in `ARCHITECTURE.md` §6 and bears repeating: without real provenance, scoped rollback becomes global rollback with a graph traversal in front of it — strictly worse than global rollback, because it pays for the traversal too.

---

## 1. What makes this hard

**Closure is dynamic.** Static system read/write sets bound what *could* be touched. What *was* touched depends on runtime data — which entities were near which, which contacts formed, which events fired.

**Physics is adversarial to scoping.** A constraint solver couples every body in an island. A vehicle with occupants, a collapsing structure, a chain of debris contacts — these produce islands that are large, transient, and formed by exactly the gameplay moments where prediction quality matters most.

**Closure grows with tick depth.** A 2-tick correction may touch 8 entities. A 6-tick correction on the same misprediction may touch 400, because each replayed tick expands the frontier.

**The budget is not uniform.** A desktop client has headroom a thermally-throttled phone at minute 40 does not. The same closure is affordable on one and not the other, simultaneously, in the same session.

**Determinism must survive scoping.** Re-simulating a subset must produce the same result as re-simulating everything, or the correction introduces a new divergence. This is the constraint that kills most naive approaches.

---

## 2. Provenance sources

Six candidate inputs. Each has a different cost/precision tradeoff and they are not mutually exclusive.

| Source | Derivation | Precision | Cost |
|---|---|---|---|
| **Static read/write sets** | `comptime`, from system query declarations | Coarse — bounds the possible | Free at runtime |
| **Dynamic interaction edges** | Recorded per tick as systems touch entities | Exact | Per-access recording overhead |
| **Physics islands** | Solver island decomposition, already computed | Exact for physics | Free — the solver builds them anyway |
| **Event producer/consumer** | Event bus routing | Exact | Cheap |
| **Command provenance** | Input log, including script commands | Exact | Free — already recorded for replay |
| **Spawn/despawn edges** | Entity lifecycle | Exact | Cheap |

**OPEN — the recording overhead of dynamic edges.** Exact per-access edge recording may cost more than it saves. Candidate mitigations: record at chunk granularity rather than entity; record only for `predicted` components; sample and conservatively over-approximate between samples. Unmeasured.

**OPEN — whether static sets alone are sufficient.** If system read/write sets are declared narrowly enough, the static closure may be small enough to skip dynamic recording entirely for most systems, with dynamic recording reserved for physics and events. This would be the cheapest viable design and should be falsified before more expensive options are built.

---

## 3. The ladder

Four steps. Step chosen **per frame against a measured budget**, never per game as configuration.

| Step | Mechanism | Cost | Visible artifact |
|---|---|---|---|
| 1 | Local prediction island — the entities the local player directly interacted with | Lowest | None |
| 2 | Expanded dynamic causal island — full closure including physics islands and event cascades | Moderate | None |
| 3 | Whole-zone rollback | High | Possible hitch |
| 4 | Authoritative correction, no local re-simulation | Lowest | **Visible snap** |

Step 4 is not failure. It is the pressure valve that makes the other three safe to attempt. A design without it will miss frames instead of snapping, which is worse.

**OPEN — step 2's viability.** If physics islands cannot be decomposed (§4), step 2 may collapse into step 3 whenever physics is involved, making it vestigial for the reference workload. This is the single highest-value question in this document and should be answered first, because a negative answer simplifies the whole design to a three-step ladder.

**OPEN — budget derivation.** Per-frame budgets must come from measurement, not from a constant. Candidates: fixed ms budget per target class; adaptive budget derived from recent frame headroom; thermal-aware budget on mobile via ADPF. Probably adaptive, but unmeasured.

**OPEN — hysteresis.** Oscillating between steps 2 and 4 frame to frame would be visually worse than consistently using step 4. Needs damping; the shape is unknown.

---

## 4. Physics islands

The crux.

The solver already computes islands — connected components of bodies coupled by contacts and constraints. That decomposition is free and exact. The question is what can be done with an island that exceeds budget.

**Option A — re-simulate the whole island.** Correct, potentially enormous. A collapsing structure can couple hundreds of bodies.

**Option B — split the island at weak couplings.** Treat low-impulse contacts as breakable for rollback purposes, re-simulate the sub-island, accept bounded error at the seam. Fast, and **introduces divergence** — the exact thing rollback exists to eliminate.

**Option C — snapshot island state and skip.** Restore the island wholesale from the authoritative snapshot without re-simulating, re-simulate only non-physics dependents. Correct for the island, but the local player's interaction with it is lost, producing a snap scoped to the island rather than the world.

**Option D — bound island size at content level.** Constrain the content so islands never exceed a size the budget can absorb. Pushes cost onto level designers and is enforced by the §6.3 metering surfacing closure size in the editor.

**OPEN — which of A/C/D, or a ladder among them.** Option B is provisionally rejected: bounded error at a seam is still divergence, and divergence in a rollback system compounds. Reopening it requires demonstrating the error is provably bounded and self-correcting, not merely small in a demo.

**Provisional lean:** D as the primary discipline, C as the runtime fallback, A when it fits. This means the engine's job is largely to *report* island sizes loudly enough that content stays inside budget.

---

## 5. Determinism under scoping

Re-simulating a subset must equal re-simulating everything. Requirements:

- **Closure must be a superset of true causal dependence.** Over-approximation costs performance. Under-approximation costs correctness. When uncertain, over-approximate.
- **Iteration order within the closure must match full-world order.** If systems iterate archetype chunks and the closure is a subset of chunks, ordering must be stable regardless of which subset. This constrains the chunk iteration design.
- **Reductions must be order-independent** or fixed-tree, per `ARCHITECTURE.md` §7.
- **Random streams must be per-entity or per-system**, never global — a global PRNG advanced a different number of times during scoped replay produces divergence immediately.

**Validation:** `--verify-scoped-rollback` runs the same misprediction through scoped and full-world rollback and compares. Must be in CI from the first working implementation, and must run against the benchmark's recorded input streams, not synthetic cases.

---

## 6. Metering

Closure size is a **first-class metric**, not a debug counter.

Per correction, record: trigger tick and depth · closure entity count · closure chunk count · largest physics island touched · ladder step selected · wall time · budget remaining.

Surfaced in three places:

1. **Editor live view** — content authors see closure size as they build. A room that produces 400-entity closures should be visible as a problem while it is being made, not after shipping.
2. **Server telemetry** — aggregate closure distributions per map region, per build.
3. **Benchmark output** — ladder step distribution is a pass criterion (`BENCHMARK_CONTRACT.md` §5).

A game whose closure regularly reaches step 3 has a content problem Bedlam should report, not silently absorb. Metering is what makes that reporting possible, which is why it ships with the first implementation rather than after.

---

## 7. Interaction with host topology

`ARCHITECTURE.md` §14.3 puts an authoritative cell on a phone. The worst case for this document is therefore: **a mobile host, at minute 40 of thermal soak, running authoritative simulation for 32 players, when a 512-body constraint island forms.**

The host is not predicting — it is authoritative, so it does not roll back. But it is the source of the snapshots every client rolls back *to*, and its tick budget is the tightest in the session. If host tick time spikes on island formation, every client's prediction quality degrades simultaneously.

**OPEN — whether the host needs its own island budget** distinct from the client rollback budget, and whether authoritative simulation may degrade island fidelity under thermal pressure without violating the invariant that simulation cadence never changes. Degrading *fidelity* while holding *cadence* may be acceptable; it is not obviously so.

---

## 8. Sequencing

1. **Measure first.** Instrument closure size on a naive full-world rollback implementation against the benchmark workload. Get the actual distribution before designing for it.
2. **Answer §4** — physics island decomposition. Everything downstream depends on it.
3. **Falsify the cheap design** — static read/write sets plus physics islands plus event edges, no dynamic per-access recording. If that suffices, stop.
4. **Build the ladder** with metering, step 1/3/4 only.
5. **Add step 2** only if §4 resolved favorably.
6. **Tune budgets** against measured data, per target class.

Steps 1 and 2 are M1. Steps 3–6 are M1 continuation and may extend past the M1 exit gate if the gate is met via steps 1/3/4 alone.
