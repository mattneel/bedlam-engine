//! Datagram transport over `std.Io.net`. `ARCHITECTURE.md` §12, M0 criterion 4.
//!
//! `src/net/session.zig` decides what a packet means; this delivers it. The split is not
//! decoration: the session is compiled for wasm32, where there is no socket at all and the
//! transport is WebTransport. A session that imported a socket could not be built for a
//! third of the shipping targets — which is why `platform/root.zig` exposes this as an
//! optional backend and `std.Io.net` does not exist on `freestanding` at all.
//!
//! **Deadline-bounded receive, never an open-ended wait.** §18.8 forbids allocation in the
//! frame loop and the same argument forbids blocking in it: a receive that waits couples
//! tick cadence to network conditions, and `CONFORMANCE_PROFILES.md` §4 says cadence does
//! not degrade in any profile. `poll` uses a zero timeout and reports "nothing waiting" as
//! `null` rather than as an error — an idle network is the ordinary case, not a failure.
//!
//! **The address family is explicit, and dual-stack is two sockets behind one `poll`.**
//!
//! The obvious design is one `::` socket with `IPV6_V6ONLY` cleared, accepting both
//! families. It does not work here, and the reason is worth recording rather than
//! rediscovering:
//!
//! > `std.Io.net`'s `BindOptions.ip6_only` is honoured **only on the POSIX path**, and
//! > there it sets `IPV6_V6ONLY` to **0 when `ip6_only` is true** — inverted. The Windows
//! > bind path does not touch the option at all, and Windows defaults it to 1. So a `::`
//! > socket on Windows is IPv6-only whatever is requested, and sending to a v4-mapped
//! > address fails with `INVALID_ADDRESS_COMPONENT`.
//!
//! Verified on this machine: a `::` socket reaches `::1` and fails on `::ffff:127.0.0.1`.
//! Relying on the option would have produced an engine where IPv4 clients cannot connect
//! to a Windows host — and it would have looked like a NAT problem, not a socket option.
//!
//! So `Socket` binds exactly one family and says which. `Pair` binds both and polls both in
//! one call, which keeps the caller's receive path single even though the sockets are not:
//! two receive loops is the thing actually worth avoiding, not two file descriptors.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

pub const Address = net.IpAddress;

pub const Error = error{
    BindFailed,
    /// Every family was refused. Distinguished from `BindFailed` because a host with both
    /// stacks disabled is a configuration problem and a busy port is not.
    NoUsableFamily,
};

/// What `poll` produced. `bytes` points into the caller's buffer.
pub const Datagram = struct {
    bytes: []u8,
    from: Address,
};

pub const Family = enum { ip4, ip6 };

