//! Deterministic package builder. `AGENTS.md` §4, M0 criterion 10 (partially).
//!
//! Produces a `.tar` containing the binary, the schema manifest, and a build descriptor,
//! **byte-identical for the same inputs**. Reproducibility is the property worth building
//! around, and it is not decoration:
//!
//!   - `SCHEMA_AND_EVOLUTION.md` §10 check 4 already requires the manifest to be
//!     byte-identical across two runs. A package that embeds a timestamp throws that away
//!     at the last step.
//!   - §14.3's replay validation identifies a build by its schema fingerprint. If two
//!     builds of one commit differ, "which build produced this replay" stops having an
//!     answer.
//!   - A package that differs run to run cannot be diffed, so "did this release change"
//!     becomes a question nobody can answer cheaply.
//!
//! So: fixed mtimes, fixed uid/gid, fixed permissions, entries in sorted order. Nothing
//! here reads the clock.
//!
//! **The archive layer is deterministic and that is the part this file is responsible for.**
//! Whether the BINARY going into it is reproducible is a separate, upstream question, and
//! the answer is not uniform: Windows PE reproduces in every mode measured, Linux ELF
//! reproduces under WSL2 and does not on a hosted `ubuntu-latest` runner. So the honest
//! scope of the claim here is the archive, which is unit-tested, plus whatever the
//! toolchain gives on a given host. `docs/UPSTREAM_FINDINGS.md` §6 has the measurements and
//! the three over-claims made along the way.
//!
//! `scripts/reproducible.ps1` is the gate. It builds twice from a CLEARED cache — reusing
//! it would prove only that Zig cached the artifact — and varies the optimize mode as a
//! control, so a packager that ignored its inputs cannot pass.
//!
//! ## What this is not
//!
//! **Not signed, and not an installer.** Criterion 10 is "package, sign, install, launch".
//! This is the first quarter. Signing needs a code-signing certificate on Windows and a
//! Developer ID on macOS — credentials, not code — and inventing a placeholder would make
//! the criterion look closer than it is. The remaining three are named in `AGENTS.md` §4
//! rather than approximated here.

const std = @import("std");

/// USTAR, not PAX or GNU. The oldest and most widely readable format, and every field it
/// needs is fixed-width — which is what makes byte-identical output easy to guarantee
/// rather than merely likely.
const block_size = 512;

const Header = extern struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8,
    mtime: [12]u8,
    checksum: [8]u8,
    typeflag: u8,
    linkname: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
    pad: [12]u8,

    comptime {
        std.debug.assert(@sizeOf(Header) == block_size);
    }
};

fn octal(buf: []u8, value: u64) void {
    @memset(buf, '0');
    buf[buf.len - 1] = 0;
    var v = value;
    var i = buf.len - 1;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 8));
        v /= 8;
        if (v == 0) break;
    }
}

/// Every value that could vary between two runs of the same inputs, pinned.
///
/// The epoch mtime is the important one. A real timestamp is the single most common reason
/// a build is not reproducible, and it buys nothing: the build descriptor inside the
/// archive records what this package *is*, and that is the fact anyone actually wants.
const fixed_mode = 0o644;
const fixed_exec_mode = 0o755;
const fixed_uid = 0;
const fixed_gid = 0;
const fixed_mtime = 0;

