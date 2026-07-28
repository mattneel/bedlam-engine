//! Quantization. Lossy on purpose, deterministic without exception.
//!
//! `BENCHMARK_CONTRACT.md` §4.1: the entire per-client snapshot budget is ~1,500 bytes
//! for ~180 entity updates, so roughly 8 bytes per update. Full-precision transforms do
//! not fit and never will; quantization is what makes the floor reachable rather than an
//! optimization applied afterwards.
//!
//! **Every operation here uses only IEEE-754 basic arithmetic** — add, subtract,
//! multiply, divide, compare, and round. No transcendentals, no FMA, no fast-math.
//! `ARCHITECTURE.md` §7 calls bit-exact cross-architecture float determinism "folklore"
//! and says not to design around it; basic operations are the exception, because IEEE-754
//! specifies them exactly and every target honours that. The one square root here is
//! `@sqrt`, which IEEE-754 also specifies exactly.
//!
//! That distinction is the whole reason this file avoids anything fancier: an encoder on
//! x86_64 and a decoder on aarch64 must agree, and §7 says agreement is constructed,
//! never assumed.

const std = @import("std");

/// Largest representable value at a given width.
pub fn maxQuantized(bits: u7) u64 {
    if (bits == 0) return 0;
    if (bits >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(bits)) - 1;
}

/// Map a bounded scalar onto `bits` bits. Values outside the range clamp rather than
/// wrap: a wrapped position teleports an entity across the map, a clamped one pins it to
/// the boundary, and only one of those is debuggable.
/// Intermediate arithmetic is f64, not f32, and the reason is not precision-for-its-own-
/// sake. `maxQuantized(32)` is 4,294,967,295, which f32 cannot represent — it rounds *up*
/// to 4,294,967,296. Multiplying a normalized 1.0 by that and rounding yields a value one
/// greater than the field's declared width, which in a bit-packed stream does not clamp,
/// it overwrites the first bit of the next field. f64 is exact for integers to 2^53, and
/// the final `@min` covers the rest.
pub fn quantize(value: f32, bits: u7, min: f32, max: f32) u64 {
    std.debug.assert(max > min);

    // Encode side, so this asserts. `std.math.clamp(NaN, min, max)` evaluates to `max`
    // under Zig's minnum/maxnum semantics, which would replicate a NaN position as the
    // map corner on every client with the server never learning — the undebuggable case
    // wearing the debuggable case's clothes. A physics blow-up producing NaN is the
    // ordinary way this happens, and the fuzz target cannot catch it because it only
    // exercises decode.
    std.debug.assert(!std.math.isNan(value));

    const limit = maxQuantized(bits);
    const steps: f64 = @floatFromInt(limit);

    const clamped = std.math.clamp(value, min, max);
    const normalized: f64 = (@as(f64, clamped) - @as(f64, min)) / (@as(f64, max) - @as(f64, min));
    // +0.5 then floor, rather than @round, so the tie-breaking rule is explicit in the
    // source and identical on every target.
    // Saturate at the ends BEFORE any conversion, rather than clamping the float and
    // converting. At bits = 64 `steps` is 2^64 (f64 cannot represent maxInt(u64) and
    // rounds up), so the scaled value can reach 2^64 — out of range for u64, which is
    // illegal behaviour and panics in ReleaseSafe. A later `@min` cannot help, because
    // the conversion has already happened. Clamping the float instead would be safe but
    // wrong: it would cap full scale below `limit`, so a maximal input would no longer
    // encode to the maximal code.
    if (normalized >= 1.0) return limit;
    if (normalized <= 0.0) return 0;

    const scaled: f64 = @floor(normalized * steps + 0.5);
    // Rounding can still push an in-range normalized value up to `steps` itself.
    if (scaled >= steps) return limit;

    return @min(limit, @as(u64, @intFromFloat(scaled)));
}

pub fn dequantize(q: u64, bits: u7, min: f32, max: f32) f32 {
    std.debug.assert(max > min);
    const steps: f64 = @floatFromInt(maxQuantized(bits));
    if (steps == 0) return min;
    const normalized: f64 = @as(f64, @floatFromInt(q)) / steps;
    return @floatCast(@as(f64, min) + normalized * (@as(f64, max) - @as(f64, min)));
}

/// Worst-case error introduced by a round trip at this width and range.
pub fn resolution(bits: u7, min: f32, max: f32) f32 {
    const steps: f64 = @floatFromInt(maxQuantized(bits));
    if (steps == 0) return max - min;
    return @floatCast((@as(f64, max) - @as(f64, min)) / steps / 2.0);
}