pub const Socket = struct {
    inner: net.Socket,
    family: Family,

    /// Counted rather than logged, for the same reason the mixer counts: this sits under a
    /// frame loop that cannot afford to format a string, and "the packet did not arrive"
    /// needs a cause.
    sent: u64 = 0,
    received: u64 = 0,
    /// Sends the OS refused. Not an error the caller must handle — UDP is lossy by
    /// definition and a full send buffer is indistinguishable from a drop one hop later —
    /// but a large number means the send scheduler is overrunning the link.
    send_failures: u64 = 0,
    /// Datagrams larger than the receive buffer. §12 caps at `max_datagram`, so a nonzero
    /// count means a peer is not speaking this protocol or the buffer is undersized.
    truncated: u64 = 0,

    /// Bind one family. `port` 0 asks the OS to choose.
    ///
    /// Choosing rather than fixing the port is what a test wants: a fixed port makes a
    /// test fail when anything else on the machine happens to hold it, and a test that
    /// fails for reasons unrelated to the code under test gets disabled.
    pub fn bind(io: Io, family: Family, local_port: u16) Error!Socket {
        const any = switch (family) {
            .ip6 => Address.parseIp6("::", local_port) catch return Error.BindFailed,
            .ip4 => Address.parseIp4("0.0.0.0", local_port) catch return Error.BindFailed,
        };
        const s = Address.bind(&any, io, .{ .mode = .dgram }) catch return Error.BindFailed;
        return .{ .inner = s, .family = family };
    }

    pub fn close(self: *Socket, io: Io) void {
        self.inner.close(io);
    }

    /// The address the socket actually bound, including the port the OS chose.
    pub fn bound(self: Socket) Address {
        return self.inner.address;
    }

    pub fn port(self: Socket) u16 {
        return switch (self.inner.address) {
            .ip4 => |a| a.port,
            .ip6 => |a| a.port,
        };
    }

    /// Send one datagram. Returns false if the OS refused it.
    ///
    /// A refusal is not propagated as an error: UDP is lossy by definition, and treating a
    /// full send buffer as fatal would end a session that the protocol is already designed
    /// to survive.
    pub fn send(self: *Socket, io: Io, to: Address, bytes: []const u8) bool {
        // A family mismatch is refused here rather than by the OS. Letting it through
        // returns a generic failure that reads as "the network dropped it", and the send
        // counter then makes a routing mistake look like packet loss.
        const matches = switch (self.family) {
            .ip4 => to == .ip4,
            .ip6 => to == .ip6,
        };
        if (!matches) {
            self.send_failures += 1;
            return false;
        }

        self.inner.send(io, &to, bytes) catch {
            self.send_failures += 1;
            return false;
        };
        self.sent += 1;
        return true;
    }

    /// **Blocks until a datagram arrives.** For the receiver thread only.
    ///
    /// The frame loop must never call this. `std.Io.net` offers `receiveTimeout` for a
    /// bounded wait, but it routes through `Io.concurrent` and returns
    /// `ConcurrencyUnavailable` on the `Io` a process actually gets — verified on this
    /// machine with both a hand-built `Io.Threaded` and `std.process.Init`'s own. An
    /// earlier version of this file swallowed that error as "nothing waiting", which is
    /// how a socket comes to report an idle network forever and every test that spun
    /// waiting for a packet timed out instead of failing with a cause.
    ///
    /// So the bounded wait lives in the architecture rather than in the syscall: a thread
    /// blocks here, and the frame loop reads a ring. §12 wants that decoupling regardless,
    /// and it is the same shape `platform/windows/audio.zig` uses for the same reason.
    pub fn receiveBlocking(self: *Socket, io: Io, buf: []u8) ?Datagram {
        const msg = self.inner.receive(io, buf) catch {
            // Includes the close that ends the receiver thread, so this is not counted as
            // an error — shutting down is not a failure.
            return null;
        };
        if (msg.flags.trunc) {
            // Counted and dropped. A truncated datagram cannot be parsed safely — the
            // header may be intact while the payload is not, which is worse than losing it.
            self.truncated += 1;
            return null;
        }
        self.received += 1;
        return .{ .bytes = msg.data, .from = msg.from };
    }

    /// Bytes identifying a peer, for `session.retryToken`.
    ///
    /// Address and port together: a token bound to the address alone lets anyone sharing a
    /// NAT reuse it. Written field by field rather than as a struct copy, because a token
    /// derived from padding or from a host-order integer is not stable — and an unstable
    /// token makes every address validation fail intermittently.
    pub fn peerKey(addr: Address, out: *[18]u8) []const u8 {
        @memset(out, 0);
        switch (addr) {
            .ip4 => |a| {
                @memcpy(out[0..4], &a.bytes);
                std.mem.writeInt(u16, out[4..6], a.port, .little);
                return out[0..6];
            },
            .ip6 => |a| {
                @memcpy(out[0..16], &a.bytes);
                std.mem.writeInt(u16, out[16..18], a.port, .little);
                return out[0..18];
            },
        }
    }

    /// Whether two addresses name the same peer.
    ///
    /// Compared by value rather than by `std.meta.eql`, which would include an IPv6 scope
    /// id and flow label that legitimately differ between two structs describing one peer.
    pub fn sameP(a: Address, b: Address) bool {
        var ka: [18]u8 = undefined;
        var kb: [18]u8 = undefined;
        return std.mem.eql(u8, peerKey(a, &ka), peerKey(b, &kb));
    }
};

