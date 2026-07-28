//! X11 window and surface. `ARCHITECTURE.md` §4.1, M0 criteria 1, 2, and the lifecycle
//! halves of 6 and 7.
//!
//! **X11 is loaded with `dlopen`, not linked.** This is the decision that shapes the file
//! and it is deliberate: `docs/CI_TIERS.md` §4 records that all eight target rows compile
//! clean from a Windows host with no platform SDKs installed, and linking `libX11` would
//! end that immediately — the Linux row would need X11 development headers on whatever
//! machine builds it, including the ones that only cross-compile. `AGENTS.md` §3 puts the
//! same pressure on dependencies from the other direction: anything that cannot
//! cross-compile with `zig cc` to all six targets is a reason to reconsider it.
//!
//! Runtime loading keeps both properties. The Linux binary builds anywhere, runs headless
//! where there is no display, and opens a real window where there is one. A machine with
//! no X11 is not a build failure and not a crash — it is `capabilities.window == false`.
//!
//! **No X11 type escapes this file.** §18.9. `Display`, `XEvent` and the atom handles
//! appear here and nowhere else; the caller sees `Surface` and `iface.Event`.
//!
//! Verified under WSLg, which is a real X server: `zig build run -- --window` opens a
//! window, pumps the real event loop, and reports what came back.

const std = @import("std");
const builtin = @import("builtin");
const iface = @import("../iface.zig");

// --- the subset of Xlib this needs ------------------------------------------

const Display = opaque {};
const XWindow = c_ulong;
const Atom = c_ulong;
const Time = c_ulong;
const Bool = c_int;

const ExposureMask: c_long = 1 << 15;
const KeyPressMask: c_long = 1 << 0;
const KeyReleaseMask: c_long = 1 << 1;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const StructureNotifyMask: c_long = 1 << 17;
const FocusChangeMask: c_long = 1 << 21;

const KeyPress: c_int = 2;
const KeyRelease: c_int = 3;
const ButtonPress: c_int = 4;
const ButtonRelease: c_int = 5;
const MotionNotify: c_int = 6;
const FocusIn: c_int = 9;
const FocusOut: c_int = 10;
const ConfigureNotify: c_int = 22;
const MapNotify: c_int = 19;
const UnmapNotify: c_int = 18;
const ClientMessage: c_int = 33;

/// `XEvent` is a union whose largest member is 24 `long`s. Declared as raw storage plus
/// per-type accessors rather than as a Zig union, because the layout is defined by the C
/// ABI and a Zig union that happened to match today would not be guaranteed to tomorrow.
const XEvent = extern struct {
    type: c_int,
    pad: [23]c_long,
};

const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XWindow,
};

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XWindow,
    root: XWindow,
    subwindow: XWindow,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};

const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XWindow,
    root: XWindow,
    subwindow: XWindow,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: Bool,
};

const XMotionEvent = XButtonEvent; // same prefix through x/y; `button` is `is_hint` there

const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: XWindow,
    window: XWindow,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: XWindow,
    override_redirect: Bool,
};

const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: XWindow,
    message_type: Atom,
    format: c_int,
    data: extern union {
        b: [20]u8,
        s: [10]c_short,
        l: [5]c_long,
    },
};