// ---------------------------------------------------------------------------
// Quaternions — smallest-three.
//
// A unit quaternion has three degrees of freedom, so the largest-magnitude component is
// recoverable from the other three. Sending 2 bits of index plus three quantized
// components beats sending four components outright, and the reconstruction is exact
// enough that the error is dominated by quantization rather than by the trick.
// ---------------------------------------------------------------------------

/// 1/sqrt(2). The largest any non-maximal component of a unit quaternion can be: if two
/// components both exceeded it the norm would exceed 1.
pub const inv_sqrt2: f32 = 0.70710678118654752440;

pub const QuantizedQuat = struct {
    largest: u2,
    a: u64,
    b: u64,
    c: u64,
};

/// The caller must supply a unit quaternion. Reconstruction solves for the dropped
/// component assuming a norm of 1, so a non-unit input decodes to a different rotation
/// with no error reported anywhere.
///
/// This asserts rather than normalizing. Encode runs on our own simulation state, so a
/// non-unit rotation is an upstream bug worth failing loudly on, and silently fixing it
/// here would hide it. The decode path takes hostile bytes and asserts nothing.
pub fn quantizeQuat(q: [4]f32, bits: u7) QuantizedQuat {
    if (std.debug.runtime_safety) {
        const norm_sq = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
        std.debug.assert(@abs(norm_sq - 1.0) < 0.01);
    }

    var largest: u2 = 0;
    var largest_abs: f32 = @abs(q[0]);
    inline for (1..4) |i| {
        const m = @abs(q[i]);
        if (m > largest_abs) {
            largest_abs = m;
            largest = @intCast(i);
        }
    }

    // q and -q are the same rotation. Normalising the sign of the dropped component
    // means the decoder can always reconstruct it as positive.
    const flip = q[largest] < 0;

    var out: [3]u64 = undefined;
    var n: usize = 0;
    inline for (0..4) |i| {
        if (i != largest) {
            const v = if (flip) -q[i] else q[i];
            out[n] = quantize(v, bits, -inv_sqrt2, inv_sqrt2);
            n += 1;
        }
    }

    return .{ .largest = largest, .a = out[0], .b = out[1], .c = out[2] };
}

/// Always returns a unit quaternion, for every possible input including hostile ones.
///
/// This runs on bytes from an untrusted peer, so it asserts nothing and rejects nothing —
/// every bit pattern must decode to a usable rotation. Two distinct hazards:
///
///   - Honest input can round slightly past a sum of squares of 1, making the
///     reconstructed component the square root of a negative number, i.e. NaN.
///   - Hostile input can set all three components near ±1/√2 for a sum of squares up to
///     1.5. Clamping at zero avoids the NaN but yields a quaternion of norm ~1.22, which
///     is not a rotation. It scales and skews every transform it reaches, and
///     `quantizeQuat` asserts on unit norm — so a peer could trip an assertion in *our*
///     encoder by choosing what to send us.
///
/// Renormalizing the three components covers both. The cost is paid only when the input
/// is out of range, which honest input essentially never is.
pub fn dequantizeQuat(qq: QuantizedQuat, bits: u7) [4]f32 {
    var a = dequantize(qq.a, bits, -inv_sqrt2, inv_sqrt2);
    var b = dequantize(qq.b, bits, -inv_sqrt2, inv_sqrt2);
    var c = dequantize(qq.c, bits, -inv_sqrt2, inv_sqrt2);

    var sum_sq = a * a + b * b + c * c;
    if (sum_sq > 1.0) {
        const inv = 1.0 / @sqrt(sum_sq);
        a *= inv;
        b *= inv;
        c *= inv;
        sum_sq = 1.0;
    }
    const largest_value = @sqrt(@max(0.0, 1.0 - sum_sq));

    var out: [4]f32 = undefined;
    var n: usize = 0;
    inline for (0..4) |i| {
        if (i == qq.largest) {
            out[i] = largest_value;
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

// ---------------------------------------------------------------------------

test "round trip stays inside the stated resolution" {
    const bits: u7 = 16;
    const min: f32 = -4096;
    const max: f32 = 4096;
    const tolerance = resolution(bits, min, max);

    for ([_]f32{ -4096, -1234.5, -1, 0, 0.25, 1, 1234.5, 4095.9, 4096 }) |v| {
        const round_tripped = dequantize(quantize(v, bits, min, max), bits, min, max);
        try std.testing.expect(@abs(round_tripped - v) <= tolerance * 1.001);
    }
}

test "out-of-range values clamp rather than wrap" {
    // A wrapped position teleports an entity across the map.
    const bits: u7 = 12;
    const lo = dequantize(quantize(-99999, bits, -10, 10), bits, -10, 10);
    const hi = dequantize(quantize(99999, bits, -10, 10), bits, -10, 10);
    try std.testing.expectApproxEqAbs(@as(f32, -10), lo, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), hi, 0.01);
}

test "range endpoints are exactly representable" {
    const bits: u7 = 10;
    try std.testing.expectEqual(@as(u64, 0), quantize(-1, bits, -1, 1));
    try std.testing.expectEqual(maxQuantized(bits), quantize(1, bits, -1, 1));
}

test "quantization never exceeds its declared width" {
    // If it did, the extra bits would silently corrupt the next field in the packet.
    inline for ([_]u7{ 1, 2, 7, 8, 12, 16, 24, 32 }) |bits| {
        for ([_]f32{ -1e9, -1, 0, 1, 1e9 }) |v| {
            try std.testing.expect(quantize(v, bits, -1, 1) <= maxQuantized(bits));
        }
    }
}

test "quaternion round trip preserves the rotation" {
    const bits: u7 = 9; // wire.WireType.quat_smallest_three: 2 + 3*9 = 29 bits
    const cases = [_][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 0, 1 },
        .{ 0.5, 0.5, 0.5, 0.5 },
        .{ -0.5, 0.5, -0.5, 0.5 },
        .{ 0.70710678, 0.70710678, 0, 0 },
        .{ -0.70710678, 0, 0.70710678, 0 },
    };

    for (cases) |q| {
        const out = dequantizeQuat(quantizeQuat(q, bits), bits);

        // q and -q are the same rotation, so compare via |dot|, which is 1 for
        // identical rotations regardless of sign.
        var dot: f32 = 0;
        for (0..4) |i| dot += q[i] * out[i];
        try std.testing.expect(@abs(dot) > 0.999);

        // And the result must still be a unit quaternion.
        var norm: f32 = 0;
        for (out) |c| norm += c * c;
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm, 0.01);
    }
}

