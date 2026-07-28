//! Bit-level reader and writer.
//!
//! `ARCHITECTURE.md` §14.2 requires a "capability-based, length-checked reader for every
//! packet, save, replay, and authoring-transaction parser. No ad-hoc byte walking at any
//! trust boundary." This is that reader. Every read is bounds-checked against a limit
//! fixed at construction, and there is no API that advances the cursor without checking.
//!
//! A malformed packet must produce an error, never a panic and never a read past the
//! buffer. That is why `Reader` has no `assume`-shaped escape hatch: the fast path and
//! the safe path are the same path. Per `AGENTS.md` §3 this module compiles `ReleaseSafe`
//! regardless of the surrounding build mode — packet parse is on the untrusted side of a
//! trust boundary and Zig's safety checks are cheaper than the CVE.
//!
//! **Bit order is defined here and is part of the wire format.** Bits fill each byte
//! LSB-first, bytes ascend. It is not derived from host endianness, because two peers on
//! different architectures must agree and `ARCHITECTURE.md` §7 says cross-architecture
//! agreement is never assumed, only constructed.

const std = @import("std");

/// Largest single read or write. 64 bits is the widest scalar in `wire.WireType`.
pub const max_bits: u7 = 64;

fn mask(bits: u7) u64 {
    if (bits == 0) return 0;
    if (bits >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(bits)) - 1;
}

/// Bit positions are `u64`, not `usize`, and that is a correctness requirement rather
/// than caution. On a 32-bit target — wasm32 is a shipping target per
/// `docs/CONFORMANCE_PROFILES.md` §2 — a 512 MiB buffer has 4.29e9 bit positions, which
/// does not fit `u32`. `ARCHITECTURE.md` §4.1 puts the wasm32 streaming budget "under
/// 2GB" and §14.2 scopes this reader to "every packet, save, replay, and
/// authoring-transaction parser", none of which is bounded to snapshot size, so buffers
/// in that range are representable rather than hypothetical.
///
/// Capping the input length instead does not work: `@min(len, cap) * 8` still overflows,
/// because the bound is not visible to the overflow check at the multiply. The offsets
/// have to be wide enough for the data.
pub const Writer = struct {
    buf: []u8,
    bit_pos: u64 = 0,

    pub const Error = error{NoSpace};

    pub fn init(buf: []u8) Writer {
        // Callers hand us a zeroed or reused buffer; we OR bits in, so it must start
        // clear or stale bits survive into the packet.
        @memset(buf, 0);
        return .{ .buf = buf };
    }

    pub fn writeBits(self: *Writer, value: u64, bits: u7) Error!void {
        std.debug.assert(bits <= max_bits);
        if (bits == 0) return;
        if (self.bit_pos + bits > @as(u64, self.buf.len) * 8) return error.NoSpace;

        var v = value & mask(bits);
        var remaining: u7 = bits;
        while (remaining > 0) {
            const byte_idx: usize = @intCast(self.bit_pos >> 3);
            const bit_off: u3 = @intCast(self.bit_pos & 7);
            const space: u7 = 8 - @as(u7, bit_off);
            const take: u7 = @min(remaining, space);

            const chunk: u8 = @truncate(v & mask(take));
            self.buf[byte_idx] |= chunk << bit_off;

            v >>= @intCast(take);
            remaining -= take;
            self.bit_pos += take;
        }
    }

    pub fn writeBool(self: *Writer, v: bool) Error!void {
        try self.writeBits(@intFromBool(v), 1);
    }

    pub fn bitsWritten(self: Writer) u64 {
        return self.bit_pos;
    }

    /// Bytes occupied, rounded up. Trailing padding bits are zero.
    pub fn bytesWritten(self: Writer) usize {
        return @intCast((self.bit_pos + 7) >> 3);
    }

    pub fn written(self: Writer) []const u8 {
        return self.buf[0..self.bytesWritten()];
    }
};

