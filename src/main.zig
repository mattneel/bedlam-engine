//! Desktop and headless entry point.
//!
//! Not the Web entry (`src/web.zig` — the browser owns the entry point) and not the iOS
//! entry (an Xcode app target owns that). See `build.zig`.
//!
//! M0 placeholder: reports what this binary actually is. It exists so the artifact is a
//! real program rather than scaffolding, and so `zig build run` says something true.

const std = @import("std");
const Io = std.Io;
const bedlam = @import("bedlam_engine");

/// The session's fingerprint field is the 64 hex characters `manifest.fingerprint` already
/// produces. Copied rather than re-derived so the value on the wire is provably the same
/// one this binary reports.
/// Every field of the replicated component. The demo sends full frames rather than acked
/// deltas -- see the steady-state comment in `--net-demo`.
const full_mask_demo: u32 = (1 << 3) - 1;

fn fp64(hex: *const [64]u8) [64]u8 {
    return hex.*;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &stdout.interface;

    const fp = try bedlam.schema.manifest.fingerprint(
        gpa,
        bedlam.schema.manifest.manifest,
        bedlam.schema.wire.Layout.desktop,
    );

    try out.print("bedlam {s}\n", .{bedlam.version});
    try out.print("target       {s}-{s}\n", .{
        @tagName(@import("builtin").cpu.arch),
        @tagName(@import("builtin").os.tag),
    });
    try out.print("schema       {s} ({d} components, {d} events, {d} rpcs)\n", .{
        bedlam.schema.manifest.schema_version,
        bedlam.schema.manifest.manifest.components.len,
        bedlam.schema.manifest.manifest.events.len,
        bedlam.schema.manifest.manifest.rpcs.len,
    });
    try out.print("fingerprint  {s}\n", .{&fp});

    // AGENTS.md §3: "--verify-determinism runs in CI from the first tick loop."
    const args = try init.minimal.args.toSlice(gpa);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--crash-report")) {
            // M0 criterion 9, demonstrated rather than asserted: capture a report from a
            // real stack and render it. The value is the CONTEXT — build, schema, tick,
            // seed — which is what turns a crash into a replay (§5.1) rather than a stack
            // of addresses nobody can re-enter.
            const plat = @import("bedlam_platform");
            plat.crash.Context.setBuildId(bedlam.version ++ "-" ++ @tagName(@import("builtin").cpu.arch));
            plat.crash.Context.setSchemaFingerprint(&fp);
            plat.crash.Context.setTick(41_203);
            plat.crash.Context.setSeed(0xBED1A3);

            const report = plat.crash.capture("demonstration capture, not a real fault");
            var render_buf: [4096]u8 = undefined;
            try out.print("\n{s}", .{plat.crash.render(&report, &render_buf)});
            try out.flush();
            continue;
        }

        if (std.mem.eql(u8, arg, "--window")) {
            // M0 criterion 1, exercised for real: create a surface, pump the OS message
            // loop, and report what came back. AGENTS.md §4 lists this first.
            const plat = @import("bedlam_platform");
            try out.print("\nwindow\n", .{});
            try out.print("  capabilities window={} surface={} lifecycle={} device_loss={}\n", .{
                plat.backend.capabilities.window,
                plat.backend.capabilities.surface,
                plat.backend.capabilities.lifecycle_events,
                plat.backend.capabilities.device_loss_events,
            });

            const title = std.unicode.utf8ToUtf16LeStringLiteral("Bedlam M0");
            var surface: plat.backend.Surface = undefined;
            surface.open(title, .{ .width = 960, .height = 540 }) catch |err| {
                try out.print("  surface unavailable: {t}\n", .{err});
                try out.flush();
                continue;
            };
            defer surface.destroy();
            surface.show();

            // Paced like a frame loop rather than spun.
            //
            // X11 delivers map and configure asynchronously, so a loop faster than the
            // round trip observes zero events and reports a window that never appeared —
            // which is what the first Linux run did. 240 frames at ~60 Hz is four seconds,
            // which is also what a person watching would expect from a window demo.
            var pumps: u32 = 0;
            var events: u32 = 0;
            while (pumps < 240 and !surface.closed) : (pumps += 1) {
                events += @intCast(surface.pump().len);
                plat.backend.sleepMs(16);
            }
            try out.print("  pumps        {d}\n", .{pumps});
            try out.print("  events       {d}\n", .{events});
            try out.print("  size         {d}x{d}\n", .{ surface.size.width, surface.size.height });
            try out.print("  closed       {}\n", .{surface.closed});
            try out.flush();
            continue;
        }

        if (std.mem.eql(u8, arg, "--net-demo")) {
            // M0 criterion 4, demonstrated rather than asserted. §18.20: compiling is not
            // a working target. Two real sockets, two real receiver threads, a real
            // handshake with address validation, and real snapshot bytes over loopback.
            //
            // What this does NOT demonstrate is encryption. §18.13 forbids custom crypto
            // and no vetted stack is wired in, so `Crypto` is null and the server does not
            // set `require_secure`. That is a stated gap, not an oversight — see
            // src/net/session.zig.
            const plat = @import("bedlam_platform");
            const sess = bedlam.net.session;
            try out.print("\nnet-demo\n", .{});

            const Udp = plat.udp_backend orelse {
                try out.print("  no datagram transport for this target\n", .{});
                try out.flush();
                continue;
            };
            const Receiver = Udp.Receiver(256);

            var server_rx = Receiver.init(gpa, io, Udp.Pair.bind(io, 0) catch {
                try out.print("  could not bind server socket\n", .{});
                try out.flush();
                continue;
            });
            try server_rx.start();
            defer server_rx.stop();

            var client_rx = Receiver.init(gpa, io, try Udp.Pair.bind(io, 0));
            try client_rx.start();
            defer client_rx.stop();

            const server_sock = server_rx.pair.ip4 orelse {
                try out.print("  no IPv4 socket bound\n", .{});
                try out.flush();
                continue;
            };
            const server_addr: Udp.Address = .{ .ip4 = .loopback(server_sock.port()) };

            // Connection ids are chosen by each side, not derived. A real server draws
            // these from a CSPRNG — a guessable id lets an off-path attacker inject into
            // a session it cannot observe. Fixed here so the demo output is readable.
            var client = sess.Session.init(0x0C11E27, fp64(&fp), .{});
            var server = sess.Session.init(0x5E4E40D, fp64(&fp), .{});

            const secret: [32]u8 = @splat(0x5A);
            var pkt: [sess.max_datagram]u8 = undefined;
            var out_buf: [sess.max_datagram]u8 = undefined;

            var retries: u32 = 0;
            var client_addr: ?Udp.Address = null;

            // --- handshake, with address validation on ---
            var n = client.clientHello(&pkt, @splat(0));
            _ = client_rx.send(server_addr, pkt[0..n]);

            var spins: u32 = 0;
            while (!client.isEstablished() and spins < 2_000_000) : (spins += 1) {
                if (server_rx.poll()) |d| {
                    client_addr = d.from;
                    var key: [18]u8 = undefined;
                    const token = sess.retryToken(secret, Udp.Socket.peerKey(d.from, &key));

                    const verdict = server.serverEvaluate(d.bytes, token, true) catch continue;
                    switch (verdict) {
                        .retry => |t| {
                            retries += 1;
                            const rn = server.writeRetry(t, &pkt);
                            _ = server_rx.send(d.from, pkt[0..rn]);
                        },
                        .accept => |hello| {
                            const an = server.serverAccept(hello, &pkt);
                            _ = server_rx.send(d.from, pkt[0..an]);
                        },
                        .reject => |r| {
                            const rn = server.writeReject(r, &pkt);
                            _ = server_rx.send(d.from, pkt[0..rn]);
                        },
                    }
                }
                if (client_rx.poll()) |d| {
                    if (client.clientReceive(d.bytes) catch null) |token| {
                        n = client.clientHello(&pkt, token);
                        _ = client_rx.send(server_addr, pkt[0..n]);
                    }
                }
            }

            if (!client.isEstablished()) {
                try out.print("  handshake did not complete\n", .{});
                try out.flush();
                continue;
            }

            // --- steady state: a real simulated world, replicated ---
            //
            // Not dummy payloads. The server steps `sim.step` and sends replication
            // frames; the client applies them into a replica world. The claim at the end
            // is the one that matters: the replica's canonical digest equals that of a
            // reference replica fed the identical frames in-process, so the network path
            // introduces nothing.
            //
            // Full-mask frames rather than acked deltas, deliberately. §12's delta path
            // needs `baseline.acknowledge` driven by the session's ack, and until that is
            // wired a lost packet would leave the replica permanently stale. A full frame
            // is idempotent, so loss costs freshness and never correctness — the honest
            // subset to demonstrate first.
            var world = try bedlam.sim.step.seedWorld(gpa, 0xBED1A3, 64);
            defer world.deinit();
            var replica = try @TypeOf(world).init(gpa, 4096, world.component_ids);
            defer replica.deinit();
            var reference = try @TypeOf(world).init(gpa, 4096, world.component_ids);
            defer reference.deinit();

            const Cols = @TypeOf(world).ColumnSet;
            const decl = bedlam.schema.schema.components[0];
            const defaults: Cols = std.mem.zeroes(Cols);
            // The sim world stores no rotation, so every frame carries the declaration's
            // identity quaternion. Zero is not merely imprecise here — `quantizeQuat`
            // asserts unit norm, and the zero quaternion has norm 0.
            const Decl = bedlam.wire.codec.Storage(decl);
            var ident: Decl = std.mem.zeroes(Decl);
            ident.rotation = .{
                bedlam.fpz.Fixed.ONE,
                bedlam.fpz.Fixed.ZERO,
                bedlam.fpz.Fixed.ZERO,
                bedlam.fpz.Fixed.ZERO,
            };

            // Per-client send state. 16 snapshots in flight is well beyond a loopback
            // round trip; on a real link it must exceed the RTT in ticks or `evicted`
            // climbs and entities are re-sent for no visible reason.
            const Out = bedlam.net.outbound.Outbound(Cols, 16, 128);
            var outbound = try Out.init(gpa);
            defer outbound.deinit();

            var it0 = world.table.chunkIterator();
            while (it0.next()) |c| {
                for (c.liveEntities()) |ent| try outbound.setInterest(ent, true);
            }

            // Which packet sequence carried which snapshot. The session's ack window is in
            // sequence space and the baseline is in snapshot space, so something has to
            // hold the correspondence — this is that, sized to the in-flight ring.
            var seq_of: [16]u32 = @splat(0);
            var snap_live: [16]bool = @splat(false);
            var snap_id: [16]u64 = @splat(0);

            const ticks = 240;
            var frames_sent: u32 = 0;
            var frames_applied: u32 = 0;
            var frame_buf: [sess.max_datagram]u8 = undefined;

            for (0..ticks) |_| {
                bedlam.sim.step.step(&world, 0xBED1A3, &bedlam.sim.step.System.all);
                world.advanceTick();
                replica.advanceTick();
                reference.advanceTick();

                // Assemble a DELTA snapshot. Only entities whose values differ from what
                // this client has acknowledged, ordered by accumulated priority so a
                // budget too small for the world starves nobody.
                var bw = bedlam.wire.bits.Writer.init(&frame_buf);
                var fw = try bedlam.net.replicate.Writer.begin(&bw, world.tick, frames_sent);
                const budget = sess.max_datagram - sess.Header.size - 32;
                const snap = try outbound.assemble(decl, &world, &fw, budget, 1, ident);
                fw.finish();
                const frame = frame_buf[0..bw.bytesWritten()];

                // The reference replica gets the identical bytes with no network involved.
                var ref_reader = bedlam.wire.bits.Reader.init(frame);
                _ = try bedlam.net.replicate.apply(decl, Cols, &reference, &ref_reader, ident, defaults);

                // Record the sequence this snapshot rides on, BEFORE writeData consumes it.
                const seq = server.next_sequence;
                const sn = server.writeData(frame, &pkt) catch continue;
                _ = server_rx.send(client_addr.?, pkt[0..sn]);
                frames_sent += 1;

                const ring: usize = @intCast(snap % 16);
                seq_of[ring] = seq;
                snap_id[ring] = snap;
                snap_live[ring] = true;

                var drained: u32 = 0;
                while (drained < 8) : (drained += 1) {
                    if (client_rx.poll()) |d| {
                        const got = client.receive(d.bytes, &out_buf) catch continue;
                        if (got == .data) {
                            var r = bedlam.wire.bits.Reader.init(got.data);
                            _ = bedlam.net.replicate.apply(decl, Cols, &replica, &r, ident, defaults) catch continue;
                            frames_applied += 1;
                            const cn = client.writePing(&pkt) catch continue;
                            _ = client_rx.send(server_addr, pkt[0..cn]);
                        }
                    } else break;
                }
                while (server_rx.poll()) |d| {
                    _ = server.receive(d.bytes, &out_buf) catch continue;
                }

                // The whole point: the session's ack window says which sequences arrived,
                // and only those snapshots promote the baseline. A snapshot the client
                // never received must NOT advance it, or every later delta is computed
                // against state that exists nowhere.
                for (0..16) |k| {
                    if (!snap_live[k]) continue;
                    if (server.peerAcked(seq_of[k])) {
                        _ = outbound.onAck(snap_id[k]) catch {};
                        snap_live[k] = false;
                    }
                }
            }

            // Drain and settle, so the comparison is of two finished worlds rather than a
            // race. Deltas mean a straggler leaves the replica genuinely behind, which is
            // the honest cost of not sending full state.
            var settle: u32 = 0;
            while (settle < 200_000 and frames_applied < frames_sent) : (settle += 1) {
                if (client_rx.poll()) |d| {
                    const got = client.receive(d.bytes, &out_buf) catch continue;
                    if (got == .data) {
                        var r = bedlam.wire.bits.Reader.init(got.data);
                        _ = bedlam.net.replicate.apply(decl, Cols, &replica, &r, ident, defaults) catch continue;
                        frames_applied += 1;
                    }
                }
            }

            const d_authority = try bedlam.world.hash.hashWorld(gpa, &world);
            const d_replica = try bedlam.world.hash.hashWorld(gpa, &replica);
            const d_reference = try bedlam.world.hash.hashWorld(gpa, &reference);

            // Captured BEFORE the orderly close, because `bye` moves both ends to
            // `ended` and reporting after it would show a session that never established.
            const both_up = client.isEstablished() and server.isEstablished();

            const bn = client.writeBye(&pkt);
            _ = client_rx.send(server_addr, pkt[0..bn]);

            // Let the server observe the close, so the reported end state is the real one.
            var closing: u32 = 0;
            while (closing < 200_000 and server.state != .ended) : (closing += 1) {
                if (server_rx.poll()) |d| _ = server.receive(d.bytes, &out_buf) catch {};
            }

            try out.print("  server       {f}\n", .{server_addr});
            try out.print("  retries      {d}\n", .{retries});
            try out.print("  established  {}\n", .{both_up});
            try out.print("  frames       {d} sent / {d} applied\n", .{ frames_sent, frames_applied });
            try out.print("  entities     {d} / {d}\n", .{ replica.liveCount(), world.liveCount() });
            try out.print("  authority    {s}\n", .{&bedlam.world.hash.hexDigest(d_authority)});
            try out.print("  replica      {s}\n", .{&bedlam.world.hash.hexDigest(d_replica)});
            try out.print("  reference    {s}\n", .{&bedlam.world.hash.hexDigest(d_reference)});
            // The claim: the world that crossed a real socket is byte-identical to the one
            // that did not. The authority differs from both, and must — the wire quantizes.
            try out.print("  over-wire == in-process  {}\n", .{std.mem.eql(u8, &d_replica, &d_reference)});
            try out.print("  quantized (expected)     {}\n", .{!std.mem.eql(u8, &d_authority, &d_replica)});
            try out.print("  snapshots    {d} sent / {d} acked\n", .{
                outbound.stats.snapshots_sent, outbound.stats.snapshots_acked,
            });
            try out.print("  records      {d} sent / {d} deferred\n", .{
                outbound.stats.records_sent, outbound.stats.deferred,
            });
            try out.print("  evicted      {d} (ring smaller than RTT if nonzero)\n", .{outbound.stats.evicted});
            try out.print("  acked        {d}\n", .{server.acked_by_peer});
            try out.print("  duplicates   {d}\n", .{server.duplicates + client.duplicates});
            try out.print("  overruns     {d}\n", .{server_rx.overruns.load(.monotonic) +
                client_rx.overruns.load(.monotonic)});
            try out.print("  closed       {t} / {t}\n", .{ client.state, server.state });
            try out.print("  encrypted    {} (§18.13: no vetted stack wired in yet)\n", .{client.crypto != null});
            try out.flush();
            continue;
        }

        if (std.mem.eql(u8, arg, "--audio")) {
            // M0 criterion 3, demonstrated rather than asserted. §18.20: compiling is not
            // a working target. This opens the real default endpoint, runs the real
            // render thread, and reports what the device actually did — a run that
            // reports zero blocks has a mixer and no audio.
            const plat = @import("bedlam_platform");
            try out.print("\naudio\n", .{});

            const Backend = plat.audio_backend orelse {
                try out.print("  no audio backend for this target\n", .{});
                try out.flush();
                continue;
            };

            // One cycle of 480 Hz at 48 kHz is exactly 100 samples, so a looping source
            // of that length is continuous with no discontinuity at the wrap — a period
            // that does not divide evenly clicks once per loop.
            const cycle = 100;
            var tone: [cycle]i16 = undefined;
            for (&tone, 0..) |*s, i| {
                const theta = (@as(f64, @floatFromInt(i)) / cycle) * 2.0 * std.math.pi;
                s.* = @intFromFloat(@round(@sin(theta) * 8000.0));
            }
            var sources = [_]?plat.mixer.Source{.{ .samples = &tone, .looping = true }};

            var mixer: plat.mixer.Mixer = .empty;
            mixer.setSources(&sources);
            var ring: plat.audio_ring.Ring(256) = .empty;

            var dev = Backend.Device.init(gpa, &mixer, &ring, .{});
            defer dev.deinit();

            dev.start() catch |err| {
                // A machine with no endpoint must still run the game. §17 describes a
                // mixer, not a requirement.
                try out.print("  device unavailable: {t}\n", .{err});
                try out.flush();
                continue;
            };

            _ = ring.send(.{ .play = .{ .voice = 0, .asset = 0, .gain_q16 = plat.mixer.unity } });
            _ = ring.send(.{ .set_position = .{ .voice = 0, .x = -1 << 24, .y = 0, .z = 0 } });

            // Sweep the source left to right so the pan path is exercised audibly rather
            // than only in a unit test.
            var ms: u32 = 0;
            while (ms < 1500) : (ms += 50) {
                const x: i32 = @intCast(@divTrunc((@as(i64, ms) - 750) * (1 << 24), 750));
                _ = ring.send(.{ .set_position = .{ .voice = 0, .x = x, .y = 0, .z = 0 } });
                Backend.sleepMs(50);
            }
            dev.stop();

            try out.print("  blocks       {d}\n", .{dev.telemetry.blocks.load(.monotonic)});
            try out.print("  frames       {d}\n", .{dev.telemetry.frames.load(.monotonic)});
            try out.print("  underruns    {d}\n", .{dev.telemetry.underruns.load(.monotonic)});
            try out.print("  buf errors   {d}\n", .{dev.telemetry.buffer_errors.load(.monotonic)});
            try out.print("  ring drops   {d}\n", .{ring.droppedCount()});
            try out.print("  clipped      {d}\n", .{mixer.stats.clipped});
            try out.print("  commands     {d}\n", .{mixer.stats.commands});
            try out.flush();
            continue;
        }

        if (std.mem.eql(u8, arg, "--world-digest")) {
            // The native side of the wasm32 conformance probe. Same seed, same entity
            // count, same tick count as tools/web — a digest that differs is §7's claim
            // failing on the target where it is hardest.
            var w = try bedlam.sim.step.seedWorld(gpa, 0xBED1A3, 64);
            defer w.deinit();
            for (0..128) |_| bedlam.sim.step.step(&w, 0xBED1A3, &bedlam.sim.step.System.all);

            const d = try bedlam.world.hash.hashWorld(gpa, &w);
            try out.print("\nworld-digest\n", .{});
            try out.print("  ticks        {d}\n", .{w.tick});
            try out.print("  live         {d}\n", .{w.liveCount()});
            try out.print("  digest       {s}\n", .{&bedlam.world.hash.hexDigest(d)});
            continue;
        }

        if (!std.mem.eql(u8, arg, "--verify-determinism")) continue;

        try out.print("\nverify-determinism\n", .{});
        const report = try bedlam.sim.step.verifyDeterminism(gpa, 0xBED1A3, 512, 256);
        try out.print("  ticks        {d}\n", .{report.ticks});
        try out.print("  final        {s}\n", .{&report.final});

        if (report.divergence) |dv| {
            // The FIRST divergent tick. By the last one two diverged worlds differ
            // everywhere and the report is useless for diagnosis.
            try out.print("  DIVERGED at tick {d} ({s})\n", .{ dv.tick, dv.variation });
            try out.print("    expected   {s}\n", .{&dv.expected});
            try out.print("    actual     {s}\n", .{&dv.actual});
            try out.flush();
            return error.DeterminismDivergence;
        }
        try out.print("  OK - identical under every schedule permutation\n", .{});
    }

    try out.flush();
}
