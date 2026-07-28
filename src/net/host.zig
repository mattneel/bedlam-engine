//! The authoritative host: many clients, one world.
//!
//! `outbound.zig` is one client's send state. This is the thing that owns several of them
//! and the world they describe. `ARCHITECTURE.md` §14.1 makes the host authoritative and
//! §2 makes the editor the engine in a client mode — so "64 concurrent editors" and "64
//! concurrent players" are the same object, and this is it.
//!
//! **Transport-agnostic, like `session.zig` and for the same reason.** A client is
//! identified by an opaque `Endpoint` the caller assigns; whether that is a UDP address, a
//! WebSocket connection or a loopback test harness is not this file's business. The host
//! never performs I/O: it produces datagrams and consumes them, and the caller moves bytes.
//! That is what lets one host serve native and browser clients simultaneously, which is the
//! whole point of the editor-over-a-link story.
//!
//! **No allocation per tick.** §18.8. Client slots, their outbound state and their scratch
//! are allocated at `init` and reused. A host that allocated per client per tick would do
//! it 64 times per tick at exactly the moment it has least headroom.
//!
//! **Every client gets its own baseline, and that is not an optimization.** Two clients
//! acknowledge different snapshots, so a delta computed against a shared baseline would be
//! correct for at most one of them and silently wrong for the rest. `baseline.zig` was
//! already per-client; this is what finally uses that.

const std = @import("std");
const wire = @import("bedlam_wire");
const world_mod = @import("bedlam_world");
const session_mod = @import("session.zig");
const outbound_mod = @import("outbound.zig");
const replicate = @import("replicate.zig");

pub const Entity = world_mod.entity.Entity;
pub const Session = session_mod.Session;

/// Opaque transport identity. The host compares these for equality and nothing else.
///
/// A `u64` rather than an address type because the host serves UDP and WebSocket clients at
/// once and must not know the difference — `platform/udp.zig` hashes a peer key into one of
/// these, and a WebSocket connection is just its slot index.
pub const Endpoint = u64;

pub const ClientId = u16;
pub const invalid_client: ClientId = std.math.maxInt(ClientId);

pub const Error = error{
    Full,
    UnknownClient,
};

pub const Stats = struct {
    joined: u64 = 0,
    left: u64 = 0,
    /// Handshakes refused. Broken out by reason in the session's own `reject_reason`; the
    /// count here is what tells an operator that clients are failing to connect at all.
    rejected: u64 = 0,
    /// Datagrams that matched no client and were not a hello. Ordinary background noise on
    /// a public port; a large number is a scan or a client that thinks it is still
    /// connected.
    unmatched: u64 = 0,
    ticks: u64 = 0,
};

