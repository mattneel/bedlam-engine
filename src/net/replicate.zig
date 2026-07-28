//! The replication frame: what `snapshot.zig` assembles into and what a client applies.
//!
//! `snapshot.zig` decides *which* entities to send and `baseline.zig` decides *which
//! fields*. Neither wrote down which entity a payload described, so nothing could receive
//! one. This is that half: a frame format with entity identity, and an applier that turns
//! it back into a world.
//!
//! **The authority names the entity.** A replica calls `world.spawnAt` with the handle the
//! server sent rather than allocating its own. `world/hash.zig` includes entity identity in
//! the canonical projection, so a client that allocated independently would hold a world
//! identical in every component and still hash differently — reporting a desync between two
//! peers in complete agreement. See `entity.Allocator.adopt` for why this is not §18.6's
//! forbidden derived identity: the handle is transmitted, not derived, and it is a runtime
//! handle scoped to one session rather than a durable ID written to a save.
//!
//! **Every offset is a bit count, not a byte count.** The payload is bit-packed by
//! `wire/codec.zig`, and a frame header that rounded to bytes would waste up to seven bits
//! per record — which at §2.1's entity census is a measurable fraction of a snapshot.
//!
//! ## What this does not do
//!
//! Interest management is `baseline.setInterest`'s job and relevance changes are not
//! represented here: an entity leaving interest is a `despawn` record to that client, which
//! is correct for the client's view and wrong as a statement about the world. That
//! distinction matters for §14.3's replay validation and is not yet drawn.

const std = @import("std");
const wire = @import("bedlam_wire");
const world_mod = @import("bedlam_world");

pub const Entity = world_mod.entity.Entity;

pub const Error = error{
    /// The frame claims more records than its bytes can hold. Refused rather than
    /// truncated: a partial world update applied as if complete is a desync, and this is
    /// the untrusted side of a trust boundary.
    Malformed,
    TooManyRecords,
};

/// Records in one frame. Bounded so a hostile peer cannot make the applier loop for a
/// length it never supplied bytes for — the count is checked against remaining bits as the
/// frame is read, but a cap makes the failure immediate rather than eventual.
pub const max_records: u16 = 4096;

/// Frame header. Explicit little-endian, like everything else on the wire.
pub const Header = struct {
    /// The authority's tick this frame describes. Not the client's — a client running
    /// ahead by prediction must know what it is reconciling against.
    tick: u64,
    /// The snapshot sequence, so `baseline.acknowledge` can be driven by the ack the
    /// session already carries.
    snapshot: u64,
    count: u16,

    pub const bits: u64 = 64 + 64 + 16;

    pub fn write(self: Header, w: *wire.bits.Writer) wire.bits.Writer.Error!void {
        try w.writeBits(self.tick, 64);
        try w.writeBits(self.snapshot, 64);
        try w.writeBits(self.count, 16);
    }

    pub fn read(r: *wire.bits.Reader) !Header {
        return .{
            .tick = try r.readBits(64),
            .snapshot = try r.readBits(64),
            .count = @intCast(try r.readBits(16)),
        };
    }
};

/// One entity's record: identity, a despawn flag, then the masked payload if present.
///
/// Identity is 32 bits — the `Entity` packed struct — written explicitly rather than
/// `@bitCast`, because a bitcast of a packed struct is a per-target layout and this must
/// be one format for all six.
pub const record_prefix_bits: u64 = 24 + 8 + 1;

fn writeEntity(w: *wire.bits.Writer, e: Entity) wire.bits.Writer.Error!void {
    try w.writeBits(e.index, 24);
    try w.writeBits(e.generation, 8);
}

fn readEntity(r: *wire.bits.Reader) !Entity {
    const index: u24 = @intCast(try r.readBits(24));
    const generation: u8 = @intCast(try r.readBits(8));
    return .{ .index = index, .generation = generation };
}

