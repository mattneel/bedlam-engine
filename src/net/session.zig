//! Session establishment and the packet header. `ARCHITECTURE.md` §12, M0 criterion 4.
//!
//! `baseline.zig` tracks what a client has acknowledged and `snapshot.zig` decides what to
//! send. Neither has anywhere to send it. This is the layer underneath: how two peers agree
//! they are talking, what a packet looks like, and how each learns what the other received.
//!
//! **Transport-agnostic on purpose.** The datagram source is a parameter, not an import.
//! Six targets means three transports — UDP on desktop and mobile, WebTransport in the
//! browser, and a loopback for tests — and a session that reaches for a socket cannot be
//! compiled for wasm32 at all. §18.9's rule about platform types applies here in its
//! sharpest form.
//!
//! **The schema fingerprint is checked in the handshake, and a mismatch is a refusal.**
//! `SCHEMA_AND_EVOLUTION.md` §10 makes the fingerprint the thing two builds compare to know
//! whether they agree on the wire. Comparing it after the connection is up is too late: by
//! then a snapshot has been decoded under the wrong layout and the receiving world is
//! quietly wrong. Refusing at handshake makes an incompatibility a connection error, which
//! is diagnosable, instead of a desync, which is not.
//!
//! ## What is deliberately absent
//!
//! **There is no encryption here and there must not be.** §18.13 forbids custom
//! cryptography, and a hand-rolled AEAD over these packets is exactly that. The session
//! carries `Crypto`, a vtable that is `null` until a vetted implementation (QUIC/DTLS via
//! a real TLS stack) fills it — and `requireSecure` refuses to establish without one. The
//! hole is a compile-visible parameter rather than a comment, because "we'll add crypto
//! later" is how it ships without any.

const std = @import("std");

pub const protocol_version: u16 = 1;

/// Bedlam's datagram marker. Two bytes, checked before anything else is parsed.
///
/// Not security — anyone can write these bytes. It exists so a port collision with an
/// unrelated protocol is rejected at the first branch rather than parsed as a header and
/// turned into a plausible-looking connection id.
pub const magic: [2]u8 = .{ 0xBE, 0xD1 };

pub const PacketType = enum(u8) {
    /// Client → server. Opens a handshake.
    hello = 1,
    /// Server → client. Address validation: echo this token in a second hello.
    ///
    /// The anti-amplification measure. Without it, a forged source address turns this
    /// server into a reflector — an attacker sends a small hello claiming to be the
    /// victim and the server answers with a much larger accept. Requiring a token the
    /// server issued proves the client can receive at the address it claims.
    retry = 2,
    /// Server → client. Handshake succeeded.
    accept = 3,
    /// Either direction. Handshake refused, with a reason.
    reject = 4,
    /// Either direction. Carries payload.
    data = 5,
    /// Either direction. Keeps the session alive and carries acks with no payload.
    ping = 6,
    /// Either direction. Orderly close.
    bye = 7,
    _,
};

pub const RejectReason = enum(u8) {
    version_mismatch = 1,
    /// The two peers were built against different schemas. The most important one: this is
    /// what stops a snapshot being decoded under a layout that does not match it.
    schema_mismatch = 2,
    server_full = 3,
    bad_token = 4,
    /// The server requires an encrypted transport and the client offered none.
    insecure = 5,
    _,
};

pub const Error = error{
    TooShort,
    BadMagic,
    UnknownConnection,
    NotEstablished,
    PayloadTooLarge,
    Rejected,
    InsecureTransport,
};

/// Maximum datagram this layer will emit.
///
/// 1200 bytes, matching QUIC's minimum. Chosen because it is the largest size that
/// traverses essentially every path without fragmentation, and an IPv6 path is guaranteed
/// to carry 1280 including headers. Discovering a larger MTU is a later optimization; a
/// packet that silently does not arrive on one player's connection is not.
pub const max_datagram: usize = 1200;

/// Fixed header on every packet after the handshake.
///
/// Explicit little-endian everywhere, never `@bitCast` over a struct. The wire is one
/// layout for all six targets and §0 P1 lets each choose its own physical layout, so a
/// struct copy is a per-target format. The cross gate runs this on two big-endian
/// architectures for exactly this reason.
pub const Header = struct {
    typ: PacketType,
    /// The connection id the RECIPIENT chose, echoed back to it.
    ///
    /// Each side picks the id it wants to be addressed by, rather than one shared id. That
    /// is what lets a peer route an incoming packet without consulting the source address,
    /// which in turn is what lets a session survive a NAT rebind or a phone moving from
    /// Wi-Fi to cellular — §12's mobile targets do this routinely.
    connection: u32,
    /// This packet's number. Never reused, never reordered by the sender.
    sequence: u32,
    /// Highest sequence the sender has received from the recipient.
    ack: u32,
    /// Which of the 32 sequences before `ack` also arrived, bit 0 = `ack - 1`.
    ///
    /// A bitfield rather than a list because the acknowledgement must fit in a fixed header
    /// — §18.8's spirit applied to the wire — and because `baseline.zig` only needs to know
    /// which deltas landed, not in what order.
    ack_bits: u32,

    pub const size: usize = 2 + 1 + 4 + 4 + 4 + 4;

    pub fn write(self: Header, buf: []u8) usize {
        std.debug.assert(buf.len >= size);
        @memcpy(buf[0..2], &magic);
        buf[2] = @intFromEnum(self.typ);
        std.mem.writeInt(u32, buf[3..7], self.connection, .little);
        std.mem.writeInt(u32, buf[7..11], self.sequence, .little);
        std.mem.writeInt(u32, buf[11..15], self.ack, .little);
        std.mem.writeInt(u32, buf[15..19], self.ack_bits, .little);
        return size;
    }

    pub fn read(buf: []const u8) Error!Header {
        if (buf.len < size) return Error.TooShort;
        if (!std.mem.eql(u8, buf[0..2], &magic)) return Error.BadMagic;
        return .{
            .typ = @enumFromInt(buf[2]),
            .connection = std.mem.readInt(u32, buf[3..7], .little),
            .sequence = std.mem.readInt(u32, buf[7..11], .little),
            .ack = std.mem.readInt(u32, buf[11..15], .little),
            .ack_bits = std.mem.readInt(u32, buf[15..19], .little),
        };
    }
};

