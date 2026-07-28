//! The audio thread's side of §17: consume the command ring, render a block.
//!
//! `audio_ring.zig` carries commands from the game thread. This is what runs on the other
//! end, and its whole contract is what it does *not* do. `render` allocates nothing, takes
//! no lock, calls into no OS, and does a bounded amount of work per sample — because it
//! runs on a thread whose deadline is 2.67 ms (the AudioWorklet quantum at 48 kHz) and
//! whose overrun is an audible click rather than a dropped frame.
//!
//! **Integer-only, like the simulation, but for a different reason.** §18.9 keeps platform
//! types out of portable code and the simulation is integer-only for cross-target
//! determinism; audio output does not need to be bit-identical across hosts. The reason
//! here is narrower and still real: the wasm32 and mobile targets are the ones under
//! thermal pressure, `set_position` values originate from replayed simulation ticks
//! (fixed-point by construction), and an integer mixer has no denormal cliff — a float
//! mixer fed a decaying tail can hit denormals and lose an order of magnitude of
//! throughput on exactly the hardware that has none to spare. Conversion to the device's
//! float format happens once, at the device boundary, in the backend.
//!
//! **Sources are immutable and registered while stopped.** A pointer handed to the audio
//! thread must outlive every voice that references it, and §11's content pipeline is
//! content-addressed precisely so streaming can swap assets without a live pointer moving
//! underneath a consumer. Streaming is not built; this is the honest subset it needs.

const std = @import("std");
const audio_ring = @import("ring.zig");

pub const Command = audio_ring.Command;

/// Voices are a fixed array, not a list. §18.8 forbids frame-loop allocation and the audio
/// thread is stricter still: `render` may not allocate at all, so the ceiling is static.
pub const max_voices: usize = 64;

/// Immutable mono PCM, owned by whoever registered it.
pub const Source = struct {
    /// Signed 16-bit mono. Mono because spatialization needs a point source; a stereo
    /// asset that is already panned cannot be placed.
    samples: []const i16,
    /// Whether the voice restarts at the end instead of stopping.
    looping: bool = false,
};

const Voice = struct {
    active: bool = false,
    /// Which `Command.play` started this voice, for `stop`/`set_gain` to address.
    id: u16 = 0,
    source: u32 = 0,
    cursor: usize = 0,
    /// As the command delivered it, kept so a later `set_position` can recombine.
    gain: u16 = 0,
    /// Pan derived from x at `set_position`. Recomputed on the command, not per sample,
    /// because per-sample trigonometry is exactly the unbounded work this thread cannot do.
    pan_l: u32 = one,
    pan_r: u32 = one,
    /// **Gain and pan folded into a single per-channel multiplier.**
    ///
    /// Not an optimization — a correctness fix the tests caught. Applying gain and pan as
    /// two separate `>> 16` stages truncates twice, so a voice at unity gain and dead
    /// centre rendered a 1000-sample as 998. One LSB per stage is inaudible in isolation
    /// and is exactly the kind of loss that compounds silently as a chain grows. Folding
    /// them makes the count of shifts independent of how many parameters exist, and costs
    /// one multiply per sample instead of two.
    scale_l: u32 = one,
    scale_r: u32 = one,
    spatialized: bool = false,

    fn refresh(self: *Voice) void {
        const g = gainScale(self.gain);
        self.scale_l = @intCast((@as(u64, g) * self.pan_l) >> 16);
        self.scale_r = @intCast((@as(u64, g) * self.pan_r) >> 16);
    }
};

/// Unity as the command carries it: `u16`, so the largest representable gain is 0xFFFF.
pub const unity: u16 = 0xFFFF;

/// Unity as the mixer holds it: Q16 with 1.0 == 65536, which does not fit a u16 and is why
/// the command and the internal representation differ. Converting once at command time
/// makes unity gain *exactly* unity rather than 65535/65536, so silence-to-full-scale
/// round-trips without loss.
const one: u32 = 1 << 16;

