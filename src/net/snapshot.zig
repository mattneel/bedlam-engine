//! Snapshot assembly under a byte budget.
//!
//! `BENCHMARK_CONTRACT.md` §4.1: 384 kbps sustained at 32 Hz is **1,500 bytes per snapshot
//! per client**, against a 512-entity relevant set — roughly 180 entity updates at a
//! realistic 8-byte quantized delta. That number is the design constraint, not an outcome:
//! most of the relevant set does not fit in any given snapshot, so something has to decide
//! who gets bytes.
//!
//! That decision is the priority accumulator (`ARCHITECTURE.md` §9.4). Each entity
//! accumulates priority every snapshot it is *not* sent; sending resets it. The result is
//! that a starved entity's priority rises without bound until it wins, so nothing is
//! starved forever even when the budget is permanently oversubscribed — which at 512
//! relevant entities and ~180 slots is the normal condition rather than an overload.
//!
//! **The budget is enforced, not advised.** §4 says exceeding the hard ceiling at any
//! point fails a run, so assembly stops at the limit and reports what it dropped rather
//! than overshooting and letting the transport fragment.

const std = @import("std");
const wire = @import("bedlam_wire");
const world_mod = @import("bedlam_world");
const baseline_mod = @import("baseline.zig");

pub const Entity = world_mod.entity.Entity;

pub const Stats = struct {
    /// Entities written into this snapshot.
    sent: u32,
    /// Relevant entities that did not fit. Not an error — it is the steady state.
    deferred: u32,
    bytes: usize,
    /// Highest priority left unsent. Rising over time means the budget is too small for
    /// the relevant set, which is a content or interest-filter problem rather than a
    /// codec one.
    max_deferred_priority: u32,
};

/// Per-entity send bookkeeping. Lives beside the world, never in a chunk — §18.5.
pub fn Scheduler(comptime Columns: type) type {
    return struct {
        const Self = @This();
        pub const BaselineType = baseline_mod.Baseline(Columns);

        gpa: std.mem.Allocator,
        /// Accumulated priority per entity index.
        priority: std.ArrayList(u32),
        /// Scratch, reused every snapshot so assembly does not allocate (§18.8).
        candidates: std.ArrayList(Candidate),

        pub const Candidate = struct {
            entity: Entity,
            priority: u32,
            mask: u32,
        };

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa, .priority = .empty, .candidates = .empty };
        }

        pub fn deinit(self: *Self) void {
            self.priority.deinit(self.gpa);
            self.candidates.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn reserve(self: *Self, entities: u32) !void {
            try self.priority.ensureTotalCapacity(self.gpa, entities);
            try self.candidates.ensureTotalCapacity(self.gpa, entities);
            while (self.priority.items.len < entities) self.priority.appendAssumeCapacity(0);
        }

        fn ensureSlot(self: *Self, index: u32) !void {
            while (self.priority.items.len <= index) try self.priority.append(self.gpa, 0);
        }

        pub fn priorityOf(self: Self, e: Entity) u32 {
            if (e.index >= self.priority.items.len) return 0;
            return self.priority.items[e.index];
        }

        /// Assemble one snapshot for one client.
        ///
        /// `weight` is the per-entity priority increment — §9.4's per-field priority
        /// weights fold into it. Returns what was written and what was held back.
        pub fn assemble(
            self: *Self,
            comptime decl: anytype,
            w: anytype,
            base: *BaselineType,
            writer: *wire.bits.Writer,
            budget_bytes: u64,
            weight: u32,
        ) !Stats {
            self.candidates.clearRetainingCapacity();

            // Gather everything relevant and changed, accumulating priority as we go.
            var it = w.table.chunkIterator();
            while (it.next()) |c| {
                for (c.liveEntities()) |e| {
                    if (!base.isInterested(e)) continue;
                    try self.ensureSlot(e.index);

                    const current = componentOf(Columns, w, e);
                    const mask = base.changedMask(e, current);
                    if (mask == 0) continue;

                    self.priority.items[e.index] +|= weight;
                    try self.candidates.append(self.gpa, .{
                        .entity = e,
                        .priority = self.priority.items[e.index],
                        .mask = mask,
                    });
                }
            }

            // Highest priority first; ties broken by entity index so two peers assembling
            // the same state produce the same packet. A comparison that fell back on
            // storage order would make snapshots differ between hosts after a migration.
            std.mem.sort(Candidate, self.candidates.items, {}, struct {
                fn less(_: void, a: Candidate, b: Candidate) bool {
                    if (a.priority != b.priority) return a.priority > b.priority;
                    return a.entity.index < b.entity.index;
                }
            }.less);

            const mask_bits: u64 = comptime @typeInfo(Columns).@"struct".fields.len;
            var stats: Stats = .{ .sent = 0, .deferred = 0, .bytes = 0, .max_deferred_priority = 0 };

            for (self.candidates.items) |cand| {
                // u64 throughout: bit offsets are u64 on every target (bits.zig widened
                // them for wasm32), and mixing them with usize does not coerce where
                // usize is 32 bits. The cross gate caught this on arm and mips.
                const cost_bits: u64 = mask_bits + maskedBits(decl, cand.mask);
                const would_be: u64 = (writer.bitsWritten() + cost_bits + 7) / 8;
                if (would_be > budget_bytes) {
                    // Deferred, not dropped: priority is retained and rises next snapshot.
                    stats.deferred += 1;
                    stats.max_deferred_priority = @max(stats.max_deferred_priority, cand.priority);
                    continue;
                }

                const values = componentOf(Columns, w, cand.entity);
                try wire.codec.encodeMasked(decl, values, cand.mask, writer);
                self.priority.items[cand.entity.index] = 0;
                stats.sent += 1;
            }

            stats.bytes = @intCast((writer.bitsWritten() + 7) / 8);
            return stats;
        }
    };
}

