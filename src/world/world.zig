//! The world database.
//!
//! Composes `entity.Allocator`, an archetype `Table`, and the change `journal` into the
//! thing systems actually run against. `ARCHITECTURE.md` §5.
//!
//! **Scope, stated so it is not mistaken for finished:** this is a single-archetype world.
//! §5 specifies archetype chunks plural, with entities migrating between archetypes as
//! components are added and removed. That migration is the part that makes a general ECS
//! hard and it is not here. What is here is the shape everything else depends on — entity
//! identity, chunk storage, the location map, and the journal — sized so the determinism
//! machinery can be built and verified against a real world rather than a mock.
//!
//! Every mutation goes through this type rather than through the table directly, because
//! the journal has to see it. A system reaching past `World` into `Table.set` produces a
//! change no projection knows about, which surfaces as a client that never receives an
//! update and is close to undiagnosable from the outside.

const std = @import("std");
const entity_mod = @import("entity.zig");
const table_mod = @import("table.zig");
const journal_mod = @import("journal.zig");
const chunk_mod = @import("chunk.zig");

pub const Entity = entity_mod.Entity;

pub fn World(comptime Columns: type, comptime budget: chunk_mod.Budget) type {
    const TableT = table_mod.Table(Columns, budget);
    const info = @typeInfo(Columns).@"struct";

    return struct {
        const Self = @This();

        pub const TableType = TableT;
        pub const ColumnSet = Columns;

        gpa: std.mem.Allocator,
        entities: entity_mod.Allocator,
        table: TableT,
        journal: journal_mod.Journal,
        tick: u64,

        /// Stable component ID per column, from the §3 registry rather than declaration
        /// order. Supplied by the caller so this type never derives identity from layout —
        /// §18.6.
        component_ids: [info.fields.len]journal_mod.ComponentId,

        pub fn init(
            gpa: std.mem.Allocator,
            journal_capacity: u32,
            component_ids: [info.fields.len]journal_mod.ComponentId,
        ) !Self {
            return .{
                .gpa = gpa,
                .entities = .empty,
                .table = TableT.init(gpa),
                .journal = try journal_mod.Journal.init(gpa, journal_capacity),
                .tick = 0,
                .component_ids = component_ids,
            };
        }

        pub fn deinit(self: *Self) void {
            self.entities.deinit(self.gpa);
            self.table.deinit();
            self.journal.deinit();
            self.* = undefined;
        }

        /// Size everything at session start so the frame loop never allocates (§18.8).
        pub fn reserve(self: *Self, entity_count: u32) !void {
            try self.table.reserve(entity_count);
            try self.entities.generations.ensureTotalCapacity(self.gpa, entity_count + 1);
            try self.entities.next_free.ensureTotalCapacity(self.gpa, entity_count + 1);
        }

        pub fn spawn(self: *Self, values: Columns) !Entity {
            const e = try self.entities.alloc(self.gpa);
            _ = try self.table.add(e, values);
            self.journal.recordSpawn(e);
            return e;
        }

        pub fn despawn(self: *Self, e: Entity) bool {
            if (!self.table.remove(e)) return false;
            self.entities.free(e);
            self.journal.recordDespawn(e);
            return true;
        }

        pub fn isLive(self: Self, e: Entity) bool {
            return self.entities.isLive(e) and self.table.contains(e);
        }

        pub fn get(self: Self, e: Entity, comptime name: []const u8) ?@FieldType(Columns, name) {
            return self.table.get(e, name);
        }

        /// Write a component and journal it. The only sanctioned mutation path.
        pub fn set(self: *Self, e: Entity, comptime name: []const u8, value: @FieldType(Columns, name)) bool {
            if (!self.table.set(e, name, value)) return false;
            self.journal.recordMutation(e, self.componentId(name));
            return true;
        }

        pub fn componentId(self: Self, comptime name: []const u8) journal_mod.ComponentId {
            const idx = comptime blk: {
                for (info.fields, 0..) |f, i| {
                    if (std.mem.eql(u8, f.name, name)) break :blk i;
                }
                @compileError("no column named '" ++ name ++ "'");
            };
            return self.component_ids[idx];
        }

        /// Bulk mutation over a chunk view, journalled per entity.
        ///
        /// Systems take chunk views (§5), so the per-entity journal entries are emitted
        /// here rather than making every system remember to. A system that mutates a
        /// column through `chunkIterator` directly is responsible for its own journalling,
        /// and that is a real hazard — see the module comment.
        pub fn mutateAll(
            self: *Self,
            comptime name: []const u8,
            context: anytype,
            comptime f: fn (@TypeOf(context), Entity, *@FieldType(Columns, name)) void,
        ) void {
            const id = self.componentId(name);
            var it = self.table.chunkIterator();
            while (it.next()) |c| {
                const values = c.column(name);
                const ents = c.liveEntities();
                for (values, ents) |*v, e| {
                    f(context, e, v);
                    self.journal.recordMutation(e, id);
                }
            }
        }

        pub fn advanceTick(self: *Self) void {
            self.journal.advance();
            self.tick += 1;
        }

        pub fn liveCount(self: Self) u32 {
            return self.table.len;
        }
    };
}

