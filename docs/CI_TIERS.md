# Bedlam — CI Tiers

Companion to `CONFORMANCE_PROFILES.md` and `BENCHMARK_CONTRACT.md`. Defines the two classes of automated verification, which claims each may support, and which targets are currently reachable by each.

---

## 0. The contradiction this resolves

`ARCHITECTURE.md` §18.20 requires "physical device, GPU, browser, network-condition, and thermal-soak matrix on every commit, at 64." `AGENTS.md` §4 requires the CI matrix be built before the second target, on the correct grounds that "six-platform CI added late is six-platform CI that never gets added."

Both are right about what matters. Together they are unsatisfiable, and not because of any project's budget:

| Input | Source | Value |
|---|---|---|
| Network condition profiles, all required | `BENCHMARK_CONTRACT.md` §5 | 6 |
| Runs per configuration | `BENCHMARK_CONTRACT.md` §11 | 3 |
| Soak duration | `BENCHMARK_CONTRACT.md` §7 | 45 min |
| Mandatory cooldown between mobile runs | `BENCHMARK_CONTRACT.md` §7 | ≥ 20 min idle |

6 × 3 × (45 + 20) = **19.5 hours of thermally-controlled device time per verdict**, at documented 22 °C ± 2 °C ambient. That is not a per-commit gate on any hardware budget. Parallelising across devices raises throughput but not verdict latency, and introduces device-to-device thermal variance as a measurement confound.

The resolution is not to weaken §18.20. §18.20's actual claim — **a compiler green check is not a working target** — is correct and is preserved exactly. What is wrong is the implied cadence. Splitting verification into two tiers keeps the claim and fixes the cadence.

> Correctness runs on every commit and proves nothing about the floor.
> Measurement runs on a schedule and is the only thing that may speak about the floor.

---

## 1. Tier C — correctness

Runs on every commit, on hosted runners, with no special hardware.

**Scope:** compilation across all six target families · unit and integration tests on every natively-executable ISA/OS combination · fuzz targets (`AGENTS.md` §3) · determinism verification across ISAs (`ARCHITECTURE.md` §7) · schema and manifest checks (`SCHEMA_AND_EVOLUTION.md` §10) · format and lint.

**Explicitly out of scope:** frame time, tick time, bandwidth, thermal behaviour, GPU output, player counts, and every other quantity in `BENCHMARK_CONTRACT.md`.

Implementation: `.github/workflows/ci.yml`.

---

## 2. Tier M — measurement

Runs on physical devices on a schedule, never as a per-commit gate.

**Scope:** everything in `BENCHMARK_CONTRACT.md`. This is the only tier whose output may be described as a result about the §1 floor, and only when §12's full seven-item pass/fail is satisfied.

Not yet implemented. It requires hardware the project does not have — see §5.

---

## 3. The inadmissibility rule, extended

`CONFORMANCE_PROFILES.md` §5 makes compatibility-profile measurements inadmissible as evidence about P0 in either direction. The same rule, for the same reason, applies to tiers:

> **Tier C output is inadmissible as evidence about P0, in either direction.**

Neither as evidence the floor is met, nor as evidence it is unmet. A hosted runner has no GPU, shares noisy vCPUs, has no thermal envelope, and shapes no network. A Tier C run that is fast proves nothing; a Tier C run that is slow proves nothing.

This cuts both ways deliberately, exactly as §5 does. It prevents a green matrix from being reported as conformance, and it prevents a slow hosted-runner result from being cited as evidence a target cannot hold the floor.

Any performance claim, regression report, or design decision citing Tier C as evidence about the floor is invalid on its face. `.github/workflows/ci.yml` carries a `tier-guard` job that fails if the workflow acquires measurement language.

---

## 4. Tier C matrix — current state

Rows are per target family in `ARCHITECTURE.md` §4.1. **Dark rows are present and expected-failing rather than absent.** The matrix shape is the thing that must not be added late; individual rows light as the build graph earns them.

