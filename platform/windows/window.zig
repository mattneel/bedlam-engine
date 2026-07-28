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
//! §4.1 lists GameInput/Raw Input for this platform, and `WM_INPUT` is not handled yet —
//! this covers window, surface, resize, focus and close, which is criterion 1 and the
//! lifecycle half of criteria 6 and 7. Input is criterion 2 and is separate work.

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

const GWLP_USERDATA: i32 = -21;

pub const capabilities: iface.Capabilities = .{
    .window = true,
    .surface = true,
    .resize = true,
    .offscreen_surface = false, // §4.1 puts that on Web only.
    .lifecycle_events = true,
    .device_loss_events = true, // WM_DISPLAYCHANGE; D3D12 removal lands with the renderer.
};

/// A window plus its event queue. The queue is owned rather than callback-driven because
/// §8's frame loop pulls events at a defined point — a callback would run engine code at
/// whatever moment Windows chose, including inside a modal resize loop.
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

test "the event queue survives a message storm" {
    // WM_SIZE arrives continuously during a drag. The queue is fixed-capacity, so the
    // property that matters is that it saturates and reports rather than corrupting.
    var q: iface.EventQueue = .{};
    for (0..1000) |i| q.push(.{ .resized = .{ .width = @intCast(i), .height = 1 } });
    try std.testing.expectEqual(iface.EventQueue.capacity, q.len);
    try std.testing.expect(q.overflowed > 900);
}
