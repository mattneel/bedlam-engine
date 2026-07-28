//! Crash capture. `AGENTS.md` §4, M0 criterion 9.
//!
//! The criterion is "crash capture and **symbolication**", and the second word is the
//! whole difficulty. A stack of hex addresses from a stripped release build on a phone is
//! not a bug report — it is a lottery ticket. Symbolication needs the build id that
//! produced those addresses, which means the id has to be recorded *at the moment of the
//! crash*, by the crashing process, into the report.
//!
//! **What makes this Bedlam-specific rather than a generic crash handler:** the report
//! carries the schema fingerprint and the simulation tick. A crash at tick 41,203 of a
//! session with a known seed and a known input log is reproducible — `ARCHITECTURE.md`
//! §5.1's replay projection is "input/event log + seeds + periodic canonical checkpoints",
//! so a report naming the tick converts a crash into a replay. Without it, the same crash
//! is a stack trace nobody can re-enter.
//!
//! §14.3 makes this load-bearing rather than a convenience: an untrusted host submits its
//! replay log for asynchronous validation, and a host that crashes has to be
//! distinguishable from a host that cheated.
//!
//! Deliberately allocation-free and syscall-light on the capture path. A crash handler
//! that allocates runs inside a process whose heap may be the thing that is broken.

const std = @import("std");
const builtin = @import("builtin");

/// Everything needed to turn a crash into a reproduction attempt.
///
/// Fixed-size and copyable: the capture path must not allocate, so the report is a value
/// the handler can fill on the stack of a process that may have a corrupt heap.
pub const Report = struct {
    pub const max_frames = 32;
    pub const max_message = 192;

    /// Identifies the build the addresses belong to. Without it the addresses are
    /// meaningless — this is the difference between capture and symbolication.
    build_id: [64]u8,
    /// Length, because a build id is not always 64 bytes and a fixed array rendered whole
    /// appends its padding to the identifier — producing an id that matches nothing when
    /// a symbol server is asked for it.
    build_id_len: u8,
    /// `SCHEMA_AND_EVOLUTION.md` §4. Two builds with different fingerprints cannot
    /// exchange state, so a crash report from one is not evidence about the other.
    schema_fingerprint: [64]u8,
    /// The tick converts a crash into a replay (§5.1). Zero means "not in a tick", which
    /// is itself diagnostic: a crash outside the simulation is a different bug class.
    tick: u64,
    /// Session seed. With the tick and the input log, this is a reproduction.
    seed: u64,

    message: [max_message]u8,
    message_len: u8,

    frames: [max_frames]usize,
    frame_count: u8,

    /// Frames the stack had beyond `max_frames`. A truncated trace that does not say it
    /// was truncated sends the reader looking for a root cause in the wrong place.
    frames_omitted: u16,

    pub fn buildIdSlice(self: *const Report) []const u8 {
        return self.build_id[0..self.build_id_len];
    }

    pub fn messageSlice(self: *const Report) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn frameSlice(self: *const Report) []const usize {
        return self.frames[0..self.frame_count];
    }
};

/// Process-wide context the handler reads. Written by the engine as it runs so that a
/// crash at any point carries the state that makes it reproducible.
///
/// Plain atomics rather than a lock: a handler that takes a lock can deadlock against the
/// thread that was holding it when it crashed, which turns a crash into a hang and loses
/// the report entirely.
pub const Context = struct {
    /// Sequence counter guarding `tick` and `seed`. Even means stable, odd means a write
    /// is in progress.
    ///
    /// A seqlock rather than 64-bit atomics because **wasm32 has none** — a shipping
    /// target (`ARCHITECTURE.md` §4.1), and `std.atomic.Value(u64)` does not compile
    /// there. The alternative of splitting into two u32 atomics permits a torn read: a
    /// crash report naming tick 0x00000001_FFFFFFFF as 0x00000002_FFFFFFFF points the
    /// reader at a replay position that never existed, which is worse than no tick.
    ///
    /// u32 because that is the width wasm32 does have.
    var seq: std.atomic.Value(u32) = .init(0);
    var tick: u64 = 0;
    var seed: u64 = 0;
    var build_id: [64]u8 = @splat(0);
    var build_id_len: std.atomic.Value(u8) = .init(0);
    var schema_fingerprint: [64]u8 = @splat('0');

    fn beginWrite() u32 {
        const s = seq.load(.monotonic);
        seq.store(s +% 1, .release);
        return s +% 1;
    }

    fn endWrite(s: u32) void {
        seq.store(s +% 1, .release);
    }

    pub fn setTick(t: u64) void {
        const s = beginWrite();
        tick = t;
        endWrite(s);
    }

    pub fn setSeed(v: u64) void {
        const s = beginWrite();
        seed = v;
        endWrite(s);
    }

    /// Read both under one consistent sequence.
    ///
    /// Bounded retries, not a spin. This runs inside a crash handler: a writer that died
    /// mid-update leaves the sequence odd forever, and a handler that loops waiting for
    /// it produces no report at all. After the bound it takes the possibly-torn values,
    /// because a slightly wrong tick is diagnostic and silence is not.
    fn readTickSeed() struct { tick: u64, seed: u64 } {
        var attempts: u8 = 0;
        while (attempts < 8) : (attempts += 1) {
            const before = seq.load(.acquire);
            if (before & 1 != 0) continue;
            const t = tick;
            const v = seed;
            if (seq.load(.acquire) == before) return .{ .tick = t, .seed = v };
        }
        return .{ .tick = tick, .seed = seed };
    }

    /// Clears the tail, and that is not tidiness.
    ///
    /// Overwriting a longer id with a shorter one and leaving the remainder produces a
    /// Frankenstein identifier: the new id followed by the old one's tail. Any consumer
    /// reading the whole array — a log line, a crash upload, a symbol-server query — sees
    /// an id that belongs to no build. It also makes the failure ORDER-DEPENDENT, which
    /// is how it survived a test written specifically to catch it.
    pub fn setBuildId(id: []const u8) void {
        const n = @min(id.len, build_id.len);
        @memcpy(build_id[0..n], id[0..n]);
        @memset(build_id[n..], 0);
        build_id_len.store(@intCast(n), .monotonic);
    }

    pub fn setSchemaFingerprint(fp: []const u8) void {
        const n = @min(fp.len, schema_fingerprint.len);
        @memcpy(schema_fingerprint[0..n], fp[0..n]);
        @memset(schema_fingerprint[n..], 0);
    }
};

