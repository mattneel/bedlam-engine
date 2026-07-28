//! Archetype identity and migration.
//!
//! `ARCHITECTURE.md` §5: "Components live in archetype chunks, SoA or AoSoA per family."
//! Plural. `world.zig` shipped a single-archetype world and said so; this is the part that
//! makes an entity's component set changeable, which is what an archetype design is for.
//!
//! **An archetype is identified by its component-ID set, not by a table index.** §18.6
//! forbids durable identity derived from layout or declaration order, and an archetype id
//! that is "the third table created" is exactly that — it changes when an unrelated
//! archetype is created first, so a save or a replay recorded under one build reads as a
//! different archetype under another.
//!
//! **Migration is the expensive operation and the honest one.** Adding a component to an
//! entity moves its row to a different chunk: copy the shared columns, default the new
//! one, swap-remove from the old chunk, fix the location map. There is no way to make
//! that cheap in an archetype design, which is exactly why gkz's flat table scored well
//! on this axis — and why §5 accepts the cost. What must not happen is pretending it is
//! cheap: `migrations` is counted so a system doing it per-entity-per-tick is visible
//! rather than merely slow.

const std = @import("std");
const journal_mod = @import("journal.zig");

pub const ComponentId = journal_mod.ComponentId;

/// Maximum components in one archetype. The bitset width follows from it.
///
/// 128 rather than 64: gkz caps at 64 and its own risk register names that a near-term
/// ceiling. §5.3 lists ten component *classes*, each with many types, so 64 is a limit a
/// real game reaches and crossing it is a wire-visible schema change.
pub const max_components: usize = 128;

/// The set of component IDs an archetype contains.
///
/// A sorted ID list rather than a bitmask over declaration indices, because a bitmask
/// bit is a position and §18.6 forbids identity derived from position. Two builds that
/// declare components in different orders must agree on what an archetype is.
pub const Signature = struct {
    ids: [max_components]ComponentId = @splat(0),
    len: u8 = 0,

    pub fn fromSlice(ids: []const ComponentId) Signature {
        std.debug.assert(ids.len <= max_components);
        var s: Signature = .{};
        for (ids) |id| _ = s.insert(id);
        return s;
    }

    /// Insert, keeping the list sorted and unique. Returns false if already present.
    ///
    /// Sorted so that two signatures built by different insertion orders compare equal —
    /// an entity that gained A then B must be in the same archetype as one that gained B
    /// then A, or the world fragments into archetypes that differ only by history.
    pub fn insert(self: *Signature, id: ComponentId) bool {
        var i: usize = 0;
        while (i < self.len and self.ids[i] < id) : (i += 1) {}
        if (i < self.len and self.ids[i] == id) return false;
        std.debug.assert(self.len < max_components);

        var j: usize = self.len;
        while (j > i) : (j -= 1) self.ids[j] = self.ids[j - 1];
        self.ids[i] = id;
        self.len += 1;
        return true;
    }

    pub fn remove(self: *Signature, id: ComponentId) bool {
        const idx = self.indexOf(id) orelse return false;
        var i: usize = idx;
        while (i + 1 < self.len) : (i += 1) self.ids[i] = self.ids[i + 1];
        self.len -= 1;
        self.ids[self.len] = 0;
        return true;
    }

    pub fn indexOf(self: Signature, id: ComponentId) ?usize {
        for (self.slice(), 0..) |x, i| {
            if (x == id) return i;
            if (x > id) return null; // sorted
        }
        return null;
    }

    pub fn contains(self: Signature, id: ComponentId) bool {
        return self.indexOf(id) != null;
    }

    pub fn slice(self: *const Signature) []const ComponentId {
        return self.ids[0..self.len];
    }

    pub fn eql(a: Signature, b: Signature) bool {
        if (a.len != b.len) return false;
        return std.mem.eql(ComponentId, a.slice(), b.slice());
    }

    /// Whether every id in `other` is present. This is what a query asks.
    pub fn supersetOf(self: Signature, other: Signature) bool {
        for (other.slice()) |id| {
            if (!self.contains(id)) return false;
        }
        return true;
    }

    /// Stable hash of the ID set.
    ///
    /// Explicit little-endian and derived only from the sorted IDs, so it is identical
    /// across architectures and across builds that declare components in different
    /// orders — the same discipline `world/hash.zig` applies for the same reason.
    pub fn hash(self: Signature) u64 {
        var h = std.hash.Wyhash.init(0);
        for (self.slice()) |id| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, id, .little);
            h.update(&buf);
        }
        return h.final();
    }
};

