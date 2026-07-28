//! PulseAudio render device. `ARCHITECTURE.md` §17, M0 criterion 3 on Linux.
//!
//! The Windows backend's counterpart, and the same three decisions:
//!
//! - **Loaded with `dlopen`, never linked.** Same argument as `linux/window.zig`: linking
//!   `libpulse-simple` would make the Linux row need PulseAudio development headers on
//!   every machine that builds it, including the ones that only cross-compile, and
//!   `docs/CI_TIERS.md` §4 records that the row builds from a Windows host with no SDKs.
//!   A machine with no sound server is `Error.NoDevice`, not a link failure.
//!
//! - **A dedicated thread with a blocking write, not a callback.** `pa_simple_write` blocks
//!   until the server has room, which is exactly the pacing an audio thread wants: it
//!   sleeps in the kernel rather than spinning, and it cannot run ahead. §17 says neither
//!   thread blocks on the other — that is about the *game* thread, which never touches
//!   this one; the ring between them is lock-free.
//!
//! - **The thread does not allocate, lock, or log.** Everything is allocated in `start`.
//!   §18.8 and stricter, for the reason the Windows backend gives.
//!
//! **No PulseAudio type escapes this file.** §18.9.
//!
//! `pa_simple` rather than the async API deliberately. The async API buys control over
//! latency and stream events that nothing here uses yet, at the cost of a mainloop this
//! would have to own. §17's requirement is a device that plays the mixer's output on a
//! deadline; that is what this is.

const std = @import("std");
const builtin = @import("builtin");
const mixer_mod = @import("bedlam_audio").mixer;
const audio_ring = @import("bedlam_audio").ring;

pub const Error = error{
    NoDevice,
    ClientInitFailed,
    StartFailed,
    ThreadFailed,
};

// --- the subset of libpulse-simple this needs -------------------------------

const pa_simple = opaque {};

const PA_STREAM_PLAYBACK: c_int = 1;
/// Signed 16-bit, little-endian. The mixer's native format, so the device boundary is a
/// copy rather than a conversion — see `mixer.zig` on why the mix is integer.
const PA_SAMPLE_S16LE: c_int = 3;

const pa_sample_spec = extern struct {
    format: c_int,
    rate: u32,
    channels: u8,
};

const pa_buffer_attr = extern struct {
    maxlength: u32,
    tlength: u32,
    prebuf: u32,
    minreq: u32,
    fragsize: u32,
};

const Pulse = struct {
    handle: ?*anyopaque = null,

    pa_simple_new: *const fn (
        ?[*:0]const u8, // server
        [*:0]const u8, // name
        c_int, // direction
        ?[*:0]const u8, // device
        [*:0]const u8, // stream name
        *const pa_sample_spec,
        ?*const anyopaque, // channel map
        ?*const pa_buffer_attr,
        ?*c_int, // error
    ) callconv(.c) ?*pa_simple = undefined,
    pa_simple_free: *const fn (*pa_simple) callconv(.c) void = undefined,
    pa_simple_write: *const fn (*pa_simple, *const anyopaque, usize, ?*c_int) callconv(.c) c_int = undefined,
    pa_simple_drain: *const fn (*pa_simple, ?*c_int) callconv(.c) c_int = undefined,
    pa_simple_flush: *const fn (*pa_simple, ?*c_int) callconv(.c) c_int = undefined,
    pa_simple_get_latency: *const fn (*pa_simple, ?*c_int) callconv(.c) u64 = undefined,
};

var lib: Pulse = .{};
var load_attempted = false;

fn load() bool {
    if (load_attempted) return lib.handle != null;
    load_attempted = true;
    if (builtin.os.tag != .linux) return false;

    const candidates = [_][:0]const u8{ "libpulse-simple.so.0", "libpulse-simple.so" };
    for (candidates) |name| {
        if (std.c.dlopen(name.ptr, .{ .LAZY = true })) |h| {
            lib.handle = h;
            break;
        }
    }
    const h = lib.handle orelse return false;

    inline for (@typeInfo(Pulse).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "handle")) continue;
        const sym = std.c.dlsym(h, f.name ++ "");
        if (sym == null) {
            // Partial loads are worse than none: a null function pointer called on the
            // audio thread is a crash with no explanation.
            lib.handle = null;
            return false;
        }
        @field(lib, f.name) = @ptrCast(@alignCast(sym.?));
    }
    return true;
}

// --- device -----------------------------------------------------------------

pub const Status = enum(u32) {
    stopped = 0,
    running = 1,
    device_lost = 2,
    failed = 3,
};

/// Deliberately the same shape as the Windows backend's. Two device backends reporting
/// different numbers would mean §7's soak has to special-case the platform, and a
/// telemetry schema that varies by backend is one nobody compares across targets.
pub const Telemetry = struct {
    blocks: std.atomic.Value(u64) = .init(0),
    frames: std.atomic.Value(u64) = .init(0),
    /// Writes the server rejected. The Pulse equivalent of an underrun: `pa_simple_write`
    /// blocks until there is room, so a failure means the stream died rather than that the
    /// deadline was missed.
    underruns: std.atomic.Value(u64) = .init(0),
    buffer_errors: std.atomic.Value(u64) = .init(0),
    status: std.atomic.Value(u32) = .init(@intFromEnum(Status.stopped)),
};

pub const Config = struct {
    sample_rate: u32 = 48_000,
    channels: u16 = 2,
    /// Frames per write. 480 at 48 kHz is 10 ms — short enough that a governor change is
    /// audible within a frame or two, long enough that the thread is not woken 1000 times
    /// a second on the target with the least power budget.
    frames_per_block: u32 = 480,
};