pub const Reader = struct {
    buf: []const u8,
    bit_pos: u64 = 0,
    /// Hard limit in bits. Never exceeds the buffer, and may be tighter when a caller
    /// hands out a sub-range — that is the capability part: a nested parser physically
    /// cannot read its parent's bytes.
    bit_limit: u64,

    pub const Error = error{ EndOfStream, Malformed };

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf, .bit_limit = @as(u64, buf.len) * 8 };
    }

    /// A reader over the next `bits` bits only, advancing the parent past them.
    /// The child cannot read beyond its grant even if it is buggy or hostile.
    pub fn subReader(self: *Reader, bits: u64) Error!Reader {
        // Subtract rather than add. `bit_pos + bits` overflows usize for a large enough
        // attacker-supplied length, which in ReleaseSafe is a panic — and this is the one
        // reader API taking an unbounded count, so it is the only place the arithmetic can
        // be driven there. `bit_limit >= bit_pos` always holds, so the subtraction cannot
        // underflow.
        if (bits > self.bit_limit - self.bit_pos) return error.EndOfStream;
        const child: Reader = .{
            .buf = self.buf,
            .bit_pos = self.bit_pos,
            .bit_limit = self.bit_pos + bits,
        };
        self.bit_pos += bits;
        return child;
    }

    pub fn readBits(self: *Reader, bits: u7) Error!u64 {
        std.debug.assert(bits <= max_bits);
        if (bits == 0) return 0;
        if (self.bit_pos + bits > self.bit_limit) return error.EndOfStream;

        var out: u64 = 0;
        var produced: u7 = 0;
        var remaining: u7 = bits;
        while (remaining > 0) {
            const byte_idx: usize = @intCast(self.bit_pos >> 3);
            const bit_off: u3 = @intCast(self.bit_pos & 7);
            const space: u7 = 8 - @as(u7, bit_off);
            const take: u7 = @min(remaining, space);

            const chunk: u64 = (self.buf[byte_idx] >> bit_off) & @as(u8, @truncate(mask(take)));
            out |= chunk << @intCast(produced);

            produced += take;
            remaining -= take;
            self.bit_pos += take;
        }
        return out;
    }

    pub fn readBool(self: *Reader) Error!bool {
        return (try self.readBits(1)) != 0;
    }

    pub fn bitsRemaining(self: Reader) u64 {
        return self.bit_limit - self.bit_pos;
    }

    pub fn bitsRead(self: Reader) u64 {
        return self.bit_pos;
    }
};

// ---------------------------------------------------------------------------

test "round-trips every width at every bit offset" {
    // The offsets are where bit packing actually breaks: a value straddling a byte
    // boundary is a different code path from one that does not.
    var buf: [64]u8 = undefined;
    for (0..8) |pad| {
        for (1..65) |bits_usize| {
            const bits: u7 = @intCast(bits_usize);
            const value: u64 = 0xDEAD_BEEF_CAFE_F00D & mask(bits);

            var w = Writer.init(&buf);
            if (pad > 0) try w.writeBits(0, @intCast(pad));
            try w.writeBits(value, bits);

            var r = Reader.init(&buf);
            if (pad > 0) _ = try r.readBits(@intCast(pad));
            try std.testing.expectEqual(value, try r.readBits(bits));
        }
    }
}

test "reader refuses to read past the end rather than panicking" {
    var buf = [_]u8{0xFF} ** 2;
    var r = Reader.init(&buf);
    _ = try r.readBits(16);
    try std.testing.expectError(error.EndOfStream, r.readBits(1));
}

test "writer refuses to overrun rather than corrupting the next allocation" {
    var buf = [_]u8{0} ** 1;
    var w = Writer.init(&buf);
    try w.writeBits(0xFF, 8);
    try std.testing.expectError(error.NoSpace, w.writeBits(1, 1));
}