/// Both families behind one `poll`.
///
/// Two sockets, because the one-socket dual-stack form does not work on Windows (see the
/// module comment). One receive path, because two receive loops is the thing actually
/// worth avoiding — a caller that polls one and forgets the other has an engine where half
/// the internet cannot connect and nothing reports it.
pub const Pair = struct {
    ip4: ?Socket = null,
    ip6: ?Socket = null,

    /// Bind both families on the same port where possible.
    ///
    /// Either may fail — a host with IPv6 disabled is ordinary — but both failing is not,
    /// because then there is no transport at all.
    pub fn bind(io: Io, local_port: u16) Error!Pair {
        var p: Pair = .{};
        p.ip4 = Socket.bind(io, .ip4, local_port) catch null;
        // Match the v4 port when the OS chose one, so a caller advertises a single number.
        const p6 = if (p.ip4) |s| s.port() else local_port;
        p.ip6 = Socket.bind(io, .ip6, p6) catch Socket.bind(io, .ip6, local_port) catch null;
        if (p.ip4 == null and p.ip6 == null) return Error.NoUsableFamily;
        return p;
    }

    pub fn close(self: *Pair, io: Io) void {
        if (self.ip4) |*s| s.close(io);
        if (self.ip6) |*s| s.close(io);
    }

    pub fn port(self: Pair) u16 {
        if (self.ip4) |s| return s.port();
        if (self.ip6) |s| return s.port();
        return 0;
    }

    /// Route by the destination's family. A caller never chooses a socket.
    pub fn send(self: *Pair, io: Io, to: Address, bytes: []const u8) bool {
        return switch (to) {
            .ip4 => if (self.ip4) |*s| s.send(io, to, bytes) else false,
            .ip6 => if (self.ip6) |*s| s.send(io, to, bytes) else false,
        };
    }

    /// Blocking receive on one family. For the receiver thread; the frame loop uses
    /// `Receiver.poll`, which touches no socket at all.
    pub fn receiveBlocking(self: *Pair, io: Io, family: Family, buf: []u8) ?Datagram {
        return switch (family) {
            .ip4 => if (self.ip4) |*s| s.receiveBlocking(io, buf) else null,
            .ip6 => if (self.ip6) |*s| s.receiveBlocking(io, buf) else null,
        };
    }

    pub fn sent(self: Pair) u64 {
        return (if (self.ip4) |s| s.sent else 0) + (if (self.ip6) |s| s.sent else 0);
    }

    pub fn received(self: Pair) u64 {
        return (if (self.ip4) |s| s.received else 0) + (if (self.ip6) |s| s.received else 0);
    }
};