test "quaternion decode never produces NaN even when rounding overshoots" {
    // The failure this guards: three components rounding up can push the sum of squares
    // past 1, making the reconstructed component sqrt of a negative number.
    const bits: u7 = 9;
    const qq: quant_test_max = .{
        .largest = 0,
        .a = maxQuantized(bits),
        .b = maxQuantized(bits),
        .c = maxQuantized(bits),
    };
    const out = dequantizeQuat(qq, bits);
    for (out) |c| try std.testing.expect(!std.math.isNan(c));
}

const quant_test_max = QuantizedQuat;

test "decode yields a unit quaternion for every possible encoding" {
    // The trust-boundary property, checked exhaustively at a small width rather than
    // sampled. A peer chooses these bits; none of them may produce a non-rotation.
    const bits: u7 = 5;
    const limit = maxQuantized(bits);
    var largest: u2 = 0;
    while (true) {
        var a: u64 = 0;
        while (a <= limit) : (a += 1) {
            var b: u64 = 0;
            while (b <= limit) : (b += 1) {
                var c: u64 = 0;
                while (c <= limit) : (c += 1) {
                    const out = dequantizeQuat(.{ .largest = largest, .a = a, .b = b, .c = c }, bits);
                    var norm: f32 = 0;
                    for (out) |v| {
                        try std.testing.expect(!std.math.isNan(v));
                        norm += v * v;
                    }
                    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm, 0.001);
                }
            }
        }
        if (largest == 3) break;
        largest += 1;
    }
}

test "a decoded quaternion can be re-encoded without tripping the encoder's assertion" {
    // Otherwise a peer could choose bytes that make our own encoder assert when the
    // value is echoed, relayed, or written to a replay.
    const bits: u7 = 9;
    const limit = maxQuantized(bits);
    const hostile: QuantizedQuat = .{ .largest = 0, .a = limit, .b = limit, .c = limit };
    const decoded = dequantizeQuat(hostile, bits);
    _ = quantizeQuat(decoded, bits);
}

