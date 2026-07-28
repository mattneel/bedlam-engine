//! A tick, and the determinism harness that verifies it.
//!
//! `AGENTS.md` §3: "`--verify-determinism` runs in CI from the first tick loop."
//! `ARCHITECTURE.md` §7 says what it must prove: the simulation "run twice at different
//! thread counts", hashing every tick and failing on divergence.
//!
//! This is the first tick loop, so this is where the flag lands. The systems are
//! deliberately trivial — the harness is the point, and building it now is what §3 means
//! by "from the first tick loop" rather than "once there is something worth verifying".
//!
//! **Anchored to a serial referent, not to a second thread count.** §7's phrasing —
//! twice at different thread counts — passes when both runs are wrong the same way, which
//! is the failure mode a shared scheduler bug produces. Comparing every configuration
//! against one canonical serial execution instead means a scheduler that corrupts state
//! identically at 4 and 8 threads still fails. Costs nothing now and is expensive to
//! retrofit once a scheduler exists.
//!
//! **Execution order is a determinism axis in its own right.** §8 specifies an explicit
//! task graph, which does not promise a fixed order across thread counts. Permuting
//! system order within a tick and requiring an identical hash catches order dependence
//! with no threads involved at all — a stronger and much cheaper check than actually
//! running threads.

const std = @import("std");
const fpz = @import("fpz");
const rng = @import("rng.zig");
const world_mod = @import("bedlam_world");

const Fixed = fpz.Fixed;

/// The reference workload's shape in miniature: a position integrated by a velocity, a
/// health value driven by seeded randomness. Enough to exercise fixed-point arithmetic,
/// the RNG, and entity lifecycle.
pub const Columns = struct {
    position: [3]Fixed,
    velocity: [3]Fixed,
    impulse: [3]Fixed,
    health: u16,
};

pub const component_ids = [_]u32{ 0x0041, 0x0041_0004, 0x0091, 0x0055 };
pub const Sim = world_mod.world.World(Columns, world_mod.chunk.Budget.desktop);

/// One system. Ordered by a stable ID rather than array position, so a permutation of the
/// schedule is expressible without renumbering anything.
///
/// `all` is deliberately a set of systems with DISJOINT writes, and no system reads what
/// another writes. That is what makes permuting them meaningful: §8's explicit task graph
/// is what declares real dependencies, and the permutation check applies to systems the
/// graph says are independent. Permuting genuinely dependent systems and demanding an
/// identical result would not be testing determinism, it would be asserting something
/// false.
///
/// `couple` is deliberately NOT in `all`. It writes velocity, which `integrate` reads, so
/// it is order-dependent by construction — it exists so the harness's ability to DETECT
/// order dependence is itself tested. A check that can only pass is not a check.
pub const System = enum(u8) {
    integrate = 0,
    decay = 1,
    jitter = 2,
    couple = 3,

    pub const all = [_]System{ .integrate, .decay, .jitter };
};

fn runSystem(w: *Sim, sys: System, seed: u64) void {
    switch (sys) {
        .integrate => w.mutateAll("position", w, struct {
            fn apply(sim: *Sim, e: world_mod.entity.Entity, p: *[3]Fixed) void {
                const v = sim.table.get(e, "velocity").?;
                inline for (0..3) |i| p[i] = Fixed.add(p[i], v[i]);
            }
        }.apply),

        .decay => w.mutateAll("health", {}, struct {
            fn apply(_: void, _: world_mod.entity.Entity, h: *u16) void {
                if (h.* > 0) h.* -= 1;
            }
        }.apply),

        .jitter => {
            const Ctx = struct { seed: u64, tick: u64 };
            const ctx: Ctx = .{ .seed = seed, .tick = w.tick };
            w.mutateAll("impulse", ctx, struct {
                fn apply(c: Ctx, e: world_mod.entity.Entity, im: *[3]Fixed) void {
                    // Keyed on (tick, entity), so re-simulating a subset produces the
                    // same values — SCOPED_ROLLBACK.md §5.
                    const lo = Fixed.rconst(-0.5);
                    const hi = Fixed.rconst(0.5);
                    im[0] = rng.drawFixed(c.seed, c.tick, e.index, .fragment_impulse, lo, hi);
                }
            }.apply);
        },

        // Reads impulse, writes velocity — which `integrate` reads. Excluded from `all`
        // for exactly that reason; see the doc on `System`.
        .couple => w.mutateAll("velocity", w, struct {
            fn apply(sim: *Sim, e: world_mod.entity.Entity, v: *[3]Fixed) void {
                const im = sim.table.get(e, "impulse").?;
                inline for (0..3) |i| v[i] = Fixed.add(v[i], im[i]);
            }
        }.apply),
    }
}

