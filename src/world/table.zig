//! An archetype table: the chunks holding one component set, plus the map from entity to
//! its location within them.
//!
//! `ARCHITECTURE.md` §5: "Components live in archetype chunks... Systems query chunk views
//! and emit commands."
//!
//! **The location map is the canonical example of "beside the database".** §18.5 forbids
//! per-field metadata inside chunks, and the obvious way to find an entity's row is to
//! store a back-pointer next to its components. That is the violation. The map lives here,
//! in the table, so chunks stay exactly as wide as the schema says.
//!
//! Allocation discipline: §18.8 forbids unbounded or implicit allocation from the engine
//! allocator in the frame loop. Spawning into a full table allocates a chunk, which is a
//! frame-loop path. `reserve` exists so a cell can size itself at session start against
//! `BENCHMARK_CONTRACT.md` §1.1's census and never allocate mid-tick; the allocation path
//! remains as a correctness fallback rather than the expected behaviour, and
//! `chunks_allocated_since_reset` makes a mid-tick allocation observable instead of
//! silent.

const std = @import("std");
const entity_mod = @import("entity.zig");
const chunk_mod = @import("chunk.zig");

pub const Entity = entity_mod.Entity;

pub const Location = struct {
    chunk: u32,
    row: u32,

    pub const none: Location = .{ .chunk = std.math.maxInt(u32), .row = 0 };

    pub fn isNone(self: Location) bool {
        return self.chunk == std.math.maxInt(u32);
    }
};

pub fn Table(comptime Columns: type, comptime budget: chunk_mod.Budget) type {
    const ChunkT = chunk_mod.Chunk(Columns, budget);

    return struct {
        const Self = @This();

        pub const ChunkType = ChunkT;
        pub const chunk_capacity = ChunkT.capacity;

        gpa: std.mem.Allocator,
        chunks: std.ArrayList(*ChunkT),
        /// Entity index -> location. Sparse by entity index, which is dense by
        /// construction (`entity.Allocator` reuses slots), so this stays compact without
        /// a hash map — and without the non-deterministic iteration order a hash map
        /// would bring to a §7 path.
        locations: std.ArrayList(Location),
        len: u32,
        /// Lowest chunk index that might have a free row. Only ever an under-estimate,
        /// so the scan below is correct however stale it gets.
        first_maybe_free: u32,
        /// Chunks allocated since the last `resetAllocationCounter`. Non-zero after a
        /// tick means the frame loop allocated, which §18.8 forbids.
        chunks_allocated_since_reset: u32,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
                .chunks = .empty,
                .locations = .empty,
                .len = 0,
                .first_maybe_free = 0,
                .chunks_allocated_since_reset = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.chunks.items) |c| self.gpa.destroy(c);
            self.chunks.deinit(self.gpa);
            self.locations.deinit(self.gpa);
            self.* = undefined;
        }

        fn appendChunk(self: *Self) !void {
            const c = try self.gpa.create(ChunkT);
            c.* = ChunkT.init;
            try self.chunks.append(self.gpa, c);
            self.chunks_allocated_since_reset += 1;
        }

        /// Pre-allocate capacity for `entities`. Call at session start against the §1.1
        /// census so the frame loop never allocates.
        pub fn reserve(self: *Self, entities: u32) !void {
            const needed = (entities + chunk_capacity - 1) / chunk_capacity;
            while (self.chunks.items.len < needed) try self.appendChunk();
            self.first_maybe_free = 0;
            if (entities > self.locations.items.len) {
                try self.locations.ensureTotalCapacity(self.gpa, entities);
            }
            self.chunks_allocated_since_reset = 0;
        }

        pub fn resetAllocationCounter(self: *Self) void {
            self.chunks_allocated_since_reset = 0;
        }

        fn ensureLocationSlot(self: *Self, index: u32) !void {
            while (self.locations.items.len <= index) {
                try self.locations.append(self.gpa, Location.none);
            }
        }

        pub fn contains(self: Self, e: Entity) bool {
            const index: u32 = e.index;
            if (index >= self.locations.items.len) return false;
            const loc = self.locations.items[index];
            if (loc.isNone()) return false;
            // Confirm the generation too: a recycled index must not resolve to the
            // previous occupant's row.
            return Entity.eql(self.chunks.items[loc.chunk].entities[loc.row], e);
        }

        pub fn locate(self: Self, e: Entity) ?Location {
            if (!self.contains(e)) return null;
            return self.locations.items[e.index];
        }

        /// Insert into the lowest-indexed chunk with room, appending one only when every
        /// existing chunk is full.
        ///
        /// First-fit rather than append-to-last, and both are equally deterministic —
        /// placement is a function of the current fill state, which two peers replaying
        /// the same operations share. What first-fit additionally does is *use*
        /// `reserve`'s chunks; appending to the last one would fill chunk N and leave
        /// 0..N-1 empty, so the reservation bought nothing and the frame loop allocated
        /// anyway. It also keeps chunks densely packed, which is the point of SoA.
        pub fn add(self: *Self, e: Entity, values: Columns) !Location {
            std.debug.assert(!e.isNone());
            try self.ensureLocationSlot(e.index);
            std.debug.assert(self.locations.items[e.index].isNone());

            var chunk_index: u32 = self.first_maybe_free;
            while (chunk_index < self.chunks.items.len and self.chunks.items[chunk_index].isFull()) {
                chunk_index += 1;
            }
            self.first_maybe_free = chunk_index;
            if (chunk_index == self.chunks.items.len) try self.appendChunk();

            const row = try self.chunks.items[chunk_index].push(e, values);

            const loc: Location = .{ .chunk = chunk_index, .row = row };
            self.locations.items[e.index] = loc;
            self.len += 1;
            return loc;
        }

        /// Remove. The chunk swap-removes, so another entity may move; its location is
        /// updated here. Missing that is the bug this API shape exists to prevent —
        /// `swapRemove` returns the moved entity rather than leaving it to be remembered.
        pub fn remove(self: *Self, e: Entity) bool {
            const loc = self.locate(e) orelse return false;
            const c = self.chunks.items[loc.chunk];

            if (c.swapRemove(loc.row)) |moved| {
                self.locations.items[moved.index] = .{ .chunk = loc.chunk, .row = loc.row };
            }
            self.locations.items[e.index] = Location.none;
            self.first_maybe_free = @min(self.first_maybe_free, loc.chunk);
            self.len -= 1;
            return true;
        }

        pub fn get(self: Self, e: Entity, comptime name: []const u8) ?@FieldType(Columns, name) {
            const loc = self.locate(e) orelse return null;
            return @field(self.chunks.items[loc.chunk].columns, name)[loc.row];
        }

        pub fn set(self: *Self, e: Entity, comptime name: []const u8, value: @FieldType(Columns, name)) bool {
            const loc = self.locate(e) orelse return false;
            @field(self.chunks.items[loc.chunk].columns, name)[loc.row] = value;
            return true;
        }

        /// Iterate chunks. Systems take whole chunk views rather than per-entity
        /// callbacks — §5 says "systems query chunk views", and a per-entity interface
        /// would defeat the SoA layout the chunk exists for.
        pub const ChunkIterator = struct {
            table: *Self,
            next_index: usize = 0,

            pub fn next(self: *ChunkIterator) ?*ChunkT {
                while (self.next_index < self.table.chunks.items.len) {
                    const c = self.table.chunks.items[self.next_index];
                    self.next_index += 1;
                    if (c.len > 0) return c;
                }
                return null;
            }
        };

        pub fn chunkIterator(self: *Self) ChunkIterator {
            return .{ .table = self };
        }
    };
}

