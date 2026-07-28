//! Dynamic archetype storage: runtime-described columns, comptime-typed views.
//!
//! `ARCHITECTURE.md` §5 wants two things that pull in opposite directions. Archetypes are
//! dynamic — an entity's component set changes at runtime, so the set of tables cannot be
//! known at compile time. But "systems query chunk views", and a view is only worth having
//! if it is a typed slice: a system reading `[]Fixed` compiles to a loop over contiguous
//! memory, and one reading `[]u8` plus a cast does not.
//!
//! The resolution is to describe columns at runtime and *type* them at the boundary.
//! Storage is byte-addressed and keyed by stable component ID; `columnTyped` hands back a
//! real slice. The unsafe step happens once, at a checked boundary, instead of everywhere.
//!
//! **Element size and alignment come from the type, identity from the registry.** §18.6
//! forbids identity derived from layout — so a `Descriptor` carries the ID *and* the
//! layout, and the two never trade places. Two builds with different physical layouts
//! agree on which column is which, which is §0 P1's whole point.
//!
//! Migration is the operation this file exists for, and it is expensive by construction:
//! adding a component copies every shared column to a new chunk. §5 accepts that cost.
//! `stats` makes it visible rather than merely slow.

const std = @import("std");
const entity_mod = @import("entity.zig");
const archetype = @import("archetype.zig");
const storable = @import("bedlam_schema").storable;

pub const Entity = entity_mod.Entity;
pub const ComponentId = archetype.ComponentId;
pub const Signature = archetype.Signature;

/// A component's runtime layout, paired with its stable identity.
pub const Descriptor = struct {
    id: ComponentId,
    size: u32,
    alignment: u8,

    /// Build from a Zig type. The type decides layout; the caller supplies identity from
    /// the registry, because deriving an ID from a type is exactly what §18.6 forbids.
    pub fn of(comptime T: type, id: ComponentId) Descriptor {
        comptime storable.assertStorable(T, "dynamic component");
        comptime storable.assertFixedWidth(T, "dynamic component");
        return .{
            .id = id,
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
        };
    }
};

