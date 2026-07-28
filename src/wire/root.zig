//! Wire format: bit packing, quantization, and generated codecs.
//!
//! `ARCHITECTURE.md` §1.3 — "Bandwidth is the binding constraint, not CPU." This module
//! is where that constraint is met, against the budget computed in
//! `BENCHMARK_CONTRACT.md` §4.1: ~1,500 bytes per snapshot per client, ~180 entity
//! updates, so roughly 8 bytes each.

const std = @import("std");
const schema_mod = @import("bedlam_schema");

pub const bits = @import("bits.zig");
pub const quant = @import("quant.zig");
pub const codec = @import("codec.zig");

test {
    _ = bits;
    _ = quant;
    _ = codec;
}

const schema = schema_mod.schema;
const Transform = schema.components[0];
const Health = schema.components[1];

fn sampleTransform() codec.Storage(Transform) {
    return .{
        .position = .{ 12.5, -300.25, 4095.0 },
        .rotation = .{ 0.5, 0.5, 0.5, 0.5 },
        .velocity = .{ 1.5, -2.5, 0.0 },
    };
}

test "generated storage type matches the declaration" {
    const T = codec.Storage(Transform);
    const info = @typeInfo(T).@"struct";
    try std.testing.expectEqual(@as(usize, 3), info.fields.len);
    try std.testing.expectEqualStrings("position", info.fields[0].name);
    try std.testing.expectEqual([3]f32, info.fields[0].type);
    try std.testing.expectEqual([4]f32, info.fields[1].type);
}

test "component round-trips through the wire" {
    var buf: [64]u8 = undefined;
    const original = sampleTransform();

    var writer = bits.Writer.init(&buf);
    try codec.encode(Transform, original, &writer);

    var reader = bits.Reader.init(writer.written());
    const decoded = try codec.decode(Transform, &reader);

    // Position: 16 bits over [-4096, 4096].
    const pos_tol = quant.resolution(16, -4096, 4096) * 1.001;
    inline for (0..3) |i| {
        try std.testing.expectApproxEqAbs(original.position[i], decoded.position[i], pos_tol);
    }

    var dot: f32 = 0;
    inline for (0..4) |i| dot += original.rotation[i] * decoded.rotation[i];
    try std.testing.expect(@abs(dot) > 0.999);
}

test "encoded size matches the comptime-computed size" {
    // The replication layer sizes snapshots from componentBits without trial encoding,
    // so a mismatch would silently overrun a per-client byte budget (§4).
    var buf: [64]u8 = undefined;
    var writer = bits.Writer.init(&buf);
    try codec.encode(Transform, sampleTransform(), &writer);
    try std.testing.expectEqual(comptime codec.componentBits(Transform), writer.bitsWritten());
}

test "Transform fits the per-entity budget from BENCHMARK_CONTRACT §4.1" {
    // 1,500 bytes per snapshot across ~180 updates is ~8.3 bytes each. A Transform is
    // the common case, so if it does not fit, the floor does not either.
    const bytes = (comptime codec.componentBits(Transform) + 7) / 8;
    try std.testing.expect(bytes <= 16);
    // 16+16+16 position, 2+9+9+9 rotation, 12+12+12 velocity = 113 bits = 15 bytes.
    try std.testing.expectEqual(@as(usize, 113), comptime codec.componentBits(Transform));
}

test "fixed-point survives the wire exactly" {
    // Unlike quantized floats, q16_16 is inside the rollback boundary (§7) and must be
    // exact — a lossy round trip there is a desync, not a visual artifact.
    var buf: [16]u8 = undefined;
    const original: codec.Storage(Health) = .{
        .current = codec.Q16_16.fromFloat(87.25),
        .maximum = 100,
    };

    var writer = bits.Writer.init(&buf);
    try codec.encode(Health, original, &writer);
    var reader = bits.Reader.init(writer.written());
    const decoded = try codec.decode(Health, &reader);

    try std.testing.expectEqual(original.current.raw, decoded.current.raw);
    try std.testing.expectEqual(original.maximum, decoded.maximum);
}

test "masked update leaves untouched fields at their baseline" {
    var buf: [64]u8 = undefined;
    const baseline = sampleTransform();
    var updated = baseline;
    updated.position = .{ 99.0, 99.0, 99.0 };

    // Field 0 (position) only.
    var writer = bits.Writer.init(&buf);
    try codec.encodeMasked(Transform, updated, 0b001, &writer);

    var reader = bits.Reader.init(writer.written());
    const decoded = try codec.decodeMasked(Transform, baseline, &reader);

    const pos_tol = quant.resolution(16, -4096, 4096) * 1.001;
    try std.testing.expectApproxEqAbs(@as(f32, 99.0), decoded.position[0], pos_tol);
    // Velocity was not sent, so it must be exactly the baseline value, not a re-decode.
    try std.testing.expectEqual(baseline.velocity[0], decoded.velocity[0]);
}

