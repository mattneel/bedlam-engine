//! The replication projection: per-client baselines and delta encoding.
//!
//! `ARCHITECTURE.md` §5.1 is unusually specific about why this cannot be shared with the
//! others: "A replication baseline is **not** a physical world snapshot. After per-client
//! interest filtering, quantization, archetype migration, dormancy transitions, and
//! authority changes, a page XOR against in-memory state is meaningless. Delta is computed
//! against **that client's last-acked canonical baseline**, which means ack tracking,
//! interest set, and baseline live together per connection."
//!
//! So this is per-connection state, and it is the reason §18.7 forbids unifying the four
//! projections. Two clients watching the same entity have different baselines because they
//! acked different snapshots; neither baseline is the world.
//!
//! **Delta is computed against the acked baseline, not the previous send.** The difference
//! matters under loss, which `BENCHMARK_CONTRACT.md` §5 puts at up to 6% on
//! `mobile-degraded`. Diffing against the last *sent* snapshot produces a delta the client
//! cannot apply if that snapshot was dropped, and the error is silent — the client applies
//! it anyway and drifts. Diffing against the last *acked* one costs more bytes after a loss
//! and is always applicable.
//!
//! The byte budget this serves: §4.1 computes ~1,500 bytes per snapshot per client for
//! ~180 entity updates. That is why the mask exists and why whole-component encodes are
//! the exception.

const std = @import("std");
const wire = @import("bedlam_wire");
const world_mod = @import("bedlam_world");

pub const Entity = world_mod.entity.Entity;

/// One client's view. `ARCHITECTURE.md` §5.1: ack tracking, interest set and baseline
/// live together per connection, so they are one type.
pub fn Baseline(comptime Columns: type) type {
    const info = @typeInfo(Columns).@"struct";

    return struct {
        const Self = @This();

        pub const ColumnSet = Columns;
        pub const field_count = info.fields.len;

        pub const Record = struct {
            entity: Entity,
            values: Columns,
            /// Snapshot in which this record was last acknowledged. Not the tick it was
            /// sent — see the module comment.
            acked_at: u64,
        };

        gpa: std.mem.Allocator,
        /// Indexed by entity index, so lookup is O(1) and iteration order is entity order
        /// rather than hash order — §7 forbids the latter on this path.
        records: std.ArrayList(?Record),
        /// Entities this client is currently interested in. §9.4's interest filtering
        /// decides membership; this type only records the result.
        interest: std.ArrayList(bool),
        last_acked_snapshot: u64,
        pending_snapshot: u64,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
                .records = .empty,
                .interest = .empty,
                .last_acked_snapshot = 0,
                .pending_snapshot = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.records.deinit(self.gpa);
            self.interest.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn reserve(self: *Self, entities: u32) !void {
            try self.records.ensureTotalCapacity(self.gpa, entities);
            try self.interest.ensureTotalCapacity(self.gpa, entities);
            while (self.records.items.len < entities) {
                self.records.appendAssumeCapacity(null);
                self.interest.appendAssumeCapacity(false);
            }
        }

        fn ensureSlot(self: *Self, index: u32) !void {
            while (self.records.items.len <= index) {
                try self.records.append(self.gpa, null);
                try self.interest.append(self.gpa, false);
            }
        }

        pub fn setInterest(self: *Self, e: Entity, interested: bool) !void {
            try self.ensureSlot(e.index);
            self.interest.items[e.index] = interested;
        }

        pub fn isInterested(self: Self, e: Entity) bool {
            if (e.index >= self.interest.items.len) return false;
            return self.interest.items[e.index];
        }

        pub fn record(self: Self, e: Entity) ?Record {
            if (e.index >= self.records.items.len) return null;
            const r = self.records.items[e.index] orelse return null;
            // A recycled index must not match the previous occupant's baseline: the new
            // entity would inherit a delta base describing a different object.
            if (!Entity.eql(r.entity, e)) return null;
            return r;
        }

        /// Which fields differ from this client's acked baseline.
        ///
        /// Returns a full mask for an entity with no baseline — a client that has never
        /// seen it needs every field, and treating "absent" as "unchanged" would send an
        /// empty delta the client cannot apply to anything.
        pub fn changedMask(self: Self, e: Entity, current: Columns) u32 {
            const base = self.record(e) orelse return (@as(u32, 1) << field_count) - 1;

            var mask: u32 = 0;
            inline for (info.fields, 0..) |f, i| {
                if (!valuesEqual(f.type, @field(current, f.name), @field(base.values, f.name))) {
                    mask |= @as(u32, 1) << @intCast(i);
                }
            }
            return mask;
        }

        /// Stage a send. The baseline is NOT updated — that happens on ack.
        pub fn stage(self: *Self, snapshot: u64) void {
            self.pending_snapshot = snapshot;
        }

        /// Acknowledge a snapshot, promoting its values to the baseline. Returns whether
        /// it was applied.
        ///
        /// Out-of-order and duplicate acks are ordinary on an unreliable channel (§9.1
        /// puts snapshots on `unreliable_unordered`), so an older or repeated ack is
        /// ignored rather than rolling the baseline backwards.
        ///
        /// **An ack covers a whole snapshot, not one entity.** Calling this once per
        /// entity with the same snapshot number applies the first and silently ignores
        /// the rest, which presents as entities that are re-sent forever. The bool return
        /// exists so that mistake is detectable instead of invisible.
        pub fn acknowledge(self: *Self, snapshot: u64, entries: []const Record) !bool {
            if (snapshot <= self.last_acked_snapshot) return false;
            for (entries) |r| {
                try self.ensureSlot(r.entity.index);
                self.records.items[r.entity.index] = .{
                    .entity = r.entity,
                    .values = r.values,
                    .acked_at = snapshot,
                };
            }
            self.last_acked_snapshot = snapshot;
            return true;
        }

        /// Drop an entity from this client's view — despawn, or leaving the interest set.
        pub fn forget(self: *Self, e: Entity) void {
            if (e.index >= self.records.items.len) return;
            self.records.items[e.index] = null;
            self.interest.items[e.index] = false;
        }
    };
}