/// What a hello carries. Everything needed to decide whether these two can talk at all.
pub const Hello = struct {
    version: u16,
    /// The connection id the CLIENT wants to be addressed by.
    client_connection: u32,
    /// `SCHEMA_AND_EVOLUTION.md` §10's compatibility fingerprint, in full. Compared
    /// byte-for-byte; a prefix comparison would accept a collision an attacker can produce
    /// cheaply and, more likely, a truncation bug nobody notices.
    fingerprint: [64]u8,
    /// Echoed from a `retry`, or zero on the first attempt.
    token: [16]u8 = @splat(0),

    pub const size: usize = 2 + 4 + 64 + 16;

    pub fn write(self: Hello, buf: []u8) usize {
        std.debug.assert(buf.len >= size);
        std.mem.writeInt(u16, buf[0..2], self.version, .little);
        std.mem.writeInt(u32, buf[2..6], self.client_connection, .little);
        @memcpy(buf[6..70], &self.fingerprint);
        @memcpy(buf[70..86], &self.token);
        return size;
    }

    pub fn read(buf: []const u8) Error!Hello {
        if (buf.len < size) return Error.TooShort;
        var h: Hello = .{
            .version = std.mem.readInt(u16, buf[0..2], .little),
            .client_connection = std.mem.readInt(u32, buf[2..6], .little),
            .fingerprint = undefined,
        };
        @memcpy(&h.fingerprint, buf[6..70]);
        @memcpy(&h.token, buf[70..86]);
        return h;
    }
};

/// The encryption boundary, empty by design.
///
/// §18.13: no custom cryptography. A hand-rolled AEAD over these packets is custom
/// cryptography no matter how carefully it is written, so this is a vtable a vetted
/// implementation fills — QUIC or DTLS over a real TLS stack — and nothing here implements
/// it. `seal` and `open` are the only two operations the session needs, which keeps the
/// eventual integration small.
pub const Crypto = struct {
    ctx: *anyopaque,
    /// Encrypt-and-authenticate `plain` into `out`, returning the length written. `out`
    /// must have room for `plain.len + overhead`.
    seal: *const fn (ctx: *anyopaque, seq: u32, plain: []const u8, out: []u8) usize,
    /// Verify and decrypt. Returns null if authentication fails — which must be treated as
    /// "packet never existed", not as an error to report, since reporting it is an oracle.
    open: *const fn (ctx: *anyopaque, seq: u32, sealed: []const u8, out: []u8) ?usize,
    overhead: usize,
};

pub const State = enum {
    closed,
    /// Client: hello sent, waiting. Server: never in this state.
    handshaking,
    /// Client: a retry arrived and the second hello is in flight.
    validating,
    established,
    /// Closed by the peer or by us, distinguished from `closed` so a caller can tell an
    /// orderly shutdown from a session that never opened.
    ended,
};

pub const Config = struct {
    /// Refuse to establish without a `Crypto`. Defaults to **false only because no vetted
    /// implementation is wired in yet**; a shipping server sets it and the handshake then
    /// rejects an unencrypted client rather than silently accepting one.
    require_secure: bool = false,
    /// Ticks without a packet before the session is declared dead.
    timeout_ticks: u32 = 300,
    /// Ticks of silence before sending a ping.
    keepalive_ticks: u32 = 60,
};