test "a masked update is smaller than a full one" {
    // The entire reason the mask exists.
    var buf: [64]u8 = undefined;

    var full = bits.Writer.init(&buf);
    try codec.encode(Transform, sampleTransform(), &full);
    const full_bits = full.bitsWritten();

    var partial = bits.Writer.init(&buf);
    try codec.encodeMasked(Transform, sampleTransform(), 0b001, &partial);
    try std.testing.expect(partial.bitsWritten() < full_bits);
}

test "decode of truncated input errors rather than panicking" {
    // The trust boundary. AGENTS.md §3 and ARCHITECTURE.md §14.2: a malformed packet
    // must never panic or read out of bounds, at any truncation point.
    var buf: [64]u8 = undefined;
    var writer = bits.Writer.init(&buf);
    try codec.encode(Transform, sampleTransform(), &writer);
    const complete = writer.written();

    for (0..complete.len) |cut| {
        var reader = bits.Reader.init(complete[0..cut]);
        try std.testing.expectError(error.EndOfStream, codec.decode(Transform, &reader));
    }
}

test "decode never rejects well-formed random bytes" {
    // Every bit pattern of the right length must decode to *something*. If it does not,
    // a peer can be disconnected by bad luck rather than by malice.
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rand = prng.random();
    const needed = (comptime codec.componentBits(Transform) + 7) / 8;

    var buf: [64]u8 = undefined;
    for (0..2000) |_| {
        rand.bytes(buf[0..needed]);
        var reader = bits.Reader.init(buf[0..needed]);
        const decoded = try codec.decode(Transform, &reader);

        // And whatever comes out must still be usable: a unit quaternion, never NaN.
        var norm: f32 = 0;
        for (decoded.rotation) |c| {
            try std.testing.expect(!std.math.isNan(c));
            norm += c * c;
        }
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm, 0.02);
        for (decoded.position) |c| try std.testing.expect(!std.math.isNan(c));
    }
}

test "every declared component has a working codec" {
    // Guards against a component being added with a field combination nothing exercises.
    var buf: [256]u8 = undefined;
    inline for (schema.components) |c| {
        if (comptime componentIsEncodable(c)) {
            var value: codec.Storage(c) = undefined;
            initToZero(c, &value);

            var writer = bits.Writer.init(&buf);
            try codec.encode(c, value, &writer);
            try std.testing.expectEqual(comptime codec.componentBits(c), writer.bitsWritten());

            var reader = bits.Reader.init(writer.written());
            _ = try codec.decode(c, &reader);
        }
    }
}

// ---------------------------------------------------------------------------
// Fuzz target. AGENTS.md §3: "Every parser gets a fuzz target."
//
// Run with `zig build test --fuzz`. The property is not "does not crash" — that is
// necessary but weak. It is that every byte string a hostile peer can send decodes to a
// value the simulation can use: no NaN, and a rotation that is actually a rotation.
// ---------------------------------------------------------------------------

test "fuzz: decode survives arbitrary input and yields usable values" {
    try std.testing.fuzz({}, fuzzDecode, .{});
}

fn fuzzDecode(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    var buf: [64]u8 = undefined;
    // Fixed-width, not usize: the fuzzer ABI needs a type with a fixed bit size.
    const len: usize = smith.valueRangeAtMost(u8, 0, buf.len);
    smith.bytes(buf[0..len]);

    var reader = bits.Reader.init(buf[0..len]);
    const decoded = codec.decode(Transform, &reader) catch |err| switch (err) {
        // Truncated input is a legitimate outcome, not a failure.
        error.EndOfStream, error.Malformed => return,
    };

    for (decoded.position) |c| if (std.math.isNan(c)) return error.DecodedNaN;
    for (decoded.velocity) |c| if (std.math.isNan(c)) return error.DecodedNaN;

    var norm: f32 = 0;
    for (decoded.rotation) |c| {
        if (std.math.isNan(c)) return error.DecodedNaN;
        norm += c * c;
    }
    if (@abs(norm - 1.0) > 0.01) return error.DecodedNonRotation;

    // A decoded value must survive re-encoding: relays, replays, and host migration all
    // round-trip peer-supplied state through our own encoder.
    var out: [64]u8 = undefined;
    var writer = bits.Writer.init(&out);
    try codec.encode(Transform, decoded, &writer);
}

fn componentIsEncodable(comptime c: @TypeOf(schema.components[0])) bool {
    for (c.fields) |f| if (f.wire == .blob) return false;
    return true;
}

fn initToZero(comptime c: @TypeOf(schema.components[0]), value: *codec.Storage(c)) void {
    inline for (c.fields) |f| {
        @field(value, f.name) = switch (f.wire) {
            .bool => false,
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .string_id => 0,
            .f32, .f64 => 0.0,
            .q16_16 => codec.Q16_16{ .raw = 0 },
            .vec3_quantized => [3]f32{ 0, 0, 0 },
            // Must be a unit quaternion: encode asserts it.
            .quat_smallest_three => [4]f32{ 1, 0, 0, 0 },
            .entity_handle => codec.EntityHandle{ .index = 0, .generation = 0 },
            .blob => unreachable,
        };
    }
}
