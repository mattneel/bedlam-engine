//! Deterministic randomness for the simulation.
//!
//! `SCOPED_ROLLBACK.md` §5 states the requirement and attaches no mechanism: "Random
//! streams must be per-entity or per-system, never global — a global PRNG advanced a
//! different number of times during scoped replay produces divergence immediately."
//!
//! **The mechanism is that there is no stream.** `draw` is a pure function of
//! `(root, tick, entity, stream)`. Nothing advances, so nothing can be advanced a
//! different number of times, and the property §5 asks for holds by construction rather
//! than by discipline.
//!
//! Keying on `tick` is what makes this work for *scoped* rollback specifically, and it is
//! stronger than §5 literally requires. A per-entity stream with internal state is
//! already immune to *ordering* differences, but not to *count* differences: a scoped
//! replay re-simulates a subset, so an entity inside the causal island is stepped while
//! one outside it is not. On the next full tick their stream positions disagree. A
//! function keyed by tick has no position to disagree about.
//!
//! `ARCHITECTURE.md` §7 profile 3: no float anywhere, wrapping integer operations only,
//! identical on every target. `--verify-determinism` will hash across the four foreign
//! architectures `zig build cross` already runs on.
//!
//! Adapted from gkz's `src/rng.zig` (github.com/mattneel/gkz), which solves the same
//! problem the same way.

const std = @import("std");
const fpz = @import("fpz");

/// Distinguishes concurrent uses within one `(tick, entity)` so they do not collide.
/// Systems that draw more than once per entity per tick vary this, not a counter.
pub const Stream = enum(u32) {
    damage_variance = 0,
    spread = 1,
    loot_roll = 2,
    ai_decision = 3,
    fragment_impulse = 4,
    spawn_jitter = 5,
    _,
};

