//! Invariant 1, as a build failure.
//!
//! `AGENTS.md` §2.1 and `ARCHITECTURE.md` §18.5, verbatim: "No per-field metadata in
//! archetype chunks. Not CRDT metadata, not undo metadata, not authoring provenance, not
//! replication bookkeeping. Metadata goes *beside* the database, never inside it."
//!
//! It is the first entry on the unretrofittable list. Until now it was protected by prose
//! in two documents, which is the weakest possible defence against the way it actually
//! gets violated: not by someone disagreeing with it, but by a well-meaning subsystem
//! adding one `u32` dirty stamp per field and nobody noticing at review time. §5.2 is
//! explicit that every one of those pressures is real.
//!
//! The mechanism is a marker declaration. A type that names something living beside the
//! database declares `pub const __no_component_store = {};`, and any attempt to store it
//! in a component is a compile error naming the alternative. Adapted from gkz's
//! `EventId` guard (github.com/mattneel/gkz `src/event.zig`), which protects the same
//! rule for the same reason.
//!
//! The check is recursive, because the violation that survives review is not
//! `field: UndoStamp` — it is a struct three levels down that happens to contain one.

const std = @import("std");

/// Attach to any type that must never be stored inside component data.
///
/// Declaring this is cheap and permanent; discovering you needed it is not.
pub const no_component_store = {};

/// Types that name something living beside the database, listed so the failure is
/// self-explanatory rather than a bare type name.
pub const Beside = struct {
    /// Identifies an entry in the change journal. Journal entries are beside the world
    /// database by §13.1 — "the authoring layer is a transaction log over the world
    /// database; the world database is the materialized view."
    pub const JournalId = struct {
        pub const __no_component_store = {};
        raw: u64,
    };

    /// A §13.2 authoring lease. Class `ephemeral_authoritative`, security-relevant, and
    /// excluded from saves — none of which survives being copied into a chunk.
    pub const LeaseToken = struct {
        pub const __no_component_store = {};
        raw: u64,
    };

    /// Replication bookkeeping: per-client acked baseline state. §5.1 says the baseline,
    /// ack tracking and interest set "live together per connection", which is precisely
    /// not per entity and not in the database.
    pub const BaselineCursor = struct {
        pub const __no_component_store = {};
        raw: u64,
    };

    /// Editor undo state. §18.12 forbids unifying editor undo with netcode rollback, and
    /// storing undo metadata in the rollback projection's storage is how that starts.
    pub const UndoStamp = struct {
        pub const __no_component_store = {};
        raw: u64,
    };
};

/// A causal reference that MAY live in component storage.
///
/// `ARCHITECTURE.md` §6 needs causal edges for scoped rollback, and the naive way to get
/// them is a provenance stamp per component — which is exactly invariant 1. This is the
/// resolution: a value that is a pure function of `(tick, system, ordinal)`, so it names
/// a cause without the engine attaching anything and without depending on whether
/// recording is switched on. If it did depend on that, an instrumented run and a
/// production run would hash differently, and the metering in §6.3 would change the thing
/// it measures.
///
/// Deliberately a distinct type from anything in `Beside`, carrying no marker.
pub const CauseToken = struct {
    tick: u64,
    system: u16,
    ordinal: u16,

    pub fn eql(a: CauseToken, b: CauseToken) bool {
        return a.tick == b.tick and a.system == b.system and a.ordinal == b.ordinal;
    }
};

/// Reject any type that is, or transitively contains, something marked as beside-only.
///
/// Recursion is the point. `field: UndoStamp` would be caught at review; a struct three
/// levels down that happens to contain one would not.
pub fn assertStorable(comptime T: type, comptime context: []const u8) void {
    comptime {
        assertStorableInner(T, context, T);
    }
}

