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

// --- net: the browser as a replication client -------------------------------
//
// **The protocol runs in Zig here, not in JavaScript.** `src/net/session.zig` and
// `src/net/replicate.zig` are compiled into this module, so the browser performs the same
// handshake, the same ack accounting and the same delta application as a native client.
// A JS reimplementation would be a second implementation of the one thing §7 says must not
// vary, and the first divergence would present as a desync nobody could localise.
//
// JavaScript owns exactly one thing: moving bytes over the WebSocket. It writes into
// `net_in`, calls `bedlamNetFeed`, and sends whatever `bedlamNetOut` reports.

var client_session: ?bedlam.net.session.Session = null;
var replica: ?step.Sim = null;

var net_in: [bedlam.net.session.max_datagram]u8 = undefined;
var net_out: [bedlam.net.session.max_datagram]u8 = undefined;
var net_out_len: u32 = 0;
var net_payload: [bedlam.net.session.max_datagram]u8 = undefined;

var net_applied: u32 = 0;
var net_frames: u32 = 0;

export fn bedlamNetInBuf() u32 {
    return @intFromPtr(&net_in);
}
export fn bedlamNetOut() u32 {
    return @intFromPtr(&net_out);
}
export fn bedlamNetOutLen() u32 {
    return net_out_len;
}
export fn bedlamNetFramesApplied() u32 {
    return net_applied;
}
export fn bedlamNetEntities() u32 {
    const r = replica orelse return 0;
    return r.liveCount();
}

/// 0 closed · 1 handshaking · 2 validating · 3 established · 4 ended
export fn bedlamNetState() u32 {
    const c = client_session orelse return 0;
    return switch (c.state) {
        .closed => 0,
        .handshaking => 1,
        .validating => 2,
        .established => 3,
        .ended => 4,
    };
}

/// Start a session and emit the opening hello.
///
/// The fingerprint is this module's own, so a page served beside a stale wasm is refused at
/// the handshake rather than decoding snapshots under a layout that does not match them —
/// which is the whole reason `SCHEMA_AND_EVOLUTION.md` §10 puts it in the hello.
export fn bedlamNetConnect() i32 {
    const fp = bedlam.schema.manifest.fingerprint(
        fba.allocator(),
        bedlam.schema.manifest.manifest,
        bedlam.schema.wire.Layout.wasm32,
    ) catch return 1;

    replica = step.Sim.init(fba.allocator(), 4096, step.component_ids) catch return 2;
    // A fixed local id is fine: the CLIENT's id only has to be unique to this connection,
    // and the server's id is the one that must be unguessable.
    client_session = bedlam.net.session.Session.init(0x0C11E27, fp, .{});
    net_out_len = @intCast(client_session.?.clientHello(&net_out, @splat(0)));
    net_applied = 0;
    net_frames = 0;
    return 0;
}

/// Feed `len` bytes that JavaScript has written into `bedlamNetInBuf`.
///
/// Returns 0 on success. Anything queued for sending is left in `bedlamNetOut`.
export fn bedlamNetFeed(len: u32) i32 {
    var c = &(client_session orelse return 1);
    net_out_len = 0;
    const datagram = net_in[0..@min(len, net_in.len)];

    if (!c.isEstablished()) {
        const token = c.clientReceive(datagram) catch return 2;
        if (token) |t| {
            // Address validation: the server demanded a token, so say it back.
            net_out_len = @intCast(c.clientHello(&net_out, t));
        }
        return 0;
    }

    const got = c.receive(datagram, &net_payload) catch return 3;
    switch (got) {
        .data => |payload| {
            var r = bedlam.wire.bits.Reader.init(payload);
            const decl = bedlam.schema.schema.components[0];
            const Cols = step.Columns;
            var ident: bedlam.wire.codec.Storage(decl) = std.mem.zeroes(bedlam.wire.codec.Storage(decl));
            ident.rotation = .{ Fixed.ONE, Fixed.ZERO, Fixed.ZERO, Fixed.ZERO };

            _ = bedlam.net.replicate.apply(
                decl,
                Cols,
                &(replica orelse return 4),
                &r,
                ident,
                std.mem.zeroes(Cols),
            ) catch return 5;
            net_applied += 1;

            // The ack rides on the next packet out, so one is produced immediately. A
            // client that only acks when it happens to send something leaves the server's
            // baseline stalled and every delta full-sized.
            net_out_len = @intCast(c.writePing(&net_out) catch 0);
        },
        .ping => net_out_len = @intCast(c.writePing(&net_out) catch 0),
        .bye => {},
        .discarded => {},
    }
    net_frames += 1;
    return 0;
}