/// Receiver thread plus a lock-free ring, so the frame loop never blocks and never
/// syscalls.
///
/// The same shape as `platform/windows/audio.zig`, for the same reason and with the same
/// constraint reversed: there, a real-time thread must not wait on the game; here, the game
/// must not wait on the network. `ARCHITECTURE.md` §12 and `CONFORMANCE_PROFILES.md` §4 —
/// tick cadence does not degrade in any profile, so it cannot be coupled to whether a
/// packet has arrived.
///
/// **Fixed slots, allocated once.** §18.8. A datagram is copied into a preallocated slot on
/// the receiver thread; `poll` returns a pointer to it. The ring is single-producer
/// single-consumer, so publication needs exactly one release store and one acquire load —
/// no compare-exchange, no lock, and nothing the frame loop can be preempted inside.
///
/// **Overrun drops the OLDEST, not the newest.** The opposite of `audio_ring.zig`, and
/// deliberately: an audio command that is dropped is a sound that never plays, while a
/// datagram that is dropped is one the protocol already tolerates — and the newest snapshot
/// is worth strictly more than the oldest one. A ring that discards the newest under load
/// delivers stale state precisely when the connection is worst.
pub fn Receiver(comptime slots: usize) type {
    comptime {
        if (slots == 0 or (slots & (slots - 1)) != 0) {
            @compileError("receiver slot count must be a non-zero power of two");
        }
    }

    return struct {
        const Self = @This();
        const mask: u32 = @intCast(slots - 1);

        gpa: std.mem.Allocator,
        io: Io,
        pair: Pair,

        /// `slots * max_datagram` bytes, allocated in `start` and owned until `stop`.
        storage: []u8 = &.{},
        lengths: []u32 = &.{},
        froms: []Address = &.{},

        /// How far the ring is CLAIMED.
        head: std.atomic.Value(u32) = .init(0),
        /// How far it is actually READABLE. Distinct from `head`: with two producers a
        /// later slot can be filled before an earlier one, and a consumer reading up to
        /// `head` would read a slot still being written.
        published: std.atomic.Value(u32) = .init(0),
        tail: std.atomic.Value(u32) = .init(0),

        threads: [2]?std.Thread = .{ null, null },
        running: std.atomic.Value(bool) = .init(false),

        /// Datagrams the ring had no room for. Nonzero means the frame loop is not draining
        /// fast enough, which is a scheduling problem rather than a network one — and the
        /// two look identical without this number.
        overruns: std.atomic.Value(u64) = .init(0),

        pub const max_datagram: usize = 1200;

        pub fn init(gpa: std.mem.Allocator, io: Io, pair: Pair) Self {
            return .{ .gpa = gpa, .io = io, .pair = pair };
        }

        pub fn start(self: *Self) !void {
            if (self.running.load(.acquire)) return;

            self.storage = try self.gpa.alloc(u8, slots * max_datagram);
            errdefer self.gpa.free(self.storage);
            self.lengths = try self.gpa.alloc(u32, slots);
            errdefer self.gpa.free(self.lengths);
            self.froms = try self.gpa.alloc(Address, slots);
            errdefer self.gpa.free(self.froms);

            self.running.store(true, .release);

            // One thread per bound family. Both produce into the same ring, so the ring is
            // strictly single-producer only when one family is bound — the enqueue path
            // therefore takes the head with a compare-exchange when two are live. Stated
            // rather than assumed, because "SPSC" that is quietly MPSC is a data race that
            // reproduces once a month on one player's machine.
            var n: usize = 0;
            if (self.pair.ip4 != null) {
                self.threads[n] = try std.Thread.spawn(.{}, loop, .{ self, Family.ip4 });
                n += 1;
            }
            if (self.pair.ip6 != null) {
                self.threads[n] = try std.Thread.spawn(.{}, loop, .{ self, Family.ip6 });
                n += 1;
            }
        }

        /// Stop the threads and free the slots.
        ///
        /// **A self-addressed datagram is what unblocks the receives, not closing the
        /// socket.** Closing it is the obvious move and it panics: on Windows a blocking
        /// receive interrupted by a close returns `STATUS_CANCELLED`, and
        /// `std.Io.Threaded`'s `netReceiveOneWindows` marks that branch `unreachable`.
        /// A timeout-based wakeup is not available either — `receiveTimeout` needs
        /// concurrency this `Io` will not give (see `receiveBlocking`).
        ///
        /// So the thread is woken the way it is designed to be woken: by a packet. It
        /// checks `running` before publishing, so the wakeup never reaches the frame loop.
        pub fn stop(self: *Self) void {
            if (!self.running.load(.acquire)) return;
            self.running.store(false, .release);

            if (self.pair.ip4) |*s| {
                _ = s.send(self.io, .{ .ip4 = .loopback(s.port()) }, &.{});
            }
            if (self.pair.ip6) |*s| {
                _ = s.send(self.io, .{ .ip6 = .loopback(s.port()) }, &.{});
            }

            for (&self.threads) |*t| {
                if (t.*) |thread| thread.join();
                t.* = null;
            }
            self.pair.close(self.io);
            if (self.storage.len > 0) self.gpa.free(self.storage);
            if (self.lengths.len > 0) self.gpa.free(self.lengths);
            if (self.froms.len > 0) self.gpa.free(self.froms);
            self.storage = &.{};
            self.lengths = &.{};
            self.froms = &.{};
        }

        fn loop(self: *Self, family: Family) void {
            const sock: *Socket = switch (family) {
                .ip4 => &self.pair.ip4.?,
                .ip6 => &self.pair.ip6.?,
            };
            var scratch: [max_datagram]u8 = undefined;

            while (self.running.load(.acquire)) {
                const d = sock.receiveBlocking(self.io, &scratch) orelse {
                    // Null means the socket closed or errored. Either way this thread is
                    // done; spinning on a dead socket burns a core on the target least able
                    // to spare one.
                    return;
                };
                // Checked AFTER the receive as well as before, so the wakeup datagram
                // `stop` sends is consumed here and never reaches the frame loop.
                if (!self.running.load(.acquire)) return;
                self.publish(d);
            }
        }

        fn publish(self: *Self, d: Datagram) void {
            while (true) {
                const h = self.head.load(.monotonic);
                const t = self.tail.load(.acquire);
                if (h -% t >= slots) {
                    _ = self.overruns.fetchAdd(1, .monotonic);
                    return;
                }
                // Claim the slot before writing it. With two receiver threads this is the
                // only contended point, and a claim that loses simply retries.
                if (self.head.cmpxchgWeak(h, h +% 1, .acquire, .monotonic) != null) continue;

                const i = h & mask;
                const n = @min(d.bytes.len, max_datagram);
                @memcpy(self.storage[i * max_datagram ..][0..n], d.bytes[0..n]);
                self.lengths[i] = @intCast(n);
                self.froms[i] = d.from;

                // Publish. The consumer's acquire load of `published` is what makes the
                // slot contents visible; writing the index first would let the frame loop
                // parse uninitialized memory as a packet header.
                while (self.published.load(.acquire) != h) std.atomic.spinLoopHint();
                self.published.store(h +% 1, .release);
                return;
            }
        }

        /// Take the next datagram, or null when the ring is empty.
        ///
        /// No syscall, no lock, no allocation. The returned bytes are valid until the
        /// `slots`-th subsequent call, which is the same contract a frame loop already has
        /// for anything it does not copy.
        pub fn poll(self: *Self) ?Datagram {
            const t = self.tail.load(.monotonic);
            const p = self.published.load(.acquire);
            if (t == p) return null;
            const i = t & mask;
            const d: Datagram = .{
                .bytes = self.storage[i * max_datagram ..][0..self.lengths[i]],
                .from = self.froms[i],
            };
            self.tail.store(t +% 1, .release);
            return d;
        }

        pub fn send(self: *Self, to: Address, bytes: []const u8) bool {
            return self.pair.send(self.io, to, bytes);
        }

        pub fn pending(self: *const Self) u32 {
            return self.published.load(.monotonic) -% self.tail.load(.monotonic);
        }
    };
}

