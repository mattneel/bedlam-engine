# Bedlam — Conformance Profiles

Companion to `ARCHITECTURE.md` §1.2. Formalizes the distinction between environments the §1 floor is measured against and environments that merely interoperate.

---

## 0. The contradiction this resolves

v0.2 asserted "64 at full tick on every platform, no exceptions" and, three sections later, that the single-threaded web fallback and the TCP transport could not hold the floor. Both statements were true. Together they were incoherent.

The resolution is not to weaken P0. It is to be precise about **what P0 is measured against**.

> The floor admits no *platform* exceptions. It admits *environment* classes, and only one of them is the measurement environment.

---

## 1. Profile definitions

### Conformant target profile

Meets the §1 floor. Measured against `BENCHMARK_CONTRACT.md`. This is the environment P0 refers to, and the only environment in which a scale claim may be made.

### Compatibility profile

Preserves functional protocol compatibility — connects, plays, interoperates, sees the same world. Makes **no** §1 performance guarantee.

### Unsupported

Does not connect. Fails with a structured capability-mismatch message naming the missing requirement.

---

## 2. Per-target requirements

### Windows / Linux / macOS

| | Conformant | Compatibility |
|---|---|---|
| GPU | D3D12 / Vulkan 1.3 / Metal 3, meeting `desktop-baseline` | Meets `mobile-baseline` |
| CPU | 4 physical cores | 2 physical cores |
| Memory | 8 GB system | 6 GB system |
| Transport | QUIC | TCP-framed |
| OS | Win10 20H2+ / glibc 2.31+ or musl / macOS 13+ | Same |

### Android

| | Conformant | Compatibility |
|---|---|---|
| GPU | Vulkan 1.1+, meeting `mobile-baseline` | Vulkan 1.0 |
| SoC | Reference tier per benchmark §6 | Below reference tier |
| Memory | 6 GB | 4 GB |
| OS | Android 12+ (GameActivity, ADPF) | Android 10+ |
| Transport | QUIC | TCP-framed |

### iOS

| | Conformant | Compatibility |
|---|---|---|
| GPU | Metal 3, meeting `mobile-baseline` | Metal 2 |
| SoC | A14-class or newer | A12–A13 |
| Memory | 4 GB | 3 GB |
| OS | iOS 16+ | iOS 15+ |
| Transport | QUIC | TCP-framed |

### Web

The target where the distinction matters most, because the same browser can be in either profile depending on how the page is served.

| Requirement | Conformant | Compatibility |
|---|---|---|
| Graphics | WebGPU | WebGPU |
| Threading | SharedArrayBuffer via COOP/COEP cross-origin isolation | Single-threaded |
| Rendering surface | Worker + OffscreenCanvas | Main-thread canvas |
| Transport | WebTransport (datagrams + streams) | WebSocket |
| Audio | AudioWorklet | AudioWorklet |
| Memory | wasm32, ≤ 1.8 GB linear | wasm32, ≤ 1.2 GB linear |
| Browser | Chrome/Edge stable, Firefox stable, Safari 26.4+ | Same, minus WebTransport |

**A build served without COOP/COEP headers is a compatibility-profile deployment regardless of the browser's capability.** This is the case most likely to be measured accidentally and reported as a conformant result. Embedded third-party contexts — iframes on sites that cannot set isolation headers — are structurally compatibility-profile.

WebGPU is required in **both** profiles. There is no WebGL path. A browser without WebGPU is unsupported.

---

## 3. Detection

Profile is determined at startup by capability probe, never by user agent string, never by device model lookup, never by configuration.

```
probe graphics capability      → capability profile tier (§4.2)
probe threading                → SharedArrayBuffer + crossOriginIsolated
probe surface                  → OffscreenCanvas transfer succeeds
probe transport                → WebTransport constructor + successful handshake
probe memory                   → reported budget vs. requirement
probe thermal API              → ADPF availability (Android)
    ↓
resolve: conformant | compatibility | unsupported
```

**Transport probing must attempt an actual handshake, not a feature check.** `WebTransport` existing tells you nothing about whether UDP/443 reaches the server from this network — the corporate-and-hotel-network case. A build that detects WebTransport support and reports conformant, then silently falls back to WebSocket on connection failure, has misreported its profile.

