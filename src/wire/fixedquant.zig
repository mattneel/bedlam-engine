//! Integer-only quantization over `fpz.Fixed`.
//!
//! The float version of this file was deterministic *by argument* — IEEE-754 specifies
//! basic arithmetic exactly, so it was probably fine. This one is deterministic *by
//! construction*: there is no float in it, so there is nothing to argue about.
//!
//! That distinction is `ARCHITECTURE.md` §7's whole point. It calls bit-exact
//! cross-architecture float determinism "folklore" and says not to design around it. A
//! quantizer sitting between the simulation and the wire is inside the rollback boundary
//! on the decode side — a client dequantizes a correction and re-simulates from it — so
//! "probably fine" is the wrong standard.
//!
//! Everything here is `i128` intermediate, integer division, and total. `zig build cross`
//! re-verifies it on big-endian and 32-bit.

const std = @import("std");
const fpz = @import("fpz");

pub fn maxQuantized(bits: u7) u64 {
    if (bits == 0) return 0;
    if (bits >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(bits)) - 1;
}

/// Map a `Fixed` in `[lo, hi]` onto `bits` bits.
///
/// Out-of-range clamps rather than wraps: a wrapped position teleports an entity across
/// the map, a clamped one pins it to the boundary, and only one of those is debuggable.
pub fn quantize(v: fpz.Fixed, bits: u7, lo: fpz.Fixed, hi: fpz.Fixed) u64 {
    std.debug.assert(hi.raw > lo.raw);
    const limit = maxQuantized(bits);
    if (limit == 0) return 0;

    const span: i128 = @as(i128, hi.raw) - @as(i128, lo.raw);
    const clamped: i128 = std.math.clamp(@as(i128, v.raw), @as(i128, lo.raw), @as(i128, hi.raw));
    const offset: i128 = clamped - @as(i128, lo.raw);

    // Round to nearest, ties away from zero — matching fpz's stated rounding rule so the
    // two layers cannot disagree at a boundary. All operands are non-negative here.
    const scaled: i128 = @divTrunc(offset * @as(i128, limit) * 2 + span, span * 2);
    return @intCast(std.math.clamp(scaled, 0, @as(i128, limit)));
}

pub fn dequantize(q: u64, bits: u7, lo: fpz.Fixed, hi: fpz.Fixed) fpz.Fixed {
    std.debug.assert(hi.raw > lo.raw);
    const limit = maxQuantized(bits);
    if (limit == 0) return lo;

    const span: i128 = @as(i128, hi.raw) - @as(i128, lo.raw);
    const clamped_q: i128 = @min(@as(i128, q), @as(i128, limit));
    const offset: i128 = @divTrunc(clamped_q * span * 2 + @as(i128, limit), @as(i128, limit) * 2);
    return fpz.Fixed.fromRaw(@intCast(@as(i128, lo.raw) + offset));
}

/// Worst-case round-trip error, in raw fixed-point units.
pub fn resolutionRaw(bits: u7, lo: fpz.Fixed, hi: fpz.Fixed) i64 {
    const limit = maxQuantized(bits);
    if (limit == 0) return hi.raw - lo.raw;
    const span: i128 = @as(i128, hi.raw) - @as(i128, lo.raw);
    return @intCast(@divTrunc(span, @as(i128, limit) * 2) + 1);
}

// ---------------------------------------------------------------------------
// Quaternions — smallest-three, integer-only.
// ---------------------------------------------------------------------------

/// 1/sqrt(2) in Q40.24. The largest any non-maximal component of a unit quaternion can
/// be: if two components both exceeded it, the norm would exceed 1.
pub const inv_sqrt2: fpz.Fixed = fpz.Fixed.rconst(0.70710678118654752440);
pub const neg_inv_sqrt2: fpz.Fixed = fpz.Fixed.rconst(-0.70710678118654752440);

pub const QuantizedQuat = struct {
    largest: u2,
    a: u64,
    b: u64,
    c: u64,
};

/// The caller must supply a unit quaternion. Reconstruction solves for the dropped
/// component assuming a norm of 1, so a non-unit input decodes to a different rotation
/// with nothing reported anywhere.
///
/// Asserts rather than normalizing: encode runs on our own simulation state, where a
/// non-unit rotation is an upstream bug worth failing loudly on. Decode asserts nothing.
pub fn quantizeQuat(q: [4]fpz.Fixed, bits: u7) QuantizedQuat {
    if (std.debug.runtime_safety) {
        var norm_sq: i128 = 0;
        for (q) |c| norm_sq += @as(i128, c.raw) * @as(i128, c.raw);
        const one_sq: i128 = @as(i128, fpz.Fixed.ONE.raw) * @as(i128, fpz.Fixed.ONE.raw);
        const tol = @divTrunc(one_sq, 50); // 2%
        std.debug.assert(norm_sq > one_sq - tol and norm_sq < one_sq + tol);
    }

    var largest: u2 = 0;
    var largest_abs: i64 = if (q[0].raw < 0) -q[0].raw else q[0].raw;
    inline for (1..4) |i| {
        const m: i64 = if (q[i].raw < 0) -q[i].raw else q[i].raw;
        if (m > largest_abs) {
            largest_abs = m;
            largest = @intCast(i);
        }
    }

    // q and -q are the same rotation. Normalising the sign of the dropped component lets
    // the decoder always reconstruct it as positive.
    const flip = q[largest].raw < 0;

    var out: [3]u64 = undefined;
    var n: usize = 0;
    inline for (0..4) |i| {
        if (i != largest) {
            const v = if (flip) fpz.Fixed.fromRaw(-q[i].raw) else q[i];
            out[n] = quantize(v, bits, neg_inv_sqrt2, inv_sqrt2);
            n += 1;
        }
    }
    return .{ .largest = largest, .a = out[0], .b = out[1], .c = out[2] };
}

