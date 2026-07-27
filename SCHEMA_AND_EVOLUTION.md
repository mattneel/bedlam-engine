# Bedlam — Schema and Evolution

Companion to `ARCHITECTURE.md` §3. Lowest risk, highest leverage of the companion documents, and everything else depends on it.

---

## 0. The failure this prevents

`comptime` gives one source declaration and generated implementations. It gives **nothing** about stable identity across builds.

An engine that derives durable IDs from declaration order, source order, layout order, or a compiler symbol hash works perfectly until the first refactor, at which point every save file, every replay, every recorded input log, every connected client on an older build, and every rolling deploy in flight reinterprets the same bytes as different fields. The failure is silent, data-corrupting, and discovered in production.

**The `comptime` declaration is authoritative. The manifest is its durable, portable artifact.** P2 is elegant within one build; the manifest is what makes it survive ten years.

---

## 1. Authority model

```
component declaration (Zig, comptime)
    │
    ├─→ generated implementations   (storage, codec, bindings, panels)
    │
    └─→ canonical manifest          (durable identity + policy)
              │
              └─→ signed artifact, shipped with cooked content
```

The declaration is the single source of truth for *shape*. The manifest is the single source of truth for *identity and policy*. They are generated together and must agree, enforced by a build-time check.

The ID registry (§2) is checked into source control and is the only mutable input the manifest generator consumes that is not derived from the declaration.

---

## 2. ID allocation

**IDs are allocated, never derived.**

### Registry

A checked-in registry file maps every stable identity to an integer. It is append-only in practice and append-or-tombstone-only by enforcement.

```
component  Transform            id=0x0041  introduced=1.0
component  Transform.position   id=0x0041_0001  introduced=1.0
component  Transform.rotation   id=0x0041_0002  introduced=1.0
component  Transform.scale      id=0x0041_0003  introduced=1.0  deprecated=2.4
component  Transform.velocity   id=0x0041_0004  introduced=2.1
event      WeaponFired          id=0x0102  introduced=1.0
rpc        RequestExtraction    id=0x0301  introduced=1.3
```

### Rules

| Rule | Enforcement |
|---|---|
| New identity takes the next unused ID in its space | Generator allocates; commit includes the registry diff |
| Removal tombstones the ID | Build error on reuse attempt |
| **Tombstoned IDs are never reusable, ever** | Build error, no override flag exists |
| Renaming a field preserves its ID | Rename is a declaration change, not an identity change |
| Changing a field's wire type requires a new ID | Old ID tombstoned, migration edge required (§5) |
| ID spaces are separate per kind | Components, fields, events, RPCs, lease classes |

There is no flag to reuse a tombstoned ID. The temptation appears roughly once a year and the cost of yielding to it is unbounded.

### Why append-only rather than content-hashed

Content-hashed identity is tempting because it needs no registry. It fails on rename (identity changes when it shouldn't) and on semantic change with identical shape (identity persists when it shouldn't). Both are silent. The registry is a small amount of ceremony that makes both cases explicit.

---

## 3. Manifest contents

Emitted every build. Deterministic — the same declarations and registry produce byte-identical manifests.

### Per component

| Field | Purpose |
|---|---|
| Stable ID | Identity |
| Name, namespace | Human and tooling reference |
| Component class | §5.3 — `authoritative`, `predicted`, `interpolated`, `replicated`, `deterministic`, `client-private`, `transient-presentation`, `ephemeral-authoritative`, `authoring`, `derived` |
| Prediction participation | Whether predicted clients simulate it |
| Rollback participation | Whether it enters the rollback projection (§5.1) |
| Save inclusion | Whether it enters the save projection |
| Replay inclusion | Whether it enters the replay projection |
| Script exposure | None / read / read-write, per client mode |
| Authoring lease class | §13.2 |
| Contention key | `entity`, `subtree`, `component-group`, `asset`, `graph`, `document-range` |
| Introduced version | |
| Deprecated version | Nullable |

### Per field

| Field | Purpose |
|---|---|
| Stable ID | Identity |
| Name | |
| Semantic type | Independent of physical layout |
| Wire type | Encoding on the replication and save projections |
| Quantization policy | Bits, range, precision — see §4 |
| Priority weight | Feeds §9.4 priority accumulators |
| Interest sensitivity | Whether relevance filtering applies |
| Introduced / deprecated | |

### Per event and RPC

Stable ID, parameter list with field IDs and wire types, channel assignment (§9.1), authority requirement, rate limit class.

### Document-level

| Field | Purpose |
|---|---|
| Schema version | |
| Compatibility fingerprint | §4 |
| Tombstone list | Every retired ID, permanently |
| Migration edges | §5 |
| Generator version | |
| Build provenance | Commit, toolchain version |

---

## 4. Fingerprinting

The compatibility fingerprint answers one question at connection time: *can these two builds exchange state without reinterpreting bytes?*

**Covered by the fingerprint:**

- Component and field IDs present
- Wire types
- Quantization policy
- Channel assignments
- Event and RPC signatures
- Tombstone list

**Not covered:**

- Names, namespaces, comments
- Physical layout, alignment, chunk size — these differ per target by P1 and must not affect compatibility
- Editor panel hints
- Anything in the `authoring` or `derived` classes that never crosses the wire

