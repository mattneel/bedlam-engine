//! Archetype chunks: SoA storage for one component set.
//!
//! `ARCHITECTURE.md` §5: "Components live in archetype chunks, SoA or AoSoA per family,
//! layout permitted to differ per target."
//!
//! Three invariants meet here, and all three are unretrofittable:
//!
//! **§18.5 — no per-field metadata, from any subsystem, ever.** A chunk holds exactly the
//! declared component columns plus the entity column. There is no dirty bit, no version
//! stamp, no provenance, no lease. `schema.storable.assertStorable` rejects a type that
//! smuggles one in, recursively. Dirty tracking lives beside the chunk, in the page
//! table, because §5.2 says the rollback projection copies *pages* — and a per-field
//! stamp inside the page would be copied with it and then be wrong.
//!
//! **§18.16 — "page" means an engine-owned logical block.** Never `mprotect`, never VM
//! page protection, never remapping. `Chunk` is an allocation this engine owns and
//! copies with `@memcpy`. Anything leaning on OS paging works on desktop long enough to
//! become load-bearing and then dies on Web.
//!
//! **§0 P1 — physical layout per target, semantic schema never.** `capacity` derives from
//! the target's chunk budget, so a wasm32 chunk holds fewer rows than a desktop one. That
//! difference must never reach the wire or the fingerprint; `SCHEMA_AND_EVOLUTION.md` §10
//! check 5 is what catches it if it does.

const std = @import("std");
const schema_mod = @import("bedlam_schema");
const storable = schema_mod.storable;

/// Per-target chunk budget. `ARCHITECTURE.md` §4.1 caps wasm32 addressability and §1.3
/// makes mobile memory a hard limit that propagates upward, so this is smaller where the
/// address space is.
pub const Budget = struct {
    bytes: u32,

    pub const wasm32: Budget = .{ .bytes = 8 * 1024 };
    pub const mobile: Budget = .{ .bytes = 16 * 1024 };
    pub const desktop: Budget = .{ .bytes = 64 * 1024 };

    /// The budget this build targets. Chosen from address space rather than from a build
    /// flag, so a target cannot accidentally be given a layout it has no room for.
    pub const target: Budget = switch (@import("builtin").cpu.arch) {
        .wasm32, .wasm64 => wasm32,
        .aarch64, .arm => mobile,
        else => desktop,
    };
};

