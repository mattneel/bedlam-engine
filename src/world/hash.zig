//! Canonical world hash: the artifact `--verify-determinism` compares.
//!
//! `CI_TIERS.md` recorded this as an open question — "which artifact does it hash?" — and
//! flagged the obvious answer as illegal. This is the answer.
//!
//! **It cannot be chunk bytes.** §0 P1 permits physical layout to differ per target, and
//! `chunk.Budget` makes it actually differ: a wasm32 chunk holds fewer rows than a desktop
//! one, so two *conformant* peers have different chunk bytes for the same world by design.
//! Hashing them would report a desync on every cross-platform session, which is the exact
//! inverse of the bug the flag exists to find.
//!
//! **So it hashes a canonical LOGICAL projection**, built to be identical wherever the
//! same logical world exists:
//!
//!   - Entities in stable-ID order, not storage order. Storage order is a function of
//!     spawn and swap-remove history, which two peers can legitimately differ on after a
//!     scoped rollback re-simulates one island and not another.
//!   - Components in stable registry-ID order (§18.6), never declaration or layout order.
//!   - Every scalar little-endian explicitly, so a big-endian host agrees. `zig build
//!     cross` runs this on s390x and mips, which is the only reason that claim is worth
//!     anything.
//!   - Only the live prefix. The dead tail is canonical (chunk.zig zeroes it) but it is
//!     not *state*, and including it would make the hash depend on chunk capacity, which
//!     is per-target — reintroducing the problem by the back door.
//!
//! SHA-256 rather than something faster, for the same reason the schema fingerprint uses
//! it: §18.13 permits no custom cryptographic construction, and a hash whose collisions
//! could be constructed is a hash an untrusted host (§14.3) can use to make a divergent
//! replay validate.

const std = @import("std");
const entity_mod = @import("entity.zig");
const journal_mod = @import("journal.zig");

pub const Digest = [32]u8;
pub const Hex = [64]u8;

pub fn hexDigest(d: Digest) Hex {
    var out: Hex = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&d}) catch unreachable;
    return out;
}

/// Hash a world's logical state.
///
/// `WorldT` must expose `table` (with `chunkIterator`), `component_ids`, and `tick`.
pub fn hashWorld(gpa: std.mem.Allocator, w: anytype) !Digest {
    const Columns = @TypeOf(w.*).ColumnSet;
    const info = @typeInfo(Columns).@"struct";

    var sha = std.crypto.hash.sha2.Sha256.init(.{});

    // The tick is part of the state. Two worlds with identical contents at different
    // ticks are not the same world, and a hash that said otherwise would hide a
    // rollback that restored the right bytes to the wrong time.
    var tick_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &tick_le, w.tick, .little);
    sha.update(&tick_le);

    // Collect live entities and sort by stable identity. Storage order is history —
    // spawn order plus swap-removes — and two peers may legitimately differ on it after
    // a scoped rollback re-simulates one island and not another, while agreeing
    // completely about the world.
    var live: std.ArrayList(entity_mod.Entity) = .empty;
    defer live.deinit(gpa);

    var it = w.table.chunkIterator();
    while (it.next()) |c| {
        for (c.liveEntities()) |e| try live.append(gpa, e);
    }
    std.mem.sort(entity_mod.Entity, live.items, {}, lessByIdentity);

    var count_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_le, live.items.len, .little);
    sha.update(&count_le);

    // Column order follows the stable registry IDs, not declaration order, so inserting a
    // column in the source cannot change the hash of an unrelated world.
    const order = comptime columnOrderPlaceholder(info.fields.len);
    var column_order: [info.fields.len]usize = order;
    sortColumnsById(&column_order, w.component_ids);

    for (live.items) |e| {
        var ent_le: [4]u8 = undefined;
        std.mem.writeInt(u32, &ent_le, @bitCast(e), .little);
        sha.update(&ent_le);

        for (column_order) |ci| {
            var id_le: [4]u8 = undefined;
            std.mem.writeInt(u32, &id_le, w.component_ids[ci], .little);
            sha.update(&id_le);

            inline for (info.fields, 0..) |f, fi| {
                if (fi == ci) {
                    const value = w.table.get(e, f.name).?;
                    hashValue(&sha, f.type, value);
                }
            }
        }
    }

    var out: Digest = undefined;
    sha.final(&out);
    return out;
}

fn lessByIdentity(_: void, a: entity_mod.Entity, b: entity_mod.Entity) bool {
    if (a.index != b.index) return a.index < b.index;
    return a.generation < b.generation;
}

fn columnOrderPlaceholder(comptime n: usize) [n]usize {
    comptime {
        var out: [n]usize = undefined;
        for (0..n) |i| out[i] = i;
        return out;
    }
}

fn sortColumnsById(order: []usize, component_ids: anytype) void {
    // Insertion sort: n is the column count, which is small and comptime-bounded.
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        var j = i;
        while (j > 0 and component_ids[order[j - 1]] > component_ids[order[j]]) : (j -= 1) {
            const tmp = order[j - 1];
            order[j - 1] = order[j];
            order[j] = tmp;
        }
    }
}