// ---------------------------------------------------------------------------

const Fixed = @import("fpz").Fixed;
const TestColumns = struct {
    health: u16,
    armour: u16,
};
/// A tiny budget so chunk-boundary behaviour is reachable in a test.
const tiny: chunk_mod.Budget = .{ .bytes = 4 * (4 + 4) };
const TestTable = Table(TestColumns, tiny);

fn mk(i: u24) Entity {
    return .{ .index = i, .generation = 1 };
}

test "add and read back" {
    var t = TestTable.init(std.testing.allocator);
    defer t.deinit();

    _ = try t.add(mk(1), .{ .health = 10, .armour = 20 });
    try std.testing.expectEqual(@as(u16, 10), t.get(mk(1), "health").?);
    try std.testing.expectEqual(@as(u32, 1), t.len);
}

test "a stale handle does not resolve after its index is reused" {
    // The generational check in `contains`. Without it, a recycled index would read the
    // previous occupant's row — and rollback plus respawn makes that ordinary.
    var t = TestTable.init(std.testing.allocator);
    defer t.deinit();

    const first: Entity = .{ .index = 5, .generation = 1 };
    const recycled: Entity = .{ .index = 5, .generation = 2 };

    _ = try t.add(first, .{ .health = 1, .armour = 1 });
    try std.testing.expect(t.remove(first));
    _ = try t.add(recycled, .{ .health = 99, .armour = 99 });

    try std.testing.expect(t.locate(first) == null);
    try std.testing.expectEqual(@as(u16, 99), t.get(recycled, "health").?);
}