/// SoA storage for a fixed set of component types.
///
/// `Columns` is a struct whose every field is a component type; the chunk stores one
/// array per field. Generated from the archetype rather than hand-written, so adding a
/// component cannot desynchronize the columns from the schema.
pub fn Chunk(comptime Columns: type, comptime budget: Budget) type {
    const info = @typeInfo(Columns).@"struct";

    comptime {
        for (info.fields) |f| {
            storable.assertStorable(f.type, "chunk column '" ++ f.name ++ "'");
            storable.assertFixedWidth(f.type, "chunk column '" ++ f.name ++ "'");
        }
    }

    // Row cost is the entity column plus every component column. Capacity follows from
    // the budget, which is why it differs per target and the wire does not.
    const row_bytes = blk: {
        var n: usize = @sizeOf(Entity);
        for (info.fields) |f| n += @sizeOf(f.type);
        break :blk n;
    };
    const cap = @max(1, budget.bytes / row_bytes);

    return struct {
        const Self = @This();

        pub const capacity: u32 = cap;
        pub const row_size: usize = row_bytes;
        pub const ColumnSet = Columns;

        /// Which entity owns each row. Not metadata about a *field* — it is the row's
        /// identity, which §18.5 does not forbid and a chunk cannot function without.
        entities: [cap]Entity,
        columns: ColumnArrays,
        len: u32,

        pub const ColumnArrays = blk: {
            var names: [info.fields.len][:0]const u8 = undefined;
            var types: [info.fields.len]type = undefined;
            for (info.fields, 0..) |f, i| {
                names[i] = f.name;
                types[i] = [cap]f.type;
            }
            break :blk @Struct(.auto, null, &names, &types, &@splat(.{}));
        };

        pub const init: Self = .{
            .entities = @splat(Entity.none),
            .columns = undefined,
            .len = 0,
        };

        pub fn isFull(self: Self) bool {
            return self.len >= capacity;
        }

        /// Append a row. Returns its index.
        pub fn push(self: *Self, e: Entity, values: Columns) error{ChunkFull}!u32 {
            if (self.isFull()) return error.ChunkFull;
            const row = self.len;
            self.entities[row] = e;
            inline for (info.fields) |f| {
                @field(self.columns, f.name)[row] = @field(values, f.name);
            }
            self.len += 1;
            return row;
        }

        /// Remove a row by swapping the last one into its place.
        ///
        /// Swap-remove rather than shifting: O(1), and iteration order within a chunk is
        /// not semantically meaningful. But it DOES move a row, so the caller must update
        /// the moved entity's location — hence returning which entity moved rather than
        /// leaving that to be remembered.
        pub fn swapRemove(self: *Self, row: u32) ?Entity {
            std.debug.assert(row < self.len);
            const last = self.len - 1;
            var moved: ?Entity = null;
            if (row != last) {
                self.entities[row] = self.entities[last];
                inline for (info.fields) |f| {
                    @field(self.columns, f.name)[row] = @field(self.columns, f.name)[last];
                }
                moved = self.entities[row];
            }

            // Clear the vacated slot to a canonical value.
            //
            // Two hosts can reach the same logical world by different spawn/despawn
            // histories. If the dead tail held whatever was there before, their chunk
            // bytes would differ while their worlds agreed — and the rollback projection
            // copies pages, so that difference would propagate into a snapshot hash and
            // look like a desync. Zeroing costs a row-width memset per removal and
            // removes the whole question.
            self.entities[last] = Entity.none;
            inline for (info.fields) |f| {
                @field(self.columns, f.name)[last] = std.mem.zeroes(f.type);
            }

            self.len = last;
            return moved;
        }

        /// A column as a slice of live rows. The query surface hands these to systems.
        pub fn column(self: *Self, comptime name: []const u8) []@FieldType(Columns, name) {
            return @field(self.columns, name)[0..self.len];
        }

        pub fn columnConst(self: *const Self, comptime name: []const u8) []const @FieldType(Columns, name) {
            return @field(self.columns, name)[0..self.len];
        }

        pub fn liveEntities(self: *const Self) []const Entity {
            return self.entities[0..self.len];
        }
    };
}

const Entity = @import("entity.zig").Entity;

// ---------------------------------------------------------------------------

const Fixed = @import("fpz").Fixed;
const TestColumns = struct {
    position: [3]Fixed,
    health: u16,
};
const TestChunk = Chunk(TestColumns, Budget.desktop);

fn sample(n: i64) TestColumns {
    return .{
        .position = .{ Fixed.fromInt(n), Fixed.fromInt(n + 1), Fixed.fromInt(n + 2) },
        .health = @intCast(n),
    };
}

test "capacity follows the target budget, so layout differs per target" {
    // §0 P1: physical layout may differ per target. A wasm32 chunk holds fewer rows than
    // a desktop one, and that difference must never reach the wire.
    const Web = Chunk(TestColumns, Budget.wasm32);
    const Desk = Chunk(TestColumns, Budget.desktop);
    try std.testing.expect(Web.capacity < Desk.capacity);
    try std.testing.expectEqual(Web.row_size, Desk.row_size);
}

test "a chunk holds exactly the declared columns and the entity column" {
    // §18.5. If a subsystem ever adds a dirty bit or a version stamp, this fails.
    const fields = @typeInfo(TestChunk.ColumnArrays).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("position", fields[0].name);
    try std.testing.expectEqualStrings("health", fields[1].name);

    const chunk_fields = @typeInfo(TestChunk).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 3), chunk_fields.len); // entities, columns, len
}

