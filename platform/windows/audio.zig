//! WASAPI render device. `ARCHITECTURE.md` §17, M0 criterion 3.
//!
//! `mixer.zig` renders a block; `audio_ring.zig` gets commands to it. This is the part that
//! makes either matter: a real device, a real thread, a real deadline.
//!
//! **No WASAPI type escapes this file.** §18.9. `IAudioClient`, `WAVEFORMATEX` and the COM
//! vtables appear here and nowhere else; the caller sees `Device` and `mixer.Mixer`.
//!
//! **Event-driven shared mode, not a polling loop.** `AUDCLNT_STREAMFLAGS_EVENTCALLBACK`
//! plus `WaitForSingleObject` means the OS wakes the thread exactly when the endpoint wants
//! samples. A sleep-and-poll loop either wakes too often — burning power on the target
//! that has least of it — or too rarely, and the second failure mode is a glitch. Shared
//! rather than exclusive mode because exclusive takes the device away from every other
//! application, which is not a thing an engine gets to do by default.
//!
//! **The render thread is the highest-priority thread in the process, via MMCSS.**
//! `AvSetMmThreadCharacteristics("Pro Audio")` is what keeps the Windows scheduler from
//! preempting the callback with ordinary work. Without it the deadline is met most of the
//! time, which for audio is indistinguishable from not meeting it.
//!
//! **The thread does not allocate, lock, or log.** Everything it needs is allocated in
//! `start` and owned by the device for the thread's lifetime. §18.8 forbids frame-loop
//! allocation and this thread is stricter, because its deadline is roughly a tenth of a
//! frame's.

const std = @import("std");
const windows = std.os.windows;
const mixer_mod = @import("bedlam_audio").mixer;
const audio_ring = @import("bedlam_audio").ring;

// std.os.windows does not declare these in 0.16; they are fixed by the Win32 ABI.
const HRESULT = i32;
const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = i32;
const GUID = windows.GUID;
const REFERENCE_TIME = i64;

pub const Error = error{
    ComInitFailed,
    NoDevice,
    ClientInitFailed,
    FormatUnsupported,
    StartFailed,
    ThreadFailed,
};

// --- COM plumbing ----------------------------------------------------------

const CLSCTX_ALL: DWORD = 0x17;
const COINIT_MULTITHREADED: DWORD = 0x0;
const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

const AUDCLNT_SHAREMODE_SHARED: u32 = 0;
const AUDCLNT_STREAMFLAGS_EVENTCALLBACK: u32 = 0x00040000;
const AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM: u32 = 0x80000000;
const AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY: u32 = 0x08000000;
/// The device went away — unplugged, disabled, or format-changed. §4's `device_lost` for
/// audio, and the reason `restart` exists rather than the thread simply dying.
const AUDCLNT_E_DEVICE_INVALIDATED: HRESULT = @bitCast(@as(u32, 0x88890004));

const eRender: u32 = 0;
const eConsole: u32 = 0;

const WAVE_FORMAT_PCM: u16 = 1;

const WAVEFORMATEX = extern struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
};

const CLSID_MMDeviceEnumerator = GUID.parse("{BCDE0395-E52F-467C-8E3D-C4579291692E}");
const IID_IMMDeviceEnumerator = GUID.parse("{A95664D2-9614-4F35-A746-DE8DB63617E6}");
const IID_IAudioClient = GUID.parse("{1CB9AD4C-DBFA-4c32-B178-C2F568A703B2}");
const IID_IAudioRenderClient = GUID.parse("{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}");

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, **anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

const IMMDeviceEnumeratorVtbl = extern struct {
    base: IUnknownVtbl,
    EnumAudioEndpoints: *const anyopaque,
    GetDefaultAudioEndpoint: *const fn (*anyopaque, u32, u32, **anyopaque) callconv(.winapi) HRESULT,
    GetDevice: *const anyopaque,
    RegisterEndpointNotificationCallback: *const anyopaque,
    UnregisterEndpointNotificationCallback: *const anyopaque,
};

const IMMDeviceVtbl = extern struct {
    base: IUnknownVtbl,
    Activate: *const fn (*anyopaque, *const GUID, DWORD, ?*anyopaque, **anyopaque) callconv(.winapi) HRESULT,
    OpenPropertyStore: *const anyopaque,
    GetId: *const anyopaque,
    GetState: *const anyopaque,
};

