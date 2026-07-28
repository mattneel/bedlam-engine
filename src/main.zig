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

            var pumps: u32 = 0;
            var events: u32 = 0;
            while (pumps < 240 and !surface.closed) : (pumps += 1) {
                events += @intCast(surface.pump().len);
            }
            try out.print("  pumps        {d}\n", .{pumps});
            try out.print("  events       {d}\n", .{events});
            try out.print("  size         {d}x{d}\n", .{ surface.size.width, surface.size.height });
            try out.print("  closed       {}\n", .{surface.closed});
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