test "removal updates the location of the entity that moved" {
    // swapRemove relocates a row. If the map is not updated, that entity silently reads
    // someone else's components from then on.
    var t = TestTable.init(std.testing.allocator);
    defer t.deinit();

    _ = try t.add(mk(1), .{ .health = 1, .armour = 1 });
    _ = try t.add(mk(2), .{ .health = 2, .armour = 2 });
    _ = try t.add(mk(3), .{ .health = 3, .armour = 3 });

    try std.testing.expect(t.remove(mk(1)));

    try std.testing.expectEqual(@as(u16, 2), t.get(mk(2), "health").?);
    try std.testing.expectEqual(@as(u16, 3), t.get(mk(3), "health").?);
    try std.testing.expect(t.locate(mk(1)) == null);
}

test "placement is deterministic across identical histories" {
    // §7: two peers on the same inputs must reach the same layout, or their page bytes
    // differ and every snapshot hash disagrees.
    const gpa = std.testing.allocator;
    var results: [2][12]TestTable.ChunkType.ColumnSet = undefined;

    for (&results) |*out| {
        var t = TestTable.init(gpa);
        defer t.deinit();
        for (0..12) |i| {
            _ = try t.add(mk(@intCast(i + 1)), .{ .health = @intCast(i), .armour = 0 });
            if (i % 4 == 3) _ = t.remove(mk(@intCast(i - 1)));
        }
        for (out, 0..) |*slot, i| {
            slot.* = .{
                .health = t.get(mk(@intCast(i + 1)), "health") orelse 0xFFFF,
                .armour = 0,
            };
        }
    }
    try std.testing.expectEqualSlices(TestTable.ChunkType.ColumnSet, &results[0], &results[1]);
}

test "spills into a second chunk when the first fills" {
    var t = TestTable.init(std.testing.allocator);
    defer t.deinit();

    const cap = TestTable.chunk_capacity;
    for (0..cap + 1) |i| {
        _ = try t.add(mk(@intCast(i + 1)), .{ .health = @intCast(i % 1000), .armour = 0 });
    }
    try std.testing.expectEqual(@as(usize, 2), t.chunks.items.len);
    try std.testing.expectEqual(cap + 1, t.len);

    // Every entity still resolves to its own value.
    for (0..cap + 1) |i| {
        try std.testing.expectEqual(@as(u16, @intCast(i % 1000)), t.get(mk(@intCast(i + 1)), "health").?);
    }
}

test "reserve removes allocation from the frame loop" {
    // §18.8 forbids unbounded allocation in the frame loop, and spawning is a frame-loop
    // path. Sizing at session start against the §1.1 census is how that is satisfied;
    // the counter makes a violation observable rather than silent.
    var t = TestTable.init(std.testing.allocator);
    defer t.deinit();

    try t.reserve(TestTable.chunk_capacity * 3);
    try std.testing.expectEqual(@as(u32, 0), t.chunks_allocated_since_reset);

    for (0..TestTable.chunk_capacity * 3) |i| {
        _ = try t.add(mk(@intCast(i + 1)), .{ .health = 0, .armour = 0 });
    }
    try std.testing.expectEqual(@as(u32, 0), t.chunks_allocated_since_reset);

    // One past the reservation does allocate, and says so.
    _ = try t.add(mk(@intCast(TestTable.chunk_capacity * 3 + 1)), .{ .health = 0, .armour = 0 });
    try std.testing.expectEqual(@as(u32, 1), t.chunks_allocated_since_reset);
}

test "the chunk iterator skips empty chunks" {
    var t = TestTable.init(std.testing.allocator);
    defer t.deinit();
    try t.reserve(TestTable.chunk_capacity * 3);

    _ = try t.add(mk(1), .{ .health = 7, .armour = 0 });

    var it = t.chunkIterator();
    var seen: usize = 0;
    while (it.next()) |c| {
        seen += 1;
        try std.testing.expect(c.len > 0);
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "systems see whole chunk views, not per-entity callbacks" {
    // §5: "Systems query chunk views." A per-entity interface would defeat the SoA
    // layout the chunk exists for.
    var t = TestTable.init(std.testing.allocator);
    defer t.deinit();
    for (0..3) |i| _ = try t.add(mk(@intCast(i + 1)), .{ .health = 10, .armour = 0 });

    var it = t.chunkIterator();
    while (it.next()) |c| {
        for (c.column("health")) |*h| h.* += 5;
    }
    for (0..3) |i| try std.testing.expectEqual(@as(u16, 15), t.get(mk(@intCast(i + 1)), "health").?);
}

test "removing an absent entity is a no-op rather than corruption" {
    // Rollback replays despawns, so a double-remove is ordinary rather than exceptional.
    var t = TestTable.init(std.testing.allocator);
    defer t.deinit();
    _ = try t.add(mk(1), .{ .health = 1, .armour = 1 });

    try std.testing.expect(t.remove(mk(1)));
    try std.testing.expect(!t.remove(mk(1)));
    try std.testing.expect(!t.remove(mk(99)));
    try std.testing.expectEqual(@as(u32, 0), t.len);
}