const IAudioClientVtbl = extern struct {
    base: IUnknownVtbl,
    Initialize: *const fn (*anyopaque, u32, u32, REFERENCE_TIME, REFERENCE_TIME, *const WAVEFORMATEX, ?*const GUID) callconv(.winapi) HRESULT,
    GetBufferSize: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    GetStreamLatency: *const fn (*anyopaque, *REFERENCE_TIME) callconv(.winapi) HRESULT,
    GetCurrentPadding: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    IsFormatSupported: *const fn (*anyopaque, u32, *const WAVEFORMATEX, ?*?*WAVEFORMATEX) callconv(.winapi) HRESULT,
    GetMixFormat: *const fn (*anyopaque, **WAVEFORMATEX) callconv(.winapi) HRESULT,
    GetDevicePeriod: *const fn (*anyopaque, *REFERENCE_TIME, *REFERENCE_TIME) callconv(.winapi) HRESULT,
    Start: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    Stop: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    Reset: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    SetEventHandle: *const fn (*anyopaque, HANDLE) callconv(.winapi) HRESULT,
    GetService: *const fn (*anyopaque, *const GUID, **anyopaque) callconv(.winapi) HRESULT,
};

const IAudioRenderClientVtbl = extern struct {
    base: IUnknownVtbl,
    GetBuffer: *const fn (*anyopaque, u32, *[*]u8) callconv(.winapi) HRESULT,
    ReleaseBuffer: *const fn (*anyopaque, u32, u32) callconv(.winapi) HRESULT,
};

/// A COM object is a pointer to a pointer to a vtable. Wrapping the double indirection
/// once keeps every call site from repeating it and getting it wrong.
fn Com(comptime Vtbl: type) type {
    return struct {
        const Self = @This();
        ptr: *anyopaque,

        fn vt(self: Self) *const Vtbl {
            return @as(**const Vtbl, @ptrCast(@alignCast(self.ptr))).*;
        }
        fn release(self: Self) void {
            _ = self.vt().base.Release(self.ptr);
        }
    };
}

const Enumerator = Com(IMMDeviceEnumeratorVtbl);
const MMDevice = Com(IMMDeviceVtbl);
const AudioClient = Com(IAudioClientVtbl);
const RenderClient = Com(IAudioRenderClientVtbl);