// ---------------------------------------------------------------------------

const Fixed = @import("fpz").Fixed;
const TestColumns = struct {
    health: u16,
    shield: u16,
};
const ids = [_]journal_mod.ComponentId{ 0x0055, 0x0056 };
const TestWorld = World(TestColumns, chunk_mod.Budget.desktop);

test "spawn, read, despawn" {
    var w = try TestWorld.init(std.testing.allocator, 256, ids);
    defer w.deinit();

    const e = try w.spawn(.{ .health = 100, .shield = 50 });
    try std.testing.expect(w.isLive(e));
    try std.testing.expectEqual(@as(u16, 100), w.get(e, "health").?);

    try std.testing.expect(w.despawn(e));
    try std.testing.expect(!w.isLive(e));
}

test "every mutation reaches the journal" {
    // The property the whole type exists to guarantee. A change no projection knows about
    // surfaces as a client that never receives an update, which is close to
    // undiagnosable from the outside.
    var w = try TestWorld.init(std.testing.allocator, 256, ids);
    defer w.deinit();

    const e = try w.spawn(.{ .health = 100, .shield = 0 });
    _ = w.set(e, "health", 90);

    const entries = w.journal.items();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(journal_mod.Kind.spawned, entries[0].kind);
    try std.testing.expectEqual(journal_mod.Kind.mutated, entries[1].kind);
    try std.testing.expectEqual(@as(u32, 0x0055), entries[1].component);
}

test "component IDs come from the registry, not declaration order" {
    // §18.6. If these were positional, inserting a column would silently renumber every
    // higher one and every recorded journal, save and replay would reinterpret.
    var w = try TestWorld.init(std.testing.allocator, 16, .{ 0xAAAA, 0xBBBB });
    defer w.deinit();
    try std.testing.expectEqual(@as(u32, 0xAAAA), w.componentId("health"));
    try std.testing.expectEqual(@as(u32, 0xBBBB), w.componentId("shield"));
}

test "a despawned entity's handle stops resolving" {
    var w = try TestWorld.init(std.testing.allocator, 256, ids);
    defer w.deinit();

    const first = try w.spawn(.{ .health = 1, .shield = 1 });
    _ = w.despawn(first);
    const second = try w.spawn(.{ .health = 2, .shield = 2 });

    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(!w.isLive(first));
    try std.testing.expect(w.get(first, "health") == null);
    try std.testing.expectEqual(@as(u16, 2), w.get(second, "health").?);
}

test "mutateAll journals every entity it touches" {
    var w = try TestWorld.init(std.testing.allocator, 256, ids);
    defer w.deinit();
    for (0..5) |_| _ = try w.spawn(.{ .health = 10, .shield = 0 });
    w.advanceTick();

    w.mutateAll("health", {}, struct {
        fn apply(_: void, _: Entity, v: *u16) void {
            v.* += 1;
        }
    }.apply);

    try std.testing.expectEqual(@as(usize, 5), w.journal.items().len);
    for (w.journal.items()) |entry| {
        try std.testing.expectEqual(journal_mod.Kind.mutated, entry.kind);
        try std.testing.expectEqual(@as(u32, 0x0055), entry.component);
    }
}

test "identical operation sequences produce identical worlds" {
    // §7, end to end across allocator, table and journal.
    const gpa = std.testing.allocator;
    var final: [2]u32 = undefined;
    var journals: [2][]journal_mod.Entry = undefined;

    for (0..2) |run| {
        var w = try TestWorld.init(gpa, 4096, ids);
        defer w.deinit();

        var handles: std.ArrayList(Entity) = .empty;
        defer handles.deinit(gpa);

        for (0..64) |i| {
            const e = try w.spawn(.{ .health = @intCast(i % 200), .shield = 0 });
            try handles.append(gpa, e);
            if (i % 5 == 4) _ = w.despawn(handles.items[i - 3]);
            if (i % 7 == 6) _ = w.set(handles.items[i - 1], "shield", @intCast(i));
        }
        final[run] = w.liveCount();
        journals[run] = try gpa.dupe(journal_mod.Entry, w.journal.items());
    }
    defer for (journals) |j| gpa.free(j);

    try std.testing.expectEqual(final[0], final[1]);
    try std.testing.expectEqualSlices(journal_mod.Entry, journals[0], journals[1]);
}

test "reserve keeps the frame loop allocation-free" {
    var w = try TestWorld.init(std.testing.allocator, 4096, ids);
    defer w.deinit();
    try w.reserve(1000);

    for (0..1000) |i| _ = try w.spawn(.{ .health = @intCast(i % 200), .shield = 0 });
    try std.testing.expectEqual(@as(u32, 0), w.table.chunks_allocated_since_reset);
}