fn assertStorableInner(comptime T: type, comptime context: []const u8, comptime root: type) void {
    comptime {
        // `@hasDecl` only accepts container types, and this walks scalars too.
        const is_container = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => true,
            else => false,
        };
        if (is_container and @hasDecl(T, "__no_component_store")) {
            @compileError(context ++ ": " ++ @typeName(T) ++ " may not be stored in component data" ++
                (if (T == root) "" else " (reached through " ++ @typeName(root) ++ ")") ++
                ". AGENTS.md §2.1 — metadata goes BESIDE the world database, never inside it. " ++
                "Rollback, replay and save/load all depend on the packed layout, and this is " ++
                "the first entry on the unretrofittable list. If you need causality in state, " ++
                "use storable.CauseToken.");
        }

        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (info.fields) |f| assertStorableInner(f.type, context, root);
            },
            .@"union" => |info| {
                for (info.fields) |f| assertStorableInner(f.type, context, root);
            },
            .array => |info| assertStorableInner(info.child, context, root),
            .optional => |info| assertStorableInner(info.child, context, root),

            // §5.2: "no pointers, no heap allocation, no non-deterministic iteration
            // order." A pointer in a chunk is not portable across a snapshot, a save, or
            // a process — the rollback projection copies pages, and a copied pointer is a
            // dangling one.
            .pointer => @compileError(context ++ ": " ++ @typeName(T) ++
                " is a pointer. ARCHITECTURE.md §5.2 — simulation components hold no pointers; " ++
                "a page copied for rollback or written to a save carries a dangling address. " ++
                "Use a generational handle."),

            else => {},
        }
    }
}

/// Reject pointer-width integers on anything that crosses a boundary.
///
/// `usize` is 64 bits on desktop and 32 on wasm32, both shipping targets, so a `usize`
/// in a wire format or a save emits a different number of bytes per architecture. Adapted
/// from gkz's `assertFixedWidth`. Bedlam's `WireType` enum is already fixed-width by
/// construction, so this guards the storage side, where a Zig type can still name one.
pub fn assertFixedWidth(comptime T: type, comptime context: []const u8) void {
    comptime {
        if (T == usize or T == isize) {
            @compileError(context ++ ": " ++ @typeName(T) ++
                " is pointer-width — 64 bits on desktop and 32 on wasm32, both of which ship. " ++
                "Use an explicit width (u32, u64, …).");
        }
    }
}

// ---------------------------------------------------------------------------

test "a plain component type is storable" {
    const Position = struct { x: i64, y: i64, z: i64 };
    assertStorable(Position, "test");
}

test "CauseToken is storable — it is the sanctioned way to name a cause in state" {
    assertStorable(CauseToken, "test");
    const WithCause = struct { value: u32, cause: CauseToken };
    assertStorable(WithCause, "test");
}

test "marked types carry the marker and CauseToken does not" {
    // The distinction the whole file rests on. If CauseToken ever acquired the marker,
    // §6 would lose its only in-state causal anchor; if a Beside type ever lost it, the
    // guard would silently stop guarding.
    try std.testing.expect(@hasDecl(Beside.JournalId, "__no_component_store"));
    try std.testing.expect(@hasDecl(Beside.LeaseToken, "__no_component_store"));
    try std.testing.expect(@hasDecl(Beside.BaselineCursor, "__no_component_store"));
    try std.testing.expect(@hasDecl(Beside.UndoStamp, "__no_component_store"));
    try std.testing.expect(!@hasDecl(CauseToken, "__no_component_store"));
}

test "nesting depth does not matter to the guard" {
    // Direct use would be caught at review. This is the case that would not be.
    const L3 = struct { stamp: Beside.UndoStamp };
    const L2 = struct { inner: L3 };
    const L1 = struct { inner: L2 };
    try std.testing.expect(@hasDecl(@typeInfo(@typeInfo(@typeInfo(L1).@"struct".fields[0].type)
        .@"struct".fields[0].type).@"struct".fields[0].type, "__no_component_store"));
}