/// Writes frames. Holds no state beyond the record count, so a caller may assemble into any
/// buffer it likes.
pub const Writer = struct {
    w: *wire.bits.Writer,
    count: u16 = 0,
    /// Where the header's count field starts, so it can be patched once the frame is
    /// complete. The count is not known in advance: the budget decides how many records
    /// fit, and reserving a maximum would waste the bits the budget is trying to save.
    count_bit: u64,

    pub fn begin(w: *wire.bits.Writer, tick: u64, snapshot: u64) !Writer {
        try w.writeBits(tick, 64);
        try w.writeBits(snapshot, 64);
        const at = w.bitsWritten();
        try w.writeBits(0, 16);
        return .{ .w = w, .count_bit = at };
    }

    /// Cost in bits of adding a record with `payload_bits` of masked component data.
    pub fn recordCost(payload_bits: u64) u64 {
        return record_prefix_bits + payload_bits;
    }

    pub fn writeUpdate(
        self: *Writer,
        comptime decl: anytype,
        e: Entity,
        values: anytype,
        mask: u32,
    ) !void {
        try writeEntity(self.w, e);
        try self.w.writeBits(0, 1); // not a despawn
        try wire.codec.encodeMasked(decl, values, mask, self.w);
        self.count += 1;
    }

    pub fn writeDespawn(self: *Writer, e: Entity) !void {
        try writeEntity(self.w, e);
        try self.w.writeBits(1, 1);
        self.count += 1;
    }

    /// Patch the count into the header. Must be called before the buffer is sent.
    pub fn finish(self: *Writer) void {
        self.w.patchBits(self.count_bit, self.count, 16);
    }
};

/// What applying a frame did. Counted rather than logged, and the counts are the ones that
/// distinguish a healthy stream from a broken one: `unknown` climbing means the client is
/// receiving deltas for entities it never got a spawn for, which is a baseline desync
/// rather than a network problem.
pub const Applied = struct {
    tick: u64 = 0,
    snapshot: u64 = 0,
    spawned: u32 = 0,
    updated: u32 = 0,
    despawned: u32 = 0,
    /// Despawns for entities the client does not have. Ordinary — a despawn may arrive
    /// after the client already dropped the entity — but a large count means the two sides
    /// disagree about what exists.
    unknown: u32 = 0,
};

/// Apply a frame to a replica world.
///
/// `WorldT` must expose `spawnAt`, `set`, `despawn`, `isLive` and `get` — the same surface
/// `world.World` provides. Taking it as `anytype` keeps this file out of the world's
/// dependency graph, which matters because the world is compiled for targets that have no
/// networking at all.
pub fn apply(
    comptime decl: anytype,
    comptime Columns: type,
    w: anytype,
    r: *wire.bits.Reader,
    /// Values a newly-spawned entity starts from, before the masked payload is applied.
    /// The authority sends a full mask for an entity the client has never seen
    /// (`baseline.changedMask` returns all-ones with no record), so in a healthy stream
    /// every field is overwritten and this is never observable. It exists so that a
    /// *partial* first frame produces a defined world rather than uninitialized memory.
    defaults: Columns,
) !Applied {
    const header = try Header.read(r);
    if (header.count > max_records) return Error.TooManyRecords;

    var out: Applied = .{ .tick = header.tick, .snapshot = header.snapshot };

    var i: u16 = 0;
    while (i < header.count) : (i += 1) {
        const e = try readEntity(r);
        const despawn = (try r.readBits(1)) != 0;

        if (despawn) {
            if (w.despawn(e)) out.despawned += 1 else out.unknown += 1;
            continue;
        }

        // Baseline for the delta: the entity's current values if the client has it, the
        // supplied defaults otherwise. Reading the payload happens either way — a frame
        // must be consumed to its end even when a record cannot be applied, or every
        // subsequent record in it is parsed from the wrong bit offset.
        const known = w.isLive(e);
        const base: Columns = if (known) currentOf(Columns, w, e) else defaults;
        const values = try wire.codec.decodeMasked(decl, base, r);

        if (known) {
            inline for (@typeInfo(Columns).@"struct".fields) |f| {
                _ = w.set(e, f.name, @field(values, f.name));
            }
            out.updated += 1;
        } else {
            if (try w.spawnAt(e, values)) out.spawned += 1 else out.unknown += 1;
        }
    }
    return out;
}