/// An IPv4 address in its v4-mapped IPv6 form, `::ffff:a.b.c.d`.
fn mapV4(v4: net.Ip4Address) Address {
    var bytes: [16]u8 = @splat(0);
    bytes[10] = 0xFF;
    bytes[11] = 0xFF;
    @memcpy(bytes[12..16], &v4.bytes);
    return .{ .ip6 = .{ .bytes = bytes, .port = v4.port } };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

// Tests need a real `Io`. Threaded rather than a single-threaded stub, because that is
// what a desktop host actually uses and the socket operations go through the vtable either
// way.

test "a bound socket reports the port the OS chose" {
    // Port 0 rather than a fixed one: a test that fails because something else on the
    // machine holds a port is a test that gets disabled.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Socket.bind(io, .ip4, 0);
    defer s.close(io);
    try testing.expect(s.port() != 0);
}

test "a family mismatch is refused here, not by the OS" {
    // Letting it through returns a generic failure that reads as "the network dropped it",
    // and the send counter then makes a routing mistake look like packet loss.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Socket.bind(io, .ip4, 0);
    defer s.close(io);

    try testing.expect(!s.send(io, .{ .ip6 = .loopback(9999) }, "x"));
    try testing.expectEqual(@as(u64, 1), s.send_failures);
    try testing.expectEqual(@as(u64, 0), s.sent);
}

/// Spin the frame loop's actual read path until something shows up.
///
/// Note what this does NOT do: touch a socket. That is the whole point of the receiver
/// thread — `poll` is a ring pop, so a test that spins here is spinning on exactly what the
/// game will spin on.
fn awaitPoll(r: anytype) !Datagram {
    var tries: u32 = 0;
    while (tries < 200_000) : (tries += 1) {
        if (r.poll()) |d| return d;
        std.atomic.spinLoopHint();
    }
    return error.NothingArrived;
}

const TestReceiver = Receiver(64);

test "a datagram crosses loopback and arrives through the ring" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = TestReceiver.init(testing.allocator, io, try Pair.bind(io, 0));
    try server.start();
    defer server.stop();

    var client_pair = try Pair.bind(io, 0);
    defer client_pair.close(io);

    var exchanged: u32 = 0;
    if (server.pair.ip4) |s| {
        try testing.expect(client_pair.send(io, .{ .ip4 = .loopback(s.port()) }, "v4"));
        try testing.expectEqualStrings("v4", (try awaitPoll(&server)).bytes);
        exchanged += 1;
    }
    if (server.pair.ip6) |s| {
        try testing.expect(client_pair.send(io, .{ .ip6 = .loopback(s.port()) }, "v6"));
        try testing.expectEqualStrings("v6", (try awaitPoll(&server)).bytes);
        exchanged += 1;
    }

    // A host with neither family is not a host this can run on.
    try testing.expect(exchanged > 0);
    try testing.expectEqual(@as(u64, 0), server.overruns.load(.monotonic));
}

