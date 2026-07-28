//! WebSocket transport and static file serving. `ARCHITECTURE.md` §12, the browser half.
//!
//! `src/net/host.zig` owns the world and performs no I/O; `platform/udp.zig` moves bytes for
//! native clients. This moves bytes for browser clients, and the host cannot tell them
//! apart — which is the entire reason the session and host layers were built
//! transport-agnostic.
//!
//! ## Why WebSocket and not WebTransport
//!
//! §12 says "QUIC datagrams natively, WebTransport in browsers, one protocol", and this is
//! not that. The deviation is deliberate and bounded:
//!
//!   - WebTransport is HTTP/3, which is QUIC, which is TLS 1.3. `std.crypto.tls` has a
//!     **Client and no Server**, and §18.13 forbids writing one. So WebTransport is blocked
//!     on vendoring a vetted TLS stack, which is its own project.
//!   - WebSocket is in `std.http.Server`, needs no dependency, and every browser has it.
//!   - **For the authoring channel it is arguably the right transport anyway.** §12 wants
//!     datagrams because *snapshots* are unreliable-unordered and head-of-line blocking
//!     hurts them. §13's authoring transactions are reliable-ordered by nature — an edit
//!     that arrives out of order is not a stale snapshot, it is a corrupted document. So
//!     WebSocket is a stop-gap for snapshots and a reasonable long-term answer for edits.
//!
//! TLS is **not terminated here.** There is no TLS server in std and §18.13 forbids
//! inventing one, so a public deployment puts a tunnel or reverse proxy in front —
//! Cloudflare Tunnel, Tailscale Funnel, nginx — which is a vetted implementation doing the
//! cryptography, exactly what §18.13 asks for. On a LAN, plain `ws://` needs nothing.
//!
//! ## Threading
//!
//! One thread per connection, moving bytes into and out of per-connection rings. The game
//! thread drains the rings and never blocks on a socket, never takes a lock, and never
//! touches a `std.http` type. Same shape as `platform/udp.zig` and
//! `platform/windows/audio.zig`, for the same reason: §18.8 and the rule that tick cadence
//! must not be coupled to network conditions.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const http = std.http;

pub const max_message: usize = 64 * 1024;
pub const max_connections: usize = 64;

pub const Error = error{
    BindFailed,
    ThreadFailed,
};

/// A bounded queue of whole messages.
///
/// WebSocket is message-framed, so unlike the UDP path there is no need to preserve
/// datagram boundaries by hand — one message in, one message out. Slots are fixed-size and
/// allocated once: §18.8, and a queue that allocated per message would do it on the
/// connection thread while the game thread waits.
fn MessageRing(comptime slots: usize) type {
    comptime {
        if (slots == 0 or (slots & (slots - 1)) != 0) {
            @compileError("message ring slots must be a non-zero power of two");
        }
    }
    return struct {
        const Self = @This();
        const mask: u32 = @intCast(slots - 1);

        storage: []u8 = &.{},
        lengths: [slots]u32 = @splat(0),
        head: std.atomic.Value(u32) = .init(0),
        published: std.atomic.Value(u32) = .init(0),
        tail: std.atomic.Value(u32) = .init(0),
        /// Messages dropped because the reader was not draining. Counted rather than
        /// blocking: blocking the connection thread on a slow game thread turns a local
        /// stall into a network stall for every client.
        dropped: std.atomic.Value(u64) = .init(0),

        fn alloc(self: *Self, gpa: std.mem.Allocator) !void {
            self.storage = try gpa.alloc(u8, slots * max_message);
        }
        fn free(self: *Self, gpa: std.mem.Allocator) void {
            if (self.storage.len > 0) gpa.free(self.storage);
            self.storage = &.{};
        }

        fn push(self: *Self, bytes: []const u8) bool {
            if (bytes.len > max_message) return false;
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h -% t >= slots) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return false;
            }
            const i = h & mask;
            @memcpy(self.storage[i * max_message ..][0..bytes.len], bytes);
            self.lengths[i] = @intCast(bytes.len);
            self.head.store(h +% 1, .monotonic);
            // Published separately so a reader never sees a slot mid-write. Single producer
            // here, unlike the UDP ring, so no claim step is needed.
            self.published.store(h +% 1, .release);
            return true;
        }

        fn pop(self: *Self) ?[]const u8 {
            const t = self.tail.load(.monotonic);
            const p = self.published.load(.acquire);
            if (t == p) return null;
            const i = t & mask;
            const out = self.storage[i * max_message ..][0..self.lengths[i]];
            self.tail.store(t +% 1, .release);
            return out;
        }

        fn pending(self: *const Self) u32 {
            return self.published.load(.monotonic) -% self.tail.load(.monotonic);
        }
    };
}

