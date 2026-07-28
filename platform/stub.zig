//! Placeholder backend for targets whose platform layer is not written yet.
//!
//! It reports NO capabilities, which is the point. `iface.Capabilities` defaults every
//! field to false so an unimplemented backend is distinguishable from a working one —
//! otherwise a platform gets reported as conformant on the strength of a stub, which is
//! precisely the accidental-conformance failure `CONFORMANCE_PROFILES.md` §2 warns about.
//!
//! Creating a surface returns `Unsupported` rather than panicking: `AGENTS.md` §4 has ten
//! M0 criteria across six targets, and a half-built matrix must fail informatively.

const std = @import("std");
const iface = @import("iface.zig");

pub const capabilities: iface.Capabilities = .{};

pub const Surface = struct {
    events: iface.EventQueue = .{},
    size: iface.Size,
    closed: bool = false,

    pub fn open(self: *Surface, title: []const u16, size: iface.Size) iface.Error!void {
        _ = self;
        _ = title;
        _ = size;
        return error.Unsupported;
    }
    pub fn destroy(self: *Surface) void {
        self.* = undefined;
    }
    pub fn show(_: *Surface) void {}
    pub fn hide(_: *Surface) void {}
    pub fn pump(self: *Surface) []const iface.Event {
        return self.events.slice();
    }
};

test "a stub claims nothing" {
    try std.testing.expect(!capabilities.window);
    try std.testing.expect(!capabilities.surface);
    const title = std.unicode.utf8ToUtf16LeStringLiteral("x");
    var s: Surface = undefined;
    try std.testing.expectError(
        error.Unsupported,
        s.open(title, .{ .width = 1, .height = 1 }),
    );
}