Two builds targeting different platforms with different physical layouts produce **identical fingerprints**. If they don't, the fingerprint covers something it shouldn't.

The fingerprint is a hash over a canonical serialization of the covered set, sorted by stable ID. Deterministic, order-independent of declaration order.

---

## 5. Migration edges

An edge declares how to transform state from one schema version to another. Edges are explicit, directional, and testable.

```
migration 2.0 → 2.1
    Transform.velocity: introduced, default = zero
    
migration 2.3 → 2.4
    Transform.scale: deprecated
        read:  preserve for save compatibility
        write: drop
        
migration 3.0 → 3.1
    Health.value: u16 → q16.16
        transform: widen, scale by 1.0
        old ID 0x0055_0002 tombstoned
        new ID 0x0055_0007
```

### Rules

- Every schema version pair that must interoperate has an edge or an explicit incompatibility declaration.
- Edges are unidirectional. Backward edges are declared separately where needed.
- **Every edge has a test.** CI applies the edge to a corpus of real saves and replays and verifies round-trip where reversible, and verifies expected loss where not.
- Missing edge between versions that negotiation attempts to bridge is a connection refusal, never a best-effort reinterpretation.

---

## 6. Negotiation protocol

At connection establishment, before any state transfer:

1. Client presents its fingerprint and schema version.
2. Server compares against its own.
3. **Identical fingerprint** → proceed, no translation.
4. **Different fingerprint, migration path exists** → server selects the edge chain, declares the negotiated wire schema, both sides bind codecs accordingly.
5. **Different fingerprint, no path** → connection refused with a structured reason naming the incompatible IDs.

Fingerprint mismatch is a **negotiated compatibility decision, never a silent reinterpretation**. There is no permissive mode.

Negotiation happens on `reliable_stream` before any datagram flows.

---

## 7. Rolling deploys

The scenario the manifest exists for: server fleet mid-upgrade, clients on N and N+1, cells migrating between hosts running different builds.

| Requirement | Mechanism |
|---|---|
| Cell migration across build versions | Migration checkpoint (§12) carries its schema version; receiving host applies edges |
| Mixed-version client population | Per-connection negotiated wire schema (§6) |
| Replay validity across deploys | Replay carries schema version; validator applies edges |
| Save compatibility | Save projection carries schema version; loader applies edges |
| Manifest distribution | Elixir control plane hosts the manifest registry (§12) |

**Deploy gate:** a build whose manifest has no migration edge from the currently-deployed version cannot be deployed to a live fleet. CI enforces this against the registry the control plane reports as live.

---

## 8. Consumer contracts

Nine consumers. Each depends on a specific manifest subset, and each must fail loudly rather than degrade on mismatch.

| Consumer | Depends on | Failure mode |
|---|---|---|
| Connection negotiation | Fingerprint, tombstones, migration edges | Refuse connection |
| Rolling deploys | Migration edges, version graph | Block deploy |
| Save migration | Save inclusion, field IDs, edges | Refuse load, offer migration |
| Replay validation | Replay inclusion, event/RPC IDs, edges | Invalidate replay |
| Editor inspection | Names, panel hints, lease class, contention key | Show unknown-field placeholder |
| QuickJS binding generation | Script exposure, field IDs, semantic types | Build error |
| Telemetry decoding | Field IDs, wire types, version | Store raw, decode later |
| Authoring transaction validation | Lease class, contention key, authority | Reject transaction |
| External C-ABI tooling | Full manifest | Version-guarded refusal |

Telemetry is the only consumer permitted to degrade — storing undecodable payloads for later decoding is better than dropping them, because telemetry from an unknown build version is exactly the telemetry you most want.

---

## 9. Build integration

```
declarations + registry
    → generator
        ├→ manifest (canonical, deterministic)
        ├→ generated Zig implementations
        ├→ generated QuickJS bindings
        └→ generated editor panel descriptors
    → build-time checks (§10)
    → sign manifest
    → ship with cooked content
```

The manifest is a **build output**, not a hand-maintained file. The registry is the hand-maintained input, and it is deliberately small.

Manifests are signed alongside cooked packages (§14) and content-addressed in object storage.

---

## 10. CI enforcement

Every one of these is a build failure, not a warning:

1. Tombstoned ID reuse.
2. ID allocated without a registry entry.
3. Field wire type changed without a new ID and tombstone.
4. Manifest not byte-identical across two runs of the same commit.
5. Fingerprint differing between platform targets of the same commit.
6. Migration edge missing between the current build and the deployed version.
7. Migration edge without a test.
8. Migration edge test failing against the save/replay corpus.
9. Declaration and manifest disagreeing on shape.
10. Component declared with a class its usage contradicts — e.g. a `derived` component appearing in the replication projection.

Check 5 is the one that catches the subtle error: if per-target physical layout leaks into the fingerprint, cross-platform play breaks and it breaks in a way that looks like a netcode bug for weeks.

---

## 11. Corpus

A permanent, growing, content-addressed corpus of real artifacts, used by checks 8 and by replay validation:

- Save files from every released schema version
- Replay logs from every released schema version
- Recorded connection negotiations, including failures
- Authoring transaction logs

The corpus never shrinks. Retiring an entry requires the same review as retiring a schema version, because the entry is the only evidence that a migration edge ever worked.