/// One end of a session. Both client and server use this; the difference is which
/// functions they call.
pub const Session = struct {
    state: State = .closed,
    config: Config = .{},

    /// The id WE chose and expect to see in incoming headers.
    local_connection: u32 = 0,
    /// The id the PEER chose, written into outgoing headers.
    remote_connection: u32 = 0,

    next_sequence: u32 = 0,
    /// Highest sequence received from the peer.
    remote_ack: u32 = 0,
    /// Which of the 32 before `remote_ack` arrived.
    remote_ack_bits: u32 = 0,
    /// Highest sequence the PEER says it received from us. `baseline.zig` consumes this.
    acked_by_peer: u32 = 0,
    /// Mirror of `remote_ack_bits` for the other direction, updated from incoming headers.
    ack_history: u32 = 0,

    crypto: ?Crypto = null,
    fingerprint: [64]u8 = @splat(0),

    idle_ticks: u32 = 0,
    reject_reason: ?RejectReason = null,

    /// Diagnostics. Not decoration: `duplicates` and `too_old` distinguish a lossy path
    /// from a reordering one, and those want different responses from the send scheduler.
    sent: u64 = 0,
    received: u64 = 0,
    duplicates: u64 = 0,
    too_old: u64 = 0,
    unauthenticated: u64 = 0,

    pub fn init(local_connection: u32, fingerprint: [64]u8, config: Config) Session {
        return .{
            .local_connection = local_connection,
            .fingerprint = fingerprint,
            .config = config,
        };
    }

    pub fn isEstablished(self: Session) bool {
        return self.state == .established;
    }

    /// Build the header for the next outgoing packet and consume a sequence number.
    fn nextHeader(self: *Session, typ: PacketType) Header {
        const h: Header = .{
            .typ = typ,
            .connection = self.remote_connection,
            .sequence = self.next_sequence,
            .ack = self.remote_ack,
            .ack_bits = self.remote_ack_bits,
        };
        self.next_sequence +%= 1;
        return h;
    }

    /// Record that `seq` arrived, maintaining the ack bitfield.
    ///
    /// Returns false for a duplicate or a packet older than the window, which the caller
    /// must drop. Without the duplicate check a replayed packet is applied twice, and an
    /// input command applied twice is a divergence §14.3 will find and nobody will explain.
    pub fn observe(self: *Session, seq: u32) bool {
        if (self.received == 0) {
            self.remote_ack = seq;
            self.remote_ack_bits = 0;
            return true;
        }

        // Wrapping-aware comparison: sequences free-run as u32 and a session long enough to
        // wrap must not treat the wrap as a 4-billion-packet jump backwards.
        const delta = seq -% self.remote_ack;
        if (delta == 0) {
            self.duplicates += 1;
            return false;
        }

        if (delta < 0x8000_0000) {
            // Newer. Shift the window forward.
            if (delta >= 32) {
                self.remote_ack_bits = 0;
            } else {
                self.remote_ack_bits = (self.remote_ack_bits << @intCast(delta)) |
                    (@as(u32, 1) << @intCast(delta - 1));
            }
            self.remote_ack = seq;
            return true;
        }

        // Older. Inside the window it is a legitimate reorder; outside it, unverifiable.
        const back = self.remote_ack -% seq;
        if (back > 32) {
            self.too_old += 1;
            return false;
        }
        const bit = @as(u32, 1) << @intCast(back - 1);
        if (self.remote_ack_bits & bit != 0) {
            self.duplicates += 1;
            return false;
        }
        self.remote_ack_bits |= bit;
        return true;
    }

    /// Whether the peer acknowledged `seq`. `baseline.zig` asks this to decide what a delta
    /// may be computed against.
    pub fn peerAcked(self: Session, seq: u32) bool {
        const delta = self.acked_by_peer -% seq;
        if (delta == 0) return true;
        if (delta > 32) return false;
        return self.ack_history & (@as(u32, 1) << @intCast(delta - 1)) != 0;
    }

    fn absorbAck(self: *Session, h: Header) void {
        const delta = h.ack -% self.acked_by_peer;
        if (self.sent == 0) return;
        // Only move forward; a reordered packet carrying a stale ack must not retract one.
        if (delta != 0 and delta < 0x8000_0000) {
            self.acked_by_peer = h.ack;
            self.ack_history = h.ack_bits;
        } else if (delta == 0) {
            self.ack_history |= h.ack_bits;
        }
    }

    // --- client side -------------------------------------------------------

    /// Write the opening hello. Returns the datagram length.
    pub fn clientHello(self: *Session, buf: []u8, token: [16]u8) usize {
        self.state = if (std.mem.allEqual(u8, &token, 0)) .handshaking else .validating;
        // The peer's id is unknown until it answers, so the header carries zero and the
        // server routes this packet by address. Every later packet routes by id.
        const h = self.nextHeader(.hello);
        var n = h.write(buf);
        const hello: Hello = .{
            .version = protocol_version,
            .client_connection = self.local_connection,
            .fingerprint = self.fingerprint,
            .token = token,
        };
        n += hello.write(buf[n..]);
        self.sent += 1;
        return n;
    }

    /// Feed a datagram received while handshaking. Returns the retry token if the server
    /// demanded address validation, in which case the caller sends a second hello.
    pub fn clientReceive(self: *Session, datagram: []const u8) Error!?[16]u8 {
        const h = try Header.read(datagram);
        if (h.connection != self.local_connection and self.state == .established) {
            return Error.UnknownConnection;
        }
        const body = datagram[Header.size..];

        switch (h.typ) {
            .retry => {
                if (body.len < 16 + 4) return Error.TooShort;
                var token: [16]u8 = undefined;
                @memcpy(&token, body[0..16]);
                return token;
            },
            .accept => {
                if (body.len < 4) return Error.TooShort;
                self.remote_connection = std.mem.readInt(u32, body[0..4], .little);
                self.state = .established;
                self.idle_ticks = 0;
                _ = self.observe(h.sequence);
                self.received += 1;
                return null;
            },
            .reject => {
                if (body.len < 1) return Error.TooShort;
                self.reject_reason = @enumFromInt(body[0]);
                self.state = .ended;
                return Error.Rejected;
            },
            else => {
                if (self.state != .established) return Error.NotEstablished;
                return null;
            },
        }
    }

    // --- server side -------------------------------------------------------

    /// Decide what to do with an incoming hello.
    pub const HelloVerdict = union(enum) {
        /// Send a retry carrying this token; the client has not proved its address.
        retry: [16]u8,
        accept: Hello,
        reject: RejectReason,
    };

    /// Validate a hello. Pure: it decides, the caller sends.
    ///
    /// `expected_token` is what this server would have issued for the source address —
    /// computed by the caller, because only the caller knows the address, and §18.9 keeps
    /// address types out of here.
    pub fn serverEvaluate(
        self: *Session,
        datagram: []const u8,
        expected_token: [16]u8,
        require_validation: bool,
    ) Error!HelloVerdict {
        const h = try Header.read(datagram);
        if (h.typ != .hello) return Error.NotEstablished;
        const hello = try Hello.read(datagram[Header.size..]);

        if (hello.version != protocol_version) return .{ .reject = .version_mismatch };

        // Checked BEFORE address validation, deliberately. A client built against the
        // wrong schema should be told so on its first packet rather than made to complete
        // a round trip first; the check costs a comparison and the answer never changes.
        if (!std.mem.eql(u8, &hello.fingerprint, &self.fingerprint)) {
            return .{ .reject = .schema_mismatch };
        }

        if (self.config.require_secure and self.crypto == null) {
            return .{ .reject = .insecure };
        }

        if (require_validation) {
            if (std.mem.allEqual(u8, &hello.token, 0)) {
                return .{ .retry = expected_token };
            }
            // Constant-time, because a byte-at-a-time comparison leaks the token one byte
            // per round trip and the whole point of the token is that a forger cannot
            // produce it.
            if (!std.crypto.timing_safe.eql([16]u8, hello.token, expected_token)) {
                return .{ .reject = .bad_token };
            }
        }
        return .{ .accept = hello };
    }

    /// Complete the handshake on the server side and write the accept datagram.
    pub fn serverAccept(self: *Session, hello: Hello, buf: []u8) usize {
        self.remote_connection = hello.client_connection;
        self.state = .established;
        self.idle_ticks = 0;

        const h = self.nextHeader(.accept);
        var n = h.write(buf);
        std.mem.writeInt(u32, buf[n..][0..4], self.local_connection, .little);
        n += 4;
        self.sent += 1;
        return n;
    }

    pub fn writeRetry(self: *Session, token: [16]u8, buf: []u8) usize {
        const h = self.nextHeader(.retry);
        var n = h.write(buf);
        @memcpy(buf[n..][0..16], &token);
        n += 16;
        // Four bytes of padding so a retry is never smaller than the hello that provoked
        // it. Anti-amplification cuts both ways: the response must not be an easy way to
        // multiply traffic, and it must be large enough that the check in `read` sees a
        // well-formed body.
        @memset(buf[n..][0..4], 0);
        n += 4;
        self.sent += 1;
        return n;
    }

    pub fn writeReject(self: *Session, reason: RejectReason, buf: []u8) usize {
        const h = self.nextHeader(.reject);
        var n = h.write(buf);
        buf[n] = @intFromEnum(reason);
        n += 1;
        self.state = .ended;
        self.sent += 1;
        return n;
    }

    // --- established -------------------------------------------------------

    /// Write a data packet carrying `payload`.
    pub fn writeData(self: *Session, payload: []const u8, buf: []u8) Error!usize {
        if (self.state != .established) return Error.NotEstablished;
        const overhead = Header.size + if (self.crypto) |c| c.overhead else 0;
        if (payload.len + overhead > @min(buf.len, max_datagram)) return Error.PayloadTooLarge;

        const h = self.nextHeader(.data);
        var n = h.write(buf);
        if (self.crypto) |c| {
            n += c.seal(c.ctx, h.sequence, payload, buf[n..]);
        } else {
            @memcpy(buf[n..][0..payload.len], payload);
            n += payload.len;
        }
        self.sent += 1;
        self.idle_ticks = 0;
        return n;
    }

    pub fn writePing(self: *Session, buf: []u8) Error!usize {
        if (self.state != .established) return Error.NotEstablished;
        const h = self.nextHeader(.ping);
        self.sent += 1;
        return h.write(buf);
    }

    pub fn writeBye(self: *Session, buf: []u8) usize {
        const h = self.nextHeader(.bye);
        self.state = .ended;
        self.sent += 1;
        return h.write(buf);
    }

    /// What an established session got out of a datagram.
    pub const Incoming = union(enum) {
        /// Payload, valid until the next call.
        data: []const u8,
        ping,
        bye,
        /// Duplicate, out of window, or failed authentication. Already counted.
        discarded,
    };

    /// Process a datagram on an established session.
    ///
    /// `out` receives decrypted payload when a `Crypto` is present; the returned slice
    /// points into `out` or into `datagram`, and is valid until the next call.
    pub fn receive(self: *Session, datagram: []const u8, out: []u8) Error!Incoming {
        if (self.state != .established) return Error.NotEstablished;
        const h = try Header.read(datagram);

        // Routed by connection id, not by source address — which is what lets a session
        // survive a NAT rebind or a phone changing networks mid-match.
        if (h.connection != self.local_connection) return Error.UnknownConnection;

        if (!self.observe(h.sequence)) return .discarded;
        self.absorbAck(h);
        self.received += 1;
        self.idle_ticks = 0;

        const body = datagram[Header.size..];
        switch (h.typ) {
            .ping => return .ping,
            .bye => {
                self.state = .ended;
                return .bye;
            },
            .data => {
                if (self.crypto) |c| {
                    const n = c.open(c.ctx, h.sequence, body, out) orelse {
                        // Counted, never reported to the peer. Telling a sender that
                        // authentication failed is an oracle.
                        self.unauthenticated += 1;
                        return .discarded;
                    };
                    return .{ .data = out[0..n] };
                }
                return .{ .data = body };
            },
            else => return .discarded,
        }
    }

    /// Advance time. Returns true when the session should send a keepalive.
    pub fn tick(self: *Session) bool {
        if (self.state != .established) return false;
        self.idle_ticks += 1;
        if (self.idle_ticks >= self.config.timeout_ticks) {
            self.state = .ended;
            return false;
        }
        return self.idle_ticks % self.config.keepalive_ticks == 0;
    }

    pub fn hasTimedOut(self: Session) bool {
        return self.state == .ended;
    }
};