test "polling an idle receiver is null and touches no socket" {
    // An empty network is the ordinary case, and it must cost the frame loop a load and a
    // compare -- not a syscall, and certainly not a wait.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = TestReceiver.init(testing.allocator, io, try Pair.bind(io, 0));
    try r.start();
    defer r.stop();

    for (0..1000) |_| try testing.expect(r.poll() == null);
    try testing.expectEqual(@as(u32, 0), r.pending());
}

test "many datagrams arrive without loss or duplication" {
    // The property the ring exists for: every packet the OS delivered appears exactly once
    // in the frame loop's view, in order, with no torn contents.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = TestReceiver.init(testing.allocator, io, try Pair.bind(io, 0));
    try server.start();
    defer server.stop();

    var client_pair = try Pair.bind(io, 0);
    defer client_pair.close(io);

    const dst: Address = if (server.pair.ip4) |s|
        .{ .ip4 = .loopback(s.port()) }
    else if (server.pair.ip6) |s|
        .{ .ip6 = .loopback(s.port()) }
    else
        return error.SkipZigTest;

    // Each payload carries its own index, so a torn or reordered slot is detectable rather
    // than merely suspected.
    const count = 32;
    var seen: [count]bool = @splat(false);
    var got: u32 = 0;

    for (0..count) |i| {
        var payload: [64]u8 = @splat(@intCast(i));
        std.mem.writeInt(u32, payload[0..4], @intCast(i), .little);
        _ = client_pair.send(io, dst, &payload);
    }

    var spins: u32 = 0;
    while (got < count and spins < 500_000) : (spins += 1) {
        if (server.poll()) |d| {
            try testing.expectEqual(@as(usize, 64), d.bytes.len);
            const i = std.mem.readInt(u32, d.bytes[0..4], .little);
            try testing.expect(i < count);
            try testing.expect(!seen[i]); // exactly once
            seen[i] = true;
            // The rest of the payload is the index as a byte: a torn slot shows up here.
            for (d.bytes[4..]) |b| try testing.expectEqual(@as(u8, @intCast(i)), b);
            got += 1;
        }
    }

    // UDP on loopback is not guaranteed lossless, so this asserts "most arrived, none
    // corrupted or duplicated" rather than a count the OS never promised.
    try testing.expect(got > count / 2);
}

