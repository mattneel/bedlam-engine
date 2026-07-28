//! The declarations themselves.
//!
//! Shape lives here; identity and policy come from `registry.txt` via `manifest.zig`.
//! `docs/SCHEMA_AND_EVOLUTION.md` §1: the declaration is the single source of truth for
//! shape, the manifest for identity, and a build-time check enforces that they agree.
//!
//! Every component below appears in the reference workload
//! (`docs/BENCHMARK_CONTRACT.md` §1.1) so the classes exercise real cases rather than
//! placeholder ones.

const d = @import("declare.zig");

pub const components = [_]d.Component{
    // Predicted: the client re-simulates it, so it enters the rollback projection and
    // script may not write it (ARCHITECTURE.md §10.1).
    .{
        .name = "Transform",
        .class = .predicted,
        .script = .read,
        .fields = &.{
            .{
                .name = "position",
                .wire = .vec3_quantized,
                .quant = .{ .bounded = .{ .bits = 16, .min = -4096, .max = 4096 } },
                .priority_weight = 8,
            },
            .{
                .name = "rotation",
                .wire = .quat_smallest_three,
                .quant = .{ .angular = .{ .bits = 9 } },
                .priority_weight = 6,
            },
            .{
                .name = "velocity",
                .wire = .vec3_quantized,
                .quant = .{ .bounded = .{ .bits = 12, .min = -256, .max = 256 } },
                .priority_weight = 4,
            },
        },
    },

    // Authoritative: server truth, mirrored to clients, never predicted.
    .{
        .name = "Health",
        .class = .authoritative,
        .script = .read,
        .fields = &.{
            .{ .name = "current", .wire = .q16_16, .priority_weight = 10 },
            .{ .name = "maximum", .wire = .u16, .priority_weight = 1, .interest_sensitive = false },
        },
    },

    .{
        .name = "WeaponState",
        .class = .predicted,
        .script = .read,
        .fields = &.{
            .{ .name = "ammo_in_mag", .wire = .u16, .priority_weight = 5 },
            .{ .name = "fire_cooldown", .wire = .q16_16, .priority_weight = 7 },
        },
    },

    // Script drives extraction policy, so it must be a class script may write —
    // which by construction means it is not predicted.
    .{
        .name = "ExtractionProgress",
        .class = .authoritative,
        .script = .read_write,
        .contention = .subtree,
        .fields = &.{
            .{ .name = "fraction", .wire = .q16_16, .priority_weight = 3 },
        },
    },

    // §16: information never sent cannot be extracted.
    .{
        .name = "LootKnowledge",
        .class = .client_private,
        .fields = &.{
            .{ .name = "seen_mask", .wire = .u64, .interest_sensitive = false },
        },
    },

    // §5.3: 16,384 fragments cannot be replicated at the floor. Reconstructed
    // client-side from destruction events plus structural state.
    .{
        .name = "FragmentDebris",
        .class = .derived,
        .fields = &.{
            .{ .name = "settle_age", .wire = .u16 },
        },
    },
};

pub const events = [_]d.Event{
    .{ .name = "WeaponFired", .channel = .unreliable_sequenced },
    // The event fragments are derived from. Reliability matters: a lost
    // StructureBroke means a client never builds the debris at all.
    .{ .name = "StructureBroke", .channel = .reliable_unordered },
};

pub const rpcs = [_]d.Rpc{
    .{ .name = "RequestExtraction", .channel = .reliable_ordered },
};
