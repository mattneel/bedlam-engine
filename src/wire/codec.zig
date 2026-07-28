//! Generated codecs.
//!
//! `ARCHITECTURE.md` §18.4 and §18.13: no duplicated definitions, and no hand-written
//! serializer for any ordinary replicated component. Storage type, encoder, and decoder
//! are all `comptime` functions of the declaration in `src/schema/schema.zig`, so adding
//! a field is one edit plus a registry line, and it is impossible for the encoder and
//! decoder to disagree — they are derived from the same source.
//!
//! `AGENTS.md` §3 puts packet parse in `ReleaseSafe`. Nothing in the decode path asserts
//! on input values; every failure is an error. The encode path operates on our own
//! simulation state and does assert, because a bad value there is an upstream bug that
//! should be loud.

const std = @import("std");
const fpz = @import("fpz");
const bits = @import("bits.zig");
const quant = @import("quant.zig");
const fq = @import("fixedquant.zig");
const schema_mod = @import("bedlam_schema");
const d = schema_mod.declare;
const storable = schema_mod.storable;
const w = schema_mod.wire;

/// The simulation's fixed-point type: `fpz.Fixed`, Q40.24 over an i64.
///
/// `ARCHITECTURE.md` §7 requires fixed point inside the rollback boundary, no FMA
/// contraction, no fast-math, and "own polynomial transcendentals, never platform libm".
/// fpz is that contract as a library — integer-only at runtime, float only at comptime,
/// and every operation total.
///
/// This replaced a hand-rolled Q16.16. That type was a demonstration of why §7 exists:
/// its `fromFloat` used an unguarded `@intFromFloat`, which is illegal behaviour out of
/// range, and the targets disagree about what illegal means — x86_64 yields INT_MIN
/// where aarch64 and wasm32 saturate to INT_MAX. A fixed-point type that inherits float
/// divergence defeats the only reason to have one.
pub const Fixed = fpz.Fixed;

/// Wire representation of a fixed-point scalar: Q16.16 in 32 bits.
///
/// The simulation type is 64-bit and the wire cannot afford that —
/// `BENCHMARK_CONTRACT.md` §4.1 gives the whole snapshot ~1,500 bytes for ~180 entity
/// updates. `ARCHITECTURE.md` §5.1 is explicit that the four projections are *not the
/// same bytes*, so narrowing here is the design rather than a compromise: simulation
/// keeps Q40.24, replication sends Q16.16, and reconciliation covers the difference.
///
/// Both directions are total. Narrowing saturates rather than wrapping, because a
/// wrapped health value flips sign and a saturated one is merely clamped.
pub const WireFixed = struct {
    /// Frac bits dropped when narrowing Q40.24 to Q16.16.
    const shift: u5 = fpz.Fixed.frac_bits - 16;

    pub fn narrow(v: Fixed) i32 {
        const shifted = v.raw >> shift;
        return @intCast(std.math.clamp(
            shifted,
            @as(i64, std.math.minInt(i32)),
            @as(i64, std.math.maxInt(i32)),
        ));
    }

    pub fn widen(raw32: i32) Fixed {
        return fpz.Fixed.fromRaw(@as(i64, raw32) << shift);
    }
};

/// Generational entity reference. `ARCHITECTURE.md` §5: entities are generational IDs, so
/// a stale handle is detectable rather than silently aliasing a recycled slot.
pub const EntityHandle = packed struct(u32) {
    index: u24,
    generation: u8,
};

/// The Zig storage type for a field, derived from its SEMANTIC type -- what the
/// simulation holds -- not from its wire type.
///
/// Deriving storage from the wire type is what put `[3]f32` inside `Transform`, a
/// `.predicted` component that enters the rollback projection, in direct violation of
/// `ARCHITECTURE.md` §7. The wire may quantize to 16 bits; the simulation must still hold
/// something reproducible across x86, ARM and wasm32. `declare.assertRollbackSafe` makes
/// that a build error rather than a reading-comprehension exercise.
///
/// Physical layout may differ per target (§0 P1); the wire encoding may not.
pub fn StorageType(comptime sem: d.SemanticType) type {
    return switch (sem) {
        .bool => bool,
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .fixed => Fixed,
        .fixed_vec3 => [3]Fixed,
        .fixed_quat => [4]Fixed,
        .f32 => f32,
        .f64 => f64,
        .entity_handle => EntityHandle,
        .string_id => u32,
        .blob => []const u8,
    };
}

