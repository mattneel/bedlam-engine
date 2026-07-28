//! Per-client send state: the piece that makes delta replication actually close.
//!
//! `baseline.zig` promotes a snapshot's values to the baseline **on acknowledgement**, and
//! `acknowledge` needs the entries that snapshot contained. Nothing was remembering them.
//! Without that, a server either has to send full state forever — which is what
//! `--net-demo` did as an honest stand-in — or promote on send, which is the classic bug:
//! the baseline advances to a snapshot the client never received, and every subsequent
//! delta is computed against state the client does not have. The client's world is then
//! wrong in a way that never corrects, because nothing is ever "changed" again.
//!
//! So this holds a small ring of in-flight snapshots. When `session.zig`'s ack window says
//! a snapshot arrived, its recorded entries are handed to `baseline.acknowledge`.
//!
//! **Everything is allocated once.** §18.8. The ring is `max_inflight` snapshots of
//! `max_per_snapshot` entries, sized at init and never grown — a send path that allocates
//! under load allocates exactly when the frame budget is tightest.
//!
//! **In-flight capacity is a real limit with a real consequence.** With `max_inflight`
//! snapshots outstanding, the oldest is dropped to make room, and dropping it means its
//! entries can never be acknowledged — those entities keep being re-sent until a later
//! snapshot containing them is acked. That is *correct* but wasteful, so `evicted` counts
//! it. At §1's tick rate, `max_inflight` should exceed the round-trip time in ticks or the
//! ring throws away acks that were about to arrive.

const std = @import("std");
const wire = @import("bedlam_wire");
const world_mod = @import("bedlam_world");
const baseline_mod = @import("baseline.zig");
const replicate = @import("replicate.zig");

pub const Entity = world_mod.entity.Entity;

pub const Stats = struct {
    snapshots_sent: u64 = 0,
    snapshots_acked: u64 = 0,
    records_sent: u64 = 0,
    /// Entities that did not fit in a snapshot's budget. Deferred, not dropped — their
    /// priority rises and they go in a later one.
    deferred: u64 = 0,
    /// In-flight snapshots discarded because the ring was full. Nonzero means the ring is
    /// smaller than the round-trip time, and the cost is redundant re-sends.
    evicted: u64 = 0,
    /// Acks for snapshots the ring no longer holds. Ordinary at startup and after an
    /// eviction; a large count means the same thing `evicted` does.
    acks_unmatched: u64 = 0,
};