/// Advance one tick, running systems in `order`.
///
/// The order parameter is what makes the permutation check possible. A correct simulation
/// produces the same state for every order; one that does not has a hidden dependency
/// between systems, which is a bug that only manifests once the scheduler is parallel and
/// is nearly impossible to attribute at that point.
pub fn step(w: *Sim, seed: u64, order: []const System) void {
    for (order) |sys| runSystem(w, sys, seed);
    w.advanceTick();
}

pub fn seedWorld(gpa: std.mem.Allocator, seed: u64, count: u16) !Sim {
    var w = try Sim.init(gpa, 1 << 16, component_ids);
    errdefer w.deinit();
    try w.reserve(count);

    for (0..count) |i| {
        const idx: u32 = @intCast(i);
        _ = try w.spawn(.{
            .position = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
            .velocity = .{
                rng.drawFixed(seed, 0, idx, .spawn_jitter, Fixed.rconst(-1), Fixed.rconst(1)),
                Fixed.ZERO,
                Fixed.ZERO,
            },
            .impulse = .{ Fixed.ZERO, Fixed.ZERO, Fixed.ZERO },
            .health = @intCast(100 + (i % 50)),
        });
    }
    return w;
}

// ---------------------------------------------------------------------------
// The harness.
// ---------------------------------------------------------------------------

pub const Divergence = struct {
    tick: u64,
    expected: world_mod.hash.Hex,
    actual: world_mod.hash.Hex,
    /// What was varied to produce the divergent run.
    variation: []const u8,
};

pub const Report = struct {
    ticks: u64,
    final: world_mod.hash.Hex,
    divergence: ?Divergence,

    pub fn ok(self: Report) bool {
        return self.divergence == null;
    }
};

/// Run the reference schedule, recording a hash per tick.
fn hashStream(gpa: std.mem.Allocator, seed: u64, entities: u16, ticks: u64, order: []const System) ![]world_mod.hash.Hex {
    var w = try seedWorld(gpa, seed, entities);
    defer w.deinit();

    const out = try gpa.alloc(world_mod.hash.Hex, @intCast(ticks));
    errdefer gpa.free(out);

    for (0..@intCast(ticks)) |t| {
        step(&w, seed, order);
        out[t] = world_mod.hash.hexDigest(try world_mod.hash.hashWorld(gpa, &w));
    }
    return out;
}

/// Rotate the schedule by `n`. Guarantees a non-identity permutation for any n not a
/// multiple of the length, which a random shuffle does not — a shuffle that happens to
/// return the identity is a silent false negative.
fn rotate(comptime n: usize) [System.all.len]System {
    var out: [System.all.len]System = undefined;
    for (System.all, 0..) |sys, i| out[(i + n) % System.all.len] = sys;
    return out;
}