/// Always returns a unit quaternion, for every input including hostile ones.
///
/// Runs on bytes from an untrusted peer, so it asserts nothing and rejects nothing. Two
/// hazards, both handled by renormalizing the three transmitted components:
///
///   - Honest input can round just past a sum of squares of 1, making the reconstructed
///     component the square root of a negative number.
///   - Hostile input can set all three near ±1/√2 for a sum of squares up to 1.5, which
///     clamping alone would turn into a quaternion of norm ~1.22 — not a rotation. It
///     would scale and skew every transform it reached, and `quantizeQuat` asserts on
///     unit norm, so a peer could trip an assertion in our own encoder by choosing what
///     to send us.
///
/// `fpz.sqrt` is integer-only, which is why this whole path can be.
pub fn dequantizeQuat(qq: QuantizedQuat, bits: u7) [4]fpz.Fixed {
    var a = dequantize(qq.a, bits, neg_inv_sqrt2, inv_sqrt2);
    var b = dequantize(qq.b, bits, neg_inv_sqrt2, inv_sqrt2);
    var c = dequantize(qq.c, bits, neg_inv_sqrt2, inv_sqrt2);

    const one_sq: i128 = @as(i128, fpz.Fixed.ONE.raw) * @as(i128, fpz.Fixed.ONE.raw);
    var sum_sq: i128 = @as(i128, a.raw) * @as(i128, a.raw) +
        @as(i128, b.raw) * @as(i128, b.raw) +
        @as(i128, c.raw) * @as(i128, c.raw);

    if (sum_sq > one_sq) {
        // Scale the three down so the sum of squares is exactly 1 and the reconstructed
        // component is zero, rather than imaginary.
        const scale = fpz.Fixed.div(fpz.Fixed.ONE, fpz.sqrt(fixedFromSquare(sum_sq)));
        a = fpz.Fixed.mul(a, scale);
        b = fpz.Fixed.mul(b, scale);
        c = fpz.Fixed.mul(c, scale);
        sum_sq = @as(i128, a.raw) * @as(i128, a.raw) +
            @as(i128, b.raw) * @as(i128, b.raw) +
            @as(i128, c.raw) * @as(i128, c.raw);
    }

    const remainder = if (sum_sq >= one_sq) fpz.Fixed.ZERO else fpz.sqrt(fixedFromSquare(one_sq - sum_sq));

    var out: [4]fpz.Fixed = undefined;
    var n: usize = 0;
    inline for (0..4) |i| {
        if (i == qq.largest) {
            out[i] = remainder;
        } else {
            out[i] = switch (n) {
                0 => a,
                1 => b,
                else => c,
            };
            n += 1;
        }
    }
    return out;
}

/// A squared Q40.24 value has 48 fractional bits; shift back to 24 to get a `Fixed`.
fn fixedFromSquare(sq: i128) fpz.Fixed {
    const shifted = sq >> fpz.Fixed.frac_bits;
    return fpz.Fixed.fromRaw(@intCast(std.math.clamp(
        shifted,
        @as(i128, std.math.minInt(i64)),
        @as(i128, std.math.maxInt(i64)),
    )));
}

// ---------------------------------------------------------------------------

fn approxRaw(a: fpz.Fixed, b: fpz.Fixed, tol: i64) !void {
    const d = if (a.raw > b.raw) a.raw - b.raw else b.raw - a.raw;
    if (d > tol) {
        std.debug.print("\nraw {d} vs {d} (delta {d} > tol {d})\n", .{ a.raw, b.raw, d, tol });
        return error.OutOfTolerance;
    }
}

test "round trip stays within the stated resolution" {
    const bits: u7 = 16;
    const lo = fpz.Fixed.fromInt(-4096);
    const hi = fpz.Fixed.fromInt(4096);
    const tol = resolutionRaw(bits, lo, hi);

    for ([_]i64{ -4096, -1234, -1, 0, 1, 1234, 4095 }) |whole| {
        const v = fpz.Fixed.fromInt(whole);
        try approxRaw(v, dequantize(quantize(v, bits, lo, hi), bits, lo, hi), tol);
    }
}