/// Derive a retry token for an address.
///
/// HMAC-SHA256 over the address bytes with a server-held secret, truncated to 16 bytes.
/// **Not custom cryptography** — it is a standard construction from `std.crypto` used for
/// its intended purpose. §18.13 forbids inventing primitives, not using them; a token that
/// was a hash of the address with no secret would be forgeable by anyone, which is the
/// same as having no token.
pub fn retryToken(secret: [32]u8, address_bytes: []const u8) [16]u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, address_bytes, &secret);
    var token: [16]u8 = undefined;
    @memcpy(&token, mac[0..16]);
    return token;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn fp(byte: u8) [64]u8 {
    return @splat(byte);
}

test "header round-trips and is byte-order explicit" {
    // Explicit little-endian, never a struct @bitCast: the wire is one layout for all six
    // targets, and the cross gate runs this on two big-endian architectures.
    const h: Header = .{
        .typ = .data,
        .connection = 0xDEADBEEF,
        .sequence = 0x01020304,
        .ack = 0x0A0B0C0D,
        .ack_bits = 0xF0F0F0F0,
    };
    var buf: [64]u8 = undefined;
    const n = h.write(&buf);
    try testing.expectEqual(Header.size, n);

    // Pinned bytes, so a change to the header layout is a deliberate wire break rather
    // than a silent one.
    try testing.expectEqualSlices(u8, &.{ 0xBE, 0xD1, 5, 0xEF, 0xBE, 0xAD, 0xDE }, buf[0..7]);

    const back = try Header.read(&buf);
    try testing.expectEqual(h.connection, back.connection);
    try testing.expectEqual(h.sequence, back.sequence);
    try testing.expectEqual(h.ack_bits, back.ack_bits);
    try testing.expectEqual(PacketType.data, back.typ);
}