extern "ole32" fn CoInitializeEx(?*anyopaque, DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(*const GUID, ?*anyopaque, DWORD, *const GUID, **anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;

extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;
extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) DWORD;
const WAIT_TIMEOUT: DWORD = 258;

/// MMCSS. Without it the callback is scheduled like any other thread and the deadline is
/// met "usually", which for audio is the same as not met.
extern "avrt" fn AvSetMmThreadCharacteristicsW([*:0]const u16, *DWORD) callconv(.winapi) ?HANDLE;
extern "avrt" fn AvRevertMmThreadCharacteristics(HANDLE) callconv(.winapi) BOOL;

/// Exposed because std removed thread sleep in 0.16 and a caller driving the device from
/// the main thread needs one. Not used by the render thread, which blocks on the endpoint
/// event instead — sleeping on an audio thread is how a stream glitches.
pub fn sleepMs(ms: u32) void {
    Sleep(ms);
}

// --- device ----------------------------------------------------------------

/// What the device is doing, readable from the game thread.
pub const Status = enum(u32) {
    stopped = 0,
    running = 1,
    /// The endpoint was invalidated — unplugged, disabled, or reconfigured. §4's
    /// `device_lost` for audio.
    device_lost = 2,
    failed = 3,
};

/// Counters the render thread publishes and the game thread reads. Atomic because they
/// genuinely cross threads; `monotonic` because a torn *count* is a cosmetic problem and
/// ordering them would cost the audio thread barriers it does not need.
pub const Telemetry = struct {
    /// Buffers handed to the endpoint.
    blocks: std.atomic.Value(u64) = .init(0),
    /// Frames rendered.
    frames: std.atomic.Value(u64) = .init(0),
    /// **Wakeups where the endpoint had less room than a full period.** The audio
    /// equivalent of a dropped frame, and the number §7's soak actually cares about: a
    /// nonzero value on a 45-minute run means the thread missed its deadline, which is
    /// audible, unlike a p99 frame time that is merely disappointing.
    underruns: std.atomic.Value(u64) = .init(0),
    /// `GetBuffer` failures other than invalidation.
    buffer_errors: std.atomic.Value(u64) = .init(0),
    status: std.atomic.Value(u32) = .init(@intFromEnum(Status.stopped)),
};

pub const Config = struct {
    sample_rate: u32 = 48_000,
    channels: u16 = 2,
    /// Requested buffer duration in 100 ns units. 30 ms is the shared-mode default region;
    /// asking for less in shared mode does not reduce latency, because the endpoint period
    /// is the engine's real quantum and it is set by the device.
    buffer_100ns: REFERENCE_TIME = 30 * 10_000,
};

pub const Device = struct {
    gpa: std.mem.Allocator,
    config: Config = .{},

    enumerator: ?Enumerator = null,
    endpoint: ?MMDevice = null,
    client: ?AudioClient = null,
    render: ?RenderClient = null,
    event: ?HANDLE = null,
    thread: ?std.Thread = null,

    /// Whether this device called `CoInitializeEx` successfully and therefore owes a
    /// `CoUninitialize`. A host that already initialized COM in a different apartment
    /// returns RPC_E_CHANGED_MODE, and calling `CoUninitialize` on that would decrement a
    /// refcount this code never incremented.
    com_owned: bool = false,

    /// Scratch the render thread mixes into, allocated once in `start`. i16 because that
    /// is what the mixer produces; conversion to the device format happens in the copy.
    scratch: []i16 = &.{},

    buffer_frames: u32 = 0,
    running: std.atomic.Value(bool) = .init(false),
    telemetry: Telemetry = .{},

    /// Not owned. Must outlive the device, and must not be touched by the game thread
    /// while `running` — the render thread owns it exclusively between start and stop.
    mixer: *mixer_mod.Mixer,
    ring: *audio_ring.Ring(256),

    pub fn init(
        gpa: std.mem.Allocator,
        m: *mixer_mod.Mixer,
        r: *audio_ring.Ring(256),
        config: Config,
    ) Device {
        return .{ .gpa = gpa, .mixer = m, .ring = r, .config = config };
    }

    /// Open the default render endpoint and begin the thread.
    ///
    /// Every failure here is recoverable by the caller: a machine with no audio device is
    /// a machine that should still run the game. §17 describes a mixer, not a requirement.
    pub fn start(self: *Device) Error!void {
        if (self.running.load(.acquire)) return;

        const hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        // S_FALSE means already initialized on this thread and we still owe an uninit;
        // RPC_E_CHANGED_MODE means someone else chose an apartment and we owe nothing.
        if (hr == RPC_E_CHANGED_MODE) {
            self.com_owned = false;
        } else if (hr == S_OK or hr == S_FALSE) {
            self.com_owned = true;
        } else {
            return Error.ComInitFailed;
        }
        errdefer self.uninitCom();

        var raw: *anyopaque = undefined;
        if (CoCreateInstance(&CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, &IID_IMMDeviceEnumerator, &raw) != S_OK) {
            return Error.NoDevice;
        }
        const enumerator: Enumerator = .{ .ptr = raw };
        errdefer enumerator.release();

        var dev_raw: *anyopaque = undefined;
        if (enumerator.vt().GetDefaultAudioEndpoint(enumerator.ptr, eRender, eConsole, &dev_raw) != S_OK) {
            return Error.NoDevice;
        }
        const endpoint: MMDevice = .{ .ptr = dev_raw };
        errdefer endpoint.release();

        var client_raw: *anyopaque = undefined;
        if (endpoint.vt().Activate(endpoint.ptr, &IID_IAudioClient, CLSCTX_ALL, null, &client_raw) != S_OK) {
            return Error.NoDevice;
        }
        const client: AudioClient = .{ .ptr = client_raw };
        errdefer client.release();

        // 16-bit PCM at the requested rate, with the OS resampling and converting.
        //
        // AUTOCONVERTPCM is what makes this legitimate rather than a hope: without it,
        // shared mode requires the endpoint's exact mix format — commonly 32-bit float at
        // whatever rate the user picked — and Initialize simply fails on any machine that
        // is not set to 48 kHz. With it, the engine keeps one integer format everywhere
        // and the OS does the conversion in the same pass it already does for mixing.
        var fmt: WAVEFORMATEX = .{
            .wFormatTag = WAVE_FORMAT_PCM,
            .nChannels = self.config.channels,
            .nSamplesPerSec = self.config.sample_rate,
            .nAvgBytesPerSec = self.config.sample_rate * self.config.channels * 2,
            .nBlockAlign = self.config.channels * 2,
            .wBitsPerSample = 16,
            .cbSize = 0,
        };

        const flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;

        if (client.vt().Initialize(client.ptr, AUDCLNT_SHAREMODE_SHARED, flags, self.config.buffer_100ns, 0, &fmt, null) != S_OK) {
            return Error.ClientInitFailed;
        }

        var frames: u32 = 0;
        if (client.vt().GetBufferSize(client.ptr, &frames) != S_OK) return Error.ClientInitFailed;

        const ev = CreateEventW(null, 0, 0, null) orelse return Error.ClientInitFailed;
        errdefer windows.CloseHandle(ev);
        if (client.vt().SetEventHandle(client.ptr, ev) != S_OK) return Error.ClientInitFailed;

        var render_raw: *anyopaque = undefined;
        if (client.vt().GetService(client.ptr, &IID_IAudioRenderClient, &render_raw) != S_OK) {
            return Error.ClientInitFailed;
        }
        const render: RenderClient = .{ .ptr = render_raw };
        errdefer render.release();

        // Allocated here, never on the render thread. §18.8, and stricter: the render
        // thread's deadline does not survive a page fault from a fresh allocation.
        self.scratch = self.gpa.alloc(i16, frames * self.config.channels) catch return Error.ClientInitFailed;
        errdefer self.gpa.free(self.scratch);

        self.enumerator = enumerator;
        self.endpoint = endpoint;
        self.client = client;
        self.render = render;
        self.event = ev;
        self.buffer_frames = frames;
        self.running.store(true, .release);
        self.telemetry.status.store(@intFromEnum(Status.running), .monotonic);

        // Prime the endpoint with silence before starting.
        //
        // Starting with an empty buffer means the first wakeup is already late: the
        // endpoint consumes while the thread is still being scheduled for the first time,
        // and the result is a click on every single stream start.
        self.primeSilence();

        if (client.vt().Start(client.ptr) != S_OK) {
            self.running.store(false, .release);
            return Error.StartFailed;
        }

        self.thread = std.Thread.spawn(.{}, renderLoop, .{self}) catch {
            _ = client.vt().Stop(client.ptr);
            self.running.store(false, .release);
            return Error.ThreadFailed;
        };
    }

    fn primeSilence(self: *Device) void {
        const render = self.render orelse return;
        var ptr: [*]u8 = undefined;
        if (render.vt().GetBuffer(render.ptr, self.buffer_frames, &ptr) != S_OK) return;
        const bytes = self.buffer_frames * self.config.channels * 2;
        @memset(ptr[0..bytes], 0);
        _ = render.vt().ReleaseBuffer(render.ptr, self.buffer_frames, 0);
    }

    pub fn stop(self: *Device) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);

        // Wake the thread so it observes the flag instead of blocking out its full timeout.
        if (self.event) |ev| _ = SetEvent(ev);
        if (self.thread) |t| t.join();
        self.thread = null;

        if (self.client) |c| _ = c.vt().Stop(c.ptr);
        self.telemetry.status.store(@intFromEnum(Status.stopped), .monotonic);
    }

    pub fn deinit(self: *Device) void {
        self.stop();
        if (self.render) |r| r.release();
        if (self.client) |c| c.release();
        if (self.endpoint) |e| e.release();
        if (self.enumerator) |e| e.release();
        if (self.event) |ev| windows.CloseHandle(ev);
        if (self.scratch.len > 0) self.gpa.free(self.scratch);
        self.uninitCom();
        self.* = undefined;
    }

    fn uninitCom(self: *Device) void {
        if (self.com_owned) {
            CoUninitialize();
            self.com_owned = false;
        }
    }

    pub fn status(self: *const Device) Status {
        return @enumFromInt(self.telemetry.status.load(.monotonic));
    }
};

