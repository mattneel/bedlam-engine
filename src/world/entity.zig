//! Generational entity handles.
//!
//! `ARCHITECTURE.md` §5: "Entities are generational IDs." The generation is what makes a
//! stale handle *detectable* rather than silently aliasing whatever now occupies the
//! slot — and in an engine where state is rolled back, replayed, and migrated between
//! hosts, stale handles are not an edge case. A rollback restores a world in which an
//! entity that was despawned exists again; a replay validator holds references from a
//! tick that has been re-simulated.
//!
//! Allocation order is deterministic, which is a §7 requirement rather than a nicety: two
//! peers simulating the same inputs must allocate the same indices, or every subsequent
//! handle disagrees. The free list is LIFO and the fallback is a bump, both of which are
//! functions of history alone — no allocator address, no hash iteration, no clock.

const std = @import("std");

/// 24 bits of index, 8 of generation, packed into the 32 bits `wire.WireType.entity_handle`
/// budgets. That is 16.7M live entities against a reference workload whose peak is 8,192
/// replicated plus 16,384 derived (`BENCHMARK_CONTRACT.md` §1.1), so the index is not the
/// constraint; the generation is.
pub const Entity = packed struct(u32) {
    index: u24,
    generation: u8,

    /// Reserved. Index 0 is never allocated so a zeroed struct is detectably not an
    /// entity, rather than being a valid handle to whatever landed in slot 0.
    pub const none: Entity = .{ .index = 0, .generation = 0 };

    pub fn eql(a: Entity, b: Entity) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    pub fn isNone(self: Entity) bool {
        return self.index == 0;
    }
};

pub const max_entities: u32 = (1 << 24) - 1;

/// Eight bits of generation wrap after 256 reuses of a slot, at which point a handle old
/// enough to have survived 256 recycles of the same index resolves as live again.
///
/// The mitigation is not a wider generation — it is the free-list discipline below, which
/// hands out the least-recently-freed slot rather than the most-recently-freed one, so
/// reaching 256 reuses requires cycling the entire free list 256 times.
pub const generation_wrap: u16 = 256;