pub const Connection = struct {
    /// Slot index doubles as the host `Endpoint`. Stable for the connection's lifetime and
    /// never reused while live, which is all the host requires of it.
    id: u32 = 0,
    live: std.atomic.Value(bool) = .init(false),
    /// Set by the game thread to ask the connection thread to finish.
    closing: std.atomic.Value(bool) = .init(false),

    inbound: MessageRing(64) = .{},
    outbound: MessageRing(64) = .{},

    thread: ?std.Thread = null,
    /// Set by the connection thread as it exits, so `freeConnection` can reap the handle
    /// and reuse the slot. Without it every static request consumes a slot forever, and a
    /// single page load costs three.
    done: std.atomic.Value(bool) = .init(false),
    stream: ?net.Stream = null,
};

/// Static content the server hands out, embedded rather than read from disk.
///
/// Embedded so a host is one file to copy and cannot serve a page that disagrees with the
/// binary. The wasm module is the important one: a page served from disk beside a stale
/// `.wasm` produces a schema-fingerprint mismatch at the handshake, which is correct
/// behaviour reporting a deployment mistake — better to make the mistake impossible.
pub const Asset = struct {
    path: []const u8,
    content_type: []const u8,
    bytes: []const u8,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    listener: net.Server = undefined,
    port: u16 = 0,
    assets: []const Asset = &.{},

    connections: []Connection = &.{},
    accept_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    live_threads: std.atomic.Value(u32) = .init(0),

    accepted: std.atomic.Value(u64) = .init(0),
    upgraded: std.atomic.Value(u64) = .init(0),
    served: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: std.mem.Allocator, io: Io, assets: []const Asset) Server {
        return .{ .gpa = gpa, .io = io, .assets = assets };
    }

    pub fn listen(self: *Server, port: u16) Error!void {
        // IPv4 only for now, and explicitly. `platform/udp.zig` §"the address family is
        // explicit" applies here too: a `::` listener on Windows is v6-only whatever is
        // requested, and a browser resolving `localhost` to `127.0.0.1` would then find
        // nothing listening.
        const addr = net.IpAddress.parseIp4("0.0.0.0", port) catch return Error.BindFailed;
        self.listener = net.IpAddress.listen(&addr, self.io, .{}) catch return Error.BindFailed;
        self.port = switch (self.listener.socket.address) {
            .ip4 => |a| a.port,
            .ip6 => |a| a.port,
        };

        self.connections = self.gpa.alloc(Connection, max_connections) catch return Error.BindFailed;
        for (self.connections, 0..) |*c, i| {
            c.* = .{ .id = @intCast(i) };
            c.inbound.alloc(self.gpa) catch return Error.BindFailed;
            c.outbound.alloc(self.gpa) catch return Error.BindFailed;
        }

        self.running.store(true, .release);
        self.accept_thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch return Error.ThreadFailed;
    }

    pub fn stop(self: *Server) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);

        for (self.connections) |*c| c.closing.store(true, .release);

        // Unblock the accept by CONNECTING TO OURSELVES, not by shutting the listener down.
        //
        // Shutdown is what `platform/udp.zig` uses to unblock a receive, and it does not
        // work here: `netAcceptWindows` in `std.Io.Threaded` marks the cancelled case
        // `unreachable`, so a shutdown mid-accept is a panic rather than an error — the
        // same upstream defect as UPSTREAM_FINDINGS §3, on a different syscall. A real
        // connection is something `accept` is guaranteed to return from, and unlike the
        // UDP wakeup datagram it does not have to route anywhere: it is a TCP connection
        // to a port on this machine that is definitely listening, because we are the ones
        // listening on it.
        {
            const self_addr = net.IpAddress.parseIp4("127.0.0.1", self.port) catch
                net.IpAddress{ .ip4 = .loopback(self.port) };
            if (net.IpAddress.connect(&self_addr, self.io, .{ .mode = .stream })) |s| {
                s.close(self.io);
            } else |_| {}
        }
        if (self.accept_thread) |t| t.join();
        self.accept_thread = null;
        self.listener.deinit(self.io);

        for (self.connections) |*c| {
            if (c.stream) |s| s.shutdown(self.io, .both) catch {};
        }

        for (self.connections) |*c| {
            if (c.thread) |t| t.join();
            c.thread = null;
            c.inbound.free(self.gpa);
            c.outbound.free(self.gpa);
        }
        if (self.connections.len > 0) self.gpa.free(self.connections);
        self.connections = &.{};
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        self.* = undefined;
    }

    /// Take the next message from any connection. Null when nothing is waiting.
    ///
    /// A ring pop, no syscall and no lock — the game thread's whole view of the network.
    pub fn poll(self: *Server) ?struct { endpoint: u64, bytes: []const u8 } {
        for (self.connections) |*c| {
            if (!c.live.load(.acquire)) continue;
            if (c.inbound.pop()) |b| return .{ .endpoint = c.id, .bytes = b };
        }
        return null;
    }

    /// Queue a message for one connection. Returns false if the client is gone or its queue
    /// is full — both of which are the caller's business, because a snapshot that cannot be
    /// queued is one the client will not acknowledge.
    pub fn send(self: *Server, endpoint: u64, bytes: []const u8) bool {
        if (endpoint >= self.connections.len) return false;
        const c = &self.connections[@intCast(endpoint)];
        if (!c.live.load(.acquire)) return false;
        return c.outbound.push(bytes);
    }

    pub fn isLive(self: *Server, endpoint: u64) bool {
        if (endpoint >= self.connections.len) return false;
        return self.connections[@intCast(endpoint)].live.load(.acquire);
    }

    pub fn liveCount(self: *Server) u32 {
        var n: u32 = 0;
        for (self.connections) |*c| {
            if (c.live.load(.acquire)) n += 1;
        }
        return n;
    }

    fn freeConnection(self: *Server) ?*Connection {
        for (self.connections) |*c| {
            if (c.live.load(.acquire)) continue;
            if (c.thread) |t| {
                // A finished thread still owns a joinable handle. Reaping it here is what
                // makes a slot reusable — without this, every static request permanently
                // consumes one and a page load costs three.
                if (c.done.load(.acquire)) {
                    t.join();
                    c.thread = null;
                    c.done.store(false, .monotonic);
                } else continue;
            }
            return c;
        }
        return null;
    }

    fn acceptLoop(self: *Server) void {
        while (self.running.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch break;
            // Re-checked after the accept: the connection that unblocked us during `stop`
            // is our own, and handing it a slot would spawn a thread the join is waiting on.
            if (!self.running.load(.acquire)) {
                stream.close(self.io);
                break;
            }
            _ = self.accepted.fetchAdd(1, .monotonic);

            const c = self.freeConnection() orelse {
                // No slot. Closing immediately is the honest answer: a connection that is
                // accepted and then ignored looks to the browser like a server that hung.
                stream.close(self.io);
                continue;
            };
            c.stream = stream;
            c.closing.store(false, .release);
            _ = self.live_threads.fetchAdd(1, .monotonic);
            c.thread = std.Thread.spawn(.{}, connectionLoop, .{ self, c }) catch {
                _ = self.live_threads.fetchSub(1, .monotonic);
                stream.close(self.io);
                c.stream = null;
                continue;
            };
        }
    }

    fn assetFor(self: *Server, target: []const u8) ?Asset {
        const path = if (std.mem.eql(u8, target, "/")) "/index.html" else target;
        // Query strings are stripped; a cache-buster must not turn into a 404.
        const clean = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;
        for (self.assets) |a| {
            if (std.mem.eql(u8, a.path, clean)) return a;
        }
        return null;
    }

    fn connectionLoop(self: *Server, c: *Connection) void {
        defer {
            c.live.store(false, .release);
            if (c.stream) |s| s.close(self.io);
            c.stream = null;
            _ = self.live_threads.fetchSub(1, .release);
            c.done.store(true, .release);
        }

        const stream = c.stream orelse return;
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);

        var server = http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch return;

        const upgrade = request.upgradeRequested();
        switch (upgrade) {
            .websocket => |key| {
                const k = key orelse return;
                var ws = request.respondWebSocket(.{ .key = k }) catch return;
                ws.flush() catch return;
                _ = self.upgraded.fetchAdd(1, .monotonic);
                c.live.store(true, .release);
                self.pump(c, &ws);
            },
            .none => {
                self.serveStatic(&request) catch {};
                _ = self.served.fetchAdd(1, .monotonic);
            },
            else => {},
        }
    }

    fn serveStatic(self: *Server, request: *http.Server.Request) !void {
        const asset = self.assetFor(request.head.target) orelse {
            try request.respond("not found", .{ .status = .not_found });
            return;
        };

        // Cross-origin isolation, because CONFORMANCE_PROFILES.md §2 makes a build served
        // without COOP/COEP a COMPATIBILITY-profile deployment regardless of what the
        // browser can do — and §5 makes anything measured there inadmissible. Sending the
        // headers costs nothing and keeps the served profile the conformant one.
        try request.respond(asset.bytes, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = asset.content_type },
                .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
                .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    }

    /// Move bytes both ways until the connection ends.
    ///
    /// **Two threads, one reading and one writing.** The obvious single-threaded shape —
    /// drain the send queue, then block on a read — deadlocks the handshake: the client
    /// sends its hello and waits for the accept, and the server will not write the accept
    /// until the client sends something else. Nobody moves. It looked adequate "for an
    /// editor" right up until a browser sat in `handshaking` forever.
    ///
    /// Sharing `ws` across the two is safe because they touch disjoint halves of it:
    /// `readSmallMessage` uses only the reader, `writeMessage` only the writer, exactly one
    /// thread does each, and TCP is full duplex. That is a real constraint rather than a
    /// happy accident, so it is stated here and any third caller breaks it.
    fn pump(self: *Server, c: *Connection, ws: *http.Server.WebSocket) void {
        var writer_thread = std.Thread.spawn(.{}, writeLoop, .{ self, c, ws }) catch {
            // No writer thread means no outbound traffic, so the connection is useless.
            // Failing closed is better than a client that connects and never hears back.
            return;
        };
        defer {
            c.closing.store(true, .release);
            writer_thread.join();
        }

        while (self.running.load(.acquire) and !c.closing.load(.acquire)) {
            const m = ws.readSmallMessage() catch return;
            switch (m.opcode) {
                .text, .binary => _ = c.inbound.push(m.data),
                // Pongs are written by the writer thread, not here — one writer, always.
                .ping => _ = c.outbound.push(m.data),
                else => {},
            }
        }
    }

    fn writeLoop(self: *Server, c: *Connection, ws: *http.Server.WebSocket) void {
        while (self.running.load(.acquire) and !c.closing.load(.acquire)) {
            var wrote = false;
            while (c.outbound.pop()) |msg| {
                ws.writeMessage(msg, .binary) catch return;
                wrote = true;
            }
            if (!wrote) {
                // Nothing queued. Sleeping beats spinning: this thread exists per
                // connection, and 64 spinning threads would consume the machine the host
                // is supposed to be simulating on.
                const nap: Io.Timeout = .{ .duration = .{
                    .raw = .{ .nanoseconds = std.time.ns_per_ms },
                    .clock = .awake,
                } };
                nap.sleep(self.io) catch return;
            }
        }
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a message ring preserves whole messages and drops rather than blocks" {
    // Blocking the connection thread on a slow game thread turns a local stall into a
    // network stall for every client, so a full ring drops and counts.
    const gpa = testing.allocator;
    var r: MessageRing(4) = .{};
    try r.alloc(gpa);
    defer r.free(gpa);

    try testing.expect(r.push("one"));
    try testing.expect(r.push("two"));
    try testing.expectEqualStrings("one", r.pop().?);
    try testing.expectEqualStrings("two", r.pop().?);
    try testing.expect(r.pop() == null);

    for (0..4) |_| _ = r.push("x");
    try testing.expect(!r.push("overflow"));
    try testing.expectEqual(@as(u64, 1), r.dropped.load(.monotonic));
}