/// The render thread. Everything it touches was allocated before it started.
fn renderLoop(dev: *Device) void {
    // The render thread needs its own COM apartment; the one `start` entered belongs to
    // the calling thread. Not fatal if it fails — nothing on this thread creates COM
    // objects, it only calls methods on ones the game thread already made.
    _ = CoInitializeEx(null, COINIT_MULTITHREADED);
    defer CoUninitialize();

    // MMCSS. A failure is survivable and worth surviving: the stream still plays, it is
    // just more likely to glitch under load.
    var task_index: DWORD = 0;
    const mmcss = AvSetMmThreadCharacteristicsW(std.unicode.utf8ToUtf16LeStringLiteral("Pro Audio"), &task_index);
    defer if (mmcss) |h| {
        _ = AvRevertMmThreadCharacteristics(h);
    };

    const client = dev.client.?;
    const render = dev.render.?;
    const event = dev.event.?;
    const channels = dev.config.channels;

    while (dev.running.load(.acquire)) {
        // 200 ms rather than INFINITE: a device that stops signalling must not wedge the
        // thread forever, because `stop` then blocks in `join` and takes the whole
        // shutdown with it.
        const wait = WaitForSingleObject(event, 200);
        if (wait == WAIT_TIMEOUT) continue;
        if (!dev.running.load(.acquire)) break;

        var padding: u32 = 0;
        const hr = client.vt().GetCurrentPadding(client.ptr, &padding);
        if (hr == AUDCLNT_E_DEVICE_INVALIDATED) {
            dev.telemetry.status.store(@intFromEnum(Status.device_lost), .monotonic);
            return;
        }
        if (hr != S_OK) {
            _ = dev.telemetry.buffer_errors.fetchAdd(1, .monotonic);
            continue;
        }

        const available = dev.buffer_frames - padding;
        if (available == 0) continue;

        var ptr: [*]u8 = undefined;
        const bhr = render.vt().GetBuffer(render.ptr, available, &ptr);
        if (bhr == AUDCLNT_E_DEVICE_INVALIDATED) {
            dev.telemetry.status.store(@intFromEnum(Status.device_lost), .monotonic);
            return;
        }
        if (bhr != S_OK) {
            _ = dev.telemetry.buffer_errors.fetchAdd(1, .monotonic);
            continue;
        }

        const samples = available * channels;
        dev.mixer.render(dev.ring, dev.scratch[0..samples]);

        // i16 to the endpoint's i16, so a copy rather than a conversion. `@memcpy` over a
        // byte-cast rather than a typed store loop because the endpoint buffer has no
        // alignment guarantee stronger than 1.
        @memcpy(ptr[0 .. samples * 2], std.mem.sliceAsBytes(dev.scratch[0..samples]));
        _ = render.vt().ReleaseBuffer(render.ptr, available, 0);

        _ = dev.telemetry.blocks.fetchAdd(1, .monotonic);
        _ = dev.telemetry.frames.fetchAdd(available, .monotonic);

        // Starvation is measured by PADDING, not by free space.
        //
        // `padding` is what the endpoint still has queued. Low padding means it is about
        // to run dry — the deadline was met barely or not at all. `available` is the
        // complement, so a *small* `available` means the endpoint is still nearly full,
        // which is the healthy case; keying off it counts underruns exactly when there
        // are none. Counted rather than logged because this thread cannot format a
        // string, and the padding was read before the mix so it reflects the wakeup.
        if (padding < dev.buffer_frames / 8) {
            _ = dev.telemetry.underruns.fetchAdd(1, .monotonic);
        }
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a device with no endpoint fails cleanly rather than trapping" {
    // CI runners have no audio endpoint, and neither does a headless session. §17
    // describes a mixer, not a requirement: a machine with no device must still run the
    // game. This test asserts the failure is an error value and that deinit after a
    // failed start does not double-free.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var m: mixer_mod.Mixer = .empty;
    var ring: audio_ring.Ring(256) = .empty;
    var dev = Device.init(testing.allocator, &m, &ring, .{});
    defer dev.deinit();

    dev.start() catch |err| {
        try testing.expect(err == Error.NoDevice or
            err == Error.ComInitFailed or
            err == Error.ClientInitFailed or
            err == Error.StartFailed);
        return;
    };

    // A device DID open, which is the interesting case on a developer machine. Let it run
    // long enough for the endpoint to signal, then assert it actually produced audio
    // rather than merely reporting that it started.
    try testing.expectEqual(Status.running, dev.status());
    Sleep(120);

    try testing.expect(dev.telemetry.blocks.load(.monotonic) > 0);
    try testing.expect(dev.telemetry.frames.load(.monotonic) > 0);
    try testing.expectEqual(@as(u64, 0), dev.telemetry.buffer_errors.load(.monotonic));

    dev.stop();
    try testing.expectEqual(Status.stopped, dev.status());
}

test "stop is idempotent and safe before start" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var m: mixer_mod.Mixer = .empty;
    var ring: audio_ring.Ring(256) = .empty;
    var dev = Device.init(testing.allocator, &m, &ring, .{});
    defer dev.deinit();

    dev.stop();
    dev.stop();
    try testing.expectEqual(Status.stopped, dev.status());
}