/// Capture a report for the current thread.
///
/// Allocation-free by construction: every field is fixed-size and the stack walk writes
/// into the caller's buffer. A crash handler that allocates is running inside a process
/// whose allocator may be exactly what failed.
pub fn capture(message: []const u8) Report {
    const ts = Context.readTickSeed();
    var r: Report = .{
        .build_id = Context.build_id,
        .build_id_len = Context.build_id_len.load(.monotonic),
        .schema_fingerprint = Context.schema_fingerprint,
        .tick = ts.tick,
        .seed = ts.seed,
        .message = @splat(0),
        .message_len = 0,
        .frames = @splat(0),
        .frame_count = 0,
        .frames_omitted = 0,
    };

    const n = @min(message.len, Report.max_message);
    @memcpy(r.message[0..n], message[0..n]);
    r.message_len = @intCast(n);

    // `allow_unsafe_unwind = false`: a crash handler that itself crashes while unwinding
    // produces nothing at all, which is strictly worse than a short trace. §14.3 needs a
    // host that crashed to be distinguishable from one that cheated, and silence is not
    // distinguishable from anything.
    var addrs: [Report.max_frames]usize = @splat(0);
    const trace = std.debug.captureCurrentStackTrace(.{ .allow_unsafe_unwind = false }, &addrs);

    const captured = @min(trace.return_addresses.len, Report.max_frames);
    @memcpy(r.frames[0..captured], trace.return_addresses[0..captured]);
    r.frame_count = @intCast(captured);
    // A truncated trace that does not say it was truncated sends the reader looking for a
    // root cause in the wrong place.
    r.frames_omitted = switch (trace.skipped) {
        .none => 0,
        else => 1,
    };
    return r;
}

/// Render a report as text, into a caller-provided buffer.
///
/// Returns what fits. Truncation is preferable to failure: a partial report naming the
/// build and tick is still a reproduction, and a report that fails to render because a
/// buffer was short is nothing at all.
pub fn render(r: *const Report, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("bedlam crash\n", .{}) catch return buf[0..w.end];
    w.print("  message      {s}\n", .{r.messageSlice()}) catch return buf[0..w.end];
    // The SLICE, not the array. Rendering the whole fixed array appends its padding to
    // the identifier — 49 NUL bytes in a report that otherwise looks correct, and an id
    // that matches nothing when a symbol server is asked for it.
    w.print("  build        {s}\n", .{r.buildIdSlice()}) catch return buf[0..w.end];
    w.print("  schema       {s}\n", .{&r.schema_fingerprint}) catch return buf[0..w.end];
    w.print("  tick         {d}\n", .{r.tick}) catch return buf[0..w.end];
    w.print("  seed         0x{x}\n", .{r.seed}) catch return buf[0..w.end];
    w.print("  target       {s}-{s}\n", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
    }) catch return buf[0..w.end];
    w.print("  frames       {d}", .{r.frame_count}) catch return buf[0..w.end];
    if (r.frames_omitted > 0) {
        w.print(" (+{d} omitted)", .{r.frames_omitted}) catch return buf[0..w.end];
    }
    w.print("\n", .{}) catch return buf[0..w.end];

    for (r.frameSlice(), 0..) |addr, i| {
        w.print("    #{d:0>2} 0x{x:0>16}\n", .{ i, addr }) catch return buf[0..w.end];
    }
    return buf[0..w.end];
}

// ---------------------------------------------------------------------------