/// The struct a component's values live in, generated from its declaration.
pub fn Storage(comptime c: d.Component) type {
    comptime {
        var names: [c.fields.len][:0]const u8 = undefined;
        var types: [c.fields.len]type = undefined;
        for (c.fields, 0..) |f, i| {
            names[i] = f.name;
            types[i] = StorageType(f.sem);
        }
        // Invariant 1, checked on the generated storage itself rather than on the
        // declaration: AGENTS.md §2.1 forbids per-field metadata in chunks "from any
        // subsystem, ever", and a subsystem adds it by widening a component's Zig type,
        // not by editing schema.zig. Recursive, because the violation that survives
        // review is a struct three levels down.
        for (types, 0..) |T, i| {
            storable.assertStorable(T, "component '" ++ c.name ++ "' field '" ++ names[i] ++ "'");
            storable.assertFixedWidth(T, "component '" ++ c.name ++ "' field '" ++ names[i] ++ "'");
        }

        // `.auto` layout, not `.@"extern"` or `.@"packed"`: ARCHITECTURE.md §0 P1 lets
        // physical layout differ per target, and the wire encoding below never reads
        // this struct's memory representation, only its fields by name.
        return @Struct(.auto, null, &names, &types, &@splat(.{}));
    }
}

/// Bits a field occupies on the wire, after quantization.
pub fn fieldBits(comptime f: d.Field) u7 {
    return switch (f.sem) {
        .fixed_vec3 => switch (f.quant) {
            .bounded => |q| @as(u7, q.bits) * 3,
            else => @compileError("fixed_vec3 field '" ++ f.name ++
                "' needs a bounded quantization policy; an unquantized vector does not fit the §4.1 byte budget"),
        },
        .fixed_quat => switch (f.quant) {
            .angular => |q| 2 + @as(u7, q.bits) * 3,
            else => @compileError("fixed_quat field '" ++ f.name ++ "' needs an angular quantization policy"),
        },
        .blob => @compileError("blob field '" ++ f.name ++
            "' is variable-length and has no fixed bit width; blobs belong on bulk_content, not in a snapshot"),
        else => blk: {
            // A quantization policy declared on a wire type that cannot honour it is a
            // build error, not a no-op. Otherwise the declaration says the field is
            // 10-bit bounded, the codec writes a full 32-bit float, and
            // `SCHEMA_AND_EVOLUTION.md` §1's "the declaration is the single source of
            // truth" is false while this file's header still claims encoder and decoder
            // "are derived from the same source".
            //
            // Worse, the manifest DOES fold the ignored policy into the fingerprint
            // (§4 covers quantization policy), so two builds differing only in a policy
            // neither of them applies would refuse to connect while being byte-identical
            // on the wire.
            if (f.quant != .none) {
                @compileError("field '" ++ f.name ++ "' declares a quantization policy, but semantic type '" ++
                    @tagName(f.sem) ++ "' does not quantize. Use fixed_vec3 or " ++
                    "fixed_quat, or drop the policy — a declared policy that is " ++
                    "silently ignored still changes the compatibility fingerprint.");
            }
            break :blk @intCast(f.wire.wireBits() orelse
                @compileError("field '" ++ f.name ++ "' has no fixed wire width"));
        },
    };
}

/// Total bits for a component. Known at comptime, which is what lets the replication
/// layer size a snapshot without trial encoding.
pub fn componentBits(comptime c: d.Component) usize {
    comptime {
        var total: usize = 0;
        for (c.fields) |f| total += fieldBits(f);
        return total;
    }
}