| Target | Build | Native test | Status | Blocker |
|---|---|---|---|---|
| Windows | ✅ cross + native | ✅ `windows-latest` x86_64 | lit | — |
| Linux | ✅ cross + native | ✅ `ubuntu-latest` x86_64 | lit | — |
| Linux arm64 | ✅ cross | ✅ `ubuntu-24.04-arm` aarch64 | lit | — |
| macOS | ✅ cross from Linux | ✅ `macos-latest` aarch64 | lit | — |
| Android | ✅ cross | ⬛ | partial | emulator row; NDK for GameActivity surfaces |
| Web (`wasm32-wasi`) | ✅ cross | ⬛ | partial | second wasm config, not the shipping target |
| Web (`wasm32-freestanding`) | ✅ cross | ⬛ | partial | the shipping target; browser harness row pending |
| iOS | ✅ cross (static lib) | ⬛ | partial | app bundle, signing and launch — see below |

Verified locally against Zig 0.16.0: **all eight build targets compile clean from a Windows host with no platform SDKs installed**, including `aarch64-ios`. No row is dark.

### Neither Web nor iOS is an executable

Both targets have a host that owns the entry point, so both are built as something other than a program — see `build.zig`.

- **Web** is rooted at `src/web.zig` with no entry point. A browser artifact is a module the TypeScript bootstrap instantiates (`ARCHITECTURE.md` §2). Rooting it at a CLI entry point pulls `std.process.Init` → `std.Io.Threaded` → `posix.getrandom` and `posix.IOV_MAX`, none of which exist on freestanding wasm.
- **iOS** is a static library. An Xcode app target owns `UIApplicationMain`, which lives in a thin Objective-C TU (§2, §4.1). A static archive has no link step, so it needs no Apple SDK and no macOS runner — which is why this row builds from any host and costs nothing.

Enforcing both structurally, by which artifact kind and root file the build graph selects, is deliberate. A conditional inside `main.zig` is something a later change can wander past.

**Linking an iOS executable is a different problem, and `--sysroot` does not solve it.** Zig needs a `--libc` file naming the SDK's `usr/include` as both `include_dir` and `sys_include_dir`, with `crt_dir` and the rest blank — or the same file via the `ZIG_LIBC` environment variable. `--sysroot` is accepted and then silently prefixed onto library search paths, producing doubled paths and the same `unable to find libSystem system library` failure. Upstream: [ziglang/zig#19217](https://github.com/ziglang/zig/issues/19217), open since March 2024. Recorded here so it is not rediscovered when the first Objective-C translation unit lands.

**The web row is rooted at `src/web.zig`, not `src/main.zig`.** A browser artifact is a module the TypeScript bootstrap instantiates (`ARCHITECTURE.md` §2), not a program with a `main()`. Rooting it at a CLI entry point pulls `std.process.Init`, which pulls `std.Io.Threaded`, which needs `posix.getrandom` and `posix.IOV_MAX` — none of which exist on freestanding wasm. Enforcing that structurally, by which file the artifact is rooted at, is deliberate: a conditional inside `main.zig` is something a later change can wander past, and §18.17 says the browser target is not an afterthought.

**macOS cross-links from any host and iOS does not.** Zig bundles libSystem `.tbd` stubs but no iOS SDK. This is a useful boundary rather than an inconvenience: it means the portable core can be kept compiling for Apple targets with no Apple hardware, which is a continuous test of §18.9 — no platform SDK types leaking into portable simulation code.

### Rows not yet present