/// One archetype's storage: a signature plus one byte-array column per component.
pub const Table = struct {
    gpa: std.mem.Allocator,
    signature: Signature,
    descriptors: []Descriptor,
    /// Column bytes, parallel to `descriptors`. Each is `capacity * size` long.
    columns: [][]u8,
    entities: std.ArrayList(Entity),
    capacity: usize,

    pub fn init(gpa: std.mem.Allocator, descs: []const Descriptor) !Table {
        var sig: Signature = .{};
        for (descs) |d| _ = sig.insert(d.id);

        // Descriptors stored in signature order, so column index is a function of the ID
        // set rather than of the order the caller happened to list them. Two tables built
        // from the same components in different orders must lay out identically, or a
        // migration between them copies the wrong columns.
        const owned = try gpa.alloc(Descriptor, descs.len);
        errdefer gpa.free(owned);
        for (sig.slice(), 0..) |id, i| {
            owned[i] = for (descs) |d| {
                if (d.id == id) break d;
            } else unreachable;
        }

        const cols = try gpa.alloc([]u8, owned.len);
        errdefer gpa.free(cols);
        for (cols) |*c| c.* = &.{};

        return .{
            .gpa = gpa,
            .signature = sig,
            .descriptors = owned,
            .columns = cols,
            .entities = .empty,
            .capacity = 0,
        };
    }

    pub fn deinit(self: *Table) void {
        for (self.columns) |c| {
            if (c.len > 0) self.gpa.free(c);
        }
        self.gpa.free(self.columns);
        self.gpa.free(self.descriptors);
        self.entities.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn len(self: Table) usize {
        return self.entities.items.len;
    }

    fn columnIndex(self: Table, id: ComponentId) ?usize {
        for (self.descriptors, 0..) |d, i| {
            if (d.id == id) return i;
        }
        return null;
    }

    fn grow(self: *Table, needed: usize) !void {
        if (needed <= self.capacity) return;
        const new_cap = @max(8, @max(needed, self.capacity * 2));

        for (self.columns, self.descriptors) |*col, d| {
            const bytes = new_cap * d.size;
            const fresh = try self.gpa.alloc(u8, bytes);
            // Zero the whole allocation, not just the tail past `len`.
            //
            // Same argument as chunk.zig: the rollback projection copies pages, so
            // uninitialized bytes anywhere in a column ride into a snapshot and make two
            // hosts with identical logical worlds hash differently.
            @memset(fresh, 0);
            if (col.len > 0) {
                @memcpy(fresh[0 .. self.len() * d.size], col.*[0 .. self.len() * d.size]);
                self.gpa.free(col.*);
            }
            col.* = fresh;
        }
        try self.entities.ensureTotalCapacity(self.gpa, new_cap);
        self.capacity = new_cap;
    }

    /// Append a row with all components zeroed. The caller writes values through
    /// `columnTyped`.
    pub fn push(self: *Table, e: Entity) !usize {
        try self.grow(self.len() + 1);
        const row = self.len();
        self.entities.appendAssumeCapacity(e);
        for (self.columns, self.descriptors) |col, d| {
            @memset(col[row * d.size ..][0..d.size], 0);
        }
        return row;
    }

    /// Swap-remove. Returns the entity that moved into `row`, if any.
    pub fn swapRemove(self: *Table, row: usize) ?Entity {
        std.debug.assert(row < self.len());
        const last = self.len() - 1;
        var moved: ?Entity = null;

        if (row != last) {
            for (self.columns, self.descriptors) |col, d| {
                @memcpy(col[row * d.size ..][0..d.size], col[last * d.size ..][0..d.size]);
            }
            self.entities.items[row] = self.entities.items[last];
            moved = self.entities.items[row];
        }

        // Canonical dead tail, for the reason in `grow`.
        for (self.columns, self.descriptors) |col, d| {
            @memset(col[last * d.size ..][0..d.size], 0);
        }
        _ = self.entities.pop();
        return moved;
    }

    /// A typed view of one column's live rows.
    ///
    /// The single unsafe step, at a checked boundary: size and alignment are verified
    /// against the descriptor before the cast, so a caller asking for the wrong type gets
    /// null rather than a reinterpretation.
    pub fn columnTyped(self: *Table, comptime T: type, id: ComponentId) ?[]T {
        const i = self.columnIndex(id) orelse return null;
        const d = self.descriptors[i];
        if (d.size != @sizeOf(T) or d.alignment != @alignOf(T)) return null;
        if (self.len() == 0) return &.{};
        const ptr: [*]T = @ptrCast(@alignCast(self.columns[i].ptr));
        return ptr[0..self.len()];
    }

    pub fn rawColumn(self: *Table, id: ComponentId) ?[]u8 {
        const i = self.columnIndex(id) orelse return null;
        return self.columns[i][0 .. self.len() * self.descriptors[i].size];
    }

    pub fn liveEntities(self: *const Table) []const Entity {
        return self.entities.items;
    }

    /// Copy one row's shared components into another table. Used by migration.
    ///
    /// Only columns present in BOTH tables move; a component being added is left zeroed
    /// and one being removed is simply not copied. Doing this by ID rather than by index
    /// is what makes it correct when the two signatures differ.
    pub fn copySharedRow(self: *Table, src_row: usize, dst: *Table, dst_row: usize) u32 {
        var copied: u32 = 0;
        for (self.descriptors, 0..) |d, i| {
            const j = dst.columnIndex(d.id) orelse continue;
            std.debug.assert(dst.descriptors[j].size == d.size);
            @memcpy(
                dst.columns[j][dst_row * d.size ..][0..d.size],
                self.columns[i][src_row * d.size ..][0..d.size],
            );
            copied += 1;
        }
        return copied;
    }
};

/// Where an entity lives.
pub const Location = struct {
    table: u32,
    row: u32,

    pub const none: Location = .{ .table = std.math.maxInt(u32), .row = 0 };
    pub fn isNone(self: Location) bool {
        return self.table == std.math.maxInt(u32);
    }
};

/// A world of many archetypes.
pub const Store = struct {
    gpa: std.mem.Allocator,
    tables: std.ArrayList(Table),
    locations: std.ArrayList(Location),
    stats: archetype.MigrationStats = .{},

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa, .tables = .empty, .locations = .empty };
    }

    pub fn deinit(self: *Store) void {
        for (self.tables.items) |*t| t.deinit();
        self.tables.deinit(self.gpa);
        self.locations.deinit(self.gpa);
        self.* = undefined;
    }

    /// Find or create the table for a component set.
    ///
    /// Looked up by SIGNATURE, so an archetype reached by two different migration paths
    /// is one table rather than two — otherwise a query has to visit both, and the world
    /// fragments by history.
    pub fn tableFor(self: *Store, descs: []const Descriptor) !u32 {
        var sig: Signature = .{};
        for (descs) |d| _ = sig.insert(d.id);

        for (self.tables.items, 0..) |t, i| {
            if (t.signature.eql(sig)) return @intCast(i);
        }
        try self.tables.append(self.gpa, try Table.init(self.gpa, descs));
        return @intCast(self.tables.items.len - 1);
    }

    fn ensureLocation(self: *Store, index: u32) !void {
        while (self.locations.items.len <= index) {
            try self.locations.append(self.gpa, Location.none);
        }
    }

    pub fn spawn(self: *Store, e: Entity, descs: []const Descriptor) !Location {
        const ti = try self.tableFor(descs);
        try self.ensureLocation(e.index);
        const row = try self.tables.items[ti].push(e);
        const loc: Location = .{ .table = ti, .row = @intCast(row) };
        self.locations.items[e.index] = loc;
        return loc;
    }

    pub fn locate(self: Store, e: Entity) ?Location {
        if (e.index >= self.locations.items.len) return null;
        const loc = self.locations.items[e.index];
        if (loc.isNone()) return null;
        const t = self.tables.items[loc.table];
        // Generation check: a recycled index must not resolve to the previous occupant.
        if (!Entity.eql(t.entities.items[loc.row], e)) return null;
        return loc;
    }

    pub fn despawn(self: *Store, e: Entity) bool {
        const loc = self.locate(e) orelse return false;
        if (self.tables.items[loc.table].swapRemove(loc.row)) |moved| {
            self.locations.items[moved.index] = loc;
        }
        self.locations.items[e.index] = Location.none;
        return true;
    }

    /// Move an entity to the archetype described by `descs`.
    ///
    /// The expensive operation, and deliberately not hidden: it allocates a row in the
    /// destination, copies every shared column, and swap-removes from the source — which
    /// also relocates whichever entity was last, so the location map is fixed here rather
    /// than by the caller.
    pub fn migrate(self: *Store, e: Entity, descs: []const Descriptor) !bool {
        const from = self.locate(e) orelse return false;
        const to_table = try self.tableFor(descs);
        if (to_table == from.table) return true;

        const dst_row = try self.tables.items[to_table].push(e);
        const copied = self.tables.items[from.table].copySharedRow(
            from.row,
            &self.tables.items[to_table],
            dst_row,
        );

        if (self.tables.items[from.table].swapRemove(from.row)) |moved| {
            self.locations.items[moved.index] = from;
        }
        self.locations.items[e.index] = .{ .table = to_table, .row = @intCast(dst_row) };

        self.stats.migrations += 1;
        self.stats.components_copied += copied;
        return true;
    }

    /// Tables whose signature contains every id in `query`.
    pub fn matching(self: *Store, query: Signature, out: []u32) []u32 {
        var n: usize = 0;
        for (self.tables.items, 0..) |t, i| {
            if (n >= out.len) break;
            if (t.signature.supersetOf(query) and t.len() > 0) {
                out[n] = @intCast(i);
                n += 1;
            }
        }
        return out[0..n];
    }
};