test "an oversized message is refused rather than truncated" {
    // A truncated message is a corrupt one, and this is the untrusted side of a trust
    // boundary — the same argument replicate.zig makes about frame counts.
    const gpa = testing.allocator;
    var r: MessageRing(2) = .{};
    try r.alloc(gpa);
    defer r.free(gpa);

    const big = try gpa.alloc(u8, max_message + 1);
    defer gpa.free(big);
    @memset(big, 'x');
    try testing.expect(!r.push(big));
}

test "the ring wraps without losing message boundaries" {
    const gpa = testing.allocator;
    var r: MessageRing(2) = .{};
    try r.alloc(gpa);
    defer r.free(gpa);

    for (0..16) |i| {
        var buf: [8]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "m{d}", .{i});
        try testing.expect(r.push(msg));
        try testing.expectEqualStrings(msg, r.pop().?);
    }
    try testing.expectEqual(@as(u32, 0), r.pending());
}

test "a server binds, reports its port, and stops cleanly" {
    // Port 0 so the test cannot fail because something else holds a port. Stopping must
    // not hang: the listener is shut down rather than waiting for a connection to arrive
    // and unblock the accept, which is the lesson platform/udp.zig learned the hard way.
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = Server.init(gpa, io, &.{});
    try s.listen(0);
    defer s.deinit();

    try testing.expect(s.port != 0);
    try testing.expectEqual(@as(u32, 0), s.liveCount());
}