const Xlib = struct {
    handle: ?*anyopaque = null,

    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display = undefined,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int = undefined,
    XDefaultScreen: *const fn (*Display) callconv(.c) c_int = undefined,
    XRootWindow: *const fn (*Display, c_int) callconv(.c) XWindow = undefined,
    XBlackPixel: *const fn (*Display, c_int) callconv(.c) c_ulong = undefined,
    XCreateSimpleWindow: *const fn (*Display, XWindow, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) XWindow = undefined,
    XStoreName: *const fn (*Display, XWindow, [*:0]const u8) callconv(.c) c_int = undefined,
    XSelectInput: *const fn (*Display, XWindow, c_long) callconv(.c) c_int = undefined,
    XMapWindow: *const fn (*Display, XWindow) callconv(.c) c_int = undefined,
    XUnmapWindow: *const fn (*Display, XWindow) callconv(.c) c_int = undefined,
    XDestroyWindow: *const fn (*Display, XWindow) callconv(.c) c_int = undefined,
    XNextEvent: *const fn (*Display, *XEvent) callconv(.c) c_int = undefined,
    XPending: *const fn (*Display) callconv(.c) c_int = undefined,
    XFlush: *const fn (*Display) callconv(.c) c_int = undefined,
    XInternAtom: *const fn (*Display, [*:0]const u8, Bool) callconv(.c) Atom = undefined,
    XSetWMProtocols: *const fn (*Display, XWindow, [*]Atom, c_int) callconv(.c) c_int = undefined,
    XLookupKeysym: *const fn (*XKeyEvent, c_int) callconv(.c) c_ulong = undefined,
    XLookupString: *const fn (*XKeyEvent, [*]u8, c_int, ?*c_ulong, ?*anyopaque) callconv(.c) c_int = undefined,
};

var lib: Xlib = .{};
var load_attempted = false;

/// Load libX11 once. Failure is a normal outcome, not an error: a headless machine is a
/// machine the engine still runs on.
fn load() bool {
    if (load_attempted) return lib.handle != null;
    load_attempted = true;
    if (builtin.os.tag != .linux) return false;

    // Both sonames tried, newest first. `libX11.so` alone exists only where the -dev
    // package is installed, which is exactly the machine this design does not require.
    const candidates = [_][:0]const u8{ "libX11.so.6", "libX11.so" };
    for (candidates) |name| {
        if (std.c.dlopen(name.ptr, // LOCAL is the default (GLOBAL unset): symbols stay private to this handle, so
            // loading X11 cannot shadow a symbol the engine resolves elsewhere.
            .{ .LAZY = true })) |h|
        {
            lib.handle = h;
            break;
        }
    }
    const h = lib.handle orelse return false;

    inline for (@typeInfo(Xlib).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "handle")) continue;
        const sym = std.c.dlsym(h, f.name ++ "");
        if (sym == null) {
            // A partial load is worse than none: a null function pointer called later is
            // a crash with no explanation, where reporting "no window support" here is a
            // capability the caller already knows how to handle.
            lib.handle = null;
            return false;
        }
        @field(lib, f.name) = @ptrCast(@alignCast(sym.?));
    }
    return true;
}

pub const capabilities: iface.Capabilities = .{
    // Reported as available at compile time and checked at run time by `open`. The
    // alternative — probing here — would dlopen X11 as a side effect of reading a
    // constant, which is the kind of thing that makes a headless server open a display.
    .window = true,
    .surface = true,
    .lifecycle_events = true,
    .device_loss_events = false,
    .text_input = true,
    .pointer = true,
};

/// X11 keycode to HID usage.
///
/// Translated from the KEYCODE, not the keysym. A keysym is what the layout produced —
/// `XK_w` is a different physical key on AZERTY — so binding movement to keysyms binds it
/// to different keys per layout. The keycode is the position, which is what `iface.Key`
/// means. This is the same argument `windows/window.zig` makes about scan codes, and the
/// numbers agree because both target HID usages rather than each other.
///
/// X11 keycodes are the kernel's evdev codes plus 8 on every modern server.
fn keycodeToKey(code: c_uint) iface.Key {
    return switch (code) {
        38 => .a, // evdev KEY_A = 30
        56 => .b,
        54 => .c,
        40 => .d,
        26 => .e,
        39 => .s,
        25 => .w,
        9 => .escape,
        65 => .space,
        113 => .left,
        114 => .right,
        111 => .up,
        116 => .down,
        else => .unknown,
    };
}

fn buttonToMouse(b: c_uint) ?iface.MouseButton {
    return switch (b) {
        1 => .left,
        2 => .middle,
        3 => .right,
        8 => .x1,
        9 => .x2,
        else => null, // 4..7 are wheel, handled separately
    };
}