// ---------------------------------------------------------------------------

const Fixed = @import("fpz").Fixed;

const POS: ComponentId = 0x0041;
const HEALTH: ComponentId = 0x0055;
const AMMO: ComponentId = 0x0061;

fn allThree() [3]Descriptor {
    return .{
        Descriptor.of([3]Fixed, POS),
        Descriptor.of(u16, HEALTH),
        Descriptor.of(u32, AMMO),
    };
}

fn mk(i: u24) Entity {
    return .{ .index = i, .generation = 1 };
}

test "a descriptor pairs identity with layout without deriving one from the other" {
    const d = Descriptor.of(u32, HEALTH);
    try std.testing.expectEqual(HEALTH, d.id);
    try std.testing.expectEqual(@as(u32, 4), d.size);
}

test "column order follows the signature, not the caller's argument order" {
    // Two tables built from the same components listed differently must lay out
    // identically, or a migration between them copies the wrong columns.
    const gpa = std.testing.allocator;
    const a = [_]Descriptor{ Descriptor.of(u16, HEALTH), Descriptor.of([3]Fixed, POS) };
    const b = [_]Descriptor{ Descriptor.of([3]Fixed, POS), Descriptor.of(u16, HEALTH) };

    var ta = try Table.init(gpa, &a);
    defer ta.deinit();
    var tb = try Table.init(gpa, &b);
    defer tb.deinit();

    try std.testing.expect(ta.signature.eql(tb.signature));
    for (ta.descriptors, tb.descriptors) |x, y| try std.testing.expectEqual(x.id, y.id);
}