test "stop is idempotent and safe before listen" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var s = Server.init(gpa, threaded.io(), &.{});
    s.stop();
    s.stop();
    try testing.expectEqual(@as(u16, 0), s.port);
}

test "asset lookup maps / to index.html and ignores a query string" {
    // A cache-buster must not turn into a 404, and the browser asks for "/" rather than
    // "/index.html".
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const assets = [_]Asset{
        .{ .path = "/index.html", .content_type = "text/html", .bytes = "<html>" },
        .{ .path = "/app.wasm", .content_type = "application/wasm", .bytes = "\x00asm" },
    };
    var s = Server.init(gpa, threaded.io(), &assets);

    try testing.expectEqualStrings("<html>", s.assetFor("/").?.bytes);
    try testing.expectEqualStrings("<html>", s.assetFor("/index.html").?.bytes);
    try testing.expectEqualStrings("\x00asm", s.assetFor("/app.wasm?v=2").?.bytes);
    try testing.expect(s.assetFor("/nope") == null);
}

test "sending to a dead endpoint fails rather than pretending" {
    // A snapshot that cannot be queued is one the client will not acknowledge, which the
    // host needs to know: silently succeeding would make the baseline wait forever for an
    // ack that can never come.
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var s = Server.init(gpa, threaded.io(), &.{});
    try s.listen(0);
    defer s.deinit();

    try testing.expect(!s.send(0, "x")); // slot exists but no client
    try testing.expect(!s.send(9999, "x")); // out of range
    try testing.expect(!s.isLive(0));
}