pub const Allocator = struct {
    /// Generation per slot. Index 0 is reserved and never handed out.
    generations: std.ArrayList(u8),
    /// Freed slots, oldest first. FIFO rather than LIFO, deliberately — see `free`.
    free_head: u32,
    free_tail: u32,
    /// Next-free link per slot, valid only while the slot is free.
    next_free: std.ArrayList(u24),
    live_count: u32,

    pub const empty: Allocator = .{
        .generations = .empty,
        .free_head = 0,
        .free_tail = 0,
        .next_free = .empty,
        .live_count = 0,
    };

    pub fn deinit(self: *Allocator, gpa: std.mem.Allocator) void {
        self.generations.deinit(gpa);
        self.next_free.deinit(gpa);
        self.* = undefined;
    }

    fn ensureSlotZero(self: *Allocator, gpa: std.mem.Allocator) !void {
        if (self.generations.items.len == 0) {
            try self.generations.append(gpa, 0);
            try self.next_free.append(gpa, 0);
        }
    }

    pub fn alloc(self: *Allocator, gpa: std.mem.Allocator) !Entity {
        try self.ensureSlotZero(gpa);

        if (self.free_head != 0) {
            const index = self.free_head;
            self.free_head = self.next_free.items[index];
            if (self.free_head == 0) self.free_tail = 0;
            self.live_count += 1;
            return .{ .index = @intCast(index), .generation = self.generations.items[index] };
        }

        const index = self.generations.items.len;
        if (index > max_entities) return error.OutOfEntities;
        try self.generations.append(gpa, 1);
        try self.next_free.append(gpa, 0);
        self.live_count += 1;
        return .{ .index = @intCast(index), .generation = 1 };
    }

    /// Freeing appends to the TAIL of the free list, not the head.
    ///
    /// A LIFO free list reuses the slot just released, so a spawn/despawn loop on one
    /// entity burns through all 256 generations in 256 ticks and starts resolving stale
    /// handles as live. FIFO means reaching that requires cycling every free slot, which
    /// turns a plausible pattern into an implausible one. The cost is one extra link
    /// write; the alternative is a bug that only appears after minutes of play.
    pub fn free(self: *Allocator, e: Entity) void {
        if (!self.isLive(e)) return;

        const index: u32 = e.index;
        self.generations.items[index] = @truncate(@as(u16, self.generations.items[index]) + 1);
        // Generation 0 marks "never allocated", so skip it on wrap.
        if (self.generations.items[index] == 0) self.generations.items[index] = 1;

        self.next_free.items[index] = 0;
        if (self.free_tail == 0) {
            self.free_head = index;
        } else {
            self.next_free.items[self.free_tail] = @intCast(index);
        }
        self.free_tail = index;
        self.live_count -= 1;
    }

    /// The generation currently recorded for a slot, or null if it was never allocated.
    ///
    /// Note this says nothing about whether the slot is OCCUPIED: `free` bumps the
    /// generation and leaves it recorded, so between a free and the next alloc this
    /// returns the generation that is about to be handed out. Occupancy is the table's
    /// question, not the allocator's.
    pub fn generationAt(self: Allocator, index: u24) ?u8 {
        if (index == 0 or index >= self.generations.items.len) return null;
        const g = self.generations.items[index];
        return if (g == 0) null else g;
    }

    /// Force a specific handle live. **Replica worlds only.**
    ///
    /// A client mirroring an authoritative world does not allocate its own handles: the
    /// server names the entity, and the client's job is to hold the same world. A local
    /// allocator producing its own handles would give the same object different identities
    /// on the two peers, and `world/hash.zig` includes identity — so two peers in perfect
    /// agreement about the world would report a desync.
    ///
    /// This is NOT §18.6's "durable ID derived from position". The handle is not derived
    /// from anything; it is *transmitted*, and it is a runtime handle scoped to one session
    /// rather than a durable identifier written to a save. `SCHEMA_AND_EVOLUTION.md`'s
    /// stable IDs remain the only durable identity.
    ///
    /// **Makes no occupancy judgement, deliberately.** An earlier version refused when
    /// `isLive` reported the slot taken, and it was wrong in a way that only appeared after
    /// a hundred rounds of spawn and despawn: `free` bumps the generation *and leaves it
    /// recorded*, so `isLive` returns true for the exact handle the allocator is about to
    /// hand out next. The replica would then refuse the authority's spawn for a slot it had
    /// itself just vacated. The table knows what is occupied; the allocator does not, and
    /// pretending otherwise produced a divergence with no error attached to it.
    pub fn adopt(self: *Allocator, gpa: std.mem.Allocator, e: Entity) !void {
        std.debug.assert(!e.isNone());
        try self.ensureSlotZero(gpa);

        const index: u32 = e.index;
        while (self.generations.items.len <= index) {
            // Generation 0 means "never allocated", which is what an unmentioned slot is.
            try self.generations.append(gpa, 0);
            try self.next_free.append(gpa, 0);
        }
        self.generations.items[index] = e.generation;
        self.live_count += 1;
    }

    pub fn isLive(self: Allocator, e: Entity) bool {
        if (e.isNone()) return false;
        const index: u32 = e.index;
        if (index >= self.generations.items.len) return false;
        return self.generations.items[index] == e.generation;
    }
};

// ---------------------------------------------------------------------------

test "entity handle packs into the 32 bits the wire budgets" {
    try std.testing.expectEqual(@as(usize, 32), @bitSizeOf(Entity));
}

test "a zeroed handle is not a valid entity" {
    // Slot 0 is reserved so `std.mem.zeroes(Component)` cannot produce a live reference.
    try std.testing.expect(Entity.none.isNone());
    var a: Allocator = .empty;
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(!a.isLive(Entity.none));

    const e = try a.alloc(std.testing.allocator);
    try std.testing.expect(e.index != 0);
}