test "typed views are real slices" {
    const gpa = std.testing.allocator;
    const d = allThree();
    var t = try Table.init(gpa, &d);
    defer t.deinit();

    _ = try t.push(mk(1));
    _ = try t.push(mk(2));

    const health = t.columnTyped(u16, HEALTH).?;
    try std.testing.expectEqual(@as(usize, 2), health.len);
    health[0] = 100;
    health[1] = 50;
    try std.testing.expectEqual(@as(u16, 100), t.columnTyped(u16, HEALTH).?[0]);

    // Contiguous, which is the point of typing the view rather than casting per access.
    const base = @intFromPtr(&health[0]);
    try std.testing.expectEqual(base + @sizeOf(u16), @intFromPtr(&health[1]));
}

test "asking for the wrong type yields null rather than a reinterpretation" {
    // The one unsafe step is at a checked boundary. Without the check, a mismatched cast
    // reads adjacent components as the requested type and looks like corrupted data.
    const gpa = std.testing.allocator;
    const d = allThree();
    var t = try Table.init(gpa, &d);
    defer t.deinit();
    _ = try t.push(mk(1));

    try std.testing.expect(t.columnTyped(u16, HEALTH) != null);
    try std.testing.expect(t.columnTyped(u64, HEALTH) == null);
    try std.testing.expect(t.columnTyped(u16, 0x9999) == null);
}

test "migration copies shared columns and zeroes the new one" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();

    const two = [_]Descriptor{ Descriptor.of([3]Fixed, POS), Descriptor.of(u16, HEALTH) };
    const three = allThree();

    const e = mk(1);
    _ = try s.spawn(e, &two);

    const loc = s.locate(e).?;
    s.tables.items[loc.table].columnTyped(u16, HEALTH).?[loc.row] = 77;

    try std.testing.expect(try s.migrate(e, &three));

    const after = s.locate(e).?;
    try std.testing.expect(after.table != loc.table);
    // Shared column survived.
    try std.testing.expectEqual(@as(u16, 77), s.tables.items[after.table].columnTyped(u16, HEALTH).?[after.row]);
    // Added column is zeroed, not garbage.
    try std.testing.expectEqual(@as(u32, 0), s.tables.items[after.table].columnTyped(u32, AMMO).?[after.row]);
    try std.testing.expectEqual(@as(u64, 1), s.stats.migrations);
}

test "migration relocates the entity that swap-remove moved" {
    // The source table swap-removes, so another entity changes row. Missing that leaves
    // it reading someone else's components — the same defect the typed Table had.
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();

    const two = [_]Descriptor{ Descriptor.of([3]Fixed, POS), Descriptor.of(u16, HEALTH) };
    const three = allThree();

    const a = mk(1);
    const b = mk(2);
    _ = try s.spawn(a, &two);
    _ = try s.spawn(b, &two);

    const bl = s.locate(b).?;
    s.tables.items[bl.table].columnTyped(u16, HEALTH).?[bl.row] = 42;

    try std.testing.expect(try s.migrate(a, &three));

    const b_after = s.locate(b).?;
    try std.testing.expectEqual(@as(u16, 42), s.tables.items[b_after.table].columnTyped(u16, HEALTH).?[b_after.row]);
}