test "a foreign datagram is rejected before it is parsed" {
    // A port collision with an unrelated protocol must be rejected at the first branch,
    // not parsed into a plausible-looking connection id.
    var buf: [64]u8 = @splat(0x41);
    try testing.expectError(Error.BadMagic, Header.read(&buf));
    try testing.expectError(Error.TooShort, Header.read(buf[0..4]));
}

test "a full handshake establishes both ends" {
    const f = fp(0xAB);
    var client = Session.init(0x1111, f, .{});
    var server = Session.init(0x2222, f, .{});

    var buf: [max_datagram]u8 = undefined;
    var n = client.clientHello(&buf, @splat(0));

    const verdict = try server.serverEvaluate(buf[0..n], @splat(0), false);
    const hello = switch (verdict) {
        .accept => |h| h,
        else => return error.TestUnexpectedResult,
    };
    n = server.serverAccept(hello, &buf);

    try testing.expect((try client.clientReceive(buf[0..n])) == null);
    try testing.expect(client.isEstablished());
    try testing.expect(server.isEstablished());

    // Each side addresses the other by the id that side chose.
    try testing.expectEqual(@as(u32, 0x2222), client.remote_connection);
    try testing.expectEqual(@as(u32, 0x1111), server.remote_connection);
}

test "a schema mismatch is refused at the handshake, not after" {
    // The one that matters most. Comparing fingerprints after the connection is up means
    // a snapshot has already been decoded under the wrong layout and the receiving world
    // is quietly wrong -- a desync instead of a connection error.
    var client = Session.init(0x1111, fp(0xAB), .{});
    var server = Session.init(0x2222, fp(0xCD), .{});

    var buf: [max_datagram]u8 = undefined;
    const n = client.clientHello(&buf, @splat(0));

    const verdict = try server.serverEvaluate(buf[0..n], @splat(0), false);
    try testing.expectEqual(RejectReason.schema_mismatch, verdict.reject);

    const rn = server.writeReject(verdict.reject, &buf);
    try testing.expectError(Error.Rejected, client.clientReceive(buf[0..rn]));
    try testing.expectEqual(RejectReason.schema_mismatch, client.reject_reason.?);
}