fn currentOf(comptime Columns: type, w: anytype, e: Entity) Columns {
    var out: Columns = undefined;
    inline for (@typeInfo(Columns).@"struct".fields) |f| {
        @field(out, f.name) = w.get(e, f.name).?;
    }
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const schema_mod = @import("bedlam_schema");
const Fixed = @import("fpz").Fixed;

const Transform = schema_mod.schema.components[0];
const TCols = wire.codec.Storage(Transform);
const TestWorld = world_mod.world.World(TCols, world_mod.chunk.Budget.desktop);
const full_mask: u32 = (1 << 3) - 1;

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

const ids = [_]u32{ 0x00410001, 0x00410002, 0x00410004 };

/// What a value becomes after one wire round trip.
///
/// **The wire is lossy and that is deliberate.** `wire/fixedquant.zig` quantizes each field
/// to the bit width its semantic type declares, so a replica does NOT hold the authority's
/// exact values and cannot be expected to. Tests that compare a replica against the
/// authority's raw state are asserting something false; they compare against this instead.
fn throughWire(v: TCols) TCols {
    var buf: [256]u8 = undefined;
    var bw = wire.bits.Writer.init(&buf);
    wire.codec.encodeMasked(Transform, v, full_mask, &bw) catch unreachable;
    var br = wire.bits.Reader.init(buf[0..bw.bytesWritten()]);
    return wire.codec.decodeMasked(Transform, v, &br) catch unreachable;
}

fn newWorld(gpa: std.mem.Allocator) !TestWorld {
    return TestWorld.init(gpa, 4096, ids);
}

/// Assemble a frame describing every live entity in `src`, then apply it to `dst`.
fn replicate(gpa: std.mem.Allocator, src: *TestWorld, dst: *TestWorld) !Applied {
    const buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buf);

    var bw = wire.bits.Writer.init(buf);
    var fw = try Writer.begin(&bw, src.tick, 1);

    var it = src.table.chunkIterator();
    while (it.next()) |c| {
        for (c.liveEntities()) |e| {
            try fw.writeUpdate(Transform, e, currentOf(TCols, src, e), full_mask);
        }
    }
    fw.finish();

    var br = wire.bits.Reader.init(buf[0..bw.bytesWritten()]);
    return apply(Transform, TCols, dst, &br, unit());
}

test "a frame round-trips one entity" {
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var client = try newWorld(gpa);
    defer client.deinit();

    const e = try server.spawn(posAt(7));
    const applied = try replicate(gpa, &server, &client);

    try testing.expectEqual(@as(u32, 1), applied.spawned);
    try testing.expect(client.isLive(e));
    // Compared against the quantized value, not the authority's raw one -- see throughWire.
    try testing.expectEqual(throughWire(posAt(7)).position[0].raw, client.get(e, "position").?[0].raw);
}

test "the wire is lossy, and a replica is not bit-identical to its authority" {
    // Stated as a test because it is the thing that makes the obvious replication assertion
    // wrong. §7's canonical world hash is a DETERMINISM instrument -- same inputs, same
    // code, same result -- not a replication one. Two peers separated by a quantizing wire
    // are supposed to differ, and a test asserting they do not would be reporting a bug
    // that is actually the design.
    const raw = posAt(7);
    const wired = throughWire(raw);
    try testing.expect(raw.position[0].raw != wired.position[0].raw);

    // But the loss is bounded: within one quantization step of the original.
    const delta = @abs(raw.position[0].raw - wired.position[0].raw);
    try testing.expect(delta < (1 << 24) / 8);
}

test "quantization is a fixed point, so a replica does not drift" {
    // The property that makes lossy replication safe. If re-encoding an already-quantized
    // value produced a different one, every tick would shift the replica a little further
    // from the authority and a session would drift without anything reporting an error.
    for ([_]i32{ 0, 1, 7, -3, 100, -100 }) |x| {
        const once = throughWire(posAt(x));
        const twice = throughWire(once);
        try testing.expectEqual(once.position[0].raw, twice.position[0].raw);
        try testing.expectEqual(once.velocity[0].raw, twice.velocity[0].raw);
        try testing.expectEqual(once.rotation[0].raw, twice.rotation[0].raw);
    }
}

test "the replica holds the authority's handles, not its own" {
    // world/hash.zig includes entity identity, so a client that allocated independently
    // would hold a world identical in every component and still hash differently --
    // reporting a desync between two peers in complete agreement.
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var client = try newWorld(gpa);
    defer client.deinit();

    // Make the server's handles non-trivial: spawn several, drop one, spawn again, so the
    // free list has been exercised and the next handle is not simply "the next index".
    var handles: [8]Entity = undefined;
    for (&handles) |*h| h.* = try server.spawn(unit());
    _ = server.despawn(handles[3]);
    const late = try server.spawn(posAt(99));

    _ = try replicate(gpa, &server, &client);

    for (handles, 0..) |h, i| {
        if (i == 3) continue;
        try testing.expect(client.isLive(h));
    }
    try testing.expect(client.isLive(late));
    try testing.expect(!client.isLive(handles[3]));
}

