//! Wire types, quantization policy, and physical layout.
//!
//! The split here is load-bearing. `WireType` and `Quantization` are *semantic* and
//! cross the network, so they are covered by the compatibility fingerprint
//! (`docs/SCHEMA_AND_EVOLUTION.md` §4). `Layout` is *physical*, differs per target by
//! `ARCHITECTURE.md` §0 P1, and must never reach the fingerprint — if it does,
//! cross-platform play breaks in a way that looks like a netcode bug for weeks.
//!
//! That separation is what §10 check 5 exists to defend, and it is enforced by type:
//! `Layout` has no path into the canonical fingerprint bytes.

const std = @import("std");

/// Encoding on the replication and save projections. Part of the fingerprint.
pub const WireType = enum {
    bool,
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    /// 16.16 fixed point. Inside the rollback boundary, per ARCHITECTURE.md §7.
    q16_16,
    vec3_quantized,
    quat_smallest_three,
    entity_handle,
    string_id,
    blob,

    pub fn parse(text: []const u8) ?WireType {
        inline for (@typeInfo(WireType).@"enum".fields) |f| {
            if (std.mem.eql(u8, text, f.name)) return @field(WireType, f.name);
        }
        return null;
    }

    /// Bits on the wire before delta encoding. `null` means variable-length.
    pub fn wireBits(self: WireType) ?u16 {
        return switch (self) {
            .bool => 1,
            .u8, .i8 => 8,
            .u16, .i16 => 16,
            .u32, .i32, .f32, .q16_16 => 32,
            .u64, .i64, .f64 => 64,
            .vec3_quantized => 48,
            .quat_smallest_three => 29,
            .entity_handle => 32,
            .string_id => 32,
            .blob => null,
        };
    }
};

/// How a field's range is compressed. Part of the fingerprint: two builds that
/// quantize differently cannot exchange state.
pub const Quantization = union(enum) {
    none,
    /// Uniform quantization of a bounded scalar or vector range.
    bounded: struct { bits: u8, min: f32, max: f32 },
    /// Angular quantization, implicitly over the unit sphere.
    angular: struct { bits: u8 },
};

/// Per-target physical layout. Deliberately NOT part of the fingerprint.
///
/// ARCHITECTURE.md §0 P1: "Component layouts, chunk sizes, and alignment may differ
/// per target. Semantic schema may not." Two builds for different targets with
/// different layouts must produce identical fingerprints.
pub const Layout = struct {
    chunk_bytes: u32,
    field_alignment: u8,

    pub const wasm32: Layout = .{ .chunk_bytes = 8 * 1024, .field_alignment = 4 };
    pub const mobile: Layout = .{ .chunk_bytes = 16 * 1024, .field_alignment = 8 };
    pub const desktop: Layout = .{ .chunk_bytes = 64 * 1024, .field_alignment = 16 };
};

test "wire type round-trips through its own name" {
    try std.testing.expectEqual(WireType.q16_16, WireType.parse("q16_16").?);
    try std.testing.expectEqual(WireType.vec3_quantized, WireType.parse("vec3_quantized").?);
    try std.testing.expect(WireType.parse("not_a_wire_type") == null);
}

test "quaternion is cheaper than three quantized floats" {
    try std.testing.expect(WireType.quat_smallest_three.wireBits().? <
        WireType.vec3_quantized.wireBits().?);
}