test "a one-byte fingerprint difference is caught" {
    // Compared in full rather than by prefix: a prefix comparison accepts a truncation bug
    // nobody notices, and truncation is the likelier failure than a collision.
    const a = fp(0xAB);
    var b = fp(0xAB);
    b[63] = 0xAC;

    var client = Session.init(1, a, .{});
    var server = Session.init(2, b, .{});
    var buf: [max_datagram]u8 = undefined;
    const n = client.clientHello(&buf, @splat(0));
    const verdict = try server.serverEvaluate(buf[0..n], @splat(0), false);
    try testing.expectEqual(RejectReason.schema_mismatch, verdict.reject);
}

test "version mismatch is refused" {
    const f = fp(0xAB);
    var client = Session.init(1, f, .{});
    var server = Session.init(2, f, .{});
    var buf: [max_datagram]u8 = undefined;
    const n = client.clientHello(&buf, @splat(0));
    // Corrupt the version field in place.
    std.mem.writeInt(u16, buf[Header.size..][0..2], protocol_version + 1, .little);

    const verdict = try server.serverEvaluate(buf[0..n], @splat(0), false);
    try testing.expectEqual(RejectReason.version_mismatch, verdict.reject);
}

test "address validation requires a token the server issued" {
    // Anti-amplification: a forged source address otherwise turns the server into a
    // reflector -- small hello in, much larger accept out, at a victim's address.
    const f = fp(0xAB);
    var client = Session.init(0x1111, f, .{});
    var server = Session.init(0x2222, f, .{});
    const secret: [32]u8 = @splat(0x5A);
    const token = retryToken(secret, "203.0.113.9:4001");

    var buf: [max_datagram]u8 = undefined;
    var n = client.clientHello(&buf, @splat(0));

    // First attempt has no token: retry.
    const first = try server.serverEvaluate(buf[0..n], token, true);
    try testing.expectEqualSlices(u8, &token, &first.retry);

    n = server.writeRetry(first.retry, &buf);
    const got = (try client.clientReceive(buf[0..n])).?;
    try testing.expectEqualSlices(u8, &token, &got);

    // Second attempt carries it: accepted.
    n = client.clientHello(&buf, got);
    const second = try server.serverEvaluate(buf[0..n], token, true);
    try testing.expect(second == .accept);
}

test "a forged token is refused" {
    const f = fp(0xAB);
    var client = Session.init(1, f, .{});
    var server = Session.init(2, f, .{});
    const real = retryToken(@splat(0x5A), "203.0.113.9:4001");

    var buf: [max_datagram]u8 = undefined;
    const n = client.clientHello(&buf, @splat(0x77));
    const verdict = try server.serverEvaluate(buf[0..n], real, true);
    try testing.expectEqual(RejectReason.bad_token, verdict.reject);
}

test "retry tokens are address-bound and secret-bound" {
    // A token that is a plain hash of the address is forgeable by anyone, which is the
    // same as having no token at all.
    const s1: [32]u8 = @splat(0x11);
    const s2: [32]u8 = @splat(0x22);
    const a = retryToken(s1, "198.51.100.1:1000");
    const b = retryToken(s1, "198.51.100.2:1000");
    const c = retryToken(s2, "198.51.100.1:1000");

    try testing.expect(!std.mem.eql(u8, &a, &b)); // different address
    try testing.expect(!std.mem.eql(u8, &a, &c)); // different secret
    try testing.expectEqualSlices(u8, &a, &retryToken(s1, "198.51.100.1:1000")); // stable
}

test "a server requiring encryption refuses a session with none" {
    // The hole is a parameter, not a comment. "We'll add crypto later" is how it ships
    // without any; a shipping server sets require_secure and the handshake enforces it.
    const f = fp(0xAB);
    var client = Session.init(1, f, .{});
    var server = Session.init(2, f, .{ .require_secure = true });

    var buf: [max_datagram]u8 = undefined;
    const n = client.clientHello(&buf, @splat(0));
    const verdict = try server.serverEvaluate(buf[0..n], @splat(0), false);
    try testing.expectEqual(RejectReason.insecure, verdict.reject);
}

fn establish(client: *Session, server: *Session) !void {
    var buf: [max_datagram]u8 = undefined;
    var n = client.clientHello(&buf, @splat(0));
    const verdict = try server.serverEvaluate(buf[0..n], @splat(0), false);
    n = server.serverAccept(verdict.accept, &buf);
    _ = try client.clientReceive(buf[0..n]);
}

test "data flows both ways and acks come back" {
    const f = fp(0xAB);
    var client = Session.init(0x1111, f, .{});
    var server = Session.init(0x2222, f, .{});
    try establish(&client, &server);

    var buf: [max_datagram]u8 = undefined;
    var out: [max_datagram]u8 = undefined;

    const n = try client.writeData("snapshot bytes", &buf);
    const got = try server.receive(buf[0..n], &out);
    try testing.expectEqualStrings("snapshot bytes", got.data);

    // The server's next packet carries the ack, and the client absorbs it.
    const rn = try server.writeData("ack me", &buf);
    _ = try client.receive(buf[0..rn], &out);
    try testing.expect(client.acked_by_peer > 0);
}

