//! Filesystem and asset read. `AGENTS.md` §4, M0 criterion 5.
//!
//! Portable across every target that has files at all, which is why it lives here rather
//! than behind the per-OS backend split: the differences that matter are *policy*, not
//! syscalls.
//!
//! **Asset bytes are untrusted input.** `ARCHITECTURE.md` §14.2 requires a "bounded
//! reader API — capability-based, length-checked reader for every packet, save, replay,
//! and authoring-transaction parser. No ad-hoc byte walking at any trust boundary."
//! An asset read from disk is on the same side of that boundary as a packet: a cooked
//! bundle can be modified by anyone with the file, and §14.1 is explicit that
//! `ReleaseSafe` plus fuzzing does not prevent "logic bombs, decompression bombs, or
//! parser resource exhaustion".
//!
//! So reads are size-capped before allocation rather than after. A 4 GB asset is refused
//! with the size in the error rather than being loaded and then rejected — on a target
//! with a 1.8 GB linear-memory budget (`CONFORMANCE_PROFILES.md` §2) the load itself is
//! the failure.
//!
//! Not here, deliberately: asset *import*. §14.2 requires importers to run out of process
//! with hard limits and no network access, and §11 makes cooking a service the editor
//! requests. This module reads cooked bytes; it never parses a source format.

const std = @import("std");

pub const Error = error{
    NotFound,
    AccessDenied,
    /// The file exceeds the caller's cap. Carries no allocation — the point is to refuse
    /// before spending the memory.
    TooLarge,
    ReadFailed,
};

/// Default cap for a single asset read.
///
/// 64 MiB is well under the 1.8 GB wasm32 budget and well over any single cooked asset
/// the reference workload implies. A caller streaming a bundle passes its own cap; this
/// is the value that applies when nobody thought about it, which is the case that needs a
/// safe default.
pub const default_max_bytes: usize = 64 * 1024 * 1024;

pub const Stats = struct {
    reads: u64 = 0,
    bytes: u64 = 0,
    refused_too_large: u64 = 0,
    not_found: u64 = 0,
};

/// A rooted, size-capped reader.
///
/// Capability-shaped in the sense §14.2 means: a Reader can only reach what its root
/// contains, so a component handed one cannot read outside it however it is called.
pub const Reader = struct {
    dir: std.Io.Dir,
    io: std.Io,
    max_bytes: usize = default_max_bytes,
    stats: Stats = .{},

    pub fn init(io: std.Io, dir: std.Io.Dir) Reader {
        return .{ .dir = dir, .io = io };
    }

    /// Read a whole asset. Refuses before allocating if it exceeds the cap.
    pub fn read(self: *Reader, gpa: std.mem.Allocator, sub_path: []const u8) (Error || std.mem.Allocator.Error)![]u8 {
        // Rejecting `..` here rather than trusting the caller: a cooked bundle's manifest
        // is data, and a path out of the asset root read from data is a traversal.
        if (containsParentRef(sub_path)) return error.AccessDenied;

        const file = self.dir.openFile(self.io, sub_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    self.stats.not_found += 1;
                    return error.NotFound;
                },
                error.AccessDenied => return error.AccessDenied,
                else => return error.ReadFailed,
            }
        };
        defer file.close(self.io);

        const st = file.stat(self.io) catch return error.ReadFailed;
        const size = st.size;
        if (size > self.max_bytes) {
            self.stats.refused_too_large += 1;
            return error.TooLarge;
        }

        const buf = try gpa.alloc(u8, @intCast(size));
        errdefer gpa.free(buf);

        const n = file.readPositionalAll(self.io, buf, 0) catch return error.ReadFailed;
        if (n != buf.len) return error.ReadFailed;

        self.stats.reads += 1;
        self.stats.bytes += n;
        return buf;
    }

    pub fn exists(self: *Reader, sub_path: []const u8) bool {
        if (containsParentRef(sub_path)) return false;
        const file = self.dir.openFile(self.io, sub_path, .{}) catch return false;
        file.close(self.io);
        return true;
    }
};