/// SplitMix64 finalizer, Stafford variant 13.
///
/// A mixing function rather than a generator: no state, no period to exhaust, and every
/// operation is a wrapping integer op with an identical result on every target. The
/// avalanche quality is what makes a *counter-derived* input acceptable as a seed —
/// adjacent ticks and adjacent entity indices produce uncorrelated output, which a
/// weaker mix would not.
fn mix64(z0: u64) u64 {
    var z = z0;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// The whole interface. Pure, total, and order-independent.
///
/// `root` is the session seed, recorded in the replay log so a run is reproducible from
/// `(seed, inputs)` alone.
pub fn draw(root: u64, tick: u64, entity: u32, stream: Stream) u64 {
    // The golden-ratio offset is not decoration. `mix64` is a bijection with 0 as a fixed
    // point, so folding the raw inputs in directly makes `draw(0, 0, 0, stream 0)` return
    // exactly 0 — and seed 0, tick 0, entity 0 is the most likely combination in any test
    // or first session. Offsetting the accumulator means no input reaches the fixed point
    // structurally.
    //
    // Each coordinate is scaled by a distinct odd constant before folding. Multiplication
    // by an odd number is a bijection on u64, so no information is lost, and it separates
    // coordinates that are otherwise dense adjacent counters — without it, entity 1 at
    // tick 2 and entity 2 at tick 1 would be uncomfortably close inputs.
    var h = root +% 0x9E3779B97F4A7C15;
    h = mix64(h +% (tick *% 0xBF58476D1CE4E5B9));
    h = mix64(h +% (@as(u64, entity) *% 0x94D049BB133111EB));
    h = mix64(h +% (@as(u64, @intFromEnum(stream)) *% 0xD6E8FEB86659FD93));
    return h;
}

/// Uniform in `[0, n)`. `n == 0` yields 0.
///
/// Uses the multiply-shift reduction rather than modulo: one 64-bit multiply instead of a
/// division, and no rejection loop — a loop would make the cost input-dependent, which is
/// a timing side channel and a variable-cost operation inside a fixed tick budget.
/// The residual modulo bias is below 2^-64 relative and irrelevant at simulation scale.
pub fn drawLessThan(root: u64, tick: u64, entity: u32, stream: Stream, n: u64) u64 {
    if (n == 0) return 0;
    const product = @as(u128, draw(root, tick, entity, stream)) * @as(u128, n);
    return @intCast(product >> 64);
}

/// Uniform in `[lo, hi]`, inclusive.
pub fn drawRange(root: u64, tick: u64, entity: u32, stream: Stream, lo: i64, hi: i64) i64 {
    std.debug.assert(hi >= lo);
    const span = @as(u64, @intCast(@as(i128, hi) - @as(i128, lo) + 1));
    return @intCast(@as(i128, lo) + drawLessThan(root, tick, entity, stream, span));
}

/// Uniform fixed-point in `[lo, hi]`.
///
/// The span is computed in i128 because `Fixed.MAX.raw - Fixed.MIN.raw` overflows i64 —
/// fpz's operations are total but its range is not symmetric about zero, and a caller
/// asking for the full range is exactly the caller least likely to have checked.
pub fn drawFixed(root: u64, tick: u64, entity: u32, stream: Stream, lo: fpz.Fixed, hi: fpz.Fixed) fpz.Fixed {
    std.debug.assert(hi.raw >= lo.raw);
    const span = @as(u128, @intCast(@as(i128, hi.raw) - @as(i128, lo.raw))) + 1;
    const offset = (@as(u128, draw(root, tick, entity, stream)) * span) >> 64;
    return fpz.Fixed.fromRaw(@intCast(@as(i128, lo.raw) + @as(i128, @intCast(offset))));
}

// ---------------------------------------------------------------------------

test "draw is a pure function — repeated calls never advance" {
    // The property SCOPED_ROLLBACK §5 needs. A stateful generator cannot have it.
    const a = draw(0xBED1A3, 100, 42, .spread);
    const b = draw(0xBED1A3, 100, 42, .spread);
    try std.testing.expectEqual(a, b);
}

test "scoped replay of a subset matches the full-world result" {
    // The failure §5 describes, reproduced directly. Simulate ticks 100..105 for four
    // entities, then re-simulate only entity 2 — as a causal island would — and require
    // identical values. With a per-entity *stream*, entity 2's position would have
    // advanced 6 times in the full run and 6 more in the replay, and diverged.
    const root: u64 = 0xC0FFEE;
    var full: [4][6]u64 = undefined;
    for (0..4) |e| {
        for (0..6) |t| {
            full[e][t] = draw(root, 100 + t, @intCast(e), .damage_variance);
        }
    }

    // The island: entity 2 only, re-simulated after the fact.
    for (0..6) |t| {
        const replayed = draw(root, 100 + t, 2, .damage_variance);
        try std.testing.expectEqual(full[2][t], replayed);
    }
}

test "system evaluation order cannot affect the result" {
    // ARCHITECTURE.md §8's task graph does not promise a fixed order across thread
    // counts, so any dependence on call order is a divergence between a serial and a
    // parallel run of the same tick.
    const root: u64 = 1;
    const forward = [_]u64{
        draw(root, 7, 0, .ai_decision),
        draw(root, 7, 1, .ai_decision),
        draw(root, 7, 2, .ai_decision),
    };
    const backward = [_]u64{
        draw(root, 7, 2, .ai_decision),
        draw(root, 7, 1, .ai_decision),
        draw(root, 7, 0, .ai_decision),
    };
    try std.testing.expectEqual(forward[0], backward[2]);
    try std.testing.expectEqual(forward[2], backward[0]);
}

test "streams within one tick and entity are independent" {
    const root: u64 = 99;
    const a = draw(root, 5, 3, .spread);
    const b = draw(root, 5, 3, .loot_roll);
    const c = draw(root, 5, 3, .damage_variance);
    try std.testing.expect(a != b);
    try std.testing.expect(b != c);
    try std.testing.expect(a != c);
}

test "adjacent ticks and entities are uncorrelated" {
    // Counter-derived inputs are only acceptable because the finalizer avalanches. If
    // this regressed, neighbouring entities would visibly share outcomes.
    const root: u64 = 0x5EED;
    var diff_bits: u64 = 0;
    for (0..64) |e| {
        diff_bits |= draw(root, 1, @intCast(e), .spread) ^ draw(root, 2, @intCast(e), .spread);
    }
    // Every bit position must differ for at least one entity.
    try std.testing.expectEqual(~@as(u64, 0), diff_bits);
}

test "drawLessThan stays in range including the degenerate cases" {
    const root: u64 = 4;
    for ([_]u64{ 0, 1, 2, 6, 100, std.math.maxInt(u32), std.math.maxInt(u64) }) |n| {
        for (0..64) |t| {
            const v = drawLessThan(root, t, 0, .loot_roll, n);
            if (n == 0) {
                try std.testing.expectEqual(@as(u64, 0), v);
            } else {
                try std.testing.expect(v < n);
            }
        }
    }
}

test "drawLessThan is roughly uniform" {
    // Not a statistical proof, just a guard against a reduction that collapses.
    const root: u64 = 0xABCDEF;
    var buckets = [_]u32{0} ** 6;
    for (0..60_000) |t| {
        buckets[@intCast(drawLessThan(root, t, 0, .loot_roll, 6))] += 1;
    }
    for (buckets) |count| {
        try std.testing.expect(count > 9_000 and count < 11_000);
    }
}

test "drawRange covers its bounds and never escapes them" {
    const root: u64 = 77;
    var saw_lo = false;
    var saw_hi = false;
    for (0..4000) |t| {
        const v = drawRange(root, t, 1, .spawn_jitter, -3, 3);
        try std.testing.expect(v >= -3 and v <= 3);
        if (v == -3) saw_lo = true;
        if (v == 3) saw_hi = true;
    }
    try std.testing.expect(saw_lo and saw_hi);
}

test "drawFixed spans the full fpz range without overflowing" {
    // Fixed.MAX.raw - Fixed.MIN.raw overflows i64; the i128 span is why this is total.
    const root: u64 = 123;
    for (0..500) |t| {
        const v = drawFixed(root, t, 0, .fragment_impulse, fpz.Fixed.MIN, fpz.Fixed.MAX);
        try std.testing.expect(v.raw >= fpz.Fixed.MIN.raw);
        try std.testing.expect(v.raw <= fpz.Fixed.MAX.raw);
    }
}

test "drawFixed respects a narrow range" {
    const root: u64 = 321;
    const lo = fpz.Fixed.fromInt(-1);
    const hi = fpz.Fixed.fromInt(1);
    for (0..2000) |t| {
        const v = drawFixed(root, t, 9, .fragment_impulse, lo, hi);
        try std.testing.expect(v.raw >= lo.raw and v.raw <= hi.raw);
    }
}

test "pinned vectors — a change here is a change to every recorded replay" {
    // ARCHITECTURE.md §5.1: a replay is "input/event log + seeds + periodic canonical
    // checkpoints". If this function changes, every replay in the §11 corpus decodes to a
    // different run while still validating structurally — silent, and exactly the class
    // of failure SCHEMA_AND_EVOLUTION.md §0 exists to make loud. Pinning makes the change
    // a visible diff.
    //
    // These also re-verify on s390x, arm and mips via `zig build cross`, which is where a
    // byte-order or word-size dependency would show up.
    try std.testing.expectEqual(@as(u64, 0x33FE8BD4F9C57863), draw(0, 0, 0, @enumFromInt(0)));
    try std.testing.expectEqual(@as(u64, 0xA2C2203025A96511), draw(1, 2, 3, @enumFromInt(4)));
}

test "the origin is not a fixed point" {
    // mix64 is a bijection with 0 as its fixed point, so an implementation that folds raw
    // inputs in returns exactly 0 for seed 0, tick 0, entity 0, stream 0 — which is the
    // single most likely combination in a test or a first session, and would look like
    // working code until someone noticed every early roll landing the same way.
    try std.testing.expect(draw(0, 0, 0, @enumFromInt(0)) != 0);

    // Nor is any small neighbourhood of it degenerate.
    var seen: [16]u64 = undefined;
    for (0..16) |i| seen[i] = draw(0, i, 0, @enumFromInt(0));
    for (seen, 0..) |a, i| {
        try std.testing.expect(a != 0);
        for (seen[i + 1 ..]) |b| try std.testing.expect(a != b);
    }
}