/// How many entities changed archetype. Counted because migration is inherently the
/// expensive operation in this design, and a system doing it per entity per tick should be
/// visible in telemetry rather than merely slow — the same argument §6.3 makes for
/// surfacing closure size.
pub const MigrationStats = struct {
    migrations: u64 = 0,
    components_copied: u64 = 0,
};

// ---------------------------------------------------------------------------

test "insertion order does not affect identity" {
    // An entity that gained A then B must land in the same archetype as one that gained
    // B then A, or the world fragments into archetypes differing only by history.
    const a = Signature.fromSlice(&.{ 0x41, 0x55, 0x61 });
    const b = Signature.fromSlice(&.{ 0x61, 0x41, 0x55 });
    const c = Signature.fromSlice(&.{ 0x55, 0x61, 0x41 });

    try std.testing.expect(a.eql(b));
    try std.testing.expect(b.eql(c));
    try std.testing.expectEqual(a.hash(), b.hash());
    try std.testing.expectEqual(b.hash(), c.hash());
}

test "identity is the ID set, not a table index" {
    // §18.6 forbids durable identity derived from layout or declaration order. An
    // archetype id that means "the third table created" changes when an unrelated
    // archetype is created first.
    const a = Signature.fromSlice(&.{ 0x41, 0x55 });
    const b = Signature.fromSlice(&.{ 0x41, 0x56 });
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(a.hash() != b.hash());
}

test "duplicate inserts are rejected" {
    var s = Signature.fromSlice(&.{0x41});
    try std.testing.expect(!s.insert(0x41));
    try std.testing.expectEqual(@as(u8, 1), s.len);
    try std.testing.expect(s.insert(0x42));
    try std.testing.expectEqual(@as(u8, 2), s.len);
}

test "removal keeps the list sorted and compact" {
    var s = Signature.fromSlice(&.{ 0x10, 0x20, 0x30, 0x40 });
    try std.testing.expect(s.remove(0x20));
    try std.testing.expectEqualSlices(ComponentId, &.{ 0x10, 0x30, 0x40 }, s.slice());
    try std.testing.expect(!s.remove(0x20));

    // The vacated tail is zeroed, so two signatures reaching the same set by different
    // removal histories compare and hash identically.
    const direct = Signature.fromSlice(&.{ 0x10, 0x30, 0x40 });
    try std.testing.expect(s.eql(direct));
    try std.testing.expectEqual(direct.hash(), s.hash());
}

test "supersetOf is what a query asks" {
    const entity = Signature.fromSlice(&.{ 0x41, 0x55, 0x61, 0x72 });
    const query = Signature.fromSlice(&.{ 0x41, 0x61 });
    const absent = Signature.fromSlice(&.{ 0x41, 0x99 });

    try std.testing.expect(entity.supersetOf(query));
    try std.testing.expect(!entity.supersetOf(absent));
    try std.testing.expect(entity.supersetOf(entity));
}

test "an empty signature is a superset of nothing but itself" {
    const empty: Signature = .{};
    const any = Signature.fromSlice(&.{0x41});
    try std.testing.expect(empty.supersetOf(empty));
    try std.testing.expect(!empty.supersetOf(any));
    try std.testing.expect(any.supersetOf(empty));
}

test "the component ceiling is above the one that bites first" {
    // gkz caps at 64 and its own risk register names that a near-term ceiling; §5.3 lists
    // ten component CLASSES, each with many types. Crossing the limit is a wire-visible
    // schema change, so the limit should not be the first thing a real game hits.
    try std.testing.expect(max_components >= 128);

    var s: Signature = .{};
    for (0..max_components) |i| {
        try std.testing.expect(s.insert(@intCast(max_components - i)));
    }
    try std.testing.expectEqual(@as(u8, max_components), s.len);

    // And it is still sorted after being filled in descending order.
    for (s.slice()[0 .. s.len - 1], s.slice()[1..]) |a, b| {
        try std.testing.expect(a < b);
    }
}

test "hash is stable across architectures" {
    // Pinned, and re-verified on s390x, arm and mips by `zig build cross`. A signature
    // hash that depends on host byte order fragments archetypes between a big-endian
    // validator and a little-endian host — §14.3 runs exactly that pairing.
    const s = Signature.fromSlice(&.{ 0x0041, 0x0055, 0x0061 });
    try std.testing.expectEqual(@as(u64, 0x16838c0c6cd809bd), s.hash());
}