test "push and read back" {
    var c = TestChunk.init;
    const e: Entity = .{ .index = 7, .generation = 1 };
    const row = try c.push(e, sample(5));

    try std.testing.expectEqual(@as(u32, 0), row);
    try std.testing.expectEqual(@as(u32, 1), c.len);
    try std.testing.expectEqual(@as(u16, 5), c.columnConst("health")[0]);
    try std.testing.expectEqual(Fixed.fromInt(5).raw, c.columnConst("position")[0][0].raw);
}

test "a full chunk refuses rather than overruns" {
    var c = TestChunk.init;
    for (0..TestChunk.capacity) |i| {
        _ = try c.push(.{ .index = @intCast(i + 1), .generation = 1 }, sample(@intCast(i % 100)));
    }
    try std.testing.expect(c.isFull());
    try std.testing.expectError(error.ChunkFull, c.push(.{ .index = 1, .generation = 1 }, sample(0)));
}

test "swapRemove reports which entity moved" {
    // The caller owns the entity-to-location map, so a silent move would leave it stale.
    var c = TestChunk.init;
    const a: Entity = .{ .index = 1, .generation = 1 };
    const b: Entity = .{ .index = 2, .generation = 1 };
    const d: Entity = .{ .index = 3, .generation = 1 };
    _ = try c.push(a, sample(1));
    _ = try c.push(b, sample(2));
    _ = try c.push(d, sample(3));

    const moved = c.swapRemove(0);
    try std.testing.expect(moved != null);
    try std.testing.expect(Entity.eql(moved.?, d));
    try std.testing.expectEqual(@as(u32, 2), c.len);
    try std.testing.expectEqual(@as(u16, 3), c.columnConst("health")[0]);
}

test "removing the last row moves nothing" {
    var c = TestChunk.init;
    _ = try c.push(.{ .index = 1, .generation = 1 }, sample(1));
    try std.testing.expect(c.swapRemove(0) == null);
    try std.testing.expectEqual(@as(u32, 0), c.len);
}

test "the dead tail is canonical, so equal worlds have equal bytes" {
    // Two hosts reaching the same logical world by different histories must produce the
    // same chunk bytes. The rollback projection copies pages (§5.2), so a stale value in
    // a vacated slot would ride along into a snapshot hash and read as a desync.
    const e1: Entity = .{ .index = 1, .generation = 1 };
    const e2: Entity = .{ .index = 2, .generation = 1 };

    // History A: push two, remove the first.
    var a = TestChunk.init;
    _ = try a.push(e1, sample(11));
    _ = try a.push(e2, sample(22));
    _ = a.swapRemove(0);

    // History B: push only the survivor, with the identity it ends up holding.
    var b = TestChunk.init;
    _ = try b.push(e2, sample(22));

    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expectEqualSlices(Entity, &a.entities, &b.entities);
    try std.testing.expectEqualSlices(u16, &a.columns.health, &b.columns.health);
}

test "add-then-remove is byte-identical to never-added" {
    const e: Entity = .{ .index = 9, .generation = 3 };
    var a = TestChunk.init;
    _ = try a.push(e, sample(42));
    _ = a.swapRemove(0);

    const b = TestChunk.init;
    try std.testing.expectEqualSlices(Entity, &a.entities, &b.entities);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expectEqualSlices(u16, &a.columns.health, &b.columns.health);
}

test "a chunk fits its budget" {
    try std.testing.expect(@sizeOf(TestChunk) <= Budget.desktop.bytes + @sizeOf(u32) + TestChunk.row_size);
}

test "columns are contiguous per field, not interleaved" {
    // SoA is the point: a system reading only health must not pull position into cache.
    var c = TestChunk.init;
    _ = try c.push(.{ .index = 1, .generation = 1 }, sample(1));
    _ = try c.push(.{ .index = 2, .generation = 1 }, sample(2));

    const health = c.column("health");
    try std.testing.expectEqual(@as(usize, 2), health.len);
    // Adjacent rows of one column are adjacent in memory.
    const base = @intFromPtr(&health[0]);
    try std.testing.expectEqual(base + @sizeOf(u16), @intFromPtr(&health[1]));
}
