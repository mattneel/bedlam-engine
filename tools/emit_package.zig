//! `zig build package` — assemble a distributable archive. M0 criterion 10, in part.
//!
//! A host tool, like `emit_manifest.zig` and for the same reason: it always runs natively,
//! so nothing about the *building* machine's layout can reach the artifact. The schema
//! fingerprint is computed here rather than read from the packaged binary, which also means
//! a cross-compiled package can be built without running the thing it packages —
//! `SCHEMA_AND_EVOLUTION.md` §10 check 5 makes that sound by requiring the fingerprint to
//! be identical across target layouts.
//!
//! Usage: emit_package <out.tar> <version> <target-triple> <binary> <manifest>

const std = @import("std");
const pkg = @import("package.zig");
const schema = @import("bedlam_schema");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 6) {
        std.debug.print("usage: emit_package <out.tar> <version> <target> <binary> <manifest>\n", .{});
        return error.BadUsage;
    }

    const out_path = args[1];
    const version = args[2];
    const target = args[3];
    const bin_path = args[4];
    const manifest_path = args[5];

    const cwd = std.Io.Dir.cwd();
    const bin = try cwd.readFileAlloc(io, bin_path, gpa, .limited(256 << 20));
    const manifest = try cwd.readFileAlloc(io, manifest_path, gpa, .limited(16 << 20));

    const fp = try schema.manifest.fingerprint(gpa, schema.manifest.manifest, schema.wire.Layout.desktop);
    const descriptor = try pkg.buildDescriptor(gpa, version, target, &fp);

    // The binary keeps its own name inside the archive, and the tree is flat enough that
    // every path fits USTAR's 100 bytes without a prefix record. A deeper layout would
    // need PAX, which is not byte-identical across implementations.
    const bin_name = std.fs.path.basename(bin_path);
    var entries = [_]pkg.Entry{
        .{ .name = bin_name, .data = bin, .executable = true },
        .{ .name = "schema-manifest.txt", .data = manifest },
        .{ .name = "BUILD.txt", .data = descriptor },
    };

    var buf: [64 * 1024]u8 = undefined;
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    var fw = file.writer(io, &buf);
    try pkg.writeArchive(gpa, &entries, &fw.interface);
    try fw.interface.flush();
}