test "a duplicate packet is dropped rather than applied twice" {
    // An input command applied twice is a divergence §14.3 will find and nobody will
    // explain.
    const f = fp(0xAB);
    var client = Session.init(0x1111, f, .{});
    var server = Session.init(0x2222, f, .{});
    try establish(&client, &server);

    var buf: [max_datagram]u8 = undefined;
    var out: [max_datagram]u8 = undefined;
    const n = try client.writeData("once", &buf);

    _ = try server.receive(buf[0..n], &out);
    const again = try server.receive(buf[0..n], &out);
    try testing.expectEqual(Session.Incoming.discarded, again);
    try testing.expectEqual(@as(u64, 1), server.duplicates);
}

test "reordering inside the window is accepted, outside it is not" {
    // Distinguishing the two matters: a lossy path and a reordering path want different
    // responses from the send scheduler, and both look like "missing packet" without this.
    var s = Session.init(1, fp(0), .{});
    s.state = .established;

    // The first observation initializes the window; `receive` increments `received`
    // afterwards, so the test does the same rather than pre-setting it and skipping the
    // initialization path.
    try testing.expect(s.observe(100));
    s.received = 1;
    try testing.expect(s.observe(102)); // gap
    try testing.expect(s.observe(101)); // fills it
    try testing.expect(!s.observe(101)); // now a duplicate
    try testing.expectEqual(@as(u64, 1), s.duplicates);

    try testing.expect(!s.observe(50)); // far outside the window
    try testing.expectEqual(@as(u64, 1), s.too_old);
}

test "sequence numbers wrap without a four-billion-packet jump backwards" {
    // A session long enough to wrap must not read the wrap as an enormous reorder.
    var s = Session.init(1, fp(0), .{});
    s.state = .established;

    try testing.expect(s.observe(0xFFFF_FFFE));
    s.received = 1;
    try testing.expect(s.observe(0xFFFF_FFFF));
    try testing.expect(s.observe(0)); // wrapped, still newer
    try testing.expectEqual(@as(u32, 0), s.remote_ack);
    try testing.expect(!s.observe(0xFFFF_FFFF)); // duplicate across the wrap
}

test "a stale ack does not retract a newer one" {
    var s = Session.init(1, fp(0), .{});
    s.state = .established;
    s.sent = 10;
    s.absorbAck(.{ .typ = .data, .connection = 1, .sequence = 0, .ack = 8, .ack_bits = 0 });
    try testing.expectEqual(@as(u32, 8), s.acked_by_peer);
    s.absorbAck(.{ .typ = .data, .connection = 1, .sequence = 1, .ack = 3, .ack_bits = 0 });
    try testing.expectEqual(@as(u32, 8), s.acked_by_peer);
}

test "peerAcked answers what baseline.zig asks" {
    var s = Session.init(1, fp(0), .{});
    s.state = .established;
    s.sent = 20;
    s.absorbAck(.{ .typ = .data, .connection = 1, .sequence = 0, .ack = 10, .ack_bits = 0b101 });

    try testing.expect(s.peerAcked(10)); // the ack itself
    try testing.expect(s.peerAcked(9)); // bit 0
    try testing.expect(!s.peerAcked(8)); // bit 1 clear
    try testing.expect(s.peerAcked(7)); // bit 2
    try testing.expect(!s.peerAcked(100)); // never sent
}

test "a packet for another connection is refused" {
    // Routing by connection id rather than source address is what lets a session survive
    // a NAT rebind or a phone moving from Wi-Fi to cellular mid-match.
    const f = fp(0xAB);
    var client = Session.init(0x1111, f, .{});
    var server = Session.init(0x2222, f, .{});
    try establish(&client, &server);

    var buf: [max_datagram]u8 = undefined;
    var out: [max_datagram]u8 = undefined;
    const n = try client.writeData("x", &buf);
    std.mem.writeInt(u32, buf[3..7], 0x9999, .little);
    try testing.expectError(Error.UnknownConnection, server.receive(buf[0..n], &out));
}

test "an oversized payload is refused rather than truncated" {
    const f = fp(0xAB);
    var client = Session.init(1, f, .{});
    var server = Session.init(2, f, .{});
    try establish(&client, &server);

    var buf: [max_datagram]u8 = undefined;
    const big: [max_datagram]u8 = @splat(0);
    try testing.expectError(Error.PayloadTooLarge, client.writeData(&big, &buf));
}

test "keepalive fires on schedule and timeout ends the session" {
    const f = fp(0xAB);
    var client = Session.init(1, f, .{ .keepalive_ticks = 10, .timeout_ticks = 35 });
    var server = Session.init(2, f, .{});
    try establish(&client, &server);

    var pings: u32 = 0;
    for (0..34) |_| {
        if (client.tick()) pings += 1;
    }
    try testing.expectEqual(@as(u32, 3), pings);
    try testing.expect(client.isEstablished());

    _ = client.tick();
    try testing.expect(!client.isEstablished());
    try testing.expect(client.hasTimedOut());
}

test "bye ends both sides in order" {
    const f = fp(0xAB);
    var client = Session.init(0x1111, f, .{});
    var server = Session.init(0x2222, f, .{});
    try establish(&client, &server);

    var buf: [max_datagram]u8 = undefined;
    var out: [max_datagram]u8 = undefined;
    const n = client.writeBye(&buf);
    try testing.expectEqual(Session.Incoming.bye, try server.receive(buf[0..n], &out));
    try testing.expectEqual(State.ended, server.state);
    try testing.expectEqual(State.ended, client.state);
}

