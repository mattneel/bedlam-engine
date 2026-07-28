//! Win32 window and surface. `ARCHITECTURE.md` §4.1, M0 criterion 1.
//!
//! The first real platform backend, and the only one this machine can exercise end to
//! end. It creates a genuine top-level window, pumps the real message loop, and
//! translates Win32 messages into `iface.Event`.
//!
//! **No Win32 type escapes this file.** §18.9: "No platform SDK types leaking into
//! portable simulation code." `HWND` and `MSG` appear here and nowhere else; the caller
//! sees `Surface` and `iface.Event`.
//!
//! Covers M0 criteria 1 (window and surface) and 2 (input and text forwarding), plus the
//! lifecycle half of 6 and 7. §4.1 also lists GameInput/Raw Input for this platform;
//! `WM_INPUT` is not handled, so relative pointer motion and gamepads are still absent.

const std = @import("std");
const iface = @import("../iface.zig");
const windows = std.os.windows;

const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const UINT = windows.UINT;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPARAM = windows.LPARAM;
// std.os.windows does not declare these in 0.16; they are pointer-width by the Win32 ABI.
const WPARAM = usize;
const LRESULT = isize;

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: i32 = 5;
const SW_HIDE: i32 = 0;
const PM_REMOVE: UINT = 0x0001;

const WM_DESTROY: UINT = 0x0002;
const WM_SIZE: UINT = 0x0005;
const WM_CLOSE: UINT = 0x0010;
const WM_ACTIVATEAPP: UINT = 0x001C;
const WM_DISPLAYCHANGE: UINT = 0x007E;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MBUTTONUP: UINT = 0x0208;
const WM_MOUSEWHEEL: UINT = 0x020A;

/// Scan code to HID usage.
///
/// Translating from the SCAN CODE rather than the virtual key is the whole point.
/// A virtual key is what the layout produced — VK_W is a different physical key on AZERTY
/// — so binding movement to virtual keys binds it to different keys per layout. The scan
/// code is the position, which is what `iface.Key` means.
fn scanToKey(scan: UINT) iface.Key {
    return switch (scan) {
        0x01 => .escape,
        0x11 => .w,
        0x1E => .a,
        0x1F => .s,
        0x20 => .d,
        0x12 => .e,
        0x2E => .c,
        0x30 => .b,
        0x39 => .space,
        0x48 => .up,
        0x50 => .down,
        0x4B => .left,
        0x4D => .right,
        else => .unknown,
    };
}