fn gainScale(g: u16) u32 {
    // Rounded rather than truncated so `unity` maps to exactly `one`.
    return @intCast((@as(u64, g) * one + (unity / 2)) / unity);
}

/// Constant-power pan table, quarter-sine over 33 steps, in the same Q16 as `one`.
///
/// Comptime float producing an integer table: the *runtime* is integer-only, and a table
/// baked into the binary is integer data. Constant-power rather than linear because linear
/// panning dips ~3 dB at centre, which is audible as a hole when a source crosses in front.
const pan_steps = 32;
const pan_table: [pan_steps + 1]u32 = blk: {
    var t: [pan_steps + 1]u32 = undefined;
    for (&t, 0..) |*v, i| {
        const theta = (@as(f64, @floatFromInt(i)) / pan_steps) * (std.math.pi / 2.0);
        v.* = @intFromFloat(@round(@sin(theta) * @as(f64, one)));
    }
    break :blk t;
};

/// Why a voice was not started. Counted rather than logged: the audio thread cannot format
/// a string, and "the sound did not play" needs a cause when it is reported from a device.
pub const Stats = struct {
    /// Commands consumed this block.
    commands: u64 = 0,
    /// `play` with no free voice slot. Distinct from a ring drop, which happened earlier
    /// and for a different reason.
    voices_exhausted: u64 = 0,
    /// `play` naming a source that was never registered.
    unknown_source: u64 = 0,
    /// `stop`/`set_gain`/`set_position` for a voice that already ended. Expected and
    /// harmless — a one-shot finishing before the game notices is normal — but a large
    /// count means the game thread believes it has voices it does not.
    stale_voice: u64 = 0,
    /// Samples that saturated at the i16 rail. Nonzero means the mix is too hot; this is
    /// the number that explains distortion nobody can otherwise account for.
    clipped: u64 = 0,
    /// Voices that ended on their own.
    completed: u64 = 0,
};