/// Whether a path contains a `..` component.
///
/// Textual rather than canonicalizing, and that is the conservative direction: it refuses
/// some paths that would have been safe, and never admits one that would not. Both
/// separators are checked because a cooked bundle authored on Windows can be read on
/// Linux, where `\` is an ordinary filename character and a naive split would miss it.
pub fn containsParentRef(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------

test "parent references are rejected on both separators" {
    // A cooked bundle authored on Windows is read on Linux, where a backslash is an
    // ordinary filename character — so splitting on the host separator alone misses it.
    try std.testing.expect(containsParentRef("../secrets"));
    try std.testing.expect(containsParentRef("a/../b"));
    try std.testing.expect(containsParentRef("a\\..\\b"));
    try std.testing.expect(containsParentRef(".."));

    // And does not reject names that merely contain dots.
    try std.testing.expect(!containsParentRef("a/b.c"));
    try std.testing.expect(!containsParentRef("..a/b"));
    try std.testing.expect(!containsParentRef("a/b.."));
    try std.testing.expect(!containsParentRef("...."));
}

test "the default cap is under the wasm32 budget" {
    // CONFORMANCE_PROFILES.md §2 gives the conformant web profile 1.8 GB of linear
    // memory. A default that could exhaust it is not a default.
    try std.testing.expect(default_max_bytes < 1_800_000_000 / 8);
}

test "stats start at zero so a refusal is distinguishable from no reads" {
    const s: Stats = .{};
    try std.testing.expectEqual(@as(u64, 0), s.reads);
    try std.testing.expectEqual(@as(u64, 0), s.refused_too_large);
}

test "reads a real file off a real filesystem" {
    // M0 criterion 5. Exercised against the actual OS rather than a mock, because the
    // criterion is about the platform and a mock would only test this file.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "cooked bytes, not a source asset";
    const f = try tmp.dir.createFile(std.testing.io, "asset.bin", .{});
    try f.writeStreamingAll(std.testing.io, payload);
    f.close(std.testing.io);

    var r = Reader.init(std.testing.io, tmp.dir);
    const bytes = try r.read(gpa, "asset.bin");
    defer gpa.free(bytes);

    try std.testing.expectEqualStrings(payload, bytes);
    try std.testing.expectEqual(@as(u64, 1), r.stats.reads);
    try std.testing.expectEqual(@as(u64, payload.len), r.stats.bytes);
}

test "an oversized file is refused BEFORE it is allocated" {
    // The property that matters on a 1.8 GB linear-memory budget: loading a 4 GB asset
    // and then rejecting it is the failure, not the detection of it. A failing allocator
    // would be the stronger proof; this at least pins that no allocation happens on the
    // refusal path, since the error is returned before `gpa.alloc`.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(std.testing.io, "big.bin", .{});
    try f.writeStreamingAll(std.testing.io, "0123456789");
    f.close(std.testing.io);

    var r = Reader.init(std.testing.io, tmp.dir);
    r.max_bytes = 4; // smaller than the file

    try std.testing.expectError(error.TooLarge, r.read(gpa, "big.bin"));
    try std.testing.expectEqual(@as(u64, 1), r.stats.refused_too_large);
    try std.testing.expectEqual(@as(u64, 0), r.stats.reads);
}

test "a missing file is NotFound rather than a crash" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = Reader.init(std.testing.io, tmp.dir);
    try std.testing.expectError(error.NotFound, r.read(gpa, "absent.bin"));
    try std.testing.expectEqual(@as(u64, 1), r.stats.not_found);
    try std.testing.expect(!r.exists("absent.bin"));
}

test "traversal out of the asset root is refused, not resolved" {
    // A cooked bundle's manifest is data. A path read from data that escapes the root is
    // a traversal, and the reader is the capability boundary — §14.2.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = Reader.init(std.testing.io, tmp.dir);
    try std.testing.expectError(error.AccessDenied, r.read(gpa, "../escape.bin"));
    try std.testing.expectError(error.AccessDenied, r.read(gpa, "a\\..\\escape.bin"));
    try std.testing.expect(!r.exists("../escape.bin"));
}