test "a sub-reader cannot read beyond its grant" {
    // The capability property. A nested parser handed 8 bits must not be able to
    // reach the 8 bits that follow, however it is written.
    var buf = [_]u8{ 0xAA, 0xBB, 0xCC };
    var parent = Reader.init(&buf);

    var child = try parent.subReader(8);
    try std.testing.expectEqual(@as(u64, 0xAA), try child.readBits(8));
    try std.testing.expectError(error.EndOfStream, child.readBits(1));

    // The parent resumed exactly where the grant ended.
    try std.testing.expectEqual(@as(u64, 0xBB), try parent.readBits(8));
}

test "a sub-reader larger than the remaining input is refused at grant time" {
    var buf = [_]u8{0x01};
    var parent = Reader.init(&buf);
    try std.testing.expectError(error.EndOfStream, parent.subReader(9));
}

test "a sub-reader length near usize max is refused rather than overflowing" {
    // subReader is the only reader API taking an unbounded count, so it is the only
    // place a hostile length can drive the bounds arithmetic into an overflow panic.
    var buf = [_]u8{ 0x01, 0x02 };
    var parent = Reader.init(&buf);
    try std.testing.expectError(error.EndOfStream, parent.subReader(std.math.maxInt(u64)));
    try std.testing.expectError(error.EndOfStream, parent.subReader(std.math.maxInt(u64) - 3));
    // And the parent is undamaged: a refused grant must not advance the cursor.
    try std.testing.expectEqual(@as(u64, 0x01), try parent.readBits(8));
}

test "bit offsets are wide enough for a 32-bit target's largest buffer" {
    // Regression. `bit_pos`/`bit_limit` were `usize`, so on wasm32 (a shipping target)
    // any buffer at or above 512 MiB overflowed `buf.len * 8` in the constructor — a
    // panic before a single bit was parsed, on data ARCHITECTURE.md §14.2 puts on the
    // untrusted side.
    //
    // Capping the input length does not fix it: `@min(len, cap) * 8` still overflows,
    // because the bound is not visible to the overflow check at the multiply. The
    // offsets have to be wide enough for the data, so they are u64 on every target.
    try std.testing.expect(@bitSizeOf(@FieldType(Reader, "bit_limit")) >= 64);
    try std.testing.expect(@bitSizeOf(@FieldType(Reader, "bit_pos")) >= 64);
    try std.testing.expect(@bitSizeOf(@FieldType(Writer, "bit_pos")) >= 64);

    // 512 MiB in bits exceeds maxInt(u32); the type must represent it.
    const half_gib_bits: u64 = @as(u64, 512 * 1024 * 1024) * 8;
    try std.testing.expect(half_gib_bits > std.math.maxInt(u32));
}

test "trailing padding bits are zero" {
    // A packet whose tail carries stale heap bytes leaks memory contents to a peer.
    var buf: [4]u8 = undefined;
    @memset(&buf, 0xFF);
    var w = Writer.init(&buf);
    try w.writeBits(0b1, 1);
    try std.testing.expectEqual(@as(u8, 0b1), w.buf[0]);
    try std.testing.expectEqual(@as(u8, 0), w.buf[1]);
}

test "zero-width reads and writes are identities" {
    var buf: [1]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeBits(0xFFFF, 0);
    try std.testing.expectEqual(@as(u64, 0), w.bitsWritten());

    var r = Reader.init(&buf);
    try std.testing.expectEqual(@as(u64, 0), try r.readBits(0));
    try std.testing.expectEqual(@as(u64, 0), r.bitsRead());
}

test "writes are truncated to their declared width" {
    // Otherwise a caller passing an out-of-range value silently corrupts the next field.
    var buf: [2]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeBits(0xFF, 4);
    try w.writeBits(0b1010, 4);

    var r = Reader.init(&buf);
    try std.testing.expectEqual(@as(u64, 0xF), try r.readBits(4));
    try std.testing.expectEqual(@as(u64, 0b1010), try r.readBits(4));
}