test "encoder and decoder agree on the sign convention" {
    // The decoder always reconstructs the dropped component as positive, so the encoder
    // must flip the whole quaternion when it is negative. If these disagree the rotation
    // is mirrored, which looks like a physics bug rather than a codec bug.
    const bits: u7 = 12;
    const raw = [4]f32{ -0.9, 0.3, 0.2, 0.1 };
    var norm: f32 = 0;
    for (raw) |c| norm += c * c;
    norm = @sqrt(norm);
    var q: [4]f32 = undefined;
    for (raw, 0..) |c, i| q[i] = c / norm;

    const out = dequantizeQuat(quantizeQuat(q, bits), bits);
    try std.testing.expect(out[0] > 0);

    var dot: f32 = 0;
    for (0..4) |i| dot += q[i] * out[i];
    try std.testing.expect(dot < -0.99); // opposite sign, same rotation
}

test "quantize is total over every documented width" {
    // bits.max_bits documents 64 as supported. At 64, `steps` is 2^64 (f64 cannot
    // represent maxInt(u64) and rounds up), so the scaled value reaches 2^64 — out of
    // range for u64, which is illegal behaviour and panics in ReleaseSafe. The @min
    // afterwards cannot help, because the conversion happens first.
    inline for ([_]u7{ 0, 1, 2, 31, 32, 33, 52, 53, 54, 62, 63, 64 }) |bits| {
        for ([_]f32{ -1e30, -1, -0.5, 0, 0.5, 1, 1e30 }) |v| {
            const q = quantize(v, bits, -1, 1);
            try std.testing.expect(q <= maxQuantized(bits));
        }
        // And the endpoints specifically, which is where the overflow lived.
        try std.testing.expectEqual(maxQuantized(bits), quantize(1, bits, -1, 1));
        try std.testing.expectEqual(@as(u64, 0), quantize(-1, bits, -1, 1));
    }
}

test "quaternion encoding is deterministic for identical input" {
    // The property the replication layer actually depends on: the same authoritative
    // float state must produce the same bits every snapshot, or a stationary entity
    // emits a delta forever against a budget §4 calls the binding constraint.
    //
    // Note this is NOT the same as encode(decode(bits)) == bits. Smallest-three has no
    // fixed point near four-way ties: quantization can make the reconstructed component
    // smaller than a transmitted one, so re-encoding picks a different `largest` index
    // and the pair oscillates with period 2. The rotation is preserved either way. The
    // rule that follows is that the replication layer encodes from authoritative state,
    // never from a decoded value — see the note in dequantizeQuat.
    const bits: u7 = 9;
    var prng = std.Random.DefaultPrng.init(0xDE7E4);
    const rand = prng.random();

    for (0..5000) |_| {
        var q: [4]f32 = undefined;
        var norm: f32 = 0;
        for (&q) |*c| {
            c.* = rand.float(f32) * 2 - 1;
            norm += c.* * c.*;
        }
        norm = @sqrt(norm);
        if (norm < 1e-6) continue;
        for (&q) |*c| c.* /= norm;

        const first = quantizeQuat(q, bits);
        const second = quantizeQuat(q, bits);
        try std.testing.expectEqual(first.largest, second.largest);
        try std.testing.expectEqual(first.a, second.a);
        try std.testing.expectEqual(first.b, second.b);
        try std.testing.expectEqual(first.c, second.c);
    }
}

test "repeated decode/encode preserves the rotation even where the bits oscillate" {
    // Bounds the known non-canonicality: the bit pattern may flip between two encodings,
    // but the rotation it denotes must not drift. If it drifted, a relayed or migrated
    // entity would slowly rotate on its own.
    const bits: u7 = 9;
    var state: QuantizedQuat = .{ .largest = 0, .a = 0, .b = 245, .c = 245 };
    const original = dequantizeQuat(state, bits);

    for (0..16) |_| {
        const decoded = dequantizeQuat(state, bits);
        var dot: f32 = 0;
        for (0..4) |i| dot += original[i] * decoded[i];
        try std.testing.expect(@abs(dot) > 0.99);

        var norm: f32 = 0;
        for (decoded) |c| norm += c * c;
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm, 0.01);

        state = quantizeQuat(decoded, bits);
    }
}

test "wide widths do not overflow their field" {
    // The f32 trap: @floatFromInt(maxQuantized(32)) rounds up in f32, so a normalized
    // 1.0 scaled by it exceeds the field width by one and corrupts the next field.
    inline for ([_]u7{ 24, 25, 30, 31, 32, 48, 53 }) |bits| {
        try std.testing.expectEqual(maxQuantized(bits), quantize(1, bits, -1, 1));
        try std.testing.expect(quantize(1e30, bits, -1, 1) <= maxQuantized(bits));
    }
}
