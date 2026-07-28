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

    try out.flush();
}