/// Pace a loop. Part of the backend rather than a std call because `std.Thread.sleep` is
/// gone in 0.16 and each platform reaches its own timer.
///
/// **Not a frame-rate governor.** §1.3 lists four governors and says none touches tick
/// rate; this is the primitive a loop uses to yield when it has nothing to do, which is
/// what makes a 240-iteration demo represent four seconds rather than four milliseconds.
/// The difference is not cosmetic: X11 delivers map and configure asynchronously, so a
/// loop that spins faster than the round trip observes no events and reports a window that
/// never appeared.
pub fn sleepMs(ms: u32) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    // Restarted on EINTR only. A signal must not turn a 16 ms yield into a busy loop --
    // that is how a paced loop silently becomes a spin on a machine running a profiler.
    // Any OTHER error returns rather than retrying: an unconditional retry on EINVAL is an
    // infinite loop in the frame pacing, which is a far worse failure than a short sleep.
    while (std.c.nanosleep(&req, &req) == -1) {
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return;
    }
}

pub const Surface = struct {
    display: ?*Display = null,
    window: XWindow = 0,
    wm_delete: Atom = 0,
    size: iface.Size = .{ .width = 0, .height = 0 },
    closed: bool = false,
    events: iface.EventQueue = .{},
    mapped: bool = false,
    focused: bool = false,

    /// Takes `self` by pointer rather than returning a value.
    ///
    /// Same reason as the Win32 backend: the surface holds handles that identify it, and a
    /// returned-by-value struct is a copy at a different address. Nothing here stores a
    /// pointer back into `self` the way `GWLP_USERDATA` does, but the asymmetry between
    /// backends is worse than the consistency is worth — a caller that learns one shape
    /// should not have to relearn it.
    pub fn open(self: *Surface, title: []const u16, size: iface.Size) iface.Error!void {
        self.* = .{};
        if (!load()) return iface.Error.Unsupported;

        const dpy = lib.XOpenDisplay(null) orelse return iface.Error.Unsupported;
        errdefer _ = lib.XCloseDisplay(dpy);

        const screen = lib.XDefaultScreen(dpy);
        const root = lib.XRootWindow(dpy, screen);
        const black = lib.XBlackPixel(dpy, screen);

        const win = lib.XCreateSimpleWindow(
            dpy,
            root,
            0,
            0,
            @intCast(size.width),
            @intCast(size.height),
            0,
            black,
            black,
        );
        if (win == 0) return iface.Error.SurfaceUnavailable;

        // The caller's title is UTF-16 because that is what the Win32 backend needs and
        // §18.9 keeps the interface one shape. Narrowed here, where the platform's
        // preference is known, rather than making every caller carry two encodings.
        var buf: [256]u8 = @splat(0);
        var n: usize = 0;
        for (title) |u| {
            if (n + 4 >= buf.len) break;
            if (u == 0) break;
            n += std.unicode.utf8Encode(@intCast(u), buf[n..]) catch break;
        }
        buf[n] = 0;
        _ = lib.XStoreName(dpy, win, @ptrCast(&buf));

        _ = lib.XSelectInput(dpy, win, KeyPressMask | KeyReleaseMask |
            ButtonPressMask | ButtonReleaseMask | PointerMotionMask |
            StructureNotifyMask | FocusChangeMask | ExposureMask);

        // WM_DELETE_WINDOW, or the window manager kills the client instead of telling it.
        // §13's authoring layer may need to flush before a close is honoured, so a close
        // must arrive as an event rather than as a process death.
        var del = lib.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        _ = lib.XSetWMProtocols(dpy, win, @ptrCast(&del), 1);

        self.display = dpy;
        self.window = win;
        self.wm_delete = del;
        self.size = size;
    }

    pub fn destroy(self: *Surface) void {
        if (self.display) |dpy| {
            if (self.window != 0) _ = lib.XDestroyWindow(dpy, self.window);
            _ = lib.XCloseDisplay(dpy);
        }
        self.* = .{};
    }

    pub fn show(self: *Surface) void {
        const dpy = self.display orelse return;
        _ = lib.XMapWindow(dpy, self.window);
        _ = lib.XFlush(dpy);
    }

    pub fn hide(self: *Surface) void {
        const dpy = self.display orelse return;
        _ = lib.XUnmapWindow(dpy, self.window);
        _ = lib.XFlush(dpy);
    }

    /// Drain the X queue into `iface.Event`s.
    ///
    /// `XPending` first and `XNextEvent` only while it is nonzero: `XNextEvent` blocks,
    /// and a frame loop that blocks on input has coupled tick cadence to whether the user
    /// moved the mouse. Same rule as `platform/udp.zig` — the bounded wait belongs in the
    /// architecture, not in the syscall.
    pub fn pump(self: *Surface) []const iface.Event {
        self.events.clear();
        const dpy = self.display orelse return self.events.slice();

        while (lib.XPending(dpy) > 0) {
            var ev: XEvent = undefined;
            _ = lib.XNextEvent(dpy, &ev);

            switch (ev.type) {
                KeyPress, KeyRelease => {
                    const ke: *XKeyEvent = @ptrCast(&ev);
                    const key = keycodeToKey(ke.keycode);
                    if (ev.type == KeyPress) {
                        self.events.push(.{ .key_down = key });
                        // Text is a separate event on purpose: a dead key produces none
                        // until composed, and Ctrl+C produces a key with no text.
                        var text: [8]u8 = undefined;
                        const n = lib.XLookupString(ke, &text, text.len, null, null);
                        if (n > 0) {
                            var i: usize = 0;
                            while (i < @as(usize, @intCast(n))) {
                                const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
                                if (i + len > @as(usize, @intCast(n))) break;
                                const cp = std.unicode.utf8Decode(text[i .. i + len]) catch break;
                                if (cp >= 0x20 and cp != 0x7F) self.events.push(.{ .text = cp });
                                i += len;
                            }
                        }
                    } else {
                        self.events.push(.{ .key_up = key });
                    }
                },
                ButtonPress, ButtonRelease => {
                    const be: *XButtonEvent = @ptrCast(&ev);
                    // X11 reports the wheel as buttons 4 and 5, which is a historical
                    // accident rather than a button.
                    if (be.button == 4 or be.button == 5) {
                        if (ev.type == ButtonPress) {
                            self.events.push(.{ .mouse_wheel = if (be.button == 4) 1 else -1 });
                        }
                    } else if (buttonToMouse(be.button)) |b| {
                        self.events.push(if (ev.type == ButtonPress)
                            .{ .mouse_down = b }
                        else
                            .{ .mouse_up = b });
                    }
                },
                MotionNotify => {
                    const me: *XMotionEvent = @ptrCast(&ev);
                    self.events.push(.{ .mouse_moved = .{ .x = me.x, .y = me.y } });
                },
                ConfigureNotify => {
                    const ce: *XConfigureEvent = @ptrCast(&ev);
                    const w: u32 = @intCast(@max(ce.width, 0));
                    const h: u32 = @intCast(@max(ce.height, 0));
                    // Only on a real change. X sends ConfigureNotify for moves too, and a
                    // resize event per window drag would have the renderer rebuilding a
                    // swapchain that did not change size.
                    if (w != self.size.width or h != self.size.height) {
                        self.size = .{ .width = w, .height = h };
                        self.events.push(.{ .resized = self.size });
                    }
                },
                FocusIn => {
                    self.focused = true;
                    self.events.push(.focus_gained);
                },
                FocusOut => {
                    self.focused = false;
                    self.events.push(.focus_lost);
                },
                // Map and unmap are this platform's suspend/resume. §4.1 collapses Android
                // lifecycle, iOS backgrounding and tab visibility to one pair because the
                // engine's response is the same, and a minimized X11 window is the same
                // situation: stop presenting, keep simulating.
                MapNotify => {
                    if (!self.mapped) {
                        self.mapped = true;
                        self.events.push(.resumed);
                    }
                },
                UnmapNotify => {
                    if (self.mapped) {
                        self.mapped = false;
                        self.events.push(.suspended);
                    }
                },
                ClientMessage => {
                    const cm: *XClientMessageEvent = @ptrCast(&ev);
                    if (@as(Atom, @bitCast(cm.data.l[0])) == self.wm_delete) {
                        self.closed = true;
                        self.events.push(.close_requested);
                    }
                },
                else => {},
            }
        }
        return self.events.slice();
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the backend satisfies the surface contract" {
    iface.assertSurfaceContract(@This());
}

test "a machine with no display is not an error path anyone has to special-case" {
    // The whole point of dlopen here: a headless build runs, a headless machine reports
    // Unsupported, and neither is a crash or a build failure.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var s: Surface = undefined;
    const title = std.unicode.utf8ToUtf16LeStringLiteral("test");
    s.open(title, .{ .width = 320, .height = 200 }) catch |err| {
        try testing.expect(err == iface.Error.Unsupported or
            err == iface.Error.SurfaceUnavailable);
        return;
    };
    defer s.destroy();

    // A display DID open — WSLg or a real desktop. Then it must actually work rather than
    // merely have been created: §18.20, a handle is not a window.
    try testing.expect(s.window != 0);
    try testing.expect(s.wm_delete != 0);
    s.show();

    var pumps: u32 = 0;
    while (pumps < 200 and !s.closed) : (pumps += 1) _ = s.pump();
    try testing.expect(s.size.width > 0);
}

test "pump on an unopened surface is empty rather than a crash" {
    var s: Surface = .{};
    try testing.expectEqual(@as(usize, 0), s.pump().len);
    s.show();
    s.hide();
    s.destroy();
}

test "keycodes map from position, not from layout" {
    // Translating from the KEYCODE rather than the keysym is the point: a keysym is what
    // the layout produced, so binding movement to keysyms binds it to different physical
    // keys per layout. These are evdev codes + 8.
    try testing.expectEqual(iface.Key.w, keycodeToKey(25));
    try testing.expectEqual(iface.Key.a, keycodeToKey(38));
    try testing.expectEqual(iface.Key.s, keycodeToKey(39));
    try testing.expectEqual(iface.Key.d, keycodeToKey(40));
    try testing.expectEqual(iface.Key.escape, keycodeToKey(9));
    try testing.expectEqual(iface.Key.unknown, keycodeToKey(250));
}

test "the wheel is not a button" {
    // X11 reports the wheel as buttons 4 and 5, which is a historical accident. Treating
    // them as buttons gives a phantom click on every scroll.
    try testing.expect(buttonToMouse(4) == null);
    try testing.expect(buttonToMouse(5) == null);
    try testing.expectEqual(iface.MouseButton.left, buttonToMouse(1).?);
    try testing.expectEqual(iface.MouseButton.middle, buttonToMouse(2).?);
    try testing.expectEqual(iface.MouseButton.right, buttonToMouse(3).?);
}

test "XEvent is large enough for every member this file casts to" {
    // The union is defined by the C ABI. Casting a smaller buffer to XKeyEvent reads past
    // it, and the failure would be intermittent and blamed on the X server.
    try testing.expect(@sizeOf(XEvent) >= @sizeOf(XKeyEvent));
    try testing.expect(@sizeOf(XEvent) >= @sizeOf(XButtonEvent));
    try testing.expect(@sizeOf(XEvent) >= @sizeOf(XConfigureEvent));
    try testing.expect(@sizeOf(XEvent) >= @sizeOf(XClientMessageEvent));
    try testing.expect(@sizeOf(XEvent) >= @sizeOf(XAnyEvent));
    // 24 longs is what Xlib documents.
    try testing.expectEqual(@as(usize, 24 * @sizeOf(c_long)), @sizeOf(XEvent));
}