test "out-of-range clamps rather than wrapping" {
    const bits: u7 = 12;
    const lo = fpz.Fixed.fromInt(-10);
    const hi = fpz.Fixed.fromInt(10);
    try std.testing.expectEqual(@as(u64, 0), quantize(fpz.Fixed.fromInt(-99999), bits, lo, hi));
    try std.testing.expectEqual(maxQuantized(bits), quantize(fpz.Fixed.fromInt(99999), bits, lo, hi));
}

test "endpoints are exactly representable" {
    const bits: u7 = 10;
    const lo = fpz.Fixed.fromInt(-1);
    const hi = fpz.Fixed.fromInt(1);
    try std.testing.expectEqual(@as(u64, 0), quantize(lo, bits, lo, hi));
    try std.testing.expectEqual(maxQuantized(bits), quantize(hi, bits, lo, hi));
}

test "quantize never exceeds its declared width, at any width" {
    const lo = fpz.Fixed.fromInt(-1);
    const hi = fpz.Fixed.fromInt(1);
    inline for ([_]u7{ 0, 1, 2, 7, 16, 31, 32, 33, 53, 63, 64 }) |bits| {
        for ([_]i64{ -1000, -1, 0, 1, 1000 }) |whole| {
            const q = quantize(fpz.Fixed.fromInt(whole), bits, lo, hi);
            try std.testing.expect(q <= maxQuantized(bits));
        }
    }
}

test "quaternion round trip preserves the rotation" {
    const bits: u7 = 9;
    const h = fpz.Fixed.rconst(0.5);
    const r = fpz.Fixed.rconst(0.70710678);
    const cases = [_][4]fpz.Fixed{
        .{ fpz.Fixed.ONE, fpz.Fixed.ZERO, fpz.Fixed.ZERO, fpz.Fixed.ZERO },
        .{ fpz.Fixed.ZERO, fpz.Fixed.ONE, fpz.Fixed.ZERO, fpz.Fixed.ZERO },
        .{ fpz.Fixed.ZERO, fpz.Fixed.ZERO, fpz.Fixed.ZERO, fpz.Fixed.ONE },
        .{ h, h, h, h },
        .{ fpz.Fixed.neg(h), h, fpz.Fixed.neg(h), h },
        .{ r, r, fpz.Fixed.ZERO, fpz.Fixed.ZERO },
    };

    for (cases) |q| {
        const out = dequantizeQuat(quantizeQuat(q, bits), bits);
        // |dot| == 1 for the same rotation, regardless of sign.
        var dot: i128 = 0;
        for (0..4) |i| dot += @as(i128, q[i].raw) * @as(i128, out[i].raw);
        const one_sq: i128 = @as(i128, fpz.Fixed.ONE.raw) * @as(i128, fpz.Fixed.ONE.raw);
        const abs_dot = if (dot < 0) -dot else dot;
        try std.testing.expect(abs_dot > @divTrunc(one_sq * 99, 100));
    }
}

test "decode yields a unit quaternion for every possible encoding" {
    // Exhaustive at a small width rather than sampled. A peer chooses these bits; none of
    // them may produce a non-rotation.
    const bits: u7 = 5;
    const limit = maxQuantized(bits);
    const one_sq: i128 = @as(i128, fpz.Fixed.ONE.raw) * @as(i128, fpz.Fixed.ONE.raw);

    var largest: u2 = 0;
    while (true) {
        var a: u64 = 0;
        while (a <= limit) : (a += 1) {
            var b: u64 = 0;
            while (b <= limit) : (b += 1) {
                var c: u64 = 0;
                while (c <= limit) : (c += 1) {
                    const out = dequantizeQuat(.{ .largest = largest, .a = a, .b = b, .c = c }, bits);
                    var norm_sq: i128 = 0;
                    for (out) |v| norm_sq += @as(i128, v.raw) * @as(i128, v.raw);
                    // Within 3% of unit.
                    try std.testing.expect(norm_sq > @divTrunc(one_sq * 97, 100));
                    try std.testing.expect(norm_sq < @divTrunc(one_sq * 103, 100));
                }
            }
        }
        if (largest == 3) break;
        largest += 1;
    }
}

test "a decoded quaternion re-encodes without tripping the encoder assertion" {
    // Otherwise a peer could choose bytes that make our own encoder assert when the value
    // is relayed, replayed, or carried through host migration.
    const bits: u7 = 9;
    const limit = maxQuantized(bits);
    const hostile: QuantizedQuat = .{ .largest = 0, .a = limit, .b = limit, .c = limit };
    _ = quantizeQuat(dequantizeQuat(hostile, bits), bits);
}

test "quantization is deterministic for identical input" {
    // The property the replication layer depends on: the same authoritative state must
    // produce the same bits every snapshot, or a stationary entity emits a delta forever
    // against a budget §4 calls the binding constraint.
    const bits: u7 = 16;
    const lo = fpz.Fixed.fromInt(-4096);
    const hi = fpz.Fixed.fromInt(4096);
    const v = fpz.Fixed.rconst(1234.5);
    try std.testing.expectEqual(quantize(v, bits, lo, hi), quantize(v, bits, lo, hi));
}