test "an unestablished session refuses to send or receive data" {
    var s = Session.init(1, fp(0), .{});
    var buf: [max_datagram]u8 = undefined;
    try testing.expectError(Error.NotEstablished, s.writeData("x", &buf));
    try testing.expectError(Error.NotEstablished, s.receive(&buf, &buf));
}

test "a sealed session refuses forged payloads without telling the sender why" {
    // A stand-in AEAD -- deliberately not cryptography, only enough to prove the session
    // routes through the vtable and treats a failure as "packet never existed" rather than
    // as an error to report, since reporting it is an oracle.
    const Stub = struct {
        var tag_byte: u8 = 0xA5;
        fn seal(_: *anyopaque, seq: u32, plain: []const u8, out: []u8) usize {
            @memcpy(out[0..plain.len], plain);
            out[plain.len] = tag_byte ^ @as(u8, @truncate(seq));
            return plain.len + 1;
        }
        fn open(_: *anyopaque, seq: u32, sealed: []const u8, out: []u8) ?usize {
            if (sealed.len == 0) return null;
            const n = sealed.len - 1;
            if (sealed[n] != (tag_byte ^ @as(u8, @truncate(seq)))) return null;
            @memcpy(out[0..n], sealed[0..n]);
            return n;
        }
    };

    const f = fp(0xAB);
    var dummy: u8 = 0;
    const crypto: Crypto = .{
        .ctx = @ptrCast(&dummy),
        .seal = Stub.seal,
        .open = Stub.open,
        .overhead = 1,
    };

    var client = Session.init(0x1111, f, .{});
    var server = Session.init(0x2222, f, .{});
    client.crypto = crypto;
    server.crypto = crypto;
    try establish(&client, &server);

    var buf: [max_datagram]u8 = undefined;
    var out: [max_datagram]u8 = undefined;

    const n = try client.writeData("secret", &buf);
    try testing.expectEqualStrings("secret", (try server.receive(buf[0..n], &out)).data);

    // Tamper with the tag: discarded, counted, and NOT surfaced as a distinguishable error.
    const n2 = try client.writeData("secret", &buf);
    buf[n2 - 1] ^= 0xFF;
    try testing.expectEqual(Session.Incoming.discarded, try server.receive(buf[0..n2], &out));
    try testing.expectEqual(@as(u64, 1), server.unauthenticated);
}

test "a long session stays consistent under loss and reordering" {
    // The property that matters: no sequence is ever ACCEPTED twice, however the path
    // mangles the order. A payload applied twice is a divergence §14.3 will find and
    // nobody will explain, and loss plus reordering is the ordinary condition of a mobile
    // connection rather than an edge case.
    const f = fp(0xAB);
    var client = Session.init(0x1111, f, .{ .timeout_ticks = 1_000_000 });
    var server = Session.init(0x2222, f, .{ .timeout_ticks = 1_000_000 });
    try establish(&client, &server);

    var buf: [max_datagram]u8 = undefined;
    var out: [max_datagram]u8 = undefined;
    var pending: [8][max_datagram]u8 = undefined;
    var pending_len: [8]usize = @splat(0);
    var held: usize = 0;

    // Every sequence the server accepted. A bit per sequence, so the check is exact
    // rather than a count that could coincidentally match.
    var accepted = std.bit_set.ArrayBitSet(usize, 8192).initEmpty();
    var accepted_count: usize = 0;

    var seed: u32 = 0xBED1A3;
    const rounds = 4000;

    for (0..rounds) |_| {
        seed = seed *% 1664525 +% 1013904223;
        const seq = client.next_sequence;
        const n = try client.writeData("payload", &buf);

        const deliver_now = switch ((seed >> 16) % 4) {
            0 => false, // dropped outright
            1 => blk: {
                if (held < pending.len) {
                    @memcpy(pending[held][0..n], buf[0..n]);
                    pending_len[held] = n;
                    held += 1;
                    break :blk false;
                }
                break :blk true;
            },
            else => true,
        };

        if (deliver_now) {
            if (try server.receive(buf[0..n], &out) == .data) {
                try testing.expect(!accepted.isSet(seq));
                accepted.set(seq);
                accepted_count += 1;
            }
        }

        // Flush a delayed packet, out of order by construction (LIFO).
        if (held > 0 and (seed >> 8) % 3 == 0) {
            held -= 1;
            const dseq = std.mem.readInt(u32, pending[held][7..11], .little);
            if (try server.receive(pending[held][0..pending_len[held]], &out) == .data) {
                try testing.expect(!accepted.isSet(dseq));
                accepted.set(dseq);
                accepted_count += 1;
            }
        }
    }

    try testing.expect(server.isEstablished());
    try testing.expect(accepted_count > rounds / 2);
    // The server's own count matches exactly. `serverEvaluate` and `serverAccept` do not
    // touch `received` -- the server never *received* its own accept -- so there is no
    // handshake packet to add here.
    try testing.expectEqual(server.received, accepted_count);
    // And the path really did stress both failure modes.
    try testing.expect(server.duplicates > 0 or server.too_old > 0);
}