fn writeEntry(w: *std.Io.Writer, name: []const u8, data: []const u8, executable: bool) !void {
    if (name.len >= 100) return error.NameTooLong;

    var h: Header = std.mem.zeroes(Header);
    @memcpy(h.name[0..name.len], name);
    octal(&h.mode, if (executable) fixed_exec_mode else fixed_mode);
    octal(&h.uid, fixed_uid);
    octal(&h.gid, fixed_gid);
    octal(&h.size, data.len);
    octal(&h.mtime, fixed_mtime);
    h.typeflag = '0';
    @memcpy(h.magic[0..6], "ustar\x00");
    @memcpy(h.version[0..2], "00");
    // uname/gname left empty rather than filled from the environment, which is exactly
    // the kind of thing that makes a package differ between two developers' machines.

    // Checksum is computed with the checksum field read as spaces, then written as octal
    // followed by NUL and space. That last detail is the one every hand-rolled tar gets
    // wrong, and the failure is an archive some tools accept and others reject.
    @memset(&h.checksum, ' ');
    var sum: u64 = 0;
    for (std.mem.asBytes(&h)) |b| sum += b;
    octal(h.checksum[0..7], sum);
    h.checksum[6] = 0;
    h.checksum[7] = ' ';

    try w.writeAll(std.mem.asBytes(&h));
    try w.writeAll(data);

    const rem = data.len % block_size;
    if (rem != 0) {
        var pad: [block_size]u8 = @splat(0);
        try w.writeAll(pad[0 .. block_size - rem]);
    }
}

pub const Entry = struct {
    name: []const u8,
    data: []const u8,
    executable: bool = false,
};

/// Write a complete archive. Entries are sorted by name first, so the caller's argument
/// order cannot leak into the bytes.
pub fn writeArchive(gpa: std.mem.Allocator, entries: []Entry, w: *std.Io.Writer) !void {
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    _ = gpa;

    for (entries) |e| try writeEntry(w, e.name, e.data, e.executable);

    // Two zero blocks terminate a tar. Some readers accept one; the format says two, and
    // an archive that only some tools read is worse than one no tool reads.
    var end: [block_size * 2]u8 = @splat(0);
    try w.writeAll(&end);
}

/// The build descriptor placed inside the package.
///
/// This is what makes the archive self-describing, and it is the reason a timestamp in the
/// tar header buys nothing: the facts anyone wants — which schema, which target, which
/// version — are recorded here as content, where they are diffable and where they cannot
/// vary between two builds of the same commit.
pub fn buildDescriptor(
    gpa: std.mem.Allocator,
    version: []const u8,
    target: []const u8,
    fingerprint: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\bedlam-package 1
        \\version      {s}
        \\target       {s}
        \\schema       {s}
        \\signed       no (M0 criterion 10 is package/sign/install/launch; this is package)
        \\
    , .{ version, target, fingerprint });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn archiveToOwned(gpa: std.mem.Allocator, entries: []Entry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer aw.deinit();
    try writeArchive(gpa, entries, &aw.writer);
    return aw.toOwnedSlice();
}

test "two archives of the same inputs are byte-identical" {
    // The property the whole file exists for. A package that differs run to run cannot be
    // diffed, so "did this release change" stops having a cheap answer -- and §14.3
    // identifies a build by its schema fingerprint, which requires one build per commit.
    const gpa = testing.allocator;
    var e1 = [_]Entry{
        .{ .name = "bedlam", .data = "binary bytes", .executable = true },
        .{ .name = "schema/manifest.txt", .data = "component ..." },
    };
    var e2 = [_]Entry{
        .{ .name = "bedlam", .data = "binary bytes", .executable = true },
        .{ .name = "schema/manifest.txt", .data = "component ..." },
    };

    const a = try archiveToOwned(gpa, &e1);
    defer gpa.free(a);
    const b = try archiveToOwned(gpa, &e2);
    defer gpa.free(b);

    try testing.expectEqualSlices(u8, a, b);
}

