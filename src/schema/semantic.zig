//! Semantic types — what a field *is*, as distinct from how it is encoded.
//!
//! `SCHEMA_AND_EVOLUTION.md` §3's per-field manifest table already lists these as two
//! separate things: "Semantic type | Independent of physical layout" and "Wire type |
//! Encoding on the replication and save projections". They were implemented as one field,
//! and collapsing them had a concrete consequence.
//!
//! `Transform` is class `.predicted`, so it enters the rollback projection
//! (`declare.projectionsFor`). `ARCHITECTURE.md` §7 requires fixed point inside that
//! boundary — "bit-exact cross-architecture float determinism across x86 / ARM / wasm32
//! is folklore. Don't design around it." But because storage was derived from the *wire*
//! type, `vec3_quantized` produced `[3]f32` storage and the engine's flagship predicted
//! component held floats inside the rollback boundary.
//!
//! Separating the two fixes it at the root: the semantic type decides what the simulation
//! holds, the wire type decides what crosses the network, and a component that is
//! re-simulated may not hold a float regardless of how it is transmitted.

const std = @import("std");
const wire = @import("wire.zig");

pub const SemanticType = enum {
    bool,
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,

    /// `fpz.Fixed` — Q40.24. The only scalar permitted inside the rollback boundary.
    fixed,
    /// `[3]fpz.Fixed`. Position, velocity, impulse.
    fixed_vec3,
    /// `[4]fpz.Fixed`, unit norm. Orientation.
    fixed_quat,

    /// Presentation only. Rejected on any class in the rollback projection.
    f32,
    f64,

    entity_handle,
    string_id,
    blob,

    /// Whether a value of this type can differ between two architectures that agree on
    /// every input. This is the predicate §7 actually cares about.
    pub fn isFloat(self: SemanticType) bool {
        return switch (self) {
            .f32, .f64 => true,
            else => false,
        };
    }

    /// Encodings this semantic type can legitimately be sent as.
    ///
    /// Not every pairing is meaningful: quantizing a `u64` is not defined, and sending a
    /// `fixed_quat` as a bare `u32` loses the unit-norm property the decoder relies on.
    /// A mismatch is a build error rather than a silent reinterpretation.
    pub fn permits(self: SemanticType, w: wire.WireType) bool {
        return switch (self) {
            .bool => w == .bool,
            .u8 => w == .u8,
            .u16 => w == .u16,
            .u32 => w == .u32,
            .u64 => w == .u64,
            .i8 => w == .i8,
            .i16 => w == .i16,
            .i32 => w == .i32,
            .i64 => w == .i64,
            .fixed => w == .q16_16,
            .fixed_vec3 => w == .vec3_quantized,
            .fixed_quat => w == .quat_smallest_three,
            .f32 => w == .f32,
            .f64 => w == .f64,
            .entity_handle => w == .entity_handle,
            .string_id => w == .string_id,
            .blob => w == .blob,
        };
    }
};

test "every semantic type permits exactly one wire type" {
    // If a semantic type permitted none, no field of it could ever be declared; if it
    // permitted several, `permits` would not be constraining anything.
    inline for (@typeInfo(SemanticType).@"enum".fields) |sf| {
        const s: SemanticType = @field(SemanticType, sf.name);
        var count: usize = 0;
        inline for (@typeInfo(wire.WireType).@"enum".fields) |wf| {
            if (s.permits(@field(wire.WireType, wf.name))) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "only the presentation types are floats" {
    try std.testing.expect(SemanticType.f32.isFloat());
    try std.testing.expect(SemanticType.f64.isFloat());
    try std.testing.expect(!SemanticType.fixed.isFloat());
    try std.testing.expect(!SemanticType.fixed_vec3.isFloat());
    try std.testing.expect(!SemanticType.fixed_quat.isFloat());
}