pub const Mixer = struct {
    voices: [max_voices]Voice = @splat(.{}),
    /// Indexed by `Command.play.asset`. A flat array rather than a map because a hash
    /// lookup on the audio thread is unbounded work, and §11's ids are dense by design.
    sources: []const ?Source = &.{},
    /// §17: "governors must be aware of each other." The render governor freeing headroom
    /// is pointless if spatialization immediately consumes it, so the budget is told to
    /// this thread rather than inferred here.
    spatial_budget: u8 = max_voices,
    stats: Stats = .{},

    pub const empty: Mixer = .{};

    /// Register the source table. **Not callable while the device is running** — the audio
    /// thread dereferences these slices without synchronization, by design.
    pub fn setSources(self: *Mixer, sources: []const ?Source) void {
        self.sources = sources;
    }

    fn find(self: *Mixer, id: u16) ?*Voice {
        for (&self.voices) |*v| {
            if (v.active and v.id == id) return v;
        }
        return null;
    }

    fn spatialCount(self: *const Mixer) u8 {
        var n: u8 = 0;
        for (&self.voices) |v| {
            if (v.active and v.spatialized) n += 1;
        }
        return n;
    }

    fn apply(self: *Mixer, cmd: Command) void {
        self.stats.commands += 1;
        switch (cmd) {
            .play => |p| {
                if (p.asset >= self.sources.len or self.sources[p.asset] == null) {
                    self.stats.unknown_source += 1;
                    return;
                }
                // Restarting an existing voice id rather than stacking a second one:
                // "play voice 7" twice means voice 7 plays, not that two voices share an
                // id and `stop` reaches an arbitrary one of them.
                const slot = self.find(p.voice) orelse for (&self.voices) |*v| {
                    if (!v.active) break v;
                } else {
                    self.stats.voices_exhausted += 1;
                    return;
                };
                slot.* = .{
                    .active = true,
                    .id = p.voice,
                    .source = p.asset,
                    .cursor = 0,
                    .gain = p.gain_q16,
                };
                slot.refresh();
            },
            .stop => |s| {
                const v = self.find(s.voice) orelse {
                    self.stats.stale_voice += 1;
                    return;
                };
                v.active = false;
            },
            .set_gain => |g| {
                const v = self.find(g.voice) orelse {
                    self.stats.stale_voice += 1;
                    return;
                };
                v.gain = g.gain_q16;
                v.refresh();
            },
            .set_position => |p| {
                const v = self.find(p.voice) orelse {
                    self.stats.stale_voice += 1;
                    return;
                };
                // Over budget: the voice still plays, centred. Dropping it instead would
                // make a governor decision audible as silence, and §17's degradation
                // ladder spends quality before it spends content.
                if (!v.spatialized and self.spatialCount() >= self.spatial_budget) {
                    v.pan_l = one;
                    v.pan_r = one;
                    v.refresh();
                    return;
                }
                v.spatialized = true;
                pan(v, p.x);
                v.refresh();
            },
            .set_voice_budget => |b| self.spatial_budget = b.spatialized,
        }
    }

    /// Drain the ring and render `out` (interleaved stereo, i16).
    ///
    /// Commands are applied *before* the block rather than sample-accurately within it.
    /// Sample-accurate scheduling needs a timestamp on the command and a sorted queue; at
    /// a 128-sample quantum the error is under 2.67 ms, which is below the threshold where
    /// it is audible as anything but latency. Stated because it is a real limitation and
    /// the fix is a wire change, not a mixer change.
    pub fn render(self: *Mixer, ring: anytype, out: []i16) void {
        std.debug.assert(out.len % 2 == 0);
        while (ring.pop()) |cmd| self.apply(cmd);
        self.renderOnly(out);
    }

    /// The rendering half, without the ring. Separated so tests can drive a deterministic
    /// command sequence, and so a backend that has already drained can reuse it.
    pub fn renderOnly(self: *Mixer, out: []i16) void {
        @memset(out, 0);
        const frames = out.len / 2;

        for (&self.voices) |*v| {
            if (!v.active) continue;
            const src = self.sources[v.source].?;

            var i: usize = 0;
            while (i < frames) : (i += 1) {
                if (v.cursor >= src.samples.len) {
                    if (!src.looping) {
                        v.active = false;
                        self.stats.completed += 1;
                        break;
                    }
                    v.cursor = 0;
                    // A zero-length looping source would spin forever otherwise, and an
                    // infinite loop on the audio thread is not a glitch, it is a hang.
                    if (src.samples.len == 0) {
                        v.active = false;
                        self.stats.completed += 1;
                        break;
                    }
                }
                const s: i64 = src.samples[v.cursor];
                v.cursor += 1;

                // i64 for the scaling multiply, i32 for the accumulator.
                //
                // The multiply needs 64 bits: -32768 * 65536 is exactly i32's minimum, so
                // an i32 product is correct today with a margin of zero and breaks
                // silently the moment `one` or the sample width changes. On 32-bit ARM
                // this is one widening multiply (`smull`), not a library call.
                //
                // The accumulator is i32 because the sum of `max_voices` full-scale
                // samples is 64 * 32767 = 2_097_088, comfortably inside it.
                const l: i32 = @intCast((s * v.scale_l) >> 16);
                const r: i32 = @intCast((s * v.scale_r) >> 16);
                out[i * 2] = clamp(@as(i32, out[i * 2]) + l, &self.stats);
                out[i * 2 + 1] = clamp(@as(i32, out[i * 2 + 1]) + r, &self.stats);
            }
        }
    }

    pub fn activeVoices(self: *const Mixer) u32 {
        var n: u32 = 0;
        for (&self.voices) |v| {
            if (v.active) n += 1;
        }
        return n;
    }
};

fn clamp(v: i32, stats: *Stats) i16 {
    if (v > std.math.maxInt(i16)) {
        stats.clipped += 1;
        return std.math.maxInt(i16);
    }
    if (v < std.math.minInt(i16)) {
        stats.clipped += 1;
        return std.math.minInt(i16);
    }
    return @intCast(v);
}