test "an archetype reached by two paths is one table" {
    // Looked up by signature, not created per call. Otherwise a query must visit both and
    // the world fragments by migration history rather than by content.
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();

    const pos_health = [_]Descriptor{ Descriptor.of([3]Fixed, POS), Descriptor.of(u16, HEALTH) };
    const health_pos = [_]Descriptor{ Descriptor.of(u16, HEALTH), Descriptor.of([3]Fixed, POS) };

    const t1 = try s.tableFor(&pos_health);
    const t2 = try s.tableFor(&health_pos);
    try std.testing.expectEqual(t1, t2);
    try std.testing.expectEqual(@as(usize, 1), s.tables.items.len);
}

test "queries match by superset" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();

    const two = [_]Descriptor{ Descriptor.of([3]Fixed, POS), Descriptor.of(u16, HEALTH) };
    const three = allThree();
    _ = try s.spawn(mk(1), &two);
    _ = try s.spawn(mk(2), &three);

    var buf: [8]u32 = undefined;
    // Everything with a position: both tables.
    try std.testing.expectEqual(@as(usize, 2), s.matching(Signature.fromSlice(&.{POS}), &buf).len);
    // Everything with ammo: only the three-component one.
    try std.testing.expectEqual(@as(usize, 1), s.matching(Signature.fromSlice(&.{AMMO}), &buf).len);
    // Nothing has this.
    try std.testing.expectEqual(@as(usize, 0), s.matching(Signature.fromSlice(&.{0x9999}), &buf).len);
}

test "a recycled entity index does not resolve to the previous occupant" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    const d = allThree();

    const first: Entity = .{ .index = 3, .generation = 1 };
    const recycled: Entity = .{ .index = 3, .generation = 2 };

    _ = try s.spawn(first, &d);
    try std.testing.expect(s.despawn(first));
    _ = try s.spawn(recycled, &d);

    try std.testing.expect(s.locate(first) == null);
    try std.testing.expect(s.locate(recycled) != null);
}

test "growth preserves data and zeroes the new capacity" {
    const gpa = std.testing.allocator;
    const d = allThree();
    var t = try Table.init(gpa, &d);
    defer t.deinit();

    for (0..64) |i| {
        const row = try t.push(mk(@intCast(i + 1)));
        t.columnTyped(u16, HEALTH).?[row] = @intCast(i);
    }
    for (0..64) |i| {
        try std.testing.expectEqual(@as(u16, @intCast(i)), t.columnTyped(u16, HEALTH).?[i]);
    }
}

test "add-then-remove leaves a canonical tail" {
    // The rollback projection copies pages, so a stale value beyond `len` rides into a
    // snapshot and makes two hosts with identical worlds hash differently.
    const gpa = std.testing.allocator;
    const d = allThree();
    var t = try Table.init(gpa, &d);
    defer t.deinit();

    const row = try t.push(mk(1));
    t.columnTyped(u16, HEALTH).?[row] = 0xBEEF;
    _ = t.swapRemove(row);

    try std.testing.expectEqual(@as(usize, 0), t.len());
    // Read past the live prefix, which is where a snapshot would look.
    const raw = t.columns[t.columnIndex(HEALTH).?];
    try std.testing.expectEqual(@as(u8, 0), raw[0]);
    try std.testing.expectEqual(@as(u8, 0), raw[1]);
}

test "migration is counted, because it cannot be made cheap" {
    const gpa = std.testing.allocator;
    var s = Store.init(gpa);
    defer s.deinit();

    const two = [_]Descriptor{ Descriptor.of([3]Fixed, POS), Descriptor.of(u16, HEALTH) };
    const three = allThree();

    for (0..10) |i| _ = try s.spawn(mk(@intCast(i + 1)), &two);
    for (0..10) |i| _ = try s.migrate(mk(@intCast(i + 1)), &three);

    try std.testing.expectEqual(@as(u64, 10), s.stats.migrations);
    // Two shared columns each time.
    try std.testing.expectEqual(@as(u64, 20), s.stats.components_copied);
}