- **Cross-ISA determinism.** `ARCHITECTURE.md` §7 requires fixed-point inside the rollback boundary, no FMA contraction, no fast-math, own polynomial transcendentals, and fixed-tree reductions. Nothing enforces any of that except running the same simulation on two ISAs and comparing per-tick hashes. The matrix above already provides x86_64 and aarch64 natively across three operating systems, which is the substrate. The row is blocked on `--verify-determinism` existing, not on hardware. **This is the highest-value job in Tier C and should land with the first tick loop, per `AGENTS.md` §3.**
- **Schema and manifest checks.** All ten checks in `SCHEMA_AND_EVOLUTION.md` §10 are pure CPU and need no device, GPU, or network. Check 5 — fingerprint identical across platform targets — *requires* the multi-target matrix above and is the check that doc flags as catching the error that "looks like a netcode bug for weeks." Blocked on the manifest generator existing.
- **Android emulator and iOS Simulator.** Cover lifecycle, suspend/resume, and device loss (`AGENTS.md` §4) without physical hardware. Neither produces a number.
- **iOS app bundle — package, sign, install, launch.** The static-library row proves the portable core compiles for iOS. It proves nothing about whether an app runs, and must never be read as though it did. This needs the Objective-C entry TU, an `Info.plist`, entitlements, a signing identity, and a `macos-latest` runner with the `--libc` file above. It is an `AGENTS.md` §4 M0 exit criterion in its own right.
- **Browser harness.** The web row compiles a module; nothing yet instantiates it under Worker + OffscreenCanvas + cross-origin isolation. Headless Chrome on a hosted runner has no GPU, so WebGPU would fall back to software — correctness only, never a number.

---

## 5. Tier M matrix — current state

| Target | Device | Admissible | Note |
|---|---|---|---|
| Windows | Development workstation | ✅ | Single machine; not a fleet |
| Linux | — | ❌ | See WSL2 below |
| macOS | — | ❌ | No hardware |
| iOS | — | ❌ | No hardware |
| Android | OnePlus 15 | ❌ | Above reference tier — see below |
| Web | Chrome/Firefox on workstation | ⚠️ partial | Safari 26.4+ requires Apple hardware |

**WSL2 is not a Linux measurement target.** WSLg's compositor is a Weston-over-RDP shim rather than a real Wayland session, and audio bridges to the Windows host. The decisive objection is `BENCHMARK_CONTRACT.md` §2.2, which requires every target live *in the same session*: if the Windows client and the Linux client are one physical machine, they are not independent measurements, they contend for one CPU, one GPU, one NIC, and one thermal envelope. WSL2 is fine for development and inadmissible for measurement.

**A flagship Android device is not the reference tier.** `BENCHMARK_CONTRACT.md` §6 pins "mid-tier 2022–2023 SoC … modal device, not flagship" and states that "revising the reference tier upward requires the same review as changing §1's floor. Drifting the reference device is the easiest way to game this contract and it is explicitly forbidden." Measuring on a current flagship and reporting a pass is that drift. A flagship remains valuable as a *development* device — real lifecycle, real device loss, and real cell↔wifi handoff, which is the only way to exercise the `handoff` profile in §5 and the WebTransport migration question in `SPEC_DEFECTS.md` §2.

**Cheapest admissibility in the project:** one used reference-tier Android handset — Adreno 6xx or Mali-G57-class, 6 GB, Android 12+. Required before M1's exit gate, not before M0's.

---

## 6. What this changes about the milestone gates

`AGENTS.md` §4 states M0's exit criteria as ten items "all six targets, on physical devices, in CI," and M1 begins "only after M0 is green on all six." Read literally against §5 above, M0 cannot be exited and therefore M1 cannot begin, which is not the intent.

Proposed reading, pending author confirmation — this is recorded rather than applied, per `AGENTS.md` §5:

- **M0 exits** when the ten criteria are green on every *reachable* target in Tier C, every unreachable target compiles or is an explicitly dark row with a named blocker, and the matrix has a row per target family.
- **M1's exit gate is unchanged.** It is `BENCHMARK_CONTRACT.md` §12, it is Tier M, and it is not satisfiable on hosted runners or on non-reference hardware. Hardware acquisition is on M1's critical path, not M0's.

This preserves the property §18.20 exists to protect — a compile is never a pass — while making M0 exitable by a project that does not yet own six devices.

---

## 7. Revision policy

Moving a check from Tier M to Tier C is equivalent to moving a requirement from the conformant profile to the compatibility profile, and carries the same prohibition (`CONFORMANCE_PROFILES.md` §10): forbidden without explicit review recorded against `ARCHITECTURE.md` §18.1.

The temptation arrives when Tier M hardware is unavailable and a gate is due, which is exactly when the review matters.
