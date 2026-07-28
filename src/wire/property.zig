//! Deterministic property testing for the decode path.
//!
//! `AGENTS.md` §3 requires every parser to have a fuzz target. It has one (`root.zig`,
//! via `std.testing.fuzz`), and that target runs — but only as
//! **`zig build test --fuzz --release=safe`**, on Linux.
//!
//!   - Debug fails to build inside Zig 0.16.0's own `lib/compiler/test_runner.zig:566`,
//!     which passes a `*builtin.StackTrace` where `*const debug.StackTrace` is expected.
//!     Upstream, and it affects every fuzz target rather than anything here.
//!   - Windows reports "not yet implemented for windows" in any mode, so locally this
//!     runs under WSL2 — `docs/CI_TIERS.md` §5.
//!
//! ReleaseSafe is the right mode regardless: `AGENTS.md` §3 puts packet parse in
//! `ReleaseSafe`, so fuzzing there exercises the configuration that actually ships
//! rather than a Debug build nobody deploys.
//!
//! This harness complements the fuzzer rather than substituting for it, and it is better
//! in one specific respect: it is **deterministic**. A CI failure here reproduces exactly
//! from its seed, on every platform, forever, with no corpus to carry around. It is worse
//! in the obvious respect — it does not learn — which is why both exist. This one gates
//! every commit on every target; the fuzzer runs nightly on Linux.
//!
//! Three generators, because uniform random bytes are a weak adversary. Most random bit
//! strings are not near an interesting boundary; mutations of *valid* encodings are.

const std = @import("std");
const bits = @import("bits.zig");
const quant = @import("quant.zig");
const codec = @import("codec.zig");
const schema_mod = @import("bedlam_schema");

const schema = schema_mod.schema;
const Transform = schema.components[0];

/// Every property the decode path must satisfy for arbitrary input.
///
/// Not merely "does not crash". A decoder that cannot crash but emits NaN positions or
/// non-unit rotations has moved the failure downstream into the simulation, where it is
/// far harder to attribute.
fn checkDecodeInvariants(input: []const u8) !void {
    var reader = bits.Reader.init(input);
    const decoded = codec.decode(Transform, &reader) catch |err| switch (err) {
        error.EndOfStream, error.Malformed => return, // legitimate for short input
    };

    for (decoded.position) |c| {
        if (std.math.isNan(c)) return error.DecodedNaN;
        if (std.math.isInf(c)) return error.DecodedInf;
        // Quantized against [-4096, 4096]; nothing outside can be produced.
        if (@abs(c) > 4097) return error.DecodedOutOfRange;
    }
    for (decoded.velocity) |c| {
        if (std.math.isNan(c)) return error.DecodedNaN;
        if (@abs(c) > 257) return error.DecodedOutOfRange;
    }

    var norm: f32 = 0;
    for (decoded.rotation) |c| {
        if (std.math.isNan(c)) return error.DecodedNaN;
        norm += c * c;
    }
    if (@abs(norm - 1.0) > 0.01) return error.DecodedNonRotation;

    // Re-encoding must succeed. Relays, replay capture, and host migration all round
    // peer-supplied state back through our own encoder, which asserts on unit norm — so
    // a decoder that emits something the encoder rejects lets a peer trip our assertion.
    var out: [64]u8 = undefined;
    var writer = bits.Writer.init(&out);
    try codec.encode(Transform, decoded, &writer);
}

const encoded_bytes = (codec.componentBits(Transform) + 7) / 8;

/// A valid encoding, used as the base for mutation.
fn validEncoding(rand: std.Random, out: []u8) []const u8 {
    var q: [4]f32 = undefined;
    var norm: f32 = 0;
    for (&q) |*c| {
        c.* = rand.float(f32) * 2.0 - 1.0;
        norm += c.* * c.*;
    }
    norm = @sqrt(norm);
    if (norm < 1e-6) {
        q = .{ 1, 0, 0, 0 };
    } else {
        for (&q) |*c| c.* /= norm;
    }

    const value: codec.Storage(Transform) = .{
        .position = .{
            rand.float(f32) * 8192 - 4096,
            rand.float(f32) * 8192 - 4096,
            rand.float(f32) * 8192 - 4096,
        },
        .rotation = q,
        .velocity = .{
            rand.float(f32) * 512 - 256,
            rand.float(f32) * 512 - 256,
            rand.float(f32) * 512 - 256,
        },
    };

    var writer = bits.Writer.init(out);
    codec.encode(Transform, value, &writer) catch unreachable;
    return writer.written();
}