test "argument order does not leak into the bytes" {
    // Entries are sorted, so a caller listing them differently produces the same archive.
    // Without this the package depends on the order a build step happened to add files,
    // which is the kind of thing that changes when someone reorders a list for readability.
    const gpa = testing.allocator;
    var forward = [_]Entry{
        .{ .name = "a.txt", .data = "1" },
        .{ .name = "b.txt", .data = "2" },
    };
    var backward = [_]Entry{
        .{ .name = "b.txt", .data = "2" },
        .{ .name = "a.txt", .data = "1" },
    };

    const a = try archiveToOwned(gpa, &forward);
    defer gpa.free(a);
    const b = try archiveToOwned(gpa, &backward);
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "different content produces a different archive" {
    // The inverse, so the equality above is not vacuous: an archive builder that emitted
    // a constant would pass every test written so far.
    const gpa = testing.allocator;
    var e1 = [_]Entry{.{ .name = "a.txt", .data = "one" }};
    var e2 = [_]Entry{.{ .name = "a.txt", .data = "two" }};

    const a = try archiveToOwned(gpa, &e1);
    defer gpa.free(a);
    const b = try archiveToOwned(gpa, &e2);
    defer gpa.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "the archive is a tar that tar itself would accept" {
    // Header layout, magic, and the checksum convention. The checksum is computed with its
    // own field read as spaces and written as six octal digits, NUL, space -- the detail
    // every hand-rolled tar gets wrong, producing an archive some tools accept and others
    // reject.
    const gpa = testing.allocator;
    var e = [_]Entry{.{ .name = "hello.txt", .data = "hi", .executable = false }};
    const out = try archiveToOwned(gpa, &e);
    defer gpa.free(out);

    try testing.expectEqualStrings("hello.txt", out[0..9]);
    try testing.expectEqualStrings("ustar\x00", out[257..263]);
    try testing.expectEqual(@as(u8, '0'), out[156]); // typeflag: regular file

    // Recompute the checksum the way a reader does.
    var hdr: [block_size]u8 = undefined;
    @memcpy(&hdr, out[0..block_size]);
    var stated: u64 = 0;
    for (hdr[148..154]) |c| {
        if (c == 0 or c == ' ') break;
        stated = stated * 8 + (c - '0');
    }
    @memset(hdr[148..156], ' ');
    var actual: u64 = 0;
    for (hdr) |b| actual += b;
    try testing.expectEqual(actual, stated);

    // Content follows the header, padded to a block, then two zero blocks.
    try testing.expectEqualStrings("hi", out[block_size .. block_size + 2]);
    try testing.expectEqual(@as(usize, block_size * 4), out.len);
}

test "an executable entry is marked executable" {
    // A package whose binary is not executable is one that cannot launch, which is the
    // criterion this is a quarter of.
    const gpa = testing.allocator;
    var e = [_]Entry{.{ .name = "bin", .data = "x", .executable = true }};
    const out = try archiveToOwned(gpa, &e);
    defer gpa.free(out);
    try testing.expectEqualStrings("0000755", out[100..107]);
}

test "the descriptor names the schema and says it is unsigned" {
    // Stated in the artifact, not only in a document. A package that does not say it is
    // unsigned is one somebody eventually assumes is signed.
    const gpa = testing.allocator;
    const d = try buildDescriptor(gpa, "0.0.0-M0", "x86_64-windows", "ca80a08a");
    defer gpa.free(d);

    try testing.expect(std.mem.indexOf(u8, d, "0.0.0-M0") != null);
    try testing.expect(std.mem.indexOf(u8, d, "x86_64-windows") != null);
    try testing.expect(std.mem.indexOf(u8, d, "ca80a08a") != null);
    try testing.expect(std.mem.indexOf(u8, d, "signed       no") != null);
}

test "the packaged version matches the engine's" {
    // build.zig names the version for the archive filename and the descriptor; the engine
    // names it for its banner and the crash report's build id. Two copies is how a package
    // ends up labelled with a version the binary inside it disagrees on, and the mismatch
    // surfaces to whoever is trying to reproduce a bug from a release.
    //
    // Compared at test time rather than enforced in the build graph, because the failure
    // then names both values instead of being a compile error about a marker string.
    const build_options = @import("build_options");
    const engine = @import("bedlam_engine");
    try testing.expectEqualStrings(engine.version, build_options.engine_version);
}

test "a name too long for USTAR is refused rather than truncated" {
    // Truncation would produce an archive that extracts to the wrong path -- silently, and
    // only for deeply nested files.
    const gpa = testing.allocator;
    const long = "a" ** 120;
    var e = [_]Entry{.{ .name = long, .data = "x" }};
    try testing.expectError(error.NameTooLong, archiveToOwned(gpa, &e));
}