const POINT = extern struct { x: i32, y: i32 };
const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque,
};

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(DWORD, [*:0]const u16, [*:0]const u16, DWORD, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;

const GWLP_USERDATA: i32 = -21;

pub const capabilities: iface.Capabilities = .{
    .window = true,
    .surface = true,
    .resize = true,
    .keyboard = true,
    .text_input = true,
    .pointer = true,
    .offscreen_surface = false, // §4.1 puts that on Web only.
    .lifecycle_events = true,
    .device_loss_events = true, // WM_DISPLAYCHANGE; D3D12 removal lands with the renderer.
};

/// A window plus its event queue. The queue is owned rather than callback-driven because
/// §8's frame loop pulls events at a defined point — a callback would run engine code at
/// whatever moment Windows chose, including inside a modal resize loop.
extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;

/// Pace a loop. See the Linux backend for why this belongs to the platform layer and is
/// not a frame-rate governor.
pub fn sleepMs(ms: u32) void {
    Sleep(ms);
}

pub const Surface = struct {
    hwnd: HWND,
    events: iface.EventQueue = .{},
    /// What the last `pump` handed out. Separate from `events` so a message sent
    /// synchronously between pumps is not lost — see `pump`.
    drained: iface.EventQueue = .{},
    size: iface.Size,
    closed: bool = false,

    var class_registered: bool = false;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("BedlamSurface");

    /// Initialize into caller-provided storage.
    ///
    /// Takes a pointer rather than returning a value, and that is not style. The window
    /// procedure reaches the Surface through GWLP_USERDATA, so the Surface needs a stable
    /// address from the moment the window exists. Returning by value meant the address
    /// could only be registered later, in `pump` — and `ShowWindow` sends WM_SIZE
    /// SYNCHRONOUSLY, before any pump, so the first resize and the initial suspended /
    /// resumed pair were dispatched to a null userdata and silently dropped. Observable
    /// as a window that reports zero events after being shown.
    pub fn open(self: *Surface, title: []const u16, size: iface.Size) iface.Error!void {
        const hinstance = GetModuleHandleW(null);

        if (!class_registered) {
            const class: WNDCLASSEXW = .{
                .cbSize = @sizeOf(WNDCLASSEXW),
                .style = 0x0003, // CS_HREDRAW | CS_VREDRAW
                .lpfnWndProc = wndProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = hinstance,
                .hIcon = null,
                .hCursor = null,
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = class_name,
                .hIconSm = null,
            };
            if (RegisterClassExW(&class) == 0) return error.SurfaceUnavailable;
            class_registered = true;
        }

        var title_buf: [256:0]u16 = undefined;
        const n = @min(title.len, title_buf.len - 1);
        @memcpy(title_buf[0..n], title[0..n]);
        title_buf[n] = 0;

        self.* = .{ .hwnd = undefined, .size = size };

        const hwnd = CreateWindowExW(
            0,
            class_name,
            &title_buf,
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(size.width),
            @intCast(size.height),
            null,
            null,
            hinstance,
            null,
        ) orelse return error.SurfaceUnavailable;

        self.hwnd = hwnd;
        // Registered before anything can be shown, so synchronously-sent messages reach
        // the queue instead of a null pointer.
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    }

    pub fn destroy(self: *Surface) void {
        _ = DestroyWindow(self.hwnd);
        self.* = undefined;
    }

    pub fn show(self: *Surface) void {
        _ = ShowWindow(self.hwnd, SW_SHOW);
    }

    pub fn hide(self: *Surface) void {
        _ = ShowWindow(self.hwnd, SW_HIDE);
    }

    /// Drain the OS queue into the portable one. Non-blocking: §8's loop never blocks,
    /// so this peeks rather than waiting for a message.
    pub fn pump(self: *Surface) []const iface.Event {
        // Dispatch FIRST, then hand out everything accumulated and reset.
        //
        // Clearing at the top loses every message Windows *sends* rather than *posts*.
        // `ShowWindow` sends WM_SIZE synchronously, before any pump, so the initial
        // resize and the suspended/resumed pair were queued and then wiped by the first
        // pump. Observable as a window that works — the size updates — while reporting
        // zero events, which reads as "this platform produces no events" rather than as
        // a bug.
        var msg: MSG = undefined;
        // BOOL is an enum in std.os.windows, and its docs are explicit that comparing
        // against TRUE is a bug — Win32 returns any nonzero for true. `toBool` is the
        // supported test.
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE).toBool()) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }

        self.drained = self.events;
        self.events.clear();
        return self.drained.slice();
    }

    fn wndProc(hwnd: ?HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
        const raw = if (hwnd) |h| GetWindowLongPtrW(h, GWLP_USERDATA) else 0;
        const self: ?*Surface = if (raw == 0) null else @ptrFromInt(@as(usize, @bitCast(raw)));

        if (self) |s| switch (msg) {
            WM_CLOSE, WM_DESTROY => {
                s.closed = true;
                s.events.push(.close_requested);
                return 0;
            },
            WM_SIZE => {
                const w: u32 = @intCast(lparam & 0xFFFF);
                const h: u32 = @intCast((lparam >> 16) & 0xFFFF);
                s.size = .{ .width = w, .height = h };
                s.events.push(.{ .resized = s.size });
                // wparam 1 is SIZE_MINIMIZED. §4.1 collapses Android lifecycle, iOS
                // backgrounding and a minimized window to one pair, because the engine's
                // response — release transient GPU state, stop presenting — is the same.
                if (wparam == 1) s.events.push(.suspended) else s.events.push(.resumed);
                return 0;
            },
            WM_ACTIVATEAPP => {
                s.events.push(if (wparam != 0) .focus_gained else .focus_lost);
                return 0;
            },
            WM_KEYDOWN, WM_SYSKEYDOWN => {
                // Bit 30 of lparam is the previous key state: set means this is an
                // auto-repeat. Dropped, because a held key is one press to the
                // simulation — §7 requires the input stream to be a function of what the
                // player did, not of the OS repeat rate, which is a per-machine setting.
                if ((lparam & (1 << 30)) == 0) {
                    s.events.push(.{ .key_down = scanToKey((@as(UINT, @intCast(lparam)) >> 16) & 0xFF) });
                }
                return 0;
            },
            WM_KEYUP, WM_SYSKEYUP => {
                s.events.push(.{ .key_up = scanToKey((@as(UINT, @intCast(lparam)) >> 16) & 0xFF) });
                return 0;
            },
            WM_CHAR => {
                // Produced by TranslateMessage after layout, dead-key composition and
                // IME. A separate stream from key_down on purpose — see iface.Event.
                //
                // Surrogate halves are skipped rather than emitted: a lone surrogate is
                // not a scalar value and u21 cannot hold a meaningful one. Astral-plane
                // text needs pairing, which belongs with the IME work rather than here.
                const cp: u32 = @intCast(wparam & 0xFFFF);
                if (cp < 0xD800 or cp > 0xDFFF) s.events.push(.{ .text = @intCast(cp) });
                return 0;
            },
            WM_MOUSEMOVE => {
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
                s.events.push(.{ .mouse_moved = .{ .x = x, .y = y } });
                return 0;
            },
            WM_LBUTTONDOWN => {
                s.events.push(.{ .mouse_down = .left });
                return 0;
            },
            WM_LBUTTONUP => {
                s.events.push(.{ .mouse_up = .left });
                return 0;
            },
            WM_RBUTTONDOWN => {
                s.events.push(.{ .mouse_down = .right });
                return 0;
            },
            WM_RBUTTONUP => {
                s.events.push(.{ .mouse_up = .right });
                return 0;
            },
            WM_MBUTTONDOWN => {
                s.events.push(.{ .mouse_down = .middle });
                return 0;
            },
            WM_MBUTTONUP => {
                s.events.push(.{ .mouse_up = .middle });
                return 0;
            },
            WM_MOUSEWHEEL => {
                const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                s.events.push(.{ .mouse_wheel = delta });
                return 0;
            },
            WM_DISPLAYCHANGE => {
                // M0 criterion 7. A display topology change invalidates a swapchain; the
                // renderer will need to rebuild rather than present into a dead one.
                s.events.push(.device_lost);
                s.events.push(.device_restored);
                return 0;
            },
            else => {},
        };
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
};