fn valuesEqual(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => a == b,
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (!valuesEqual(f.type, @field(a, f.name), @field(b, f.name))) break :blk false;
            }
            break :blk true;
        },
        .array => |arr| blk: {
            for (a, b) |x, y| {
                if (!valuesEqual(arr.child, x, y)) break :blk false;
            }
            break :blk true;
        },
        .float => @compileError("baseline: " ++ @typeName(T) ++
            " is a float. Equality on floats makes the delta decision architecture-dependent, " ++
            "which is ARCHITECTURE.md §7's whole objection. Use a fixed-point semantic type."),
        else => @compileError("baseline: uncomparable type " ++ @typeName(T)),
    };
}

// ---------------------------------------------------------------------------

const Fixed = @import("fpz").Fixed;

const TestColumns = struct {
    health: u16,
    position: [3]Fixed,
};
const TestBaseline = Baseline(TestColumns);

fn mk(i: u24) Entity {
    return .{ .index = i, .generation = 1 };
}

fn sample(h: u16) TestColumns {
    return .{ .health = h, .position = .{ Fixed.fromInt(h), Fixed.ZERO, Fixed.ZERO } };
}

test "an entity with no baseline needs every field" {
    // Treating "absent" as "unchanged" would send an empty delta the client cannot apply
    // to anything.
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectEqual(@as(u32, 0b11), b.changedMask(mk(1), sample(10)));
}

test "an unchanged entity needs nothing" {
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();

    _ = try b.acknowledge(1, &.{.{ .entity = mk(1), .values = sample(10), .acked_at = 1 }});
    try std.testing.expectEqual(@as(u32, 0), b.changedMask(mk(1), sample(10)));
}

test "only changed fields are marked" {
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();
    _ = try b.acknowledge(1, &.{.{ .entity = mk(1), .values = sample(10), .acked_at = 1 }});

    var changed = sample(10);
    changed.health = 11;
    try std.testing.expectEqual(@as(u32, 0b01), b.changedMask(mk(1), changed));

    var moved = sample(10);
    moved.position[1] = Fixed.fromInt(5);
    try std.testing.expectEqual(@as(u32, 0b10), b.changedMask(mk(1), moved));
}

test "the baseline advances on ack, not on send" {
    // The property that makes this correct under loss. §5 puts loss at up to 6% on
    // mobile-degraded; a delta against the last SENT snapshot is inapplicable if that
    // snapshot was dropped, and the client applies it anyway and drifts.
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();

    _ = try b.acknowledge(1, &.{.{ .entity = mk(1), .values = sample(10), .acked_at = 1 }});
    b.stage(2); // sent, not acked — imagine it is dropped
    b.stage(3);

    // Still diffing against snapshot 1's values.
    try std.testing.expectEqual(@as(u32, 0), b.changedMask(mk(1), sample(10)));
    try std.testing.expectEqual(@as(u64, 1), b.last_acked_snapshot);
}

