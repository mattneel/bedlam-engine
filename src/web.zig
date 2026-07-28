//! Web entry point.
//!
//! The browser build is a module the TypeScript bootstrap instantiates inside a Worker
//! (`docs/ARCHITECTURE.md` §2, §4.1), not a program with a `main()`. It has no entry
//! point, no stdio, and no process arguments.
//!
//! **Nothing reachable from this file may touch `std.process` or the OS-backed parts of
//! `std.Io`.** Freestanding wasm has no syscalls behind them: `std.Io.Threaded` reaches
//! for `posix.getrandom` and `posix.IOV_MAX`, neither of which exists on this target.
//! That is why this root exists instead of a conditional inside `src/main.zig` — the
//! constraint is structural and should be enforced by which file the artifact is rooted
//! at, not by a branch someone can wander past.
//!
//! **The claim this file exists to make good on:** the same simulation, stepped in a
//! browser, produces a per-tick digest bit-identical to a native run. `ARCHITECTURE.md`
//! §7 says cross-architecture agreement is constructed rather than assumed, and wasm32 is
//! the target where that is hardest — 32-bit, a different ISA, and a different compiler
//! backend. `tools/web/check.mjs` compares the two.

const std = @import("std");
const bedlam = @import("bedlam_engine");

const Fixed = bedlam.fpz.Fixed;
const step = bedlam.sim.step;

/// A single simulation, owned by the module. The browser instantiates one module per
/// Worker (§4.1), so one world per module is the right granularity.
var sim: ?step.Sim = null;

/// wasm32 has no allocator by default. A fixed arena rather than a growing heap: §18.8
/// forbids unbounded allocation in the frame loop, and a browser tab that grows its
/// linear memory mid-tick is exactly what `CONFORMANCE_PROFILES.md` §2's 1.8 GB budget is
/// meant to prevent.
var arena_buf: [8 * 1024 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&arena_buf);

/// Bits a Transform occupies on the wire. Exported so the TypeScript bootstrap sizes its
/// receive buffers from the engine rather than a duplicated constant — §18.4 forbids
/// duplicated definitions, and a hand-copied number in TypeScript is exactly that.
export fn bedlamTransformBits() u32 {
    return comptime bedlam.wire.codec.componentBits(bedlam.schema.schema.components[0]);
}

export fn bedlamComponentCount() u32 {
    return @intCast(bedlam.schema.manifest.manifest.components.len);
}

/// Create the world. Returns 0 on success.
export fn bedlamInit(seed_lo: u32, seed_hi: u32, entities: u32) i32 {
    if (sim != null) return -1;
    const seed = (@as(u64, seed_hi) << 32) | seed_lo;
    sim = step.seedWorld(fba.allocator(), seed, @intCast(entities)) catch return -2;
    return 0;
}

/// Advance `ticks` ticks with the reference schedule.
export fn bedlamStep(seed_lo: u32, seed_hi: u32, ticks: u32) i32 {
    const s = &(sim orelse return -1);
    const seed = (@as(u64, seed_hi) << 32) | seed_lo;
    for (0..ticks) |_| step.step(s, seed, &step.System.all);
    return 0;
}

var digest_hex: [64]u8 = undefined;

/// Canonical world digest as 64 hex bytes in linear memory. Returns the offset, or 0 on
/// failure — the browser reads it directly rather than being handed a copy.
export fn bedlamWorldDigest() u32 {
    const s = &(sim orelse return 0);
    const d = bedlam.world.hash.hashWorld(fba.allocator(), s) catch return 0;
    digest_hex = bedlam.world.hash.hexDigest(d);
    return @intFromPtr(&digest_hex);
}

export fn bedlamDigestLen() u32 {
    return digest_hex.len;
}

export fn bedlamTick() u32 {
    const s = sim orelse return 0;
    return @intCast(s.tick);
}

export fn bedlamLiveCount() u32 {
    const s = sim orelse return 0;
    return s.liveCount();
}

/// Live entity positions, as raw fixed-point x/y pairs.
///
/// Exported so the Worker has something to *draw*. §4.1's M0 criterion 8 is not "a worker
/// exists" — it is a worker owning an OffscreenCanvas and presenting the simulation, which
/// needs the simulation's state to cross into JS.
///
/// **Raw `i64` halves, not floats.** `Fixed` is Q40.24 over i64 and JS numbers cannot hold
/// an i64 exactly. Sending a pre-divided float would move the fixed-to-float conversion
/// into the engine, where §7 says it does not belong; sending the raw halves keeps the
/// conversion on the presentation side where a rounding difference cannot reach the
/// simulation. The layout is `[lo, hi]` per coordinate, little-endian pairs, x then y.
var position_buf: [4096]i32 = undefined;

export fn bedlamPositions() u32 {
    if (sim == null) return 0;
    const s = &sim.?;
    var n: usize = 0;
    var it = s.table.chunkIterator();
    outer: while (it.next()) |c| {
        for (c.liveEntities()) |e| {
            if (n + 4 > position_buf.len) break :outer;
            const p = s.table.get(e, "position").?;
            position_buf[n + 0] = @truncate(p[0].raw);
            position_buf[n + 1] = @truncate(p[0].raw >> 32);
            position_buf[n + 2] = @truncate(p[1].raw);
            position_buf[n + 3] = @truncate(p[1].raw >> 32);
            n += 4;
        }
    }
    return @intFromPtr(&position_buf);
}

/// Number of i32 words `bedlamPositions` filled — four per entity.
export fn bedlamPositionWords() u32 {
    const s = sim orelse return 0;
    return @min(s.liveCount() * 4, position_buf.len);
}

/// Schema fingerprint, so the page can verify it is running the build it thinks it is —
/// `SCHEMA_AND_EVOLUTION.md` §6 makes this a connection-time decision, and the browser is
/// a peer like any other.
var fingerprint_hex: [64]u8 = undefined;

export fn bedlamFingerprint() u32 {
    const fp = bedlam.schema.manifest.fingerprint(
        fba.allocator(),
        bedlam.schema.manifest.manifest,
        bedlam.schema.wire.Layout.wasm32,
    ) catch return 0;
    fingerprint_hex = fp;
    return @intFromPtr(&fingerprint_hex);
}
