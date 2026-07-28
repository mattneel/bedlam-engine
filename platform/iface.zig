//! The portable side of the platform boundary.
//!
//! Every type here is target-independent by construction. A backend converts its native
//! representation into these; nothing in the other direction. §18.9 is the rule and this
//! file is where it is expressible.

const std = @import("std");

pub const Error = error{
    /// The platform refused to create the surface — no display, no permission, or a
    /// class registration that failed.
    SurfaceUnavailable,
    /// The window was created and then lost. `AGENTS.md` §4 lists device loss and
    /// recovery as an M0 criterion, so this is a normal outcome rather than a fatal one.
    SurfaceLost,
    Unsupported,
};

pub const Size = struct { width: u32, height: u32 };

/// What a backend can actually do, probed rather than assumed.
///
/// `CONFORMANCE_PROFILES.md` §3: "Profile is determined at startup by capability probe,
/// never by user agent string, never by device model lookup, never by configuration."
/// The same discipline applies to the platform layer — a backend reports what it has.
pub const Capabilities = struct {
    window: bool = false,
    /// Whether a surface can be created at all in this process. False under CI, in a
    /// headless container, or on a session with no display.
    surface: bool = false,
    resize: bool = false,
    /// M0 criterion 2, first half: physical key positions.
    keyboard: bool = false,
    /// M0 criterion 2, second half. Distinct from `keyboard` because a backend can have
    /// keys without composed text — an IME is a separate capability, not a formatting
    /// detail of the same one.
    text_input: bool = false,
    pointer: bool = false,
    /// §4.1 Web: the render surface is a Worker + OffscreenCanvas, not a main-thread
    /// canvas, and `CONFORMANCE_PROFILES.md` §2 makes that a conformance requirement.
    offscreen_surface: bool = false,
    /// M0: suspend and resume.
    lifecycle_events: bool = false,
    /// M0: device loss and recovery.
    device_loss_events: bool = false,
};

/// Physical key position, not the character it produces.
///
/// `AGENTS.md` §4 lists "input and text forwarding" as one criterion because they are two
/// different things that get conflated. A key is a POSITION — the same physical key is
/// `W` on QWERTY and `Z` on AZERTY, and a game that binds movement to a character binds
/// it to a different physical key on every layout. Text is a separate stream carrying
/// what the layout, dead keys and IME actually produced.
///
/// Values follow USB HID usage codes so a backend translating from any platform lands on
/// the same number, and so the set is not derived from one platform's enumeration.
pub const Key = enum(u16) {
    unknown = 0,
    a = 4,
    b = 5,
    c = 6,
    d = 7,
    e = 8,
    s = 22,
    w = 26,
    escape = 41,
    space = 44,
    left = 80,
    right = 79,
    up = 82,
    down = 81,
    _,
};

pub const MouseButton = enum(u8) { left, right, middle, x1, x2, _ };

/// Events the portable layer understands. Deliberately not a superset of any one
/// platform's event model — a backend that cannot produce one simply never does.
pub const Event = union(enum) {
    close_requested,
    resized: Size,
    focus_gained,
    focus_lost,

    key_down: Key,
    key_up: Key,
    /// One Unicode scalar produced by the layout. Separate from `key_down` on purpose:
    /// a dead key produces no text until composed, an IME produces text with no
    /// corresponding key at all, and `Ctrl+C` produces a key with no text.
    text: u21,

    mouse_down: MouseButton,
    mouse_up: MouseButton,
    /// Client-area coordinates. Absolute rather than relative, because relative motion is
    /// a raw-input concept and §4.1 puts that on GameInput/Raw Input, which is separate.
    mouse_moved: struct { x: i32, y: i32 },
    mouse_wheel: i32,
    /// §4.1: Android lifecycle, iOS backgrounding, browser tab visibility. All three
    /// collapse to this pair because the engine's response is the same.
    suspended,
    resumed,
    device_lost,
    device_restored,
};

/// A drained event queue. Fixed capacity: draining is a frame-loop operation and §18.8
/// forbids allocation there.
pub const EventQueue = struct {
    pub const capacity = 64;

    items: [capacity]Event = undefined,
    len: usize = 0,
    /// Events dropped because the queue was full. Reported rather than silently lost —
    /// a dropped `suspended` is a client that never releases its GPU resources.
    overflowed: u32 = 0,

    pub fn push(self: *EventQueue, e: Event) void {
        if (self.len >= capacity) {
            self.overflowed += 1;
            return;
        }
        self.items[self.len] = e;
        self.len += 1;
    }

    pub fn slice(self: *const EventQueue) []const Event {
        return self.items[0..self.len];
    }

    pub fn clear(self: *EventQueue) void {
        self.len = 0;
        self.overflowed = 0;
    }
};

/// The shape every backend's `Surface` must have.
///
/// Zig has no interface keyword, so without this the contract is whatever the callers
/// happen to use — and a backend that omits a field compiles fine until someone builds
/// for that target. That is precisely how it failed the first time: the Windows Surface
/// grew `closed`, the stub did not, and every non-Windows target broke at the call site
/// rather than at the backend.
///
/// Called from `platform/root.zig` for whichever backend was selected, so the error names
/// the backend and the missing member instead of naming a line in `main.zig`.
pub fn assertSurfaceContract(comptime Backend: type) void {
    comptime {
        if (!@hasDecl(Backend, "capabilities"))
            @compileError(@typeName(Backend) ++ " has no `capabilities` — a backend must declare " ++
                "what it can do, because Capabilities defaults every field to false and silence " ++
                "would read as a working backend.");

        const S = Backend.Surface;
        for ([_][]const u8{ "events", "size", "closed" }) |field| {
            if (!@hasField(S, field))
                @compileError(@typeName(S) ++ " is missing field `" ++ field ++
                    "`, required of every platform Surface.");
        }
        for ([_][]const u8{ "open", "destroy", "show", "hide", "pump" }) |method| {
            if (!@hasDecl(S, method))
                @compileError(@typeName(S) ++ " is missing method `" ++ method ++
                    "`, required of every platform Surface.");
        }
    }
}

test "the event queue reports overflow rather than dropping silently" {
    // A dropped `suspended` is a client that never releases its GPU resources, and a
    // dropped `device_lost` is one that renders into a dead swapchain. Both are M0
    // criteria; neither may be lost without a trace.
    var q: EventQueue = .{};
    for (0..EventQueue.capacity + 5) |_| q.push(.focus_gained);

    try std.testing.expectEqual(EventQueue.capacity, q.len);
    try std.testing.expectEqual(@as(u32, 5), q.overflowed);
}

test "clear resets both the queue and the overflow counter" {
    var q: EventQueue = .{};
    for (0..EventQueue.capacity + 1) |_| q.push(.resumed);
    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.len);
    try std.testing.expectEqual(@as(u32, 0), q.overflowed);
}

test "capabilities default to nothing" {
    // A backend must opt in to each claim. Defaulting to true would make an unimplemented
    // backend indistinguishable from a working one, which is how a platform gets reported
    // as conformant on the strength of a stub.
    const c: Capabilities = .{};
    try std.testing.expect(!c.window);
    try std.testing.expect(!c.surface);
    try std.testing.expect(!c.offscreen_surface);
    try std.testing.expect(!c.lifecycle_events);
    try std.testing.expect(!c.device_loss_events);
}