test "a repeated snapshot number is reported, not silently ignored" {
    // Calling acknowledge once per entity with the same snapshot applies the first and
    // drops the rest, which presents as entities re-sent forever. The bool makes it
    // visible at the call site.
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();

    try std.testing.expect(try b.acknowledge(1, &.{.{ .entity = mk(1), .values = sample(10), .acked_at = 1 }}));
    try std.testing.expect(!try b.acknowledge(1, &.{.{ .entity = mk(2), .values = sample(20), .acked_at = 1 }}));
    // Entity 2 has no baseline, exactly as the return value said.
    try std.testing.expectEqual(@as(u32, 0b11), b.changedMask(mk(2), sample(20)));
}

test "an out-of-order ack does not roll the baseline backwards" {
    // §9.1 puts snapshots on unreliable_unordered, so a late ack for an older snapshot is
    // ordinary rather than exceptional.
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();

    _ = try b.acknowledge(5, &.{.{ .entity = mk(1), .values = sample(50), .acked_at = 5 }});
    _ = try b.acknowledge(3, &.{.{ .entity = mk(1), .values = sample(30), .acked_at = 3 }});

    try std.testing.expectEqual(@as(u64, 5), b.last_acked_snapshot);
    try std.testing.expectEqual(@as(u32, 0), b.changedMask(mk(1), sample(50)));
}

test "a recycled entity index does not inherit the previous occupant's baseline" {
    // Otherwise the new entity's first delta is computed against a description of a
    // different object, and the client renders the difference between two unrelated
    // things.
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();

    const first: Entity = .{ .index = 4, .generation = 1 };
    const recycled: Entity = .{ .index = 4, .generation = 2 };

    _ = try b.acknowledge(1, &.{.{ .entity = first, .values = sample(10), .acked_at = 1 }});
    try std.testing.expectEqual(@as(u32, 0b11), b.changedMask(recycled, sample(10)));
}

test "two clients hold different baselines for the same entity" {
    // The reason this is per-connection state and §18.7 forbids unifying the projections.
    // Neither baseline is the world.
    const gpa = std.testing.allocator;
    var a = TestBaseline.init(gpa);
    defer a.deinit();
    var c = TestBaseline.init(gpa);
    defer c.deinit();

    _ = try a.acknowledge(1, &.{.{ .entity = mk(1), .values = sample(10), .acked_at = 1 }});
    _ = try c.acknowledge(1, &.{.{ .entity = mk(1), .values = sample(10), .acked_at = 1 }});
    _ = try a.acknowledge(2, &.{.{ .entity = mk(1), .values = sample(20), .acked_at = 2 }});

    const now = sample(20);
    try std.testing.expectEqual(@as(u32, 0), a.changedMask(mk(1), now));
    try std.testing.expect(c.changedMask(mk(1), now) != 0);
}

test "interest is tracked per client" {
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();

    try std.testing.expect(!b.isInterested(mk(1)));
    try b.setInterest(mk(1), true);
    try std.testing.expect(b.isInterested(mk(1)));
    try b.setInterest(mk(1), false);
    try std.testing.expect(!b.isInterested(mk(1)));
}

test "forget clears both the baseline and the interest bit" {
    var b = TestBaseline.init(std.testing.allocator);
    defer b.deinit();
    try b.setInterest(mk(1), true);
    _ = try b.acknowledge(1, &.{.{ .entity = mk(1), .values = sample(10), .acked_at = 1 }});

    b.forget(mk(1));
    try std.testing.expect(!b.isInterested(mk(1)));
    // And a re-entering entity needs a full send, not a delta against stale values.
    try std.testing.expectEqual(@as(u32, 0b11), b.changedMask(mk(1), sample(10)));
}

test "a masked delta is smaller than a full send" {
    // §4.1's arithmetic: ~1,500 bytes per snapshot for ~180 updates. If the mask did not
    // pay for itself the budget would not close.
    const decl = @import("bedlam_schema").schema.components[0]; // Transform
    var buf: [64]u8 = undefined;

    var full = wire.bits.Writer.init(&buf);
    try wire.codec.encode(decl, zeroed(decl), &full);

    var partial = wire.bits.Writer.init(&buf);
    try wire.codec.encodeMasked(decl, zeroed(decl), 0b001, &partial);

    try std.testing.expect(partial.bitsWritten() < full.bitsWritten());
}

fn zeroed(comptime c: @TypeOf(@import("bedlam_schema").schema.components[0])) wire.codec.Storage(c) {
    var v: wire.codec.Storage(c) = undefined;
    inline for (c.fields) |f| {
        @field(v, f.name) = switch (f.sem) {
            .bool => false,
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .string_id => 0,
            .f32, .f64 => 0.0,
            .fixed => Fixed.ZERO,
            .fixed_vec3 => [3]Fixed{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
            .fixed_quat => [4]Fixed{ Fixed.ONE, Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
            .entity_handle => wire.codec.EntityHandle{ .index = 0, .generation = 0 },
            .blob => unreachable,
        };
    }
    return v;
}