/// Pan from a fixed-point x, hard left at -1.0 and hard right at +1.0 in Q16.24.
///
/// Clamped rather than wrapped: a source 40 metres to the left is fully left, and a
/// wrapping pan would put it hard *right*, which is the kind of bug that survives review
/// because it only shows up beyond the play area.
fn pan(v: *Voice, x: i32) void {
    const full: i64 = 1 << 24;
    const clamped: i64 = std.math.clamp(@as(i64, x), -full, full);
    // Map [-full, full] to [0, pan_steps].
    const idx: usize = @intCast(@divTrunc((clamped + full) * pan_steps, 2 * full));
    v.pan_r = pan_table[idx];
    v.pan_l = pan_table[pan_steps - idx];
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const Ring = audio_ring.Ring;

fn constantSource(comptime n: usize, value: i16) [n]i16 {
    return @splat(value);
}

test "an empty mixer renders silence, not garbage" {
    var m: Mixer = .empty;
    var out: [64]i16 = @splat(0x7FFF);
    m.renderOnly(&out);
    for (out) |s| try testing.expectEqual(@as(i16, 0), s);
}

test "render allocates nothing and drains the ring" {
    const samples = constantSource(16, 1000);
    var sources = [_]?Source{.{ .samples = &samples }};

    var m: Mixer = .empty;
    m.setSources(&sources);

    var ring: Ring(16) = .empty;
    _ = ring.send(.{ .play = .{ .voice = 1, .asset = 0, .gain_q16 = unity } });

    var out: [8]i16 = undefined;
    m.render(&ring, &out);

    try testing.expect(ring.isEmpty());
    try testing.expectEqual(@as(u32, 1), m.activeVoices());
    // **Exactly** unity, not 65535/65536 of it. This is the assertion that caught the
    // double-truncation: with gain and pan applied as separate `>> 16` stages a centred
    // voice at unity rendered 998, and one LSB per stage is precisely the loss that
    // compounds unnoticed as the chain grows.
    try testing.expectEqual(@as(i16, 1000), out[0]);
    try testing.expectEqual(@as(i16, 1000), out[1]);
}

test "a one-shot ends on its own and frees the slot" {
    const samples = constantSource(4, 500);
    var sources = [_]?Source{.{ .samples = &samples }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    m.apply(.{ .play = .{ .voice = 1, .asset = 0, .gain_q16 = unity } });
    var out: [16]i16 = undefined; // 8 frames, source is 4
    m.renderOnly(&out);

    try testing.expectEqual(@as(u32, 0), m.activeVoices());
    try testing.expectEqual(@as(u64, 1), m.stats.completed);
    // Rendered for four frames, silent after.
    try testing.expect(out[6] != 0);
    try testing.expectEqual(@as(i16, 0), out[8]);
}

test "a looping source wraps instead of ending" {
    const samples = constantSource(4, 500);
    var sources = [_]?Source{.{ .samples = &samples, .looping = true }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    m.apply(.{ .play = .{ .voice = 1, .asset = 0, .gain_q16 = unity } });
    var out: [32]i16 = undefined;
    m.renderOnly(&out);

    try testing.expectEqual(@as(u32, 1), m.activeVoices());
    for (out) |s| try testing.expect(s != 0);
}

test "a zero-length looping source does not hang the audio thread" {
    // An infinite loop here is not a glitch, it is a hang on a thread the OS will kill the
    // process over. The wrap path has to check the length it just wrapped to.
    const empty_samples: [0]i16 = .{};
    var sources = [_]?Source{.{ .samples = &empty_samples, .looping = true }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    m.apply(.{ .play = .{ .voice = 1, .asset = 0, .gain_q16 = unity } });
    var out: [8]i16 = undefined;
    m.renderOnly(&out); // must return
    try testing.expectEqual(@as(u32, 0), m.activeVoices());
}

test "playing an unregistered source is counted, not dereferenced" {
    var m: Mixer = .empty;
    m.setSources(&.{});
    m.apply(.{ .play = .{ .voice = 1, .asset = 7, .gain_q16 = unity } });
    try testing.expectEqual(@as(u64, 1), m.stats.unknown_source);
    try testing.expectEqual(@as(u32, 0), m.activeVoices());
}

test "replaying a live voice id restarts it rather than stacking" {
    // "play voice 7" twice must mean voice 7 plays. Two voices sharing an id makes `stop`
    // reach an arbitrary one of them and leaves the other stuck on.
    const samples = constantSource(64, 500);
    var sources = [_]?Source{.{ .samples = &samples }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    m.apply(.{ .play = .{ .voice = 7, .asset = 0, .gain_q16 = unity } });
    var out: [8]i16 = undefined;
    m.renderOnly(&out);
    m.apply(.{ .play = .{ .voice = 7, .asset = 0, .gain_q16 = unity } });

    try testing.expectEqual(@as(u32, 1), m.activeVoices());
    m.apply(.{ .stop = .{ .voice = 7 } });
    try testing.expectEqual(@as(u32, 0), m.activeVoices());
}

test "voice exhaustion is counted and does not overrun the array" {
    const samples = constantSource(1024, 100);
    var sources = [_]?Source{.{ .samples = &samples }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    for (0..max_voices + 8) |i| {
        m.apply(.{ .play = .{ .voice = @intCast(i), .asset = 0, .gain_q16 = unity } });
    }
    try testing.expectEqual(@as(u32, max_voices), m.activeVoices());
    try testing.expectEqual(@as(u64, 8), m.stats.voices_exhausted);
}

test "clipping saturates and is counted" {
    // Nonzero `clipped` is the number that explains distortion nobody can otherwise
    // account for. Wrapping instead would turn a hot mix into full-scale noise.
    const loud = constantSource(16, std.math.maxInt(i16));
    var sources = [_]?Source{.{ .samples = &loud }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    for (0..8) |i| m.apply(.{ .play = .{ .voice = @intCast(i), .asset = 0, .gain_q16 = unity } });
    var out: [8]i16 = undefined;
    m.renderOnly(&out);

    try testing.expect(m.stats.clipped > 0);
    for (out) |s| try testing.expectEqual(std.math.maxInt(i16), s);
}

test "a full-scale mix of every voice does not wrap the accumulator" {
    // 64 voices at full scale is 2_097_088, inside i32. If this ever moves to more voices
    // or a wider source format the accumulator has to move with it.
    const loud = constantSource(8, std.math.maxInt(i16));
    var sources = [_]?Source{.{ .samples = &loud }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    for (0..max_voices) |i| m.apply(.{ .play = .{ .voice = @intCast(i), .asset = 0, .gain_q16 = unity } });
    var out: [8]i16 = undefined;
    m.renderOnly(&out);
    for (out) |s| try testing.expectEqual(std.math.maxInt(i16), s);
}

test "panning is constant-power and does not dip at centre" {
    // Linear panning loses ~3 dB at centre, audible as a hole when a source crosses in
    // front of the listener.
    var v: Voice = .{};
    pan(&v, 0);
    // sin(45 deg) = 0.7071 -> 46341 in Q16
    try testing.expectApproxEqAbs(@as(f64, 46341), @as(f64, @floatFromInt(v.pan_l)), 2);
    try testing.expectEqual(v.pan_l, v.pan_r);

    const power = (@as(u64, v.pan_l) * v.pan_l + @as(u64, v.pan_r) * v.pan_r) >> 16;
    // Within a quantization step of equal power with a centred source.
    try testing.expect(power > one - 64 and power < one + 64);
}

test "a source far off-axis pans fully, not wrapped to the wrong side" {
    // Wrapping puts a source 40 metres left at hard RIGHT — a bug that survives review
    // because it only appears outside the play area.
    var v: Voice = .{};
    pan(&v, -40 << 24);
    try testing.expectEqual(one, v.pan_l);
    try testing.expectEqual(@as(u32, 0), v.pan_r);

    pan(&v, 40 << 24);
    try testing.expectEqual(@as(u32, 0), v.pan_l);
    try testing.expectEqual(one, v.pan_r);
}

test "the spatial budget is respected and over-budget voices still play" {
    // §17's ladder spends quality before content: over budget, the voice is centred rather
    // than dropped, because a governor decision must not be audible as silence.
    const samples = constantSource(64, 1000);
    var sources = [_]?Source{.{ .samples = &samples }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    m.apply(.{ .set_voice_budget = .{ .spatialized = 2 } });
    for (0..4) |i| {
        m.apply(.{ .play = .{ .voice = @intCast(i), .asset = 0, .gain_q16 = unity } });
        m.apply(.{ .set_position = .{ .voice = @intCast(i), .x = -1 << 24, .y = 0, .z = 0 } });
    }

    try testing.expectEqual(@as(u8, 2), m.spatialCount());
    try testing.expectEqual(@as(u32, 4), m.activeVoices()); // all four audible

    var out: [8]i16 = undefined;
    m.renderOnly(&out);
    for (out) |s| try testing.expect(s != 0);
}

test "commands for an ended voice are counted rather than ignored silently" {
    // Expected and harmless on its own -- a one-shot finishing before the game notices is
    // normal -- but a large count means the game thread believes it has voices it does not.
    var m: Mixer = .empty;
    m.setSources(&.{});
    m.apply(.{ .stop = .{ .voice = 3 } });
    m.apply(.{ .set_gain = .{ .voice = 3, .gain_q16 = 100 } });
    m.apply(.{ .set_position = .{ .voice = 3, .x = 0, .y = 0, .z = 0 } });
    try testing.expectEqual(@as(u64, 3), m.stats.stale_voice);
}

test "gain scales linearly" {
    const samples = constantSource(8, 10000);
    var sources = [_]?Source{.{ .samples = &samples }};
    var m: Mixer = .empty;
    m.setSources(&sources);

    m.apply(.{ .play = .{ .voice = 1, .asset = 0, .gain_q16 = unity / 2 } });
    var out: [4]i16 = undefined;
    m.renderOnly(&out);
    try testing.expectApproxEqAbs(@as(f64, 5000), @as(f64, @floatFromInt(out[0])), 2);
}

test "a long run stays bounded and terminates" {
    // Proxy for the property the device actually needs: `render` returns in bounded time
    // for every command sequence, because a hang here is a hang the OS kills the process
    // over rather than a glitch.
    const samples = constantSource(97, 300); // deliberately not a block multiple
    var sources = [_]?Source{
        .{ .samples = &samples, .looping = true },
        .{ .samples = &samples },
    };
    var m: Mixer = .empty;
    m.setSources(&sources);

    var ring: Ring(64) = .empty;
    var out: [256]i16 = undefined;
    var seed: u32 = 0xBED1A3;

    for (0..2000) |i| {
        seed = seed *% 1664525 +% 1013904223;
        const v: u16 = @intCast((seed >> 8) % max_voices);
        _ = switch ((seed >> 3) % 4) {
            0 => ring.send(.{ .play = .{ .voice = v, .asset = @intCast(i % 2), .gain_q16 = unity } }),
            1 => ring.send(.{ .stop = .{ .voice = v } }),
            2 => ring.send(.{ .set_gain = .{ .voice = v, .gain_q16 = @truncate(seed) } }),
            else => ring.send(.{ .set_position = .{ .voice = v, .x = @bitCast(seed), .y = 0, .z = 0 } }),
        };
        m.render(&ring, &out);
    }
    try testing.expect(m.stats.commands > 1000);
    try testing.expect(m.activeVoices() <= max_voices);
}