Resolution is recorded in the session record and attached to every telemetry event.

---

## 4. Degradation behavior

### Conformant

All governors (§1.3) operate within their nominal-to-floor ranges. Simulation and prediction cadence invariant at 64 Hz. Sustained governor operation at floor values is a **failure signal**, reported as such, not a working state.

### Compatibility

- Simulation and prediction cadence **still invariant at 64 Hz**. This does not degrade in any profile. A compatibility client that predicts at a lower rate would desynchronize from the authoritative cell, which is a correctness failure, not a performance one.
- Replication rate may run below the conformant floor.
- Interpolation delay may exceed conformant bounds.
- Render quality may drop below `mobile-baseline`.
- Relevant-set size may be reduced by more aggressive interest filtering.
- Voice may be reduced to server-mixed fold only, no client-side spatialization.
- Session may cap concurrent players below 64.

**What never degrades in any profile:** simulation cadence, prediction cadence, schema compatibility, wire protocol correctness, authority model, anti-cheat validation.

---

## 5. The inadmissibility rule

> **Measurements taken in the compatibility profile are inadmissible as evidence about P0, in either direction.**

Neither as evidence the floor is met, nor as evidence it is unmet. A compatibility-profile run is a compatibility-profile result and is reported under that label.

This cuts both ways deliberately. It prevents a passing single-threaded web run from being reported as conformance, and it prevents a failing WebSocket run from being cited as proof the floor is unachievable.

Any performance claim, benchmark report, CI gate result, or design decision citing a compatibility-profile measurement as evidence about the floor is invalid on its face.

---

## 6. Interaction with governors

| Governor | Conformant range | Compatibility range |
|---|---|---|
| Replication-rate | 32 Hz nominal → 16 Hz floor | 16 Hz nominal → 8 Hz floor |
| Interpolation-delay | 2 snapshots nominal → 4 max | 3 nominal → 8 max |
| Render-quality | Profile tier, ≥ `mobile-baseline` | Any tier |
| Presentation-rate | Target Hz per benchmark §2.2 | Best effort |

Governors are **profile-aware**. A conformant client and a compatibility client in the same session run different governor configurations, and the server tracks both.

Per §17, the governors must be aware of each other. Audio CPU, networking CPU, and render CPU compete for one thermal envelope on mobile; a render-quality reduction that frees headroom consumed immediately by a voice-spatialization increase accomplishes nothing.

---

## 7. Interaction with topology profiles

Topology profiles (§9.3) and conformance profiles are orthogonal, with one constraint:

**A compatibility-profile client may not host an authoritative cell.**

Hosting requires conformant transport (direct QUIC listen, or relay-mediated for web hosts per `ARCHITECTURE.md` §9.5) and conformant thermal and memory headroom. A compatibility-profile client participates in any topology; it hosts none.

Host floors by target are in `BENCHMARK_CONTRACT.md` §10: 64 desktop, 32 mobile, 32 web.

Host trust class (`ARCHITECTURE.md` §14.3) is independent of and additional to this constraint.

---

## 8. Mixed-profile sessions

Expected and supported. A session may contain conformant and compatibility clients simultaneously.

- The authoritative cell runs to conformant parameters regardless of population mix.
- Per-client replication parameters follow that client's profile.
- **Session player cap is set by the cell, not by the weakest client.** One compatibility client does not reduce a 64-player session.
- Conformant clients are never degraded to match compatibility clients. Ever. This is the failure mode that turns a floor into a ceiling.

---

## 9. Reporting

Every session record and telemetry event carries:

- Resolved profile
- Resolution reason — which probe determined it
- Probe results in full
- Governor configuration in effect
- For web: isolation status, transport actually established, surface type

Fleet-level dashboards report conformant/compatibility/unsupported distribution per platform per build. **A rising compatibility share on a platform is a regression signal** — it usually means a capability probe broke or a deployment lost its isolation headers, not that user hardware changed.

---

## 10. Revision policy

Adding a requirement to the conformant profile narrows the addressable audience and is a product decision requiring the same review as changing §1's floor.

**Moving a requirement from conformant to compatibility is the easiest way to make the floor meaningless** and is forbidden without explicit review recorded against §18.1. The temptation arrives when a conformance gate fails close to a deadline, which is exactly when the review matters.
