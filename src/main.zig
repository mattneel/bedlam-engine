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