test "a freed handle stops resolving" {
    const gpa = std.testing.allocator;
    var a: Allocator = .empty;
    defer a.deinit(gpa);

    const e = try a.alloc(gpa);
    try std.testing.expect(a.isLive(e));
    a.free(e);
    try std.testing.expect(!a.isLive(e));
}

test "a recycled slot does not honour the old handle" {
    // The property the generation exists for. Without it, a rollback that respawns into
    // a recycled slot would silently redirect every stale reference.
    const gpa = std.testing.allocator;
    var a: Allocator = .empty;
    defer a.deinit(gpa);

    const first = try a.alloc(gpa);
    a.free(first);
    const second = try a.alloc(gpa);

    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(!Entity.eql(first, second));
    try std.testing.expect(!a.isLive(first));
    try std.testing.expect(a.isLive(second));
}

test "freeing is FIFO, so one entity cycling does not burn its generation" {
    // A LIFO free list would hand slot N straight back, exhausting 256 generations in
    // 256 spawn/despawn pairs — reachable in four seconds at 64 Hz. FIFO requires
    // cycling the whole list first.
    const gpa = std.testing.allocator;
    var a: Allocator = .empty;
    defer a.deinit(gpa);

    var handles: [8]Entity = undefined;
    for (&handles) |*h| h.* = try a.alloc(gpa);
    for (handles) |h| a.free(h);

    // Reallocation follows free order, oldest first.
    for (handles) |original| {
        const reused = try a.alloc(gpa);
        try std.testing.expectEqual(original.index, reused.index);
        try std.testing.expect(reused.generation != original.generation);
    }
}

test "allocation order is a function of history alone" {
    // §7: two peers on the same inputs must allocate identical indices, or every
    // subsequent handle disagrees. Nothing here may depend on an address or a hash order.
    const gpa = std.testing.allocator;

    var runs: [2][16]Entity = undefined;
    for (&runs) |*run| {
        var a: Allocator = .empty;
        defer a.deinit(gpa);
        for (run, 0..) |*slot, i| {
            slot.* = try a.alloc(gpa);
            if (i % 3 == 2) a.free(slot.*);
        }
    }
    try std.testing.expectEqualSlices(Entity, &runs[0], &runs[1]);
}

test "generation skips zero on wrap" {
    // Generation 0 means "never allocated"; a wrapped slot landing there would make a
    // stale handle resolve against a slot that has been reused 256 times.
    const gpa = std.testing.allocator;
    var a: Allocator = .empty;
    defer a.deinit(gpa);

    const e = try a.alloc(gpa);
    const index: u32 = e.index;
    a.generations.items[index] = 255;

    var live = e;
    live.generation = 255;
    a.free(live);
    try std.testing.expectEqual(@as(u8, 1), a.generations.items[index]);
}

test "live_count tracks allocation and release" {
    const gpa = std.testing.allocator;
    var a: Allocator = .empty;
    defer a.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 0), a.live_count);
    const x = try a.alloc(gpa);
    const y = try a.alloc(gpa);
    try std.testing.expectEqual(@as(u32, 2), a.live_count);
    a.free(x);
    try std.testing.expectEqual(@as(u32, 1), a.live_count);
    a.free(y);
    try std.testing.expectEqual(@as(u32, 0), a.live_count);

    // Double-free is a no-op rather than corruption: rollback replays despawns.
    a.free(x);
    try std.testing.expectEqual(@as(u32, 0), a.live_count);
}

test "handles survive the reference workload's peak census" {
    const gpa = std.testing.allocator;
    var a: Allocator = .empty;
    defer a.deinit(gpa);

    // BENCHMARK_CONTRACT.md §1.1: ~8,192 replicated peak plus 16,384 derived.
    var live: std.ArrayList(Entity) = .empty;
    defer live.deinit(gpa);
    for (0..24_576) |_| try live.append(gpa, try a.alloc(gpa));

    try std.testing.expectEqual(@as(u32, 24_576), a.live_count);
    for (live.items) |e| try std.testing.expect(a.isLive(e));
}