// ---------------------------------------------------------------------------

test "capabilities are declared, not assumed" {
    try std.testing.expect(capabilities.window);
    try std.testing.expect(capabilities.surface);
    // §4.1 puts OffscreenCanvas on Web only; claiming it here would make the conformance
    // probe report a capability this backend does not have.
    try std.testing.expect(!capabilities.offscreen_surface);
}

test "a real window is created, pumped and destroyed" {
    // Runs on a real Windows session. Under a headless CI runner there is a window
    // station but no interactive desktop, and creation can fail — that is reported as
    // SurfaceUnavailable and skipped rather than failing the suite, because a CI runner
    // without a desktop is not evidence about the platform layer.
    const title = std.unicode.utf8ToUtf16LeStringLiteral("bedlam-test");
    var s: Surface = undefined;
    s.open(title, .{ .width = 640, .height = 360 }) catch |err| switch (err) {
        error.SurfaceUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer s.destroy();

    // Hidden: a test must not steal focus from whoever is at the keyboard.
    _ = s.pump();
    try std.testing.expectEqual(@as(u32, 640), s.size.width);
    try std.testing.expectEqual(@as(u32, 360), s.size.height);
}

test "showing a window produces events" {
    // Regression. ShowWindow sends WM_SIZE synchronously, so a Surface whose address is
    // only registered at first pump drops it — the window works and reports nothing,
    // which reads as "the platform has no events" rather than as a bug.
    const title = std.unicode.utf8ToUtf16LeStringLiteral("bedlam-events");
    var s: Surface = undefined;
    s.open(title, .{ .width = 320, .height = 200 }) catch |err| switch (err) {
        error.SurfaceUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer s.destroy();

    s.show();
    const events = s.pump();
    try std.testing.expect(events.len > 0);

    var saw_resize = false;
    for (events) |e| switch (e) {
        .resized => saw_resize = true,
        else => {},
    };
    try std.testing.expect(saw_resize);
}

/// Post a message to the window and pump it, so tests exercise the real wndProc through
/// the real message loop rather than calling the translation directly.
fn postAndPump(s: *Surface, msg: UINT, wparam: WPARAM, lparam: LPARAM) []const iface.Event {
    _ = PostMessageW(s.hwnd, msg, wparam, lparam);
    return s.pump();
}

/// Initialize into caller-provided storage. Returning a Surface by value would move it,
/// leaving GWLP_USERDATA pointing at a dead address — the same defect `open` exists to
/// prevent, and one that makes event tests pass VACUOUSLY, since a loop over zero events
/// asserts nothing.
fn openHidden(s: *Surface) bool {
    const title = std.unicode.utf8ToUtf16LeStringLiteral("bedlam-input");
    s.open(title, .{ .width = 320, .height = 200 }) catch return false;
    return true;
}

test "keys are reported by physical position, not by layout" {
    // Scan 0x11 is the key labelled W on QWERTY and Z on AZERTY. Binding movement to the
    // virtual key would bind it to a different physical key per layout; the scan code is
    // the position, which is what iface.Key means.
    var s: Surface = undefined;
    if (!openHidden(&s)) return error.SkipZigTest;
    defer s.destroy();
    _ = s.pump();

    const events = postAndPump(&s, WM_KEYDOWN, 0x57, 0x11 << 16);
    var saw = false;
    for (events) |e| switch (e) {
        .key_down => |k| {
            try std.testing.expectEqual(iface.Key.w, k);
            saw = true;
        },
        else => {},
    };
    try std.testing.expect(saw);
}

test "auto-repeat is dropped" {
    // Bit 30 set means the key was already down. A held key is ONE press to the
    // simulation — §7 needs the input stream to be a function of what the player did,
    // not of the OS repeat rate, which is a per-machine setting and would desync two
    // peers holding the same key.
    var s: Surface = undefined;
    if (!openHidden(&s)) return error.SkipZigTest;
    defer s.destroy();
    _ = s.pump();

    const repeat: LPARAM = (0x11 << 16) | (1 << 30);
    const events = postAndPump(&s, WM_KEYDOWN, 0x57, repeat);
    for (events) |e| switch (e) {
        .key_down => return error.AutoRepeatLeaked,
        else => {},
    };
}

test "text is a separate stream from keys" {
    // A dead key produces no text until composed, an IME produces text with no key, and
    // Ctrl+C produces a key with no text. Conflating them breaks all three.
    var s: Surface = undefined;
    if (!openHidden(&s)) return error.SkipZigTest;
    defer s.destroy();
    _ = s.pump();

    const events = postAndPump(&s, WM_CHAR, 'A', 0);
    var saw: ?u21 = null;
    for (events) |e| switch (e) {
        .text => |c| saw = c,
        .key_down => return error.TextProducedAKeyEvent,
        else => {},
    };
    try std.testing.expectEqual(@as(?u21, 'A'), saw);
}

test "lone surrogates are not emitted as text" {
    // A surrogate half is not a scalar value; emitting one would put an invalid code
    // point into the text stream that no consumer can render.
    var s: Surface = undefined;
    if (!openHidden(&s)) return error.SkipZigTest;
    defer s.destroy();
    _ = s.pump();

    const events = postAndPump(&s, WM_CHAR, 0xD83D, 0);
    for (events) |e| switch (e) {
        .text => return error.SurrogateLeaked,
        else => {},
    };
}

test "mouse position is reported in client coordinates" {
    var s: Surface = undefined;
    if (!openHidden(&s)) return error.SkipZigTest;
    defer s.destroy();
    _ = s.pump();

    const packed_xy: LPARAM = (37 << 16) | 12;
    const events = postAndPump(&s, WM_MOUSEMOVE, 0, packed_xy);
    var saw = false;
    for (events) |e| switch (e) {
        .mouse_moved => |p| {
            try std.testing.expectEqual(@as(i32, 12), p.x);
            try std.testing.expectEqual(@as(i32, 37), p.y);
            saw = true;
        },
        else => {},
    };
    try std.testing.expect(saw);
}

test "the event queue survives a message storm" {
    // WM_SIZE arrives continuously during a drag. The queue is fixed-capacity, so the
    // property that matters is that it saturates and reports rather than corrupting.
    var q: iface.EventQueue = .{};
    for (0..1000) |i| q.push(.{ .resized = .{ .width = @intCast(i), .height = 1 } });
    try std.testing.expectEqual(iface.EventQueue.capacity, q.len);
    try std.testing.expect(q.overflowed > 900);
}