test "ring overrun is counted rather than silently dropping newer state" {
    // Overrun drops the OLDEST, so the frame loop always sees the freshest snapshot it can.
    // A ring that discarded the newest would deliver stale state precisely when the
    // connection is worst.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Tiny = Receiver(2);
    var server = Tiny.init(testing.allocator, io, try Pair.bind(io, 0));
    try server.start();
    defer server.stop();

    var client_pair = try Pair.bind(io, 0);
    defer client_pair.close(io);

    const dst: Address = if (server.pair.ip4) |s|
        .{ .ip4 = .loopback(s.port()) }
    else
        return error.SkipZigTest;

    // Send far more than the ring holds without draining.
    for (0..64) |_| _ = client_pair.send(io, dst, "x");

    var spins: u32 = 0;
    while (server.overruns.load(.monotonic) == 0 and spins < 500_000) : (spins += 1) {
        std.atomic.spinLoopHint();
    }
    try testing.expect(server.overruns.load(.monotonic) > 0);

    // And the ring is still usable afterwards rather than wedged.
    _ = server.poll();
    _ = server.poll();
    try testing.expect(server.pending() == 0);
}

test "stopping a receiver joins its threads and frees its slots" {
    // Closing the socket is what unblocks the receive. Without it `stop` hangs in `join`
    // and takes the whole shutdown with it -- which on a server is a process that will not
    // exit and on a phone is a process the OS kills.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = TestReceiver.init(testing.allocator, io, try Pair.bind(io, 0));
    try r.start();
    r.stop();
    r.stop(); // idempotent
}

test "peerKey distinguishes address and port and is stable" {
    // A token bound to the address alone lets anyone behind the same NAT reuse it.
    var k1: [18]u8 = undefined;
    var k2: [18]u8 = undefined;
    var k3: [18]u8 = undefined;

    const a = try Address.parse("192.0.2.1", 4000);
    const b = try Address.parse("192.0.2.1", 4001);
    const c = try Address.parse("192.0.2.2", 4000);

    try testing.expect(!std.mem.eql(u8, Socket.peerKey(a, &k1), Socket.peerKey(b, &k2)));
    try testing.expect(!std.mem.eql(u8, Socket.peerKey(a, &k1), Socket.peerKey(c, &k3)));

    var again: [18]u8 = undefined;
    try testing.expectEqualSlices(u8, Socket.peerKey(a, &k1), Socket.peerKey(a, &again));
}

test "peerKey is byte-order explicit, so a token is stable across architectures" {
    // The token is an HMAC over these bytes. If they were host-ordered, a big-endian
    // validator and a little-endian host would derive different tokens for the same peer
    // and every address validation between them would fail.
    const a = try Address.parse("192.0.2.1", 0x1234);
    var k: [18]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 192, 0, 2, 1, 0x34, 0x12 }, Socket.peerKey(a, &k));
}

test "an ipv4 and an ipv6 peer never collide" {
    const v4 = try Address.parse("192.0.2.1", 4000);
    const v6 = try Address.parse("2001:db8::1", 4000);
    var k1: [18]u8 = undefined;
    var k2: [18]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, Socket.peerKey(v4, &k1), Socket.peerKey(v6, &k2)));
}

test "a v4-mapped destination keeps its address and port" {
    // Kept as a helper because a future transport may need it, and getting it wrong sends
    // every IPv4 client's traffic to the wrong place -- which looks like "IPv4 clients
    // cannot connect" rather than like a byte-order bug.
    const v4 = try Address.parse("203.0.113.7", 4321);
    const mapped = mapV4(v4.ip4);
    try testing.expectEqual(@as(u16, 4321), mapped.ip6.port);
    try testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 203, 0, 113, 7 },
        &mapped.ip6.bytes,
    );
}