test "two replicas of one authority agree on the canonical world hash" {
    // The property the replication path actually produces, and the one that matters: every
    // client of a server holds the SAME world, byte for byte, under §7's canonical digest.
    //
    // Not client-vs-server: the wire quantizes, so the authority and its replicas are
    // supposed to differ. Client-vs-client is the assertion with teeth, because any
    // nondeterminism in encode or apply -- iteration order, a field read from uninitialized
    // memory, a mask applied inconsistently -- shows up here and nowhere else.
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var a = try newWorld(gpa);
    defer a.deinit();
    var b = try newWorld(gpa);
    defer b.deinit();

    for (0..32) |i| _ = try server.spawn(posAt(@intCast(i)));
    _ = try replicate(gpa, &server, &a);
    _ = try replicate(gpa, &server, &b);

    const ha = try world_mod.hash.hashWorld(gpa, &a);
    const hb = try world_mod.hash.hashWorld(gpa, &b);
    try testing.expectEqualSlices(u8, &ha, &hb);

    // And a replica of a replica is the same world again -- quantization having already
    // happened, the second hop is lossless.
    var c = try newWorld(gpa);
    defer c.deinit();
    _ = try replicate(gpa, &a, &c);
    const hc = try world_mod.hash.hashWorld(gpa, &c);
    try testing.expectEqualSlices(u8, &ha, &hc);
}

test "a despawn removes the entity and a repeat is counted, not fatal" {
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var client = try newWorld(gpa);
    defer client.deinit();

    const e = try server.spawn(posAt(1));
    _ = try replicate(gpa, &server, &client);
    try testing.expect(client.isLive(e));

    var buf: [256]u8 = undefined;
    var bw = wire.bits.Writer.init(&buf);
    var fw = try Writer.begin(&bw, 1, 2);
    try fw.writeDespawn(e);
    try fw.writeDespawn(e); // duplicate
    fw.finish();

    var br = wire.bits.Reader.init(buf[0..bw.bytesWritten()]);
    const applied = try apply(Transform, TCols, &client, &br, unit());

    try testing.expectEqual(@as(u32, 1), applied.despawned);
    try testing.expectEqual(@as(u32, 1), applied.unknown);
    try testing.expect(!client.isLive(e));
}

test "re-describing a known entity updates rather than duplicating" {
    // A snapshot may legitimately re-describe an entity the client already has. Treating
    // that as an error would end the session over a duplicate.
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var client = try newWorld(gpa);
    defer client.deinit();

    const e = try server.spawn(posAt(1));
    _ = try replicate(gpa, &server, &client);

    _ = server.set(e, "position", posAt(42).position);
    const applied = try replicate(gpa, &server, &client);

    try testing.expectEqual(@as(u32, 1), applied.updated);
    try testing.expectEqual(@as(u32, 0), applied.spawned);
    try testing.expectEqual(@as(u32, 1), client.liveCount());
    try testing.expectEqual(throughWire(posAt(42)).position[0].raw, client.get(e, "position").?[0].raw);
}

test "a partial mask leaves the other fields alone" {
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var client = try newWorld(gpa);
    defer client.deinit();

    const e = try server.spawn(posAt(5));
    _ = try replicate(gpa, &server, &client);

    // Send only field 0 (position), with a different velocity that must NOT arrive.
    var changed = posAt(11);
    changed.velocity[0] = Fixed.fromInt(9);

    var buf: [512]u8 = undefined;
    var bw = wire.bits.Writer.init(&buf);
    var fw = try Writer.begin(&bw, 2, 3);
    try fw.writeUpdate(Transform, e, changed, 0b001);
    fw.finish();

    var br = wire.bits.Reader.init(buf[0..bw.bytesWritten()]);
    _ = try apply(Transform, TCols, &client, &br, unit());

    try testing.expectEqual(throughWire(posAt(11)).position[0].raw, client.get(e, "position").?[0].raw);
    try testing.expectEqual(Fixed.ZERO.raw, client.get(e, "velocity").?[0].raw);
}

test "the count is patched, so a budget-truncated frame is still well-formed" {
    // The record count is not known in advance -- the budget decides how many fit, and
    // reserving a maximum would waste the bits the budget exists to save.
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var client = try newWorld(gpa);
    defer client.deinit();

    var buf: [4096]u8 = undefined;
    var bw = wire.bits.Writer.init(&buf);
    var fw = try Writer.begin(&bw, 9, 4);
    for (0..5) |i| {
        const e = try server.spawn(posAt(@intCast(i)));
        try fw.writeUpdate(Transform, e, posAt(@intCast(i)), full_mask);
    }
    fw.finish();

    var br = wire.bits.Reader.init(buf[0..bw.bytesWritten()]);
    const applied = try apply(Transform, TCols, &client, &br, unit());
    try testing.expectEqual(@as(u16, 5), fw.count);
    try testing.expectEqual(@as(u32, 5), applied.spawned);
    try testing.expectEqual(@as(u64, 9), applied.tick);
    try testing.expectEqual(@as(u64, 4), applied.snapshot);
}

