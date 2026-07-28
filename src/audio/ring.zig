//! Lock-free command queue, game thread to audio thread.
//!
//! `ARCHITECTURE.md` §17: "Lock-free command queue from game thread to audio thread.
//! Neither blocks on the other."
//!
//! That sentence is a hard requirement rather than a performance note, and the reason is
//! asymmetric. The audio thread has a deadline measured in single-digit milliseconds — the
//! Web target's AudioWorklet quantum is 128 samples, which at 48 kHz is 2.67 ms — and
//! missing it produces an audible glitch, not a dropped frame. A mutex here means the
//! audio thread can be blocked by whatever the game thread is doing, including a page
//! fault or a scheduler preemption it has no control over.
//!
//! So: a single-producer single-consumer ring with no locks and no allocation. SPSC
//! specifically, because it is the only configuration where correctness needs just two
//! atomics with acquire/release ordering and no compare-exchange loop — and a CAS loop on
//! the audio thread is unbounded work on a bounded deadline.
//!
//! **Overrun drops the newest command and says so.** The alternative is blocking the
//! producer, which turns an audio-thread problem into a frame-loop stall and violates
//! §18.8 as well. A dropped "start this sound" is a missing sound; a stalled frame loop
//! is a missed tick, and §7 does not permit tick cadence to vary.

const std = @import("std");

/// Commands the mixer understands. Deliberately small and copyable — anything requiring
/// allocation or a pointer into game state is the wrong shape for this queue, because the
/// audio thread may consume it long after the producer moved on.
pub const Command = union(enum) {
    /// Begin a voice. `asset` is a content-addressed id, not a pointer: §11's content
    /// pipeline is content-addressed, and a pointer would race with asset streaming.
    play: struct { voice: u16, asset: u32, gain_q16: u16 },
    stop: struct { voice: u16 },
    set_gain: struct { voice: u16, gain_q16: u16 },
    /// §17: HRTF spatialization. Position is fixed-point for the same reason the
    /// simulation is — this value can originate from a replayed tick.
    set_position: struct { voice: u16, x: i32, y: i32, z: i32 },
    /// §17's "governors must be aware of each other": the render-quality governor freeing
    /// headroom is pointless if voice spatialization immediately consumes it, so the
    /// audio thread is told its budget rather than inferring one.
    set_voice_budget: struct { spatialized: u8 },
};

/// Single-producer, single-consumer ring.
///
/// `capacity` must be a power of two: the mask replaces a modulo, and more importantly it
/// makes index wraparound exact, so the head and tail counters can free-run as u32 and be
/// compared by difference without a wrap special case.
pub fn Ring(comptime capacity: usize) type {
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("audio ring capacity must be a non-zero power of two");
        }
    }

    return struct {
        const Self = @This();
        pub const mask: u32 = @intCast(capacity - 1);
        pub const size: usize = capacity;

        buf: [capacity]Command = undefined,

        /// Written only by the producer, read by both.
        head: std.atomic.Value(u32) = .init(0),
        /// Written only by the consumer, read by both.
        tail: std.atomic.Value(u32) = .init(0),

        /// Commands ABANDONED by `send`. Not failed `push` attempts — a caller that
        /// retries has not dropped anything, and counting attempts made this number
        /// report tens of thousands of "drops" in a run that lost nothing. It exists to
        /// explain a missing sound, so it has to mean exactly that.
        dropped: std.atomic.Value(u32) = .init(0),

        pub const empty: Self = .{};

        /// Producer side. Returns false if the ring is full.
        ///
        /// The release store is what publishes the payload: the consumer's acquire load of
        /// `head` is what makes the preceding buffer write visible. Writing the payload
        /// after the index would let the consumer read uninitialized memory, which on an
        /// audio thread is a burst of noise at full amplitude.
        pub fn push(self: *Self, cmd: Command) bool {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h -% t >= capacity) return false;
            self.buf[h & mask] = cmd;
            self.head.store(h +% 1, .release);
            return true;
        }

        /// The game thread's intended call: enqueue, or give up and count it.
        ///
        /// Giving up is correct here and blocking is not. §17 says neither thread blocks
        /// on the other, and §7 does not permit tick cadence to vary — so a full ring
        /// costs a sound, never a tick. `push` is the primitive for a caller that has
        /// somewhere better to put the command.
        pub fn send(self: *Self, cmd: Command) bool {
            if (self.push(cmd)) return true;
            _ = self.dropped.fetchAdd(1, .monotonic);
            return false;
        }

        /// Consumer side. Returns null when empty.
        pub fn pop(self: *Self) ?Command {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (h == t) return null;
            const cmd = self.buf[t & mask];
            self.tail.store(t +% 1, .release);
            return cmd;
        }

        pub fn len(self: *const Self) u32 {
            return self.head.load(.monotonic) -% self.tail.load(.monotonic);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn droppedCount(self: *const Self) u32 {
            return self.dropped.load(.monotonic);
        }
    };
}

// ---------------------------------------------------------------------------

const TestRing = Ring(8);

test "capacity must be a power of two" {
    // Not style: the mask replaces a modulo AND makes u32 wraparound exact, so head and
    // tail can free-run without a wrap special case. A non-power-of-two silently breaks
    // the wraparound arithmetic rather than the indexing.
    try std.testing.expectEqual(@as(u32, 7), TestRing.mask);
    try std.testing.expectEqual(@as(usize, 8), TestRing.size);
}