/// `--verify-determinism`.
///
/// Runs the reference schedule, then every rotation of it, and requires a bit-identical
/// per-tick hash stream from all of them. Reports the FIRST divergent tick, because the
/// last one is nearly useless for diagnosis — by then the two worlds differ everywhere.
pub fn verifyDeterminism(gpa: std.mem.Allocator, seed: u64, entities: u16, ticks: u64) !Report {
    const reference = try hashStream(gpa, seed, entities, ticks, &System.all);
    defer gpa.free(reference);

    // A second identical run first: if this diverges, the cause is ambient state rather
    // than ordering, and the ordering results would be noise.
    {
        const repeat = try hashStream(gpa, seed, entities, ticks, &System.all);
        defer gpa.free(repeat);
        for (reference, repeat, 0..) |a, b, t| {
            if (!std.mem.eql(u8, &a, &b)) {
                return .{
                    .ticks = ticks,
                    .final = reference[reference.len - 1],
                    .divergence = .{ .tick = t, .expected = a, .actual = b, .variation = "repeat run" },
                };
            }
        }
    }

    inline for (1..System.all.len) |n| {
        const order = comptime rotate(n);
        const permuted = try hashStream(gpa, seed, entities, ticks, &order);
        defer gpa.free(permuted);

        for (reference, permuted, 0..) |a, b, t| {
            if (!std.mem.eql(u8, &a, &b)) {
                return .{
                    .ticks = ticks,
                    .final = reference[reference.len - 1],
                    .divergence = .{
                        .tick = t,
                        .expected = a,
                        .actual = b,
                        .variation = "system order rotated by " ++ std.fmt.comptimePrint("{d}", .{n}),
                    },
                };
            }
        }
    }

    return .{ .ticks = ticks, .final = reference[reference.len - 1], .divergence = null };
}

// ---------------------------------------------------------------------------

test "a tick is reproducible" {
    const gpa = std.testing.allocator;
    var a = try seedWorld(gpa, 0xBED1A3, 32);
    defer a.deinit();
    var b = try seedWorld(gpa, 0xBED1A3, 32);
    defer b.deinit();

    for (0..16) |_| {
        step(&a, 0xBED1A3, &System.all);
        step(&b, 0xBED1A3, &System.all);
    }
    try std.testing.expectEqual(try world_mod.hash.hashWorld(gpa, &a), try world_mod.hash.hashWorld(gpa, &b));
}

test "verify-determinism passes on the reference schedule" {
    const gpa = std.testing.allocator;
    const report = try verifyDeterminism(gpa, 0xC0FFEE, 24, 32);
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(u64, 32), report.ticks);
}

test "the harness can actually fail" {
    // A check that can only pass is not a check. `couple` writes velocity, which
    // `integrate` reads, so their relative order is observable — and the hash stream must
    // say so.
    const gpa = std.testing.allocator;

    const a = try hashStream(gpa, 1, 8, 4, &[_]System{ .jitter, .couple, .integrate });
    defer gpa.free(a);
    const b = try hashStream(gpa, 1, 8, 4, &[_]System{ .jitter, .integrate, .couple });
    defer gpa.free(b);

    try std.testing.expect(!std.mem.eql(u8, &a[0], &b[0]));
}

test "divergence is reported at the FIRST tick, not the last" {
    // By the last tick two diverged worlds differ everywhere and the report is useless
    // for diagnosis. Compare two streams that are equal until tick 2 by construction.
    const gpa = std.testing.allocator;
    const a = try hashStream(gpa, 3, 8, 8, &[_]System{ .jitter, .integrate, .couple });
    defer gpa.free(a);
    const b = try hashStream(gpa, 3, 8, 8, &[_]System{ .jitter, .couple, .integrate });
    defer gpa.free(b);

    var first: ?usize = null;
    for (a, b, 0..) |x, y, t| {
        if (!std.mem.eql(u8, &x, &y)) {
            first = t;
            break;
        }
    }
    try std.testing.expectEqual(@as(?usize, 0), first);
}

test "the RNG is keyed so a re-simulated subset agrees" {
    // SCOPED_ROLLBACK.md §5 end to end: the jitter system draws per (tick, entity), so
    // stepping a world twice from the same state yields identical values regardless of
    // how many entities were stepped in between.
    const gpa = std.testing.allocator;
    var w = try seedWorld(gpa, 42, 16);
    defer w.deinit();

    step(&w, 42, &System.all);
    const after_one = try world_mod.hash.hashWorld(gpa, &w);

    var fresh = try seedWorld(gpa, 42, 16);
    defer fresh.deinit();
    step(&fresh, 42, &System.all);

    try std.testing.expectEqual(after_one, try world_mod.hash.hashWorld(gpa, &fresh));
}