/// Explicit little-endian for every scalar.
///
/// `@bitCast` to bytes would inherit host byte order and pass every test on the six
/// shipping targets, all of which are little-endian — the bug would only ever appear on a
/// platform Bedlam does not ship, which is to say never, until a replay recorded on one
/// architecture is validated on another.
fn hashValue(sha: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .bool => sha.update(&[_]u8{@intFromBool(value)}),
        .int => |i| {
            // Sign-extend to a byte-aligned width, then reinterpret as unsigned in two's
            // complement. Going via @intCast to unsigned panics on every negative value —
            // and Fixed.raw is signed, so that is the common case, not the edge case.
            const bit_count = @max(8, i.bits);
            const Signed = std.meta.Int(.signed, bit_count);
            const Unsigned = std.meta.Int(.unsigned, bit_count);
            const widened: Unsigned = switch (i.signedness) {
                .signed => @bitCast(@as(Signed, value)),
                .unsigned => @intCast(value),
            };
            var buf: [@sizeOf(Unsigned)]u8 = undefined;
            std.mem.writeInt(Unsigned, &buf, widened, .little);
            sha.update(&buf);
        },
        .@"enum" => |e| hashValue(sha, e.tag_type, @intFromEnum(value)),
        .@"struct" => |s| {
            inline for (s.fields) |f| hashValue(sha, f.type, @field(value, f.name));
        },
        .array => |a| {
            for (value) |elem| hashValue(sha, a.child, elem);
        },
        .float => @compileError("hashWorld: " ++ @typeName(T) ++
            " is a float. ARCHITECTURE.md §7 — a float in hashed state makes the digest " ++
            "architecture-dependent, which is the thing --verify-determinism exists to detect."),
        else => @compileError("hashWorld: unhashable type " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------------------

const world_mod = @import("world.zig");
const chunk_mod = @import("chunk.zig");
const Fixed = @import("fpz").Fixed;

const TestColumns = struct {
    health: u16,
    position: [3]Fixed,
};
const ids = [_]journal_mod.ComponentId{ 0x0055, 0x0041 };
const TestWorld = world_mod.World(TestColumns, chunk_mod.Budget.desktop);

fn seeded(gpa: std.mem.Allocator, n: u16) !TestWorld {
    var w = try TestWorld.init(gpa, 4096, ids);
    for (0..n) |i| {
        _ = try w.spawn(.{
            .health = @intCast(i % 100),
            .position = .{ Fixed.fromInt(@intCast(i)), Fixed.ZERO, Fixed.ZERO },
        });
    }
    return w;
}

test "the same logical world hashes the same" {
    const gpa = std.testing.allocator;
    var a = try seeded(gpa, 32);
    defer a.deinit();
    var b = try seeded(gpa, 32);
    defer b.deinit();

    try std.testing.expectEqual(try hashWorld(gpa, &a), try hashWorld(gpa, &b));
}

test "a different value changes the hash" {
    const gpa = std.testing.allocator;
    var a = try seeded(gpa, 8);
    defer a.deinit();
    const before = try hashWorld(gpa, &a);

    var it = a.table.chunkIterator();
    const first = it.next().?.liveEntities()[0];
    _ = a.set(first, "health", 0xFFFF);

    try std.testing.expect(!std.mem.eql(u8, &before, &(try hashWorld(gpa, &a))));
}

test "storage order does not affect the hash" {
    // The property that makes this usable after a scoped rollback. Two peers can reach
    // the same logical world with different chunk layouts — one re-simulated an island
    // and swap-removed in a different order — and must still agree.
    const gpa = std.testing.allocator;

    var a = try TestWorld.init(gpa, 4096, ids);
    defer a.deinit();
    var b = try TestWorld.init(gpa, 4096, ids);
    defer b.deinit();

    // A: spawn three, drop the middle one.
    const a1 = try a.spawn(.{ .health = 1, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });
    _ = a1;
    const a2 = try a.spawn(.{ .health = 2, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });
    const a3 = try a.spawn(.{ .health = 3, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });
    _ = a3;
    _ = a.despawn(a2);

    // B: spawn the same three, drop the middle one — but the swap-remove leaves storage
    // in a different order than a naive replay would.
    const b1 = try b.spawn(.{ .health = 1, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });
    _ = b1;
    const b2 = try b.spawn(.{ .health = 2, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });
    const b3 = try b.spawn(.{ .health = 3, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });
    _ = b3;
    _ = b.despawn(b2);

    try std.testing.expectEqual(try hashWorld(gpa, &a), try hashWorld(gpa, &b));
}

test "the tick is part of the state" {
    // A rollback that restored the right bytes to the wrong time would otherwise hash
    // as correct.
    const gpa = std.testing.allocator;
    var w = try seeded(gpa, 4);
    defer w.deinit();

    const before = try hashWorld(gpa, &w);
    w.advanceTick();
    try std.testing.expect(!std.mem.eql(u8, &before, &(try hashWorld(gpa, &w))));
}

test "entity identity is hashed, not just component values" {
    // Two worlds holding the same values under different handles are not the same world:
    // every reference between them means something different.
    const gpa = std.testing.allocator;

    var a = try TestWorld.init(gpa, 4096, ids);
    defer a.deinit();
    _ = try a.spawn(.{ .health = 7, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });

    var b = try TestWorld.init(gpa, 4096, ids);
    defer b.deinit();
    const throwaway = try b.spawn(.{ .health = 7, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });
    _ = b.despawn(throwaway);
    _ = try b.spawn(.{ .health = 7, .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO } });

    // Same value, but b's entity carries a later generation.
    try std.testing.expect(!std.mem.eql(u8, &(try hashWorld(gpa, &a)), &(try hashWorld(gpa, &b))));
}

test "pinned digest — re-verified on big-endian and 32-bit by zig build cross" {
    // The claim this file makes is that the digest is a property of the logical world and
    // not of the host. Only a foreign architecture can falsify that, and all six shipping
    // targets are little-endian, so `zig build cross` on s390x and mips is the only place
    // this assertion means anything.
    const gpa = std.testing.allocator;
    var w = try seeded(gpa, 4);
    defer w.deinit();

    const hex = hexDigest(try hashWorld(gpa, &w));
    try std.testing.expectEqualStrings(
        "488e37506676644303891e33deea08cdd0a65d0443b6e2c8a4e5f8a6c943ce05",
        &hex,
    );
}
