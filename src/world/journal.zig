//! The change journal.
//!
//! `ARCHITECTURE.md` §5.1: "One schema (§3), one change journal, four projections that are
//! not the same bytes." This is that journal — the single record of what changed in a
//! tick, from which the replication, save, and replay projections are each derived
//! differently.
//!
//! **It is not a fifth projection, and the distinction is load-bearing.** §18.7 forbids
//! unifying the four, and the way that gets violated is not by someone merging them
//! deliberately: it is by the journal quietly becoming canonical, so the other three
//! become views of *it* rather than of the world. So the journal records **what changed**,
//! never **what the new value is**. A consumer that wants a value reads the world. That
//! one rule is what keeps it a change log rather than a state format.
//!
//! Consequences worth stating, because each is a thing the journal deliberately cannot do:
//!
//!   - Replication reads the journal to know which components to consider, then encodes
//!     from the world through per-client interest and quantization (§9.4). It cannot
//!     replay journal entries at a client, because the entries carry no values.
//!   - Save walks the world, using the journal only to skip untouched regions.
//!   - Replay records inputs and events, not journal entries — §5.1 is explicit that the
//!     replay projection is "input/event log + seeds + periodic canonical checkpoints".
//!   - Rollback does not read the journal at all. It swaps pages (§5.2). The journal
//!     tells the *page store* which pages to mark dirty; it is not the mechanism.
//!
//! Ordering is insertion order, which is deterministic because the tick's system schedule
//! is (§8's explicit task graph). Nothing here sorts by a pointer or iterates a hash.

const std = @import("std");
const entity_mod = @import("entity.zig");

pub const Entity = entity_mod.Entity;
/// Stable component ID from the §3 registry — never a runtime type pointer or a
/// declaration index, because §18.6 forbids identity derived from layout or source order.
pub const ComponentId = u32;

pub const Kind = enum(u8) {
    spawned,
    despawned,
    /// A component's value changed. The value itself is deliberately absent.
    mutated,
    component_added,
    component_removed,
};

pub const Entry = struct {
    kind: Kind,
    entity: Entity,
    /// Meaningless for spawn/despawn, which concern the entity rather than a component.
    component: ComponentId,
};

/// Bounded, because §18.8 forbids unbounded allocation in the frame loop and a journal
/// is the most tempting place to ignore that — churn is bursty, and one explosion can
/// produce more entries than a whole quiet minute.
///
/// Overflow is reported rather than grown. A consumer that sees `overflowed` must fall
/// back to treating the whole tick as dirty, which is slower and correct; growing the
/// buffer mid-tick would be faster and would violate the invariant.
pub const Journal = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    capacity: u32,
    overflowed: bool,
    tick: u64,

    pub fn init(gpa: std.mem.Allocator, capacity: u32) !Journal {
        var entries: std.ArrayList(Entry) = .empty;
        try entries.ensureTotalCapacity(gpa, capacity);
        return .{
            .gpa = gpa,
            .entries = entries,
            .capacity = capacity,
            .overflowed = false,
            .tick = 0,
        };
    }

    pub fn deinit(self: *Journal) void {
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    fn push(self: *Journal, e: Entry) void {
        if (self.entries.items.len >= self.capacity) {
            self.overflowed = true;
            return;
        }
        // Capacity was reserved in `init`, so this cannot allocate.
        self.entries.appendAssumeCapacity(e);
    }

    pub fn recordSpawn(self: *Journal, e: Entity) void {
        self.push(.{ .kind = .spawned, .entity = e, .component = 0 });
    }

    pub fn recordDespawn(self: *Journal, e: Entity) void {
        self.push(.{ .kind = .despawned, .entity = e, .component = 0 });
    }

    pub fn recordMutation(self: *Journal, e: Entity, component: ComponentId) void {
        self.push(.{ .kind = .mutated, .entity = e, .component = component });
    }

    pub fn recordComponentAdded(self: *Journal, e: Entity, component: ComponentId) void {
        self.push(.{ .kind = .component_added, .entity = e, .component = component });
    }

    pub fn recordComponentRemoved(self: *Journal, e: Entity, component: ComponentId) void {
        self.push(.{ .kind = .component_removed, .entity = e, .component = component });
    }

    pub fn items(self: Journal) []const Entry {
        return self.entries.items;
    }

    pub fn isEmpty(self: Journal) bool {
        return self.entries.items.len == 0 and !self.overflowed;
    }

    /// Clear for the next tick. Retains capacity — the frame loop must not allocate.
    pub fn advance(self: *Journal) void {
        self.entries.clearRetainingCapacity();
        self.overflowed = false;
        self.tick += 1;
    }

    /// True if a consumer must treat the whole world as dirty this tick.
    pub fn requiresFullScan(self: Journal) bool {
        return self.overflowed;
    }
};