/// Declaration indices ordered by stable field ID.
///
/// `ARCHITECTURE.md` §5.1 requires "stable field ordering" in the replication projection,
/// and this is why. The compatibility fingerprint (`SCHEMA_AND_EVOLUTION.md` §4) is sorted
/// by stable ID and is deliberately blind to declaration order, because §2 says a rename
/// or a reshuffle preserves identity. If the wire followed declaration order instead,
/// moving one field in `schema.zig` would produce an identical fingerprint and a different
/// byte layout — two builds would negotiate as compatible and then reinterpret each
/// other's fields.
///
/// That is exactly the silent, data-corrupting, discovered-in-production failure
/// `SCHEMA_AND_EVOLUTION.md` §0 describes. So the wire follows stable IDs, and declaration
/// order becomes what §4 says it is: cosmetic.
fn wireOrder(comptime c: d.Component) [c.fields.len]usize {
    comptime {
        const m = schema_mod.manifest.manifest;

        var entry: ?@TypeOf(m.components[0]) = null;
        for (m.components) |ce| {
            if (std.mem.eql(u8, ce.name, c.name)) {
                entry = ce;
                break;
            }
        }
        const ce = entry orelse
            @compileError("codec: component '" ++ c.name ++ "' is absent from the manifest");

        var order: [c.fields.len]usize = undefined;
        for (0..c.fields.len) |i| order[i] = i;

        // Insertion sort by stable ID. n is small and this runs once per component.
        for (1..c.fields.len) |i| {
            var j = i;
            while (j > 0 and ce.fields[order[j - 1]].id > ce.fields[order[j]].id) : (j -= 1) {
                const tmp = order[j - 1];
                order[j - 1] = order[j];
                order[j] = tmp;
            }
        }
        return order;
    }
}

fn encodeField(comptime f: d.Field, value: anytype, writer: *bits.Writer) bits.Writer.Error!void {
    const n = comptime fieldBits(f);
    switch (f.sem) {
        .bool => try writer.writeBool(value),
        .u8, .u16, .u32, .u64 => try writer.writeBits(value, n),
        .i8, .i16, .i32, .i64 => {
            // Two's complement, truncated to width. Sign-extended on the way back out.
            const U = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(value)));
            try writer.writeBits(@as(U, @bitCast(value)), n);
        },
        .f32 => try writer.writeBits(@as(u32, @bitCast(value)), 32),
        .f64 => try writer.writeBits(@as(u64, @bitCast(value)), 64),
        .fixed => try writer.writeBits(@as(u32, @bitCast(WireFixed.narrow(value))), 32),
        .entity_handle => try writer.writeBits(@as(u32, @bitCast(value)), 32),
        .string_id => try writer.writeBits(value, 32),
        .fixed_vec3 => {
            const q = comptime f.quant.bounded;
            // Bounds are declared as comptime floats for authoring convenience and folded
            // to Fixed here. fpz permits float at comptime and never at runtime.
            const lo = comptime fpz.Fixed.rconst(q.min);
            const hi = comptime fpz.Fixed.rconst(q.max);
            inline for (0..3) |i| {
                try writer.writeBits(fq.quantize(value[i], q.bits, lo, hi), q.bits);
            }
        },
        .fixed_quat => {
            const q = comptime f.quant.angular;
            const qq = fq.quantizeQuat(value, q.bits);
            try writer.writeBits(qq.largest, 2);
            try writer.writeBits(qq.a, q.bits);
            try writer.writeBits(qq.b, q.bits);
            try writer.writeBits(qq.c, q.bits);
        },
        .blob => comptime unreachable, // rejected by fieldBits
    }
}

fn decodeField(comptime f: d.Field, reader: *bits.Reader) bits.Reader.Error!StorageType(f.sem) {
    const n = comptime fieldBits(f);
    const T = StorageType(f.sem);
    return switch (f.sem) {
        .bool => try reader.readBool(),
        .u8, .u16, .u32, .u64 => @intCast(try reader.readBits(n)),
        .i8, .i16, .i32, .i64 => blk: {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(@as(U, @intCast(try reader.readBits(n))));
        },
        .f32 => @bitCast(@as(u32, @intCast(try reader.readBits(32)))),
        .f64 => @bitCast(try reader.readBits(64)),
        .fixed => WireFixed.widen(@bitCast(@as(u32, @intCast(try reader.readBits(32))))),
        .entity_handle => @bitCast(@as(u32, @intCast(try reader.readBits(32)))),
        .string_id => @intCast(try reader.readBits(32)),
        .fixed_vec3 => blk: {
            const q = comptime f.quant.bounded;
            const lo = comptime fpz.Fixed.rconst(q.min);
            const hi = comptime fpz.Fixed.rconst(q.max);
            var out: [3]Fixed = undefined;
            inline for (0..3) |i| {
                out[i] = fq.dequantize(try reader.readBits(q.bits), q.bits, lo, hi);
            }
            break :blk out;
        },
        .fixed_quat => blk: {
            const q = comptime f.quant.angular;
            const largest: u2 = @intCast(try reader.readBits(2));
            const a = try reader.readBits(q.bits);
            const b = try reader.readBits(q.bits);
            const c = try reader.readBits(q.bits);
            break :blk fq.dequantizeQuat(.{ .largest = largest, .a = a, .b = b, .c = c }, q.bits);
        },
        .blob => comptime unreachable,
    };
}