test "round-trips in order" {
    var r = TestRing.empty;
    try std.testing.expect(r.push(.{ .play = .{ .voice = 1, .asset = 100, .gain_q16 = 65535 } }));
    try std.testing.expect(r.push(.{ .stop = .{ .voice = 1 } }));

    switch (r.pop().?) {
        .play => |p| try std.testing.expectEqual(@as(u32, 100), p.asset),
        else => return error.WrongOrder,
    }
    switch (r.pop().?) {
        .stop => |p| try std.testing.expectEqual(@as(u16, 1), p.voice),
        else => return error.WrongOrder,
    }
    try std.testing.expect(r.pop() == null);
}

test "a full ring drops the newest and counts it" {
    // Blocking the producer instead would turn an audio problem into a frame-loop stall,
    // and §7 does not permit tick cadence to vary. A missing sound is the cheaper failure,
    // but it must be countable or it is indistinguishable from a mixer bug.
    var r = TestRing.empty;
    for (0..TestRing.size) |i| {
        try std.testing.expect(r.send(.{ .stop = .{ .voice = @intCast(i) } }));
    }
    try std.testing.expect(!r.send(.{ .stop = .{ .voice = 99 } }));
    try std.testing.expectEqual(@as(u32, 1), r.droppedCount());

    // The ring still holds exactly what was accepted, in order.
    try std.testing.expectEqual(@as(u32, TestRing.size), r.len());
    for (0..TestRing.size) |i| {
        switch (r.pop().?) {
            .stop => |p| try std.testing.expectEqual(@as(u16, @intCast(i)), p.voice),
            else => return error.WrongCommand,
        }
    }
}

test "indices wrap without a special case" {
    // Free-running u32 counters compared by difference. Pushing far past 2^32 is not
    // testable directly, so this drives many wraps of the ring itself and checks order
    // holds throughout.
    var r = TestRing.empty;
    var expected: u16 = 0;
    var sent: u16 = 0;

    for (0..1000) |_| {
        while (r.len() < TestRing.size and sent < 60000) {
            _ = r.push(.{ .stop = .{ .voice = sent } });
            sent +%= 1;
        }
        while (r.pop()) |cmd| {
            switch (cmd) {
                .stop => |p| {
                    try std.testing.expectEqual(expected, p.voice);
                    expected +%= 1;
                },
                else => return error.WrongCommand,
            }
        }
    }
    try std.testing.expectEqual(sent, expected);
}

test "concurrent producer and consumer preserve order and lose nothing" {
    // The property the whole design exists for, exercised on real threads. A ring that
    // works single-threaded and races under contention is worse than a mutex, because the
    // failure is a burst of noise at an unpredictable moment.
    const total: u32 = 200_000;
    var ring = TestRing.empty;

    const Producer = struct {
        fn run(r: *TestRing, n: u32) void {
            var i: u32 = 0;
            while (i < n) {
                if (r.push(.{ .set_gain = .{ .voice = @truncate(i), .gain_q16 = @truncate(i) } })) {
                    i += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    };

    var received: u32 = 0;
    var out_of_order: u32 = 0;

    var producer = try std.Thread.spawn(.{}, Producer.run, .{ &ring, total });

    while (received < total) {
        if (ring.pop()) |cmd| {
            switch (cmd) {
                .set_gain => |g| {
                    if (g.gain_q16 != @as(u16, @truncate(received))) out_of_order += 1;
                },
                else => out_of_order += 1,
            }
            received += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }
    producer.join();

    try std.testing.expectEqual(total, received);
    try std.testing.expectEqual(@as(u32, 0), out_of_order);
    // Zero drops because the producer used `push` and retried. This is the distinction
    // that made the counter wrong the first time: it counted failed ATTEMPTS, so a run
    // that lost nothing reported tens of thousands of drops.
    try std.testing.expectEqual(@as(u32, 0), ring.droppedCount());
}

test "a retried push is not a drop; an abandoned send is" {
    // The counter exists to explain a missing sound. If it counts contention it explains
    // nothing, and a real drop is invisible in the noise.
    var r = TestRing.empty;
    for (0..TestRing.size) |i| _ = r.push(.{ .stop = .{ .voice = @intCast(i) } });

    // Contention: fails, but the caller can retry, so nothing is lost.
    try std.testing.expect(!r.push(.{ .stop = .{ .voice = 99 } }));
    try std.testing.expectEqual(@as(u32, 0), r.droppedCount());

    // Abandonment: the command is gone.
    try std.testing.expect(!r.send(.{ .stop = .{ .voice = 99 } }));
    try std.testing.expectEqual(@as(u32, 1), r.droppedCount());
}

test "commands are copyable and hold no pointers" {
    // The audio thread may consume a command long after the producer moved on, so a
    // pointer into game state is a use-after-free with a deadline. Asset references are
    // content-addressed ids for the same reason (§11).
    inline for (@typeInfo(Command).@"union".fields) |f| {
        inline for (@typeInfo(f.type).@"struct".fields) |inner| {
            switch (@typeInfo(inner.type)) {
                .pointer => @compileError("audio Command." ++ f.name ++ "." ++ inner.name ++
                    " holds a pointer; the audio thread consumes commands asynchronously."),
                else => {},
            }
        }
    }
    try std.testing.expect(@sizeOf(Command) <= 24);
}