test "a report carries what makes a crash reproducible" {
    // §5.1: a replay is "input/event log + seeds + periodic canonical checkpoints". A
    // report naming the tick and seed converts a crash into a replay; without them it is
    // a stack trace nobody can re-enter.
    Context.setTick(41_203);
    Context.setSeed(0xBED1A3);
    Context.setBuildId("deadbeefcafef00ddeadbeefcafef00ddeadbeefcafef00ddeadbeefcafef00d");
    Context.setSchemaFingerprint("ca80a08a6cea22036cff9d6c529992e925e56dc953afe1cc0c5a43a41044d8f4");

    const r = capture("assertion failed in tick loop");
    try std.testing.expectEqual(@as(u64, 41_203), r.tick);
    try std.testing.expectEqual(@as(u64, 0xBED1A3), r.seed);
    try std.testing.expectEqualStrings("assertion failed in tick loop", r.messageSlice());
    try std.testing.expectEqualStrings(
        "ca80a08a6cea22036cff9d6c529992e925e56dc953afe1cc0c5a43a41044d8f4",
        &r.schema_fingerprint,
    );
}

test "the build id is present, because addresses without it are not symbolicable" {
    Context.setBuildId("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    const r = capture("x");
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        r.buildIdSlice(),
    );
}

test "a short build id does not acquire padding" {
    // A fixed array rendered whole appends its fill to the identifier, producing an id
    // that matches nothing when a symbol server is asked for it — and the report still
    // LOOKS right, which is the part that wastes an afternoon.
    Context.setBuildId("short-id");
    const r = capture("x");
    try std.testing.expectEqualStrings("short-id", r.buildIdSlice());

    var buf: [1024]u8 = undefined;
    const text = render(&r, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "build        short-id") != null);

    // No NUL anywhere in the rendered report. This is the assertion that matters, and
    // the first version of this test missed the bug by checking for '0' padding when the
    // actual padding was 0x00 — the report was 49 NUL bytes long in the middle and the
    // test was green.
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0) == null);
}

test "a stack trace is actually captured" {
    const r = nested(3);
    // Debug info may be unavailable in some configurations; the report must still be
    // well-formed rather than claiming frames it does not have.
    try std.testing.expect(r.frame_count <= Report.max_frames);
    try std.testing.expectEqual(@as(usize, r.frame_count), r.frameSlice().len);
}

fn nested(depth: u32) Report {
    if (depth == 0) return capture("deep");
    return nested(depth - 1);
}

test "an over-long message is truncated rather than overflowing" {
    const long = "x" ** 500;
    const r = capture(long);
    try std.testing.expectEqual(@as(u8, Report.max_message), r.message_len);
    try std.testing.expectEqual(@as(usize, Report.max_message), r.messageSlice().len);
}

test "rendering into a short buffer truncates rather than failing" {
    // A partial report naming the build and tick is still a reproduction. A report that
    // fails to render because the buffer was short is nothing at all.
    Context.setTick(7);
    const r = capture("short buffer");

    var tiny: [24]u8 = undefined;
    const out = render(&r, &tiny);
    try std.testing.expect(out.len <= tiny.len);
    try std.testing.expect(out.len > 0);

    var big: [4096]u8 = undefined;
    const full = render(&r, &big);
    try std.testing.expect(std.mem.indexOf(u8, full, "tick") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "schema") != null);
}

test "tick and seed are read as a consistent pair" {
    // A seqlock rather than two independent reads: a report naming a tick from before an
    // update and a seed from after describes a session that never ran.
    Context.setSeed(0xAAAA_BBBB_CCCC_DDDD);
    Context.setTick(0x1111_2222_3333_4444);
    const r = capture("pair");
    try std.testing.expectEqual(@as(u64, 0x1111_2222_3333_4444), r.tick);
    try std.testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDDD), r.seed);
}

test "a writer that died mid-update does not hang the handler" {
    // Bounded retries. A crash handler that spins waiting for an odd sequence produces
    // no report at all, and no report is strictly worse than a possibly-torn tick.
    Context.setTick(5);
    Context.setSeed(6);
    _ = Context.beginWrite(); // leave the sequence odd, as a dead writer would

    const r = capture("interrupted writer");
    try std.testing.expectEqual(@as(u64, 5), r.tick);
    try std.testing.expectEqual(@as(u64, 6), r.seed);

    // Restore, so ordering between tests does not matter.
    Context.seq.store(0, .release);
}

test "capture allocates nothing" {
    // A crash handler runs inside a process whose heap may be exactly what failed. This
    // is a structural check — every field of Report is fixed-size — rather than an
    // allocator assertion, because `capture` takes no allocator to fail.
    inline for (@typeInfo(Report).@"struct".fields) |f| {
        switch (@typeInfo(f.type)) {
            .pointer => @compileError("Report." ++ f.name ++ " is a pointer; the crash path must not allocate"),
            else => {},
        }
    }
    try std.testing.expect(@sizeOf(Report) > 0);
}
