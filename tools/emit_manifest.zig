//! Emits the canonical schema manifest.
//!
//! `docs/SCHEMA_AND_EVOLUTION.md` §9: the manifest is a build output, the registry is
//! the hand-maintained input. This tool is the "generator" in that diagram — a host
//! binary in the build graph, not an external step someone can forget to run against a
//! stale registry, because the declarations and registry are compiled into it.
//!
//! Usage:  emit_manifest <output-path>
//!         emit_manifest --print

const std = @import("std");
const bedlam_schema = @import("bedlam_schema");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);

    const m = bedlam_schema.manifest.manifest;
    // Layout is per-target and must not affect the output. Passing the desktop layout
    // is arbitrary on purpose: any value must produce the same fingerprint (§10 check 5).
    const text = try bedlam_schema.manifest.render(gpa, m, bedlam_schema.wire.Layout.desktop);
    const fp = try bedlam_schema.manifest.fingerprint(gpa, m, bedlam_schema.wire.Layout.desktop);

    const io = init.io;

    if (args.len < 2 or std.mem.eql(u8, args[1], "--print")) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.File.Writer = .init(.stdout(), io, &buf);
        try w.interface.writeAll(text);
        try w.interface.flush();
        return;
    }

    // The output path is supplied by the build graph (`addOutputFileArg`), so the
    // directory already exists and the manifest is a cacheable build artifact rather
    // than something written beside the source tree.
    const file = try std.Io.Dir.cwd().createFile(io, args[1], .{});
    defer file.close(io);
    try file.writeStreamingAll(io, text);

    std.log.info("manifest: {d} components, {d} events, {d} rpcs, {d} tombstones", .{
        m.components.len, m.events.len, m.rpcs.len, m.tombstones.len,
    });
    std.log.info("fingerprint: {s}", .{&fp});
}
