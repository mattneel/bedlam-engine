//! The declaration API. One declaration drives every downstream implementation.
//!
//! `ARCHITECTURE.md` §0 P2: storage layout, wire codec, replication policy, prediction
//! participation, save format, replay format, script binding, authoring permissions and
//! editor panels all derive from a single declaration. This file is that declaration's
//! shape; `manifest.zig` derives identity and policy from it plus the registry.
//!
//! Projection membership is DERIVED from component class rather than declared
//! separately. Four independently-declared booleans would drift, and §18.7 forbids
//! unifying the projections precisely because they are supposed to differ — so the
//! rules that decide membership live in one place and are tested.

const std = @import("std");
const wire = @import("wire.zig");

/// `ARCHITECTURE.md` §5.3.
pub const Class = enum {
    authoritative,
    predicted,
    interpolated,
    replicated,
    deterministic,
    client_private,
    transient_presentation,
    ephemeral_authoritative,
    authoring,
    derived,
};

/// `ARCHITECTURE.md` §13.2. Schema-declared, never inferred at runtime.
pub const ContentionKey = enum {
    entity,
    subtree,
    component_group,
    asset,
    graph,
    document_range,
};

pub const ScriptExposure = enum { none, read, read_write };

/// `ARCHITECTURE.md` §9.1.
pub const Channel = enum {
    unreliable_unordered,
    unreliable_sequenced,
    reliable_unordered,
    reliable_ordered,
    reliable_stream,
    voice,
    bulk_content,
};

pub const Field = struct {
    name: []const u8,
    wire: wire.WireType,
    quant: wire.Quantization = .none,
    /// Feeds the §9.4 priority accumulators.
    priority_weight: u8 = 1,
    interest_sensitive: bool = true,
};

pub const Component = struct {
    name: []const u8,
    namespace: []const u8 = "bedlam",
    class: Class,
    fields: []const Field,
    script: ScriptExposure = .none,
    contention: ContentionKey = .entity,
};

pub const Event = struct {
    name: []const u8,
    channel: Channel,
    params: []const Field = &.{},
};

pub const Rpc = struct {
    name: []const u8,
    channel: Channel = .reliable_ordered,
    params: []const Field = &.{},
    /// Authority required of the caller.
    requires_authority: bool = true,
};

/// Which of the four state projections (`ARCHITECTURE.md` §5.1) a class enters.
/// They are not the same bytes and must not be unified; this only decides membership.
pub const Projections = struct {
    replication: bool,
    rollback: bool,
    save: bool,
    replay: bool,
};

pub fn projectionsFor(class: Class) Projections {
    return switch (class) {
        // Server-owned truth. Everything except the rollback projection, which only
        // predicted and deterministic state enters.
        .authoritative => .{ .replication = true, .rollback = false, .save = true, .replay = true },

        // The only classes clients re-simulate, so the only ones that need pages.
        .predicted => .{ .replication = true, .rollback = true, .save = true, .replay = true },
        .deterministic => .{ .replication = false, .rollback = true, .save = true, .replay = true },

        // Received and smoothed, never re-simulated.
        .interpolated => .{ .replication = true, .rollback = false, .save = false, .replay = false },
        .replicated => .{ .replication = true, .rollback = false, .save = true, .replay = true },

        // §13.2: server-authoritative, security-relevant, excluded from saves.
        .ephemeral_authoritative => .{ .replication = true, .rollback = false, .save = false, .replay = true },

        // §16: exists so the client is never sent what it should not have.
        .client_private => .{ .replication = false, .rollback = false, .save = true, .replay = false },

        // §13.5: cursors, selections, gizmo drags. Timeout-expired, never persisted.
        .transient_presentation => .{ .replication = true, .rollback = false, .save = false, .replay = false },

        // Editor state. Saved, never on the simulation wire.
        .authoring => .{ .replication = false, .rollback = false, .save = true, .replay = false },

        // §5.3: reconstructed client-side from replicated events plus structural state.
        // Replicating it is the thing the class exists to avoid — see §10 check 10.
        .derived => .{ .replication = false, .rollback = false, .save = false, .replay = false },
    };
}

/// Script may not drive prediction. `ARCHITECTURE.md` §10.1: rollback replays recorded
/// commands and never re-invokes JS, so script output is authoritative-only and anything
/// authored in script displays at full RTT. A script-writable `predicted` component is
/// therefore a contradiction, and it is invisible until someone plays at 140 ms.
pub fn scriptMayWrite(class: Class) bool {
    return switch (class) {
        .authoritative, .ephemeral_authoritative, .authoring => true,
        .predicted, .interpolated, .replicated, .deterministic => false,
        .client_private, .transient_presentation, .derived => false,
    };
}

test "derived never enters the replication projection" {
    // docs/SCHEMA_AND_EVOLUTION.md §10 check 10. Replicating 16,384 fragments is
    // exactly what the class exists to prevent.
    try std.testing.expect(!projectionsFor(.derived).replication);
}

test "only predicted and deterministic enter the rollback projection" {
    inline for (@typeInfo(Class).@"enum".fields) |f| {
        const class: Class = @enumFromInt(f.value);
        const expected = class == .predicted or class == .deterministic;
        try std.testing.expectEqual(expected, projectionsFor(class).rollback);
    }
}

test "ephemeral-authoritative is excluded from saves" {
    // ARCHITECTURE.md §13.2 — leases are security-relevant and must not persist.
    try std.testing.expect(!projectionsFor(.ephemeral_authoritative).save);
}

test "client-private never crosses the wire" {
    try std.testing.expect(!projectionsFor(.client_private).replication);
}

test "script may not write any class the client predicts" {
    try std.testing.expect(!scriptMayWrite(.predicted));
    try std.testing.expect(!scriptMayWrite(.deterministic));
    try std.testing.expect(scriptMayWrite(.authoritative));
}