pub fn Host(
    comptime Columns: type,
    comptime max_clients: usize,
    comptime max_inflight: usize,
    comptime max_per_snapshot: usize,
) type {
    return struct {
        const Self = @This();
        pub const OutboundType = outbound_mod.Outbound(Columns, max_inflight, max_per_snapshot);

        pub const Client = struct {
            live: bool = false,
            endpoint: Endpoint = 0,
            session: Session = undefined,
            out: OutboundType = undefined,
            /// Which packet sequence carried which snapshot.
            ///
            /// The session's ack window is in SEQUENCE space and the baseline is in
            /// SNAPSHOT space; something has to hold the correspondence, and it is sized to
            /// the in-flight ring because a snapshot older than that can no longer be
            /// acknowledged anyway.
            seq_of: [max_inflight]u32 = @splat(0),
            snap_id: [max_inflight]u64 = @splat(0),
            snap_live: [max_inflight]bool = @splat(false),
        };

        gpa: std.mem.Allocator,
        clients: []Client,
        fingerprint: [64]u8,
        /// Server secret for retry tokens. Never leaves this process.
        secret: [32]u8,
        require_validation: bool,
        stats: Stats = .{},

        /// Connection ids the host hands out.
        ///
        /// Drawn from a counter mixed with the secret rather than allocated sequentially: a
        /// guessable connection id lets an off-path attacker inject into a session it
        /// cannot observe, because the id is what routes a packet once the handshake is
        /// done. A real deployment should use a CSPRNG; this is a deterministic stand-in
        /// that is at least not the slot index.
        next_connection: u64 = 1,

        pub fn init(
            gpa: std.mem.Allocator,
            fingerprint: [64]u8,
            secret: [32]u8,
            require_validation: bool,
        ) !Self {
            const clients = try gpa.alloc(Client, max_clients);
            errdefer gpa.free(clients);
            for (clients) |*c| c.* = .{};

            return .{
                .gpa = gpa,
                .clients = clients,
                .fingerprint = fingerprint,
                .secret = secret,
                .require_validation = require_validation,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.clients) |*c| {
                if (c.live) c.out.deinit();
            }
            self.gpa.free(self.clients);
            self.* = undefined;
        }

        pub fn count(self: Self) u32 {
            var n: u32 = 0;
            for (self.clients) |c| {
                if (c.live) n += 1;
            }
            return n;
        }

        pub fn find(self: *Self, endpoint: Endpoint) ?ClientId {
            for (self.clients, 0..) |c, i| {
                if (c.live and c.endpoint == endpoint) return @intCast(i);
            }
            return null;
        }

        fn freeSlot(self: *Self) ?ClientId {
            for (self.clients, 0..) |c, i| {
                if (!c.live) return @intCast(i);
            }
            return null;
        }

        fn deriveConnection(self: *Self) u32 {
            // Mixed with the secret so the id is not the slot index and not a counter an
            // observer can predict from someone else's connection.
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(&self.secret);
            var le: [8]u8 = undefined;
            std.mem.writeInt(u64, &le, self.next_connection, .little);
            h.update(&le);
            self.next_connection += 1;

            var digest: [32]u8 = undefined;
            h.final(&digest);
            const id = std.mem.readInt(u32, digest[0..4], .little);
            // Zero is reserved: a hello carries connection 0 because the client does not yet
            // know the server's id, so a client whose id was 0 could not be distinguished
            // from an unrouted packet.
            return if (id == 0) 1 else id;
        }

        /// What arrived on the wire, after routing.
        pub const Incoming = union(enum) {
            /// A hello that must be answered with the bytes in `reply`.
            handshake: struct { reply: []const u8, client: ?ClientId },
            /// Payload from an established client.
            data: struct { client: ClientId, payload: []const u8 },
            /// A client closed cleanly.
            bye: ClientId,
            /// Nothing to do, and nothing to send.
            ignored,
        };

        /// Route one datagram. The caller sends `reply` back to `endpoint` when present.
        ///
        /// `peer_key` is whatever the transport considers a stable identity for the sender,
        /// used only for the retry token. `platform/udp.zig` supplies address+port; a
        /// WebSocket supplies the connection's remote address. The host does not interpret
        /// it.
        pub fn receive(
            self: *Self,
            endpoint: Endpoint,
            peer_key: []const u8,
            datagram: []const u8,
            reply_buf: []u8,
            payload_buf: []u8,
        ) Incoming {
            if (self.find(endpoint)) |id| {
                const c = &self.clients[id];
                const got = c.session.receive(datagram, payload_buf) catch return .ignored;
                switch (got) {
                    .data => |p| return .{ .data = .{ .client = id, .payload = p } },
                    .bye => {
                        self.drop(id);
                        return .{ .bye = id };
                    },
                    .ping, .discarded => return .ignored,
                }
            }

            // Not a known endpoint, so the only thing it may legitimately be is a hello.
            var probe = Session.init(0, self.fingerprint, .{});
            const token = session_mod.retryToken(self.secret, peer_key);
            const verdict = probe.serverEvaluate(datagram, token, self.require_validation) catch {
                self.stats.unmatched += 1;
                return .ignored;
            };

            switch (verdict) {
                .retry => |t| {
                    const n = probe.writeRetry(t, reply_buf);
                    return .{ .handshake = .{ .reply = reply_buf[0..n], .client = null } };
                },
                .reject => |r| {
                    self.stats.rejected += 1;
                    const n = probe.writeReject(r, reply_buf);
                    return .{ .handshake = .{ .reply = reply_buf[0..n], .client = null } };
                },
                .accept => |hello| {
                    const id = self.freeSlot() orelse {
                        // Full is a REJECTION, not silence. A client that hears nothing
                        // retries forever and cannot tell a full server from a dead one.
                        self.stats.rejected += 1;
                        const n = probe.writeReject(.server_full, reply_buf);
                        return .{ .handshake = .{ .reply = reply_buf[0..n], .client = null } };
                    };

                    const c = &self.clients[id];
                    c.* = .{
                        .live = true,
                        .endpoint = endpoint,
                        .session = Session.init(self.deriveConnection(), self.fingerprint, .{}),
                        .out = OutboundType.init(self.gpa) catch {
                            c.live = false;
                            self.stats.rejected += 1;
                            const n = probe.writeReject(.server_full, reply_buf);
                            return .{ .handshake = .{ .reply = reply_buf[0..n], .client = null } };
                        },
                    };

                    const n = c.session.serverAccept(hello, reply_buf);
                    self.stats.joined += 1;
                    return .{ .handshake = .{ .reply = reply_buf[0..n], .client = id } };
                },
            }
        }

        /// Everything in the world becomes relevant to this client.
        ///
        /// Interest management (§9.4) is what makes 64 players affordable and it is not here
        /// yet. For an editor the shared scene IS the interest set — every editor sees the
        /// whole document — so this is correct for that case and a placeholder for the
        /// other. Stated so it is not mistaken for the finished thing.
        pub fn interestAll(self: *Self, id: ClientId, w: anytype) !void {
            if (id >= self.clients.len or !self.clients[id].live) return Error.UnknownClient;
            const c = &self.clients[id];
            var it = w.table.chunkIterator();
            while (it.next()) |chunk| {
                for (chunk.liveEntities()) |e| try c.out.setInterest(e, true);
            }
        }

        pub fn drop(self: *Self, id: ClientId) void {
            if (id >= self.clients.len or !self.clients[id].live) return;
            self.clients[id].out.deinit();
            self.clients[id] = .{};
            self.stats.left += 1;
        }

        /// Assemble this client's next snapshot into `buf`, ready to send.
        ///
        /// Returns null when the client has nothing owed — an unchanged world costs an
        /// empty frame, not a full one, which is the entire reason `baseline.zig` exists.
        pub fn assemble(
            self: *Self,
            comptime decl: anytype,
            id: ClientId,
            w: anytype,
            buf: []u8,
            budget_bytes: u64,
            decl_fallback: wire.codec.Storage(decl),
        ) !?[]const u8 {
            if (id >= self.clients.len or !self.clients[id].live) return Error.UnknownClient;
            const c = &self.clients[id];
            if (!c.session.isEstablished()) return null;

            var frame: [4096]u8 = undefined;
            const room = @min(frame.len, budget_bytes);
            var bw = wire.bits.Writer.init(frame[0..room]);
            var fw = try replicate.Writer.begin(&bw, w.tick, 0);
            const snap = try c.out.assemble(decl, w, &fw, room, 1, decl_fallback);
            fw.finish();

            if (fw.count == 0) return null;

            const seq = c.session.next_sequence;
            const n = c.session.writeData(frame[0..bw.bytesWritten()], buf) catch return null;

            const ring: usize = @intCast(snap % max_inflight);
            c.seq_of[ring] = seq;
            c.snap_id[ring] = snap;
            c.snap_live[ring] = true;
            return buf[0..n];
        }

        /// Promote every snapshot the session's ack window says arrived.
        ///
        /// Driven by acks rather than by sends, which is the whole point of `outbound.zig`:
        /// a baseline advanced to a snapshot the client never received makes every later
        /// delta a description of a state that exists nowhere.
        pub fn absorbAcks(self: *Self, id: ClientId) !void {
            if (id >= self.clients.len or !self.clients[id].live) return Error.UnknownClient;
            const c = &self.clients[id];
            for (0..max_inflight) |k| {
                if (!c.snap_live[k]) continue;
                if (c.session.peerAcked(c.seq_of[k])) {
                    _ = c.out.onAck(c.snap_id[k]) catch {};
                    c.snap_live[k] = false;
                }
            }
        }

        /// Advance every client's timers, dropping those that timed out.
        ///
        /// Returns how many were dropped. A silent timeout is how a server accumulates dead
        /// slots until it reports itself full to clients that could have joined.
        pub fn tick(self: *Self) u32 {
            self.stats.ticks += 1;
            var dropped: u32 = 0;
            for (self.clients, 0..) |*c, i| {
                if (!c.live) continue;
                _ = c.session.tick();
                if (c.session.hasTimedOut()) {
                    self.drop(@intCast(i));
                    dropped += 1;
                }
            }
            return dropped;
        }

        pub fn sessionOf(self: *Self, id: ClientId) ?*Session {
            if (id >= self.clients.len or !self.clients[id].live) return null;
            return &self.clients[id].session;
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
const TestHost = Host(TCols, 4, 8, 128);
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

fn fp(byte: u8) [64]u8 {
    return @splat(byte);
}

/// Drive a client through the handshake against the host, in memory.
fn connect(h: *TestHost, client: *Session, endpoint: Endpoint, key: []const u8) !ClientId {
    var buf: [session_mod.max_datagram]u8 = undefined;
    var payload: [session_mod.max_datagram]u8 = undefined;
    var reply: [session_mod.max_datagram]u8 = undefined;

    var n = client.clientHello(&buf, @splat(0));
    var rounds: u32 = 0;
    while (rounds < 4) : (rounds += 1) {
        const got = h.receive(endpoint, key, buf[0..n], &reply, &payload);
        switch (got) {
            .handshake => |hs| {
                if (try client.clientReceive(hs.reply)) |token| {
                    n = client.clientHello(&buf, token);
                    continue;
                }
                if (client.isEstablished()) return hs.client orelse return error.NoClientId;
                return error.HandshakeStalled;
            },
            else => return error.UnexpectedVerdict,
        }
    }
    return error.HandshakeStalled;
}

test "two clients join and get different connection ids" {
    // A guessable connection id lets an off-path attacker inject into a session it cannot
    // observe, because the id is what routes a packet once the handshake is done. The slot
    // index would be the worst possible choice and the most obvious one.
    const gpa = testing.allocator;
    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    var a = Session.init(0x1111, fp(0xAB), .{});
    var b = Session.init(0x2222, fp(0xAB), .{});

    const ia = try connect(&h, &a, 1, "peer-a");
    const ib = try connect(&h, &b, 2, "peer-b");

    try testing.expect(ia != ib);
    try testing.expectEqual(@as(u32, 2), h.count());

    const ca = h.sessionOf(ia).?.local_connection;
    const cb = h.sessionOf(ib).?.local_connection;
    try testing.expect(ca != cb);
    try testing.expect(ca != ia and cb != ib); // not the slot index
    try testing.expect(ca != 0 and cb != 0); // zero is reserved for an unrouted packet
}

test "a full host rejects rather than going silent" {
    // A client that hears nothing retries forever and cannot tell a full server from a dead
    // one. Refusing with a reason is what lets a UI say something true.
    const gpa = testing.allocator;
    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    var sessions: [4]Session = undefined;
    for (&sessions, 0..) |*s, i| {
        s.* = Session.init(@intCast(0x1000 + i), fp(0xAB), .{});
        _ = try connect(&h, s, @intCast(i + 1), "peer");
    }
    try testing.expectEqual(@as(u32, 4), h.count());

    var extra = Session.init(0x9999, fp(0xAB), .{});
    var buf: [session_mod.max_datagram]u8 = undefined;
    var reply: [session_mod.max_datagram]u8 = undefined;
    var payload: [session_mod.max_datagram]u8 = undefined;

    const n = extra.clientHello(&buf, @splat(0));
    const got = h.receive(99, "peer-x", buf[0..n], &reply, &payload);
    try testing.expectError(session_mod.Error.Rejected, extra.clientReceive(got.handshake.reply));
    try testing.expectEqual(session_mod.RejectReason.server_full, extra.reject_reason.?);
}

test "a client built against a different schema is refused at the door" {
    const gpa = testing.allocator;
    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    var wrong = Session.init(0x1111, fp(0xCD), .{});
    var buf: [session_mod.max_datagram]u8 = undefined;
    var reply: [session_mod.max_datagram]u8 = undefined;
    var payload: [session_mod.max_datagram]u8 = undefined;

    const n = wrong.clientHello(&buf, @splat(0));
    const got = h.receive(1, "peer", buf[0..n], &reply, &payload);
    try testing.expectError(session_mod.Error.Rejected, wrong.clientReceive(got.handshake.reply));
    try testing.expectEqual(session_mod.RejectReason.schema_mismatch, wrong.reject_reason.?);
    try testing.expectEqual(@as(u32, 0), h.count());
}

test "every client converges on the authority's world" {
    // The claim the editor rests on: several clients, one document, and each replica ends up
    // holding what the host holds. Client-vs-client rather than client-vs-host, because the
    // wire quantizes -- see SPEC_DEFECTS §15.
    const gpa = testing.allocator;
    var world = try TestWorld.init(gpa, 4096, ids);
    defer world.deinit();
    for (0..12) |i| _ = try world.spawn(posAt(@intCast(i)));

    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    var replicas: [3]TestWorld = undefined;
    var sessions: [3]Session = undefined;
    var client_ids: [3]ClientId = undefined;
    for (&replicas) |*r| r.* = try TestWorld.init(gpa, 4096, ids);
    defer for (&replicas) |*r| r.deinit();

    for (&sessions, 0..) |*s, i| {
        s.* = Session.init(@intCast(0x1000 + i), fp(0xAB), .{});
        client_ids[i] = try connect(&h, s, @intCast(i + 1), "peer");
        try h.interestAll(client_ids[i], &world);
    }

    var buf: [session_mod.max_datagram]u8 = undefined;
    var payload: [session_mod.max_datagram]u8 = undefined;

    // Enough ticks for the whole world to reach every client through the budget.
    for (0..40) |_| {
        for (client_ids, 0..) |id, i| {
            const frame = (try h.assemble(Transform, id, &world, &buf, 1000, unit())) orelse continue;
            const got = sessions[i].receive(frame, &payload) catch continue;
            if (got == .data) {
                var r = wire.bits.Reader.init(got.data);
                _ = try replicate.apply(Transform, TCols, &replicas[i], &r, unit(), unit());
                // The client's ack rides on its next packet; feed it straight back.
                var ack: [session_mod.max_datagram]u8 = undefined;
                const an = sessions[i].writePing(&ack) catch continue;
                _ = h.sessionOf(id).?.receive(ack[0..an], &payload) catch {};
            }
            try h.absorbAcks(id);
        }
        world.advanceTick();
        for (&replicas) |*r| r.advanceTick();
    }

    for (&replicas) |*r| try testing.expectEqual(world.liveCount(), r.liveCount());

    const d0 = try world_mod.hash.hashWorld(gpa, &replicas[0]);
    for (replicas[1..]) |*r| {
        const d = try world_mod.hash.hashWorld(gpa, r);
        try testing.expectEqualSlices(u8, &d0, &d);
    }
}

test "clients hold independent baselines" {
    // Two clients acknowledge different snapshots, so a delta computed against a shared
    // baseline is correct for at most one of them and silently wrong for the rest.
    const gpa = testing.allocator;
    var world = try TestWorld.init(gpa, 4096, ids);
    defer world.deinit();
    const e = try world.spawn(posAt(1));

    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    var a = Session.init(0x1111, fp(0xAB), .{});
    var b = Session.init(0x2222, fp(0xAB), .{});
    const ia = try connect(&h, &a, 1, "peer-a");
    const ib = try connect(&h, &b, 2, "peer-b");
    try h.interestAll(ia, &world);
    try h.interestAll(ib, &world);

    var buf: [session_mod.max_datagram]u8 = undefined;
    var payload: [session_mod.max_datagram]u8 = undefined;

    // Only client A acknowledges. B's baseline must not advance with it.
    const fa = (try h.assemble(Transform, ia, &world, &buf, 1000, unit())).?;
    _ = a.receive(fa, &payload) catch {};
    var ack: [session_mod.max_datagram]u8 = undefined;
    const an = try a.writePing(&ack);
    _ = h.sessionOf(ia).?.receive(ack[0..an], &payload) catch {};
    try h.absorbAcks(ia);

    _ = (try h.assemble(Transform, ib, &world, &buf, 1000, unit())).?;
    try h.absorbAcks(ib);

    try testing.expect(h.clients[ia].out.base.record(e) != null);
    try testing.expect(h.clients[ib].out.base.record(e) == null);
}

test "an unchanged world costs an empty frame, not a full one" {
    const gpa = testing.allocator;
    var world = try TestWorld.init(gpa, 4096, ids);
    defer world.deinit();
    _ = try world.spawn(posAt(1));

    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();
    var c = Session.init(0x1111, fp(0xAB), .{});
    const id = try connect(&h, &c, 1, "peer");
    try h.interestAll(id, &world);

    var buf: [session_mod.max_datagram]u8 = undefined;
    var payload: [session_mod.max_datagram]u8 = undefined;

    const first = (try h.assemble(Transform, id, &world, &buf, 1000, unit())).?;
    _ = c.receive(first, &payload) catch {};
    var ack: [session_mod.max_datagram]u8 = undefined;
    const an = try c.writePing(&ack);
    _ = h.sessionOf(id).?.receive(ack[0..an], &payload) catch {};
    try h.absorbAcks(id);

    // Nothing changed, so there is nothing owed.
    try testing.expect((try h.assemble(Transform, id, &world, &buf, 1000, unit())) == null);
}

test "a timed-out client frees its slot" {
    // A silent timeout is how a server accumulates dead slots until it reports itself full
    // to clients that could have joined.
    const gpa = testing.allocator;
    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    var c = Session.init(0x1111, fp(0xAB), .{});
    const id = try connect(&h, &c, 1, "peer");
    try testing.expectEqual(@as(u32, 1), h.count());

    var dropped: u32 = 0;
    for (0..1000) |_| dropped += h.tick();

    try testing.expectEqual(@as(u32, 1), dropped);
    try testing.expectEqual(@as(u32, 0), h.count());
    try testing.expect(h.sessionOf(id) == null);
    try testing.expectEqual(@as(u64, 1), h.stats.left);
}

test "a bye frees the slot immediately" {
    const gpa = testing.allocator;
    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    var c = Session.init(0x1111, fp(0xAB), .{});
    const id = try connect(&h, &c, 1, "peer");

    var buf: [session_mod.max_datagram]u8 = undefined;
    var reply: [session_mod.max_datagram]u8 = undefined;
    var payload: [session_mod.max_datagram]u8 = undefined;
    const n = c.writeBye(&buf);

    const got = h.receive(1, "peer", buf[0..n], &reply, &payload);
    try testing.expectEqual(TestHost.Incoming{ .bye = id }, got);
    try testing.expectEqual(@as(u32, 0), h.count());
}

test "a slot is reusable after a client leaves" {
    // The allocation lives with the slot, so a host that leaked on rejoin would fail after
    // exactly max_clients connections rather than at a sensible boundary.
    const gpa = testing.allocator;
    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    for (0..12) |i| {
        var c = Session.init(@intCast(0x1000 + i), fp(0xAB), .{});
        const id = try connect(&h, &c, @intCast(i + 1), "peer");
        h.drop(id);
    }
    try testing.expectEqual(@as(u32, 0), h.count());
    try testing.expectEqual(@as(u64, 12), h.stats.joined);
    try testing.expectEqual(@as(u64, 12), h.stats.left);
}

test "address validation is enforced when required" {
    const gpa = testing.allocator;
    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), true);
    defer h.deinit();

    var c = Session.init(0x1111, fp(0xAB), .{});
    const id = try connect(&h, &c, 1, "peer-key");
    try testing.expect(c.isEstablished());
    try testing.expectEqual(@as(u32, 1), h.count());
    _ = id;
}

test "noise on the port is counted, not acted on" {
    const gpa = testing.allocator;
    var h = try TestHost.init(gpa, fp(0xAB), @splat(0x5A), false);
    defer h.deinit();

    var reply: [session_mod.max_datagram]u8 = undefined;
    var payload: [session_mod.max_datagram]u8 = undefined;
    const junk = [_]u8{0x41} ** 64;

    try testing.expectEqual(TestHost.Incoming.ignored, h.receive(7, "scanner", &junk, &reply, &payload));
    try testing.expectEqual(@as(u32, 0), h.count());
    try testing.expectEqual(@as(u64, 1), h.stats.unmatched);
}