test "property: uniform random bytes decode to usable values" {
    var prng = std.Random.DefaultPrng.init(0xB3D1A3);
    const rand = prng.random();
    var buf: [64]u8 = undefined;

    for (0..20_000) |_| {
        rand.bytes(buf[0..encoded_bytes]);
        try checkDecodeInvariants(buf[0..encoded_bytes]);
    }
}

test "property: bit-flipped valid encodings decode to usable values" {
    // The generator that matters. A valid encoding with one bit flipped lands near the
    // boundaries a uniform generator almost never reaches — the quaternion's largest
    // index, the top bit of a quantized component, the edge of a range.
    var prng = std.Random.DefaultPrng.init(0x5EED_5EED);
    const rand = prng.random();
    var base: [64]u8 = undefined;
    var mutated: [64]u8 = undefined;

    for (0..20_000) |_| {
        const valid = validEncoding(rand, &base);
        @memcpy(mutated[0..valid.len], valid);

        const flips = rand.intRangeAtMost(usize, 1, 5);
        for (0..flips) |_| {
            const bit = rand.intRangeLessThan(usize, 0, valid.len * 8);
            mutated[bit >> 3] ^= @as(u8, 1) << @intCast(bit & 7);
        }

        try checkDecodeInvariants(mutated[0..valid.len]);
    }
}

test "property: truncations of valid encodings error rather than misbehave" {
    var prng = std.Random.DefaultPrng.init(0x7C0FFEE);
    const rand = prng.random();
    var base: [64]u8 = undefined;

    for (0..2_000) |_| {
        const valid = validEncoding(rand, &base);
        const cut = rand.intRangeAtMost(usize, 0, valid.len);
        try checkDecodeInvariants(valid[0..cut]);
    }
}

test "property: all-zero and all-ones inputs are handled" {
    // Both are overwhelmingly likely in real corruption and vanishingly unlikely from a
    // uniform generator at this length.
    var buf: [64]u8 = undefined;

    @memset(buf[0..encoded_bytes], 0x00);
    try checkDecodeInvariants(buf[0..encoded_bytes]);

    @memset(buf[0..encoded_bytes], 0xFF);
    try checkDecodeInvariants(buf[0..encoded_bytes]);

    @memset(buf[0..encoded_bytes], 0xAA);
    try checkDecodeInvariants(buf[0..encoded_bytes]);

    @memset(buf[0..encoded_bytes], 0x55);
    try checkDecodeInvariants(buf[0..encoded_bytes]);
}

test "property: masked decode over a baseline is always usable" {
    // decodeMasked reads a variable number of fields depending on attacker-controlled
    // mask bits, so it has a failure mode the full decode does not.
    var prng = std.Random.DefaultPrng.init(0x1A5C0DE);
    const rand = prng.random();
    var base: [64]u8 = undefined;
    var buf: [64]u8 = undefined;

    const baseline_bytes = validEncoding(rand, &base);
    var baseline_reader = bits.Reader.init(baseline_bytes);
    const baseline = try codec.decode(Transform, &baseline_reader);

    for (0..20_000) |_| {
        const len = rand.intRangeAtMost(usize, 0, encoded_bytes + 2);
        rand.bytes(buf[0..len]);

        var reader = bits.Reader.init(buf[0..len]);
        const decoded = codec.decodeMasked(Transform, baseline, &reader) catch continue;

        var norm: f32 = 0;
        for (decoded.rotation) |c| {
            if (std.math.isNan(c)) return error.DecodedNaN;
            norm += c * c;
        }
        if (@abs(norm - 1.0) > 0.01) return error.DecodedNonRotation;
        for (decoded.position) |c| if (std.math.isNan(c)) return error.DecodedNaN;
    }
}