/// Components this codec may serialize.
///
/// `ARCHITECTURE.md` §5.1 defines four projections that are deliberately NOT the same
/// bytes; this file is the *replication* codec and nothing else. Without the check
/// below, `encode` would happily serialize a `client_private` component — and §16 says
/// that class exists precisely so "the client is never sent information it should not
/// have. Information never received cannot be extracted." A codec that will encode it on
/// request turns an anti-cheat guarantee into a convention.
///
/// `derived` is rejected for the same structural reason `SCHEMA_AND_EVOLUTION.md` §10
/// check 10 rejects it in the manifest: replicating 16,384 fragments is the thing the
/// class exists to avoid.
fn assertReplicable(comptime c: d.Component) void {
    comptime {
        if (!d.projectionsFor(c.class).replication) {
            @compileError("codec: component '" ++ c.name ++ "' is class '" ++ @tagName(c.class) ++
                "', which is not in the replication projection (ARCHITECTURE.md §5.1). " ++
                "This is the replication codec; save and replay are different projections " ++
                "with different representations and §18.7 forbids unifying them.");
        }
    }
}

/// Encode every field. Full-state encode; delta against an acked baseline is §9.4 and
/// builds on this.
pub fn encode(comptime c: d.Component, value: Storage(c), writer: *bits.Writer) bits.Writer.Error!void {
    comptime assertReplicable(c);
    inline for (comptime wireOrder(c)) |i| {
        const f = c.fields[i];
        try encodeField(f, @field(value, f.name), writer);
    }
}

/// Decode every field.
///
/// Every failure mode is an error. There is no input a hostile peer can send that makes
/// this panic, read out of bounds, or loop — the widths are comptime constants and the
/// reader is bounds-checked, so the only failure is running out of bits.
pub fn decode(comptime c: d.Component, reader: *bits.Reader) bits.Reader.Error!Storage(c) {
    comptime assertReplicable(c);
    var out: Storage(c) = undefined;
    inline for (comptime wireOrder(c)) |i| {
        const f = c.fields[i];
        @field(out, f.name) = try decodeField(f, reader);
    }
    return out;
}

/// Encode only the fields whose mask bit is set, preceded by the mask.
///
/// This is what makes §4.1's arithmetic work: 1,500 bytes per snapshot across ~180
/// entity updates means whole-component encodes are unaffordable for anything that did
/// not change.
pub fn encodeMasked(
    comptime c: d.Component,
    value: Storage(c),
    field_mask: u32,
    writer: *bits.Writer,
) bits.Writer.Error!void {
    comptime assertReplicable(c);
    comptime std.debug.assert(c.fields.len <= 32);
    // Mask bits are indexed by wire order, not declaration order, for the same reason
    // the fields themselves are — see wireOrder.
    try writer.writeBits(field_mask, @intCast(c.fields.len));
    inline for (comptime wireOrder(c), 0..) |field_index, bit| {
        if (field_mask & (@as(u32, 1) << @intCast(bit)) != 0) {
            const f = c.fields[field_index];
            try encodeField(f, @field(value, f.name), writer);
        }
    }
}

/// Decode a masked update over a baseline. Absent fields keep their baseline value.
pub fn decodeMasked(
    comptime c: d.Component,
    baseline: Storage(c),
    reader: *bits.Reader,
) bits.Reader.Error!Storage(c) {
    comptime assertReplicable(c);
    comptime std.debug.assert(c.fields.len <= 32);
    var out = baseline;
    const field_mask: u32 = @intCast(try reader.readBits(@intCast(c.fields.len)));
    inline for (comptime wireOrder(c), 0..) |field_index, bit| {
        if (field_mask & (@as(u32, 1) << @intCast(bit)) != 0) {
            const f = c.fields[field_index];
            @field(out, f.name) = try decodeField(f, reader);
        }
    }
    return out;
}
