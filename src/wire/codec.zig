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
const bits = @import("bits.zig");
const quant = @import("quant.zig");
const schema_mod = @import("bedlam_schema");
const d = schema_mod.declare;
const w = schema_mod.wire;

/// 16.16 fixed point. `ARCHITECTURE.md` §7 requires fixed point inside the rollback
/// boundary — floats are not bit-exact across x86, ARM, and wasm32, and pretending
/// otherwise is the folklore §7 names.
pub const Q16_16 = struct {
    raw: i32,

    pub const one: Q16_16 = .{ .raw = 1 << 16 };

    pub fn fromFloat(v: f32) Q16_16 {
        return .{ .raw = @intFromFloat(@round(v * 65536.0)) };
    }
    pub fn toFloat(self: Q16_16) f32 {
        return @as(f32, @floatFromInt(self.raw)) / 65536.0;
    }
    pub fn add(a: Q16_16, b: Q16_16) Q16_16 {
        return .{ .raw = a.raw +% b.raw };
    }
};

/// Generational entity reference. `ARCHITECTURE.md` §5: entities are generational IDs, so
/// a stale handle is detectable rather than silently aliasing a recycled slot.
pub const EntityHandle = packed struct(u32) {
    index: u24,
    generation: u8,
};

/// The Zig storage type for a wire type. Physical layout may differ per target
/// (`ARCHITECTURE.md` §0 P1); the wire encoding may not.
pub fn StorageType(comptime wt: w.WireType) type {
    return switch (wt) {
        .bool => bool,
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .f32 => f32,
        .f64 => f64,
        .q16_16 => Q16_16,
        .vec3_quantized => [3]f32,
        .quat_smallest_three => [4]f32,
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
            types[i] = StorageType(f.wire);
        }
        // `.auto` layout, not `.@"extern"` or `.@"packed"`: ARCHITECTURE.md §0 P1 lets
        // physical layout differ per target, and the wire encoding below never reads
        // this struct's memory representation, only its fields by name.
        return @Struct(.auto, null, &names, &types, &@splat(.{}));
    }
}

/// Bits a field occupies on the wire, after quantization.
pub fn fieldBits(comptime f: d.Field) u7 {
    return switch (f.wire) {
        .vec3_quantized => switch (f.quant) {
            .bounded => |q| @as(u7, q.bits) * 3,
            else => @compileError("vec3_quantized field '" ++ f.name ++
                "' needs a bounded quantization policy; an unquantized vector does not fit the §4.1 byte budget"),
        },
        .quat_smallest_three => switch (f.quant) {
            .angular => |q| 2 + @as(u7, q.bits) * 3,
            else => @compileError("quat_smallest_three field '" ++ f.name ++ "' needs an angular quantization policy"),
        },
        .blob => @compileError("blob field '" ++ f.name ++
            "' is variable-length and has no fixed bit width; blobs belong on bulk_content, not in a snapshot"),
        else => @intCast(f.wire.wireBits() orelse
            @compileError("field '" ++ f.name ++ "' has no fixed wire width")),
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
    switch (f.wire) {
        .bool => try writer.writeBool(value),
        .u8, .u16, .u32, .u64 => try writer.writeBits(value, n),
        .i8, .i16, .i32, .i64 => {
            // Two's complement, truncated to width. Sign-extended on the way back out.
            const U = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(value)));
            try writer.writeBits(@as(U, @bitCast(value)), n);
        },
        .f32 => try writer.writeBits(@as(u32, @bitCast(value)), 32),
        .f64 => try writer.writeBits(@as(u64, @bitCast(value)), 64),
        .q16_16 => try writer.writeBits(@as(u32, @bitCast(value.raw)), 32),
        .entity_handle => try writer.writeBits(@as(u32, @bitCast(value)), 32),
        .string_id => try writer.writeBits(value, 32),
        .vec3_quantized => {
            const q = comptime f.quant.bounded;
            inline for (0..3) |i| {
                try writer.writeBits(quant.quantize(value[i], q.bits, q.min, q.max), q.bits);
            }
        },
        .quat_smallest_three => {
            const q = comptime f.quant.angular;
            const qq = quant.quantizeQuat(value, q.bits);
            try writer.writeBits(qq.largest, 2);
            try writer.writeBits(qq.a, q.bits);
            try writer.writeBits(qq.b, q.bits);
            try writer.writeBits(qq.c, q.bits);
        },
        .blob => comptime unreachable, // rejected by fieldBits
    }
}

fn decodeField(comptime f: d.Field, reader: *bits.Reader) bits.Reader.Error!StorageType(f.wire) {
    const n = comptime fieldBits(f);
    const T = StorageType(f.wire);
    return switch (f.wire) {
        .bool => try reader.readBool(),
        .u8, .u16, .u32, .u64 => @intCast(try reader.readBits(n)),
        .i8, .i16, .i32, .i64 => blk: {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(@as(U, @intCast(try reader.readBits(n))));
        },
        .f32 => @bitCast(@as(u32, @intCast(try reader.readBits(32)))),
        .f64 => @bitCast(try reader.readBits(64)),
        .q16_16 => .{ .raw = @bitCast(@as(u32, @intCast(try reader.readBits(32)))) },
        .entity_handle => @bitCast(@as(u32, @intCast(try reader.readBits(32)))),
        .string_id => @intCast(try reader.readBits(32)),
        .vec3_quantized => blk: {
            const q = comptime f.quant.bounded;
            var out: [3]f32 = undefined;
            inline for (0..3) |i| {
                out[i] = quant.dequantize(try reader.readBits(q.bits), q.bits, q.min, q.max);
            }
            break :blk out;
        },
        .quat_smallest_three => blk: {
            const q = comptime f.quant.angular;
            const largest: u2 = @intCast(try reader.readBits(2));
            const a = try reader.readBits(q.bits);
            const b = try reader.readBits(q.bits);
            const c = try reader.readBits(q.bits);
            break :blk quant.dequantizeQuat(.{ .largest = largest, .a = a, .b = b, .c = c }, q.bits);
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