pub fn Outbound(comptime Columns: type, comptime max_inflight: usize, comptime max_per_snapshot: usize) type {
    comptime {
        if (max_inflight == 0 or (max_inflight & (max_inflight - 1)) != 0) {
            @compileError("max_inflight must be a non-zero power of two");
        }
    }

    return struct {
        const Self = @This();
        pub const BaselineType = baseline_mod.Baseline(Columns);
        pub const Record = BaselineType.Record;

        const Slot = struct {
            snapshot: u64 = 0,
            count: u32 = 0,
            /// Whether this slot holds a snapshot that has not been acked or evicted.
            live: bool = false,
        };

        gpa: std.mem.Allocator,
        base: BaselineType,

        slots: [max_inflight]Slot = @splat(.{}),
        /// `max_inflight * max_per_snapshot` entries, allocated once.
        entries: []Record = &.{},

        /// Accumulated priority per entity index. A deferred entity's priority rises until
        /// it is sent, which is what stops the same entities being starved forever by a
        /// budget that cannot fit everything — the defect `--net-demo` hit with a naive
        /// iteration order.
        priority: std.ArrayList(u32),

        next_snapshot: u64 = 1,
        stats: Stats = .{},

        pub fn init(gpa: std.mem.Allocator) !Self {
            var self: Self = .{
                .gpa = gpa,
                .base = BaselineType.init(gpa),
                .priority = .empty,
            };
            self.entries = try gpa.alloc(Record, max_inflight * max_per_snapshot);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.base.deinit();
            self.priority.deinit(self.gpa);
            if (self.entries.len > 0) self.gpa.free(self.entries);
            self.* = undefined;
        }

        pub fn reserve(self: *Self, entity_count: u32) !void {
            try self.base.reserve(entity_count);
            try self.priority.ensureTotalCapacity(self.gpa, entity_count + 1);
            while (self.priority.items.len <= entity_count) {
                self.priority.appendAssumeCapacity(0);
            }
        }

        fn ensurePriority(self: *Self, index: u32) !void {
            while (self.priority.items.len <= index) {
                try self.priority.append(self.gpa, 0);
            }
        }

        fn slotFor(self: *Self, snapshot: u64) *Slot {
            return &self.slots[@intCast(snapshot % max_inflight)];
        }

        fn entriesOf(self: *Self, snapshot: u64) []Record {
            const i: usize = @intCast(snapshot % max_inflight);
            return self.entries[i * max_per_snapshot ..][0..max_per_snapshot];
        }

        pub const Candidate = struct {
            entity: Entity,
            values: Columns,
            priority: u32,
            mask: u32,
        };

        /// Assemble one snapshot into `writer` and record what it contained.
        ///
        /// Returns the snapshot number, which the caller must be able to associate with
        /// the packet sequence the session assigns — `onAck` is driven by that.
        pub fn assemble(
            self: *Self,
            comptime decl: anytype,
            w: anytype,
            fw: *replicate.Writer,
            budget_bytes: u64,
            /// Priority gained per tick by an entity that changed but did not fit. Higher
            /// values clear a backlog faster and make the send order less stable; §12
            /// leaves the constant to tuning.
            weight: u32,
            decl_fallback: wire.codec.Storage(decl),
        ) !u64 {
            const snapshot = self.next_snapshot;
            self.next_snapshot += 1;

            var cands: [max_per_snapshot]Candidate = undefined;
            var n: usize = 0;

            var it = w.table.chunkIterator();
            while (it.next()) |c| {
                for (c.liveEntities()) |e| {
                    if (!self.base.isInterested(e)) continue;
                    if (n >= cands.len) break;
                    try self.ensurePriority(e.index);

                    var cols: Columns = undefined;
                    inline for (@typeInfo(Columns).@"struct".fields) |f| {
                        @field(cols, f.name) = w.table.get(e, f.name).?;
                    }
                    const mask = self.base.changedMask(e, cols);
                    if (mask == 0) continue;

                    self.priority.items[e.index] +|= weight;
                    cands[n] = .{
                        .entity = e,
                        .values = cols,
                        .priority = self.priority.items[e.index],
                        .mask = mask,
                    };
                    n += 1;
                }
            }

            // Highest priority first, ties by entity index. The tiebreak is not cosmetic:
            // storage order is a function of spawn and swap-remove history, so two hosts
            // with identical worlds would otherwise assemble different packets and §14.3's
            // replay validation would have nothing stable to compare.
            std.mem.sort(Candidate, cands[0..n], {}, struct {
                fn less(_: void, a: Candidate, b: Candidate) bool {
                    if (a.priority != b.priority) return a.priority > b.priority;
                    return a.entity.index < b.entity.index;
                }
            }.less);

            // Claim the ring slot. Evicting a live one loses the ability to ack it.
            const slot = self.slotFor(snapshot);
            if (slot.live) self.stats.evicted += 1;
            slot.* = .{ .snapshot = snapshot, .count = 0, .live = true };
            const store = self.entriesOf(snapshot);

            const decl_bits = comptime wire.codec.componentBits(decl);
            for (cands[0..n]) |cand| {
                const cost = replicate.Writer.recordCost(decl_bits);
                if ((fw.w.bitsWritten() + cost + 7) / 8 > budget_bytes) {
                    // Deferred, not dropped: the priority just added stays, so this entity
                    // outranks unchanged ones next time.
                    self.stats.deferred += 1;
                    continue;
                }

                const projected = replicate.projectFor(decl, Columns, cand.values, decl_fallback);
                try fw.writeUpdate(decl, cand.entity, projected, cand.mask);

                store[slot.count] = .{
                    .entity = cand.entity,
                    // **The world's values, not the quantized ones that went on the wire.**
                    //
                    // The tempting alternative is to record what the client will actually
                    // hold. It does not work: `changedMask` compares the world's current
                    // values against this baseline, so both sides must be in the same space.
                    // Record the quantized value and every field differs from its raw
                    // counterpart on the very next tick — the mask is full every time and
                    // delta compression does nothing at all.
                    //
                    // The cost of this choice is bandwidth, not correctness: a field whose
                    // raw value moves but quantizes to the same code is re-sent needlessly.
                    // It cannot drift, because a delta carries absolute values rather than
                    // increments — the client is *assigned* the quantized value each time
                    // rather than accumulating a correction.
                    .values = cand.values,
                    .acked_at = snapshot,
                };
                slot.count += 1;
                self.priority.items[cand.entity.index] = 0;
                self.stats.records_sent += 1;
            }

            self.base.stage(snapshot);
            self.stats.snapshots_sent += 1;
            return snapshot;
        }

        /// Promote a snapshot's entries to the baseline. Driven by the session's ack.
        ///
        /// Returns false when the snapshot is not in the ring — evicted, already acked, or
        /// never sent. Ordinary, and counted rather than treated as an error.
        pub fn onAck(self: *Self, snapshot: u64) !bool {
            const slot = self.slotFor(snapshot);
            if (!slot.live or slot.snapshot != snapshot) {
                self.stats.acks_unmatched += 1;
                return false;
            }
            const applied = try self.base.acknowledge(snapshot, self.entriesOf(snapshot)[0..slot.count]);
            slot.live = false;
            if (applied) self.stats.snapshots_acked += 1;
            return applied;
        }

        pub fn setInterest(self: *Self, e: Entity, interested: bool) !void {
            try self.base.setInterest(e, interested);
        }

        pub fn forget(self: *Self, e: Entity) void {
            self.base.forget(e);
        }

        pub fn inFlight(self: *const Self) u32 {
            var n: u32 = 0;
            for (self.slots) |s| {
                if (s.live) n += 1;
            }
            return n;
        }
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const schema_mod = @import("bedlam_schema");
const Fixed = @import("fpz").Fixed;

const Transform = schema_mod.schema.components[0];
const TCols = wire.codec.Storage(Transform);
const TestWorld = world_mod.world.World(TCols, world_mod.chunk.Budget.desktop);
const TestOut = Outbound(TCols, 8, 128);
const ids = [_]u32{ 0x00410001, 0x00410002, 0x00410004 };

fn unit() TCols {
    return .{
        .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
        .rotation = .{ Fixed.ONE, Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
        .velocity = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
    };
}

fn posAt(x: i32) TCols {
    var v = unit();
    v.position[0] = Fixed.fromInt(x);
    return v;
}

/// Assemble one snapshot, returning its number and the bytes.
fn send(o: *TestOut, w: *TestWorld, buf: []u8, budget: u64) !struct { u64, []u8 } {
    var bw = wire.bits.Writer.init(buf);
    var fw = try replicate.Writer.begin(&bw, w.tick, 0);
    const snap = try o.assemble(Transform, w, &fw, budget, 1, unit());
    fw.finish();
    return .{ snap, buf[0..bw.bytesWritten()] };
}

test "an unacked snapshot does not advance the baseline" {
    // The classic bug this file exists to prevent: promoting on SEND advances the baseline
    // to a snapshot the client never received, and every later delta is then computed
    // against state that exists nowhere. The client's world is wrong and never corrects,
    // because nothing is ever "changed" again.
    const gpa = testing.allocator;
    var w = try TestWorld.init(gpa, 4096, ids);
    defer w.deinit();
    var o = try TestOut.init(gpa);
    defer o.deinit();

    const e = try w.spawn(posAt(5));
    try o.setInterest(e, true);

    var buf: [4096]u8 = undefined;
    _ = try send(&o, &w, &buf, 1200);
    // Nothing acked, so the same entity is still "changed" and goes out again.
    const second = try send(&o, &w, &buf, 1200);
    try testing.expectEqual(@as(u64, 2), o.stats.records_sent);
    try testing.expect(second[1].len > 0);
}

test "an ack promotes the baseline, and an unchanged entity then costs nothing" {
    const gpa = testing.allocator;
    var w = try TestWorld.init(gpa, 4096, ids);
    defer w.deinit();
    var o = try TestOut.init(gpa);
    defer o.deinit();

    const e = try w.spawn(posAt(5));
    try o.setInterest(e, true);

    var buf: [4096]u8 = undefined;
    const first = try send(&o, &w, &buf, 1200);
    try testing.expect(try o.onAck(first[0]));
    try testing.expectEqual(@as(u64, 1), o.stats.snapshots_acked);

    const before = o.stats.records_sent;
    _ = try send(&o, &w, &buf, 1200);
    try testing.expectEqual(before, o.stats.records_sent); // nothing changed
}

test "after an ack only the changed field is re-sent" {
    const gpa = testing.allocator;
    var w = try TestWorld.init(gpa, 4096, ids);
    defer w.deinit();
    var o = try TestOut.init(gpa);
    defer o.deinit();

    const e = try w.spawn(posAt(5));
    try o.setInterest(e, true);

    var buf: [4096]u8 = undefined;
    const full = try send(&o, &w, &buf, 1200);
    const full_len = full[1].len;
    _ = try o.onAck(full[0]);

    _ = w.set(e, "position", posAt(9).position);
    const delta = try send(&o, &w, &buf, 1200);

    // A one-field delta is strictly smaller than the full record.
    try testing.expect(delta[1].len < full_len);
}

test "an evicted snapshot is counted and its ack is unmatched" {
    // In-flight capacity is a real limit: with the ring full the oldest is dropped, and its
    // entries can never be acked. Correct but wasteful, so it is counted rather than
    // presenting as entities that are re-sent for no visible reason.
    const gpa = testing.allocator;
    var w = try TestWorld.init(gpa, 4096, ids);
    defer w.deinit();
    var o = try TestOut.init(gpa);
    defer o.deinit();

    const e = try w.spawn(posAt(1));
    try o.setInterest(e, true);

    var buf: [4096]u8 = undefined;
    var first: u64 = 0;
    for (0..9) |i| {
        const r = try send(&o, &w, &buf, 1200);
        if (i == 0) first = r[0];
        _ = w.set(e, "position", posAt(@intCast(i + 2)).position);
    }
    try testing.expect(o.stats.evicted > 0);
    try testing.expect(!try o.onAck(first));
    try testing.expect(o.stats.acks_unmatched > 0);
}

test "an out-of-order ack does not roll the baseline backwards" {
    const gpa = testing.allocator;
    var w = try TestWorld.init(gpa, 4096, ids);
    defer w.deinit();
    var o = try TestOut.init(gpa);
    defer o.deinit();

    const e = try w.spawn(posAt(1));
    try o.setInterest(e, true);

    var buf: [4096]u8 = undefined;
    const s1 = try send(&o, &w, &buf, 1200);
    _ = w.set(e, "position", posAt(2).position);
    const s2 = try send(&o, &w, &buf, 1200);

    try testing.expect(try o.onAck(s2[0]));
    // s1 is older; applying it would claim the client holds the earlier position.
    try testing.expect(!try o.onAck(s1[0]));
}

test "a budget that cannot fit everything defers rather than starves" {
    // The defect --net-demo hit with a naive iteration order: the same entities were cut
    // every frame and never arrived, with nothing reporting it. Priority rises on every
    // deferral, so a deferred entity outranks the others next time.
    const gpa = testing.allocator;
    var w = try TestWorld.init(gpa, 4096, ids);
    defer w.deinit();
    var o = try TestOut.init(gpa);
    defer o.deinit();

    var handles: [40]Entity = undefined;
    for (&handles, 0..) |*h, i| {
        h.* = try w.spawn(posAt(@intCast(i)));
        try o.setInterest(h.*, true);
    }

    // A budget far too small for 40 records.
    var buf: [4096]u8 = undefined;
    var seen = std.AutoHashMap(u24, void).init(gpa);
    defer seen.deinit();

    for (0..40) |_| {
        var bw = wire.bits.Writer.init(&buf);
        var fw = try replicate.Writer.begin(&bw, w.tick, 0);
        const snap = try o.assemble(Transform, &w, &fw, 60, 1, unit());
        fw.finish();
        _ = try o.onAck(snap);
        w.advanceTick();
        // Change everything again so all remain candidates.
        for (handles, 0..) |h, i| _ = w.set(h, "position", posAt(@intCast(i + 1)).position);
    }

    // Every entity got at least one send: none was starved by the budget.
    try testing.expect(o.stats.deferred > 0);
    try testing.expect(o.stats.records_sent >= handles.len);

    // Stronger: check the baseline knows about every entity, which only happens if each
    // was sent AND acked at least once.
    for (handles) |h| try testing.expect(o.base.record(h) != null);
}

test "a sub-quantum change costs bandwidth but never accumulates" {
    // The consequence of holding world values in the baseline, stated where it would be
    // noticed. A raw change too small to alter the transmitted code is re-sent — wasteful —
    // but the client is ASSIGNED the quantized value each time rather than accumulating a
    // correction, so the replica cannot walk away from the authority.
    const gpa = testing.allocator;
    var w = try TestWorld.init(gpa, 4096, ids);
    defer w.deinit();
    var o = try TestOut.init(gpa);
    defer o.deinit();
    var replica = try TestWorld.init(gpa, 4096, ids);
    defer replica.deinit();

    const e = try w.spawn(posAt(3));
    try o.setInterest(e, true);

    var buf: [4096]u8 = undefined;
    var applied_pos: i64 = 0;

    for (0..64) |i| {
        // Nudge by one raw unit — far below a quantization step.
        var p = w.get(e, "position").?;
        p[0] = Fixed.fromRaw(p[0].raw + 1);
        _ = w.set(e, "position", p);

        const r = try send(&o, &w, &buf, 1200);
        var br = wire.bits.Reader.init(r[1]);
        _ = try replicate.apply(Transform, TCols, &replica, &br, unit(), unit());
        _ = try o.onAck(r[0]);

        const got = replica.get(e, "position").?[0].raw;
        if (i > 0) {
            // Never more than one quantization step from where it started: no accumulation.
            try testing.expect(@abs(got - applied_pos) < (1 << 24));
        }
        applied_pos = got;
    }
}

test "entities outside the interest set are never sent" {
    const gpa = testing.allocator;
    var w = try TestWorld.init(gpa, 4096, ids);
    defer w.deinit();
    var o = try TestOut.init(gpa);
    defer o.deinit();

    const seen_e = try w.spawn(posAt(1));
    _ = try w.spawn(posAt(2)); // no interest
    try o.setInterest(seen_e, true);

    var buf: [4096]u8 = undefined;
    _ = try send(&o, &w, &buf, 1200);
    try testing.expectEqual(@as(u64, 1), o.stats.records_sent);
}

test "assembly order does not depend on storage order" {
    // Storage order is a function of spawn and swap-remove history, so two hosts with
    // identical worlds would otherwise assemble different packets and §14.3's replay
    // validation would have nothing stable to compare.
    const gpa = testing.allocator;

    var a = try TestWorld.init(gpa, 4096, ids);
    defer a.deinit();
    var b = try TestWorld.init(gpa, 4096, ids);
    defer b.deinit();

    // Same logical world, different spawn/despawn history.
    var ha: [6]Entity = undefined;
    for (&ha, 0..) |*h, i| h.* = try a.spawn(posAt(@intCast(i)));

    var hb: [8]Entity = undefined;
    for (&hb, 0..) |*h, i| h.* = try b.spawn(posAt(@intCast(i)));
    _ = b.despawn(hb[6]);
    _ = b.despawn(hb[7]);

    var oa = try TestOut.init(gpa);
    defer oa.deinit();
    var ob = try TestOut.init(gpa);
    defer ob.deinit();
    for (ha) |h| try oa.setInterest(h, true);
    for (hb[0..6]) |h| try ob.setInterest(h, true);

    var ba: [4096]u8 = undefined;
    var bb: [4096]u8 = undefined;
    const ra = try send(&oa, &a, &ba, 1200);
    const rb = try send(&ob, &b, &bb, 1200);

    try testing.expectEqualSlices(u8, ra[1], rb[1]);
}