test "a frame claiming more records than it carries is refused, not truncated" {
    // The untrusted side of a trust boundary. A partial world update applied as if
    // complete is a desync, and one that reads past its buffer is worse.
    const gpa = testing.allocator;
    var client = try newWorld(gpa);
    defer client.deinit();

    var buf: [64]u8 = @splat(0);
    var bw = wire.bits.Writer.init(&buf);
    try bw.writeBits(1, 64); // tick
    try bw.writeBits(1, 64); // snapshot
    try bw.writeBits(500, 16); // count, wildly more than the bytes hold

    var br = wire.bits.Reader.init(buf[0..bw.bytesWritten()]);
    try testing.expectError(error.EndOfStream, apply(Transform, TCols, &client, &br, unit()));
}

test "an absurd record count is refused immediately" {
    const gpa = testing.allocator;
    var client = try newWorld(gpa);
    defer client.deinit();

    var buf: [64]u8 = @splat(0xFF);
    var br = wire.bits.Reader.init(&buf);
    try testing.expectError(Error.TooManyRecords, apply(Transform, TCols, &client, &br, unit()));
}

test "a long run of spawns, updates and despawns keeps every replica identical" {
    // The end-to-end property, over a stream that exercises every record type and the
    // entity allocator's free list. Two independent replicas of one authority, compared at
    // EVERY step rather than only at the end: a divergence that self-corrects is still a
    // divergence, and §14.3 needs the first tick it happened, not the last.
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var a = try newWorld(gpa);
    defer a.deinit();
    var b = try newWorld(gpa);
    defer b.deinit();

    var live: std.ArrayList(Entity) = .empty;
    defer live.deinit(gpa);

    var seed: u32 = 0xBED1A3;
    for (0..200) |round| {
        seed = seed *% 1664525 +% 1013904223;

        switch ((seed >> 16) % 3) {
            0 => try live.append(gpa, try server.spawn(posAt(@intCast(round % 100)))),
            1 => if (live.items.len > 0) {
                const idx = (seed >> 8) % live.items.len;
                _ = server.set(live.items[idx], "position", posAt(@intCast(seed % 50)).position);
            },
            else => if (live.items.len > 0) {
                const idx = (seed >> 8) % live.items.len;
                const e = live.swapRemove(idx);
                _ = server.despawn(e);
                // The despawn must be transmitted, or each replica keeps a ghost.
                var buf: [256]u8 = undefined;
                var bw = wire.bits.Writer.init(&buf);
                var fw = try Writer.begin(&bw, server.tick, round);
                try fw.writeDespawn(e);
                fw.finish();
                for ([_]*TestWorld{ &a, &b }) |w| {
                    var br = wire.bits.Reader.init(buf[0..bw.bytesWritten()]);
                    _ = try apply(Transform, TCols, w, &br, unit());
                }
            },
        }

        server.advanceTick();
        a.advanceTick();
        b.advanceTick();
        _ = try replicate(gpa, &server, &a);
        _ = try replicate(gpa, &server, &b);

        const ha = try world_mod.hash.hashWorld(gpa, &a);
        const hb = try world_mod.hash.hashWorld(gpa, &b);
        try testing.expectEqualSlices(u8, &ha, &hb);
    }

    try testing.expect(server.liveCount() > 10);
    try testing.expectEqual(server.liveCount(), a.liveCount());
}

test "a resting entity does not drift across replication" {
    // The bug `maxQuantized` was changed to fix, stated where it would be noticed. With an
    // odd level count zero is not on the grid, so an object at rest replicates as moving
    // -- consistently, which reads as a physics bug rather than a wire bug.
    const gpa = testing.allocator;
    var server = try newWorld(gpa);
    defer server.deinit();
    var client = try newWorld(gpa);
    defer client.deinit();

    const e = try server.spawn(unit()); // zero position, zero velocity, identity rotation

    // Replicate repeatedly. If zero were off-grid, each hop would move it again.
    for (0..64) |_| _ = try replicate(gpa, &server, &client);

    for (0..3) |i| {
        try testing.expectEqual(@as(i64, 0), client.get(e, "position").?[i].raw);
        try testing.expectEqual(@as(i64, 0), client.get(e, "velocity").?[i].raw);
    }
}