fn componentOf(comptime Columns: type, w: anytype, e: Entity) Columns {
    var out: Columns = undefined;
    inline for (@typeInfo(Columns).@"struct".fields) |f| {
        @field(out, f.name) = w.table.get(e, f.name).?;
    }
    return out;
}

/// Bits a masked update occupies, excluding the mask itself.
fn maskedBits(comptime decl: anytype, mask: u32) u64 {
    var total: u64 = 0;
    inline for (decl.fields, 0..) |f, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0) total += comptime wire.codec.fieldBits(f);
    }
    return total;
}

// ---------------------------------------------------------------------------

const schema_mod = @import("bedlam_schema");
const chunk_mod = world_mod.chunk;
const Fixed = @import("fpz").Fixed;

const Transform = schema_mod.schema.components[0];
const TCols = wire.codec.Storage(Transform);
const TestWorld = world_mod.world.World(TCols, chunk_mod.Budget.desktop);
const TestSched = Scheduler(TCols);
const ids = [_]u32{ 0x00410001, 0x00410002, 0x00410004 };

fn unit() TCols {
    return .{
        .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
        .rotation = .{ Fixed.ONE, Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
        .velocity = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
    };
}

fn seeded(gpa: std.mem.Allocator, n: u32) !TestWorld {
    var w = try TestWorld.init(gpa, 1 << 16, ids);
    errdefer w.deinit();
    try w.reserve(n);
    for (0..n) |i| {
        var v = unit();
        v.position[0] = Fixed.fromInt(@intCast(i));
        _ = try w.spawn(v);
    }
    return w;
}

test "assembly respects the byte budget" {
    // §4 makes exceeding the hard ceiling a run failure, so this is enforced rather than
    // advisory.
    const gpa = std.testing.allocator;
    var w = try seeded(gpa, 512);
    defer w.deinit();

    var base = TestSched.BaselineType.init(gpa);
    defer base.deinit();
    var it = w.table.chunkIterator();
    while (it.next()) |c| for (c.liveEntities()) |e| try base.setInterest(e, true);

    var sched = TestSched.init(gpa);
    defer sched.deinit();

    var buf: [1500]u8 = undefined;
    var writer = wire.bits.Writer.init(&buf);
    const stats = try sched.assemble(Transform, &w, &base, &writer, 1500, 1);

    try std.testing.expect(stats.bytes <= 1500);
    try std.testing.expect(stats.sent > 0);
    // 512 relevant entities do not fit in 1,500 bytes. That is §4.1's whole point.
    try std.testing.expect(stats.deferred > 0);
}

test "the §4.1 arithmetic holds: ~180 full Transforms per 1,500 bytes" {
    // A Transform is 113 bits plus a 3-bit mask = 116 bits = 14.5 bytes. 1,500 / 14.5 is
    // about 103 whole-component sends — fewer than 180 because 180 assumes ~8-byte
    // partial deltas, not full sends. Recorded so the budget is checked rather than
    // asserted.
    const gpa = std.testing.allocator;
    var w = try seeded(gpa, 512);
    defer w.deinit();

    var base = TestSched.BaselineType.init(gpa);
    defer base.deinit();
    var it = w.table.chunkIterator();
    while (it.next()) |c| for (c.liveEntities()) |e| try base.setInterest(e, true);

    var sched = TestSched.init(gpa);
    defer sched.deinit();

    var buf: [1500]u8 = undefined;
    var writer = wire.bits.Writer.init(&buf);
    const stats = try sched.assemble(Transform, &w, &base, &writer, 1500, 1);

    // Every entity is new to this client, so every send is a full 3-field update.
    try std.testing.expect(stats.sent >= 95 and stats.sent <= 110);
}

test "a starved entity's priority rises until it is sent" {
    // The property the accumulator exists for. At 512 relevant entities and ~100 slots
    // the budget is permanently oversubscribed, so without this the same entities would
    // win every snapshot and the rest would never be seen.
    const gpa = std.testing.allocator;
    var w = try seeded(gpa, 300);
    defer w.deinit();

    var base = TestSched.BaselineType.init(gpa);
    defer base.deinit();
    var it = w.table.chunkIterator();
    while (it.next()) |c| for (c.liveEntities()) |e| try base.setInterest(e, true);

    var sched = TestSched.init(gpa);
    defer sched.deinit();

    // Track which entities have ever been sent across several snapshots.
    var ever_sent = try gpa.alloc(bool, 400);
    defer gpa.free(ever_sent);
    @memset(ever_sent, false);

    var buf: [1500]u8 = undefined;
    var snapshot: u64 = 1;
    for (0..8) |_| {
        var writer = wire.bits.Writer.init(&buf);
        _ = try sched.assemble(Transform, &w, &base, &writer, 1500, 1);

        // Anything whose priority reset to 0 was sent this snapshot. Collect them all
        // and acknowledge once — see the note in the previous test.
        var acked: std.ArrayList(TestSched.BaselineType.Record) = .empty;
        defer acked.deinit(gpa);

        var it2 = w.table.chunkIterator();
        while (it2.next()) |c| {
            for (c.liveEntities()) |e| {
                if (sched.priorityOf(e) == 0) {
                    ever_sent[e.index] = true;
                    try acked.append(gpa, .{
                        .entity = e,
                        .values = componentOf(TCols, &w, e),
                        .acked_at = snapshot,
                    });
                }
            }
        }
        _ = try base.acknowledge(snapshot, acked.items);
        snapshot += 1;
    }

    var unseen: u32 = 0;
    var it3 = w.table.chunkIterator();
    while (it3.next()) |c| for (c.liveEntities()) |e| {
        if (!ever_sent[e.index]) unseen += 1;
    };
    try std.testing.expectEqual(@as(u32, 0), unseen);
}

test "an unchanged entity costs nothing" {
    const gpa = std.testing.allocator;
    var w = try seeded(gpa, 16);
    defer w.deinit();

    var base = TestSched.BaselineType.init(gpa);
    defer base.deinit();
    var sched = TestSched.init(gpa);
    defer sched.deinit();

    // Acknowledge ONE snapshot carrying every entity, not one snapshot per entity:
    // an ack is per snapshot by definition, and `acknowledge` ignores a repeat of a
    // snapshot it has already applied.
    var records: std.ArrayList(TestSched.BaselineType.Record) = .empty;
    defer records.deinit(gpa);

    var it = w.table.chunkIterator();
    while (it.next()) |c| for (c.liveEntities()) |e| {
        try base.setInterest(e, true);
        try records.append(gpa, .{
            .entity = e,
            .values = componentOf(TCols, &w, e),
            .acked_at = 1,
        });
    };
    _ = try base.acknowledge(1, records.items);

    var buf: [1500]u8 = undefined;
    var writer = wire.bits.Writer.init(&buf);
    const stats = try sched.assemble(Transform, &w, &base, &writer, 1500, 1);

    try std.testing.expectEqual(@as(u32, 0), stats.sent);
    try std.testing.expectEqual(@as(usize, 0), stats.bytes);
}

test "entities outside the interest set are never considered" {
    // §16: information never sent cannot be extracted.
    const gpa = std.testing.allocator;
    var w = try seeded(gpa, 32);
    defer w.deinit();

    var base = TestSched.BaselineType.init(gpa);
    defer base.deinit();
    var sched = TestSched.init(gpa);
    defer sched.deinit();

    // Interested in exactly one.
    var it = w.table.chunkIterator();
    const only = it.next().?.liveEntities()[0];
    try base.setInterest(only, true);

    var buf: [1500]u8 = undefined;
    var writer = wire.bits.Writer.init(&buf);
    const stats = try sched.assemble(Transform, &w, &base, &writer, 1500, 1);

    try std.testing.expectEqual(@as(u32, 1), stats.sent);
    try std.testing.expectEqual(@as(u32, 0), stats.deferred);
}

test "assembly is deterministic across hosts" {
    // Two peers assembling the same state must produce the same packet, or a host
    // migration changes what clients receive mid-session. Ties break on entity index
    // rather than storage order for exactly this reason.
    const gpa = std.testing.allocator;
    var out: [2][]u8 = undefined;

    for (&out) |*slot| {
        var w = try seeded(gpa, 64);
        defer w.deinit();
        var base = TestSched.BaselineType.init(gpa);
        defer base.deinit();
        var sched = TestSched.init(gpa);
        defer sched.deinit();

        var it = w.table.chunkIterator();
        while (it.next()) |c| for (c.liveEntities()) |e| try base.setInterest(e, true);

        var buf: [1500]u8 = undefined;
        var writer = wire.bits.Writer.init(&buf);
        _ = try sched.assemble(Transform, &w, &base, &writer, 1500, 1);
        slot.* = try gpa.dupe(u8, writer.written());
    }
    defer for (out) |o| gpa.free(o);

    try std.testing.expectEqualSlices(u8, out[0], out[1]);
}