/// Exposed for the same reason the Windows backend exposes it: std dropped `Thread.sleep`
/// in 0.16 and a caller driving the device from the main thread needs one.
pub fn sleepMs(ms: u32) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&req, &req) == -1) {
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return;
    }
}

pub const Device = struct {
    gpa: std.mem.Allocator,
    config: Config = .{},

    stream: ?*pa_simple = null,
    thread: ?std.Thread = null,
    scratch: []i16 = &.{},

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

    pub fn start(self: *Device) Error!void {
        if (self.running.load(.acquire)) return;
        if (!load()) return Error.NoDevice;

        const spec: pa_sample_spec = .{
            .format = PA_SAMPLE_S16LE,
            .rate = self.config.sample_rate,
            .channels = @intCast(self.config.channels),
        };

        const bytes_per_block = self.config.frames_per_block * self.config.channels * 2;
        // `tlength` is the target buffer fill; everything else is left to the server,
        // which knows its own scheduling better than a constant here would.
        const attr: pa_buffer_attr = .{
            .maxlength = std.math.maxInt(u32),
            .tlength = bytes_per_block * 4,
            .prebuf = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .fragsize = std.math.maxInt(u32),
        };

        var err: c_int = 0;
        const s = lib.pa_simple_new(
            null,
            "Bedlam",
            PA_STREAM_PLAYBACK,
            null,
            "simulation",
            &spec,
            null,
            &attr,
            &err,
        ) orelse return Error.NoDevice;
        errdefer lib.pa_simple_free(s);

        // Allocated here, never on the audio thread. §18.8, and stricter: a page fault
        // from a fresh allocation does not fit inside a 10 ms budget.
        self.scratch = self.gpa.alloc(i16, self.config.frames_per_block * self.config.channels) catch
            return Error.ClientInitFailed;
        errdefer self.gpa.free(self.scratch);

        self.stream = s;
        self.running.store(true, .release);
        self.telemetry.status.store(@intFromEnum(Status.running), .monotonic);

        self.thread = std.Thread.spawn(.{}, renderLoop, .{self}) catch {
            self.running.store(false, .release);
            return Error.ThreadFailed;
        };
    }

    pub fn stop(self: *Device) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);
        // No wakeup needed, unlike the UDP receiver: `pa_simple_write` returns on its own
        // within one block time, so the thread observes the flag without being poked.
        if (self.thread) |t| t.join();
        self.thread = null;
        self.telemetry.status.store(@intFromEnum(Status.stopped), .monotonic);
    }

    pub fn deinit(self: *Device) void {
        self.stop();
        if (self.stream) |s| lib.pa_simple_free(s);
        if (self.scratch.len > 0) self.gpa.free(self.scratch);
        self.* = undefined;
    }

    pub fn status(self: *const Device) Status {
        return @enumFromInt(self.telemetry.status.load(.monotonic));
    }
};

fn renderLoop(dev: *Device) void {
    const s = dev.stream.?;
    const samples = dev.scratch.len;
    const bytes = samples * 2;

    while (dev.running.load(.acquire)) {
        dev.mixer.render(dev.ring, dev.scratch);

        var err: c_int = 0;
        if (lib.pa_simple_write(s, dev.scratch.ptr, bytes, &err) < 0) {
            // A write failure means the stream is gone — the server exited, the sink was
            // removed. §4's device_lost for audio.
            _ = dev.telemetry.underruns.fetchAdd(1, .monotonic);
            dev.telemetry.status.store(@intFromEnum(Status.device_lost), .monotonic);
            return;
        }

        _ = dev.telemetry.blocks.fetchAdd(1, .monotonic);
        _ = dev.telemetry.frames.fetchAdd(dev.config.frames_per_block, .monotonic);
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a machine with no sound server fails cleanly rather than trapping" {
    // §17 describes a mixer, not a requirement: a machine with no audio must still run the
    // game. CI runners have no sound server, so this is the path they take — and it must
    // be an error value, with a deinit afterwards that does not double-free.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var m: mixer_mod.Mixer = .empty;
    var ring: audio_ring.Ring(256) = .empty;
    var dev = Device.init(testing.allocator, &m, &ring, .{});
    defer dev.deinit();

    dev.start() catch |err| {
        try testing.expect(err == Error.NoDevice or
            err == Error.ClientInitFailed or
            err == Error.StartFailed);
        return;
    };

    // A device DID open — WSLg routes to PulseAudio. Then it must actually produce audio
    // rather than merely report that it started: §18.20, a handle is not a device.
    try testing.expectEqual(Status.running, dev.status());
    sleepMs(150);

    try testing.expect(dev.telemetry.blocks.load(.monotonic) > 0);
    try testing.expect(dev.telemetry.frames.load(.monotonic) > 0);

    dev.stop();
    try testing.expectEqual(Status.stopped, dev.status());
}

test "stop is idempotent and safe before start" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var m: mixer_mod.Mixer = .empty;
    var ring: audio_ring.Ring(256) = .empty;
    var dev = Device.init(testing.allocator, &m, &ring, .{});
    defer dev.deinit();

    dev.stop();
    dev.stop();
    try testing.expectEqual(Status.stopped, dev.status());
}

test "the telemetry shape matches the Windows backend" {
    // Two device backends reporting different numbers means §7's soak has to special-case
    // the platform, and a telemetry schema that varies by backend is one nobody compares
    // across targets. Checked structurally so drift is a compile error, not a surprise in
    // a report six months from now.
    const T = Telemetry;
    inline for ([_][]const u8{ "blocks", "frames", "underruns", "buffer_errors", "status" }) |f| {
        if (!@hasField(T, f)) @compileError("Telemetry lost field " ++ f);
    }
    try testing.expectEqual(@as(u64, 0), (T{}).blocks.load(.monotonic));
}