// ---------------------------------------------------------------------------

fn mk(i: u24) Entity {
    return .{ .index = i, .generation = 1 };
}

test "records what changed, never the new value" {
    // The rule that keeps this a change log rather than a fifth state projection. If an
    // Entry ever gains a payload, §18.7 is broken by contract rather than by refactor:
    // the other projections become views of the journal instead of the world.
    const fields = @typeInfo(Entry).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    inline for (fields) |f| {
        const ok = std.mem.eql(u8, f.name, "kind") or
            std.mem.eql(u8, f.name, "entity") or
            std.mem.eql(u8, f.name, "component");
        try std.testing.expect(ok);
    }
}

test "component identity is the stable registry ID, not a type pointer" {
    // §18.6: no durable ID derived from source order, layout order, or symbol hash.
    try std.testing.expectEqual(u32, @TypeOf(@as(Entry, undefined).component));
}

test "records in insertion order" {
    // §8's explicit task graph fixes the system schedule, so insertion order is
    // deterministic. Sorting here would discard that and cost time.
    const gpa = std.testing.allocator;
    var j = try Journal.init(gpa, 16);
    defer j.deinit();

    j.recordSpawn(mk(3));
    j.recordMutation(mk(1), 0x41);
    j.recordDespawn(mk(2));

    const got = j.items();
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqual(Kind.spawned, got[0].kind);
    try std.testing.expectEqual(@as(u24, 3), got[0].entity.index);
    try std.testing.expectEqual(Kind.mutated, got[1].kind);
    try std.testing.expectEqual(@as(u32, 0x41), got[1].component);
    try std.testing.expectEqual(Kind.despawned, got[2].kind);
}

test "overflow is reported, never grown" {
    // §18.8. Churn is bursty — one explosion produces more entries than a quiet minute —
    // so the tempting fix is to grow mid-tick. Reporting is slower and correct.
    const gpa = std.testing.allocator;
    var j = try Journal.init(gpa, 4);
    defer j.deinit();

    for (0..4) |i| j.recordMutation(mk(@intCast(i + 1)), 1);
    try std.testing.expect(!j.requiresFullScan());

    j.recordMutation(mk(99), 1);
    try std.testing.expect(j.requiresFullScan());
    try std.testing.expectEqual(@as(usize, 4), j.items().len);
}

test "advance clears without releasing capacity" {
    const gpa = std.testing.allocator;
    var j = try Journal.init(gpa, 8);
    defer j.deinit();

    const before = j.entries.capacity;
    j.recordSpawn(mk(1));
    j.recordMutation(mk(1), 7);
    j.advance();

    try std.testing.expect(j.isEmpty());
    try std.testing.expectEqual(@as(u64, 1), j.tick);
    try std.testing.expectEqual(before, j.entries.capacity);
}

test "advance clears the overflow flag" {
    // Otherwise one bursty tick would force a full scan for the rest of the session.
    const gpa = std.testing.allocator;
    var j = try Journal.init(gpa, 1);
    defer j.deinit();

    j.recordSpawn(mk(1));
    j.recordSpawn(mk(2));
    try std.testing.expect(j.requiresFullScan());

    j.advance();
    try std.testing.expect(!j.requiresFullScan());
}

test "identical operation sequences produce identical journals" {
    // §7. Two peers on the same inputs must agree on what changed, or their replication
    // deltas diverge even where their worlds do not.
    const gpa = std.testing.allocator;
    var runs: [2][]Entry = undefined;

    for (&runs) |*out| {
        var j = try Journal.init(gpa, 64);
        defer j.deinit();
        for (0..10) |i| {
            j.recordSpawn(mk(@intCast(i + 1)));
            j.recordMutation(mk(@intCast(i + 1)), @intCast(0x41 + i));
            if (i % 3 == 0) j.recordDespawn(mk(@intCast(i + 1)));
        }
        out.* = try gpa.dupe(Entry, j.items());
    }
    defer for (runs) |r| gpa.free(r);

    try std.testing.expectEqualSlices(Entry, runs[0], runs[1]);
}

test "recording never allocates once initialized" {
    // The property §18.8 actually needs. Capacity is reserved up front; a
    // failing-allocator wrapper would be the stronger test, but exceeding capacity is the
    // only path that could allocate and it returns instead.
    const gpa = std.testing.allocator;
    var j = try Journal.init(gpa, 128);
    defer j.deinit();

    const cap = j.entries.capacity;
    for (0..128) |i| j.recordMutation(mk(@intCast((i % 100) + 1)), 1);
    try std.testing.expectEqual(cap, j.entries.capacity);
    try std.testing.expect(!j.requiresFullScan());
}