/// Replica entity positions, same layout as `bedlamPositions`.
export fn bedlamNetPositions() u32 {
    const r = &(replica orelse return 0);
    var n: usize = 0;
    var it = r.table.chunkIterator();
    outer: while (it.next()) |c| {
        for (c.liveEntities()) |e| {
            if (n + 4 > position_buf.len) break :outer;
            const p = r.table.get(e, "position").?;
            position_buf[n + 0] = @truncate(p[0].raw);
            position_buf[n + 1] = @truncate(p[0].raw >> 32);
            position_buf[n + 2] = @truncate(p[1].raw);
            position_buf[n + 3] = @truncate(p[1].raw >> 32);
            n += 4;
        }
    }
    return @intFromPtr(&position_buf);
}

export fn bedlamNetPositionWords() u32 {
    const r = replica orelse return 0;
    return @min(r.liveCount() * 4, position_buf.len);
}

// --- audio: the AudioWorklet side of M0 criterion 3 -------------------------
//
// The mixer is engine code (`src/audio/`), so the browser runs the SAME mixer as the
// Windows and Linux devices rather than a JavaScript reimplementation. That is the whole
// point: §17's degradation ladder, voice budget, panning and clipping behaviour are one
// implementation, verified on s390x and mips, not four that drift.
//
// The Worklet is the device. It owns the deadline — 128 frames, 2.67 ms at 48 kHz — and it
// converts to the float format the Web Audio graph wants at the boundary, exactly where
// WASAPI and PulseAudio convert to theirs.

var audio_mixer: bedlam.audio.mixer.Mixer = .empty;
var audio_ring: bedlam.audio.ring.Ring(256) = .empty;

/// One cycle of 480 Hz at 48 kHz is exactly 100 samples, so a looping source of that
/// length is continuous at the wrap. A period that does not divide evenly clicks once per
/// loop, which is audible and reads as a mixer bug.
var tone: [100]i16 = undefined;
var audio_sources: [1]?bedlam.audio.mixer.Source = .{null};

/// Interleaved stereo, sized for the largest quantum a caller should ask for. Allocated
/// statically because §18.8 forbids frame-loop allocation and an audio callback is
/// stricter still.
var audio_out: [2048]i16 = undefined;

export fn bedlamAudioInit() i32 {
    // Integer-only construction of the table, so nothing here depends on the browser's
    // float behaviour. A sine built at runtime in JS would be a second implementation of
    // the one thing that must not vary.
    for (&tone, 0..) |*sample, i| {
        const theta = (@as(f64, @floatFromInt(i)) / tone.len) * 2.0 * std.math.pi;
        sample.* = @intFromFloat(@round(@sin(theta) * 8000.0));
    }
    audio_sources[0] = .{ .samples = &tone, .looping = true };
    audio_mixer = .empty;
    audio_mixer.setSources(&audio_sources);
    audio_ring = .empty;
    return 0;
}

export fn bedlamAudioPlay(voice: u32, gain: u32) i32 {
    return if (audio_ring.send(.{ .play = .{
        .voice = @truncate(voice),
        .asset = 0,
        .gain_q16 = @truncate(gain),
    } })) 0 else 1;
}

export fn bedlamAudioPan(voice: u32, x_q24: i32) i32 {
    return if (audio_ring.send(.{ .set_position = .{
        .voice = @truncate(voice),
        .x = x_q24,
        .y = 0,
        .z = 0,
    } })) 0 else 1;
}

/// Render `frames` stereo frames and return a pointer to interleaved i16.
///
/// The caller converts to float. Doing it here would put a float conversion inside the
/// engine for no benefit — §7 keeps the runtime integer, and the Web Audio graph is the
/// only consumer that wants floats.
export fn bedlamAudioRender(frames: u32) u32 {
    const samples = @min(frames * 2, audio_out.len);
    if (samples == 0) return 0;
    audio_mixer.render(&audio_ring, audio_out[0..samples]);
    return @intFromPtr(&audio_out);
}

export fn bedlamAudioClipped() u32 {
    return @truncate(audio_mixer.stats.clipped);
}

export fn bedlamAudioVoices() u32 {
    return audio_mixer.activeVoices();
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
