//! Suspend/resume and device loss. `AGENTS.md` §4, M0 criteria 6 and 7.
//!
//! The platform backends already emit `suspended`, `resumed`, `device_lost` and
//! `device_restored`. This is the part that makes them *mean* something: a state machine
//! saying what the engine is allowed to do in each state, and what it must have released
//! before entering one.
//!
//! **The two are separate axes, and collapsing them is the classic bug.** An app can be
//! suspended with a perfectly valid device (Android home button), and it can lose its
//! device while fully foregrounded (Windows TDR, a GPU driver update, an iOS memory
//! warning). Modelling them as one flag means either resuming into a dead swapchain or
//! rebuilding resources nobody can see.
//!
//! **Simulation cadence is not one of the things that varies.** `ARCHITECTURE.md` §1.3
//! lists four governors and says none touches tick rate; `CONFORMANCE_PROFILES.md` §4
//! says cadence "does not degrade in any profile" because a client predicting at a lower
//! rate desynchronizes from the authoritative cell — a correctness failure, not a
//! performance one. So `mayStepSimulation` is true even while suspended: a suspended
//! client that stops ticking has to resynchronize on resume, and §14.3's replay
//! validation then cannot distinguish it from one that stalled deliberately.
//!
//! What suspension actually gates is *presentation*: rendering, audio output, and GPU
//! resource residency.

const std = @import("std");
const iface = @import("iface.zig");

pub const Presentation = enum {
    /// Foreground with a live device. Everything runs.
    active,
    /// Backgrounded, device intact. Stop presenting, keep simulating.
    suspended,
    /// Device gone. Release everything device-owned and wait; may happen in either
    /// foreground or background.
    device_lost,
    /// Device back but resources not yet rebuilt. Distinct from `active` because
    /// presenting here draws into a swapchain that does not exist yet.
    restoring,
};

pub const State = struct {
    presentation: Presentation = .active,
    /// Tracked separately from `presentation` because the two axes are independent —
    /// an app can be backgrounded with a live device and vice versa.
    foreground: bool = true,
    device_ok: bool = true,

    /// Transitions observed. Diagnostic, and directly useful: §7's 45-minute soak on a
    /// phone will background and foreground the app repeatedly, and a leak shows up as a
    /// suspend count that does not match the resume count.
    suspends: u32 = 0,
    resumes: u32 = 0,
    device_losses: u32 = 0,
    device_restores: u32 = 0,

    /// True when the engine may present a frame.
    pub fn mayPresent(self: State) bool {
        return self.presentation == .active;
    }

    /// True when device-owned resources may be created or used.
    ///
    /// False while restoring: the device exists but the swapchain and pools do not yet,
    /// and a system that creates resources here races the rebuild.
    pub fn mayUseDevice(self: State) bool {
        return self.presentation == .active;
    }

    /// True when audio output should run. Separate from `mayPresent` because a
    /// backgrounded app on some platforms keeps audio and loses video — and §17's mixer
    /// competes for the same thermal envelope, so this is a real decision rather than an
    /// alias.
    pub fn mayOutputAudio(self: State) bool {
        return self.presentation == .active;
    }

    /// **Always true.** §1.3 and `CONFORMANCE_PROFILES.md` §4: simulation and prediction
    /// cadence never degrade, in any profile or state. A suspended client that stops
    /// ticking must resynchronize on resume, and §14.3's replay validation cannot then
    /// distinguish it from a host that stalled deliberately.
    pub fn mayStepSimulation(self: State) bool {
        _ = self;
        return true;
    }

    /// True when device-owned resources must be released BEFORE returning from the
    /// handler. Both platforms that enforce this — Android's onSurfaceDestroyed and iOS's
    /// backgrounding — will kill the process if they are not.
    pub fn mustReleaseDeviceResources(self: State) bool {
        return self.presentation == .device_lost;
    }

    pub fn apply(self: *State, event: iface.Event) void {
        switch (event) {
            .suspended => {
                if (self.foreground) self.suspends += 1;
                self.foreground = false;
            },
            .resumed => {
                if (!self.foreground) self.resumes += 1;
                self.foreground = true;
            },
            .device_lost => {
                if (self.device_ok) self.device_losses += 1;
                self.device_ok = false;
            },
            .device_restored => {
                if (!self.device_ok) self.device_restores += 1;
                self.device_ok = true;
            },
            // A close request does not itself change presentation: the engine decides
            // whether to honour it, and §13's authoring layer may need to flush first.
            else => {},
        }
        self.presentation = derive(self.foreground, self.device_ok, self.presentation);
    }

    /// Presentation as a function of the two axes.
    ///
    /// `restoring` is sticky until something explicitly clears it, because a device
    /// coming back does not mean resources exist — see `finishRestore`.
    fn derive(foreground: bool, device_ok: bool, previous: Presentation) Presentation {
        if (!device_ok) return .device_lost;
        if (previous == .device_lost) return .restoring;
        if (previous == .restoring) return .restoring;
        return if (foreground) .active else .suspended;
    }

    /// Called by the renderer once device resources are rebuilt.
    ///
    /// Explicit rather than automatic on `device_restored`, because only the renderer
    /// knows when its swapchain and pools actually exist. Treating the event as the
    /// completion is how a frame gets presented into a swapchain that has not been
    /// recreated.
    pub fn finishRestore(self: *State) void {
        if (self.presentation != .restoring) return;
        self.presentation = if (self.foreground) .active else .suspended;
    }

    pub fn applyAll(self: *State, events: []const iface.Event) void {
        for (events) |e| self.apply(e);
    }

    /// Suspends without matching resumes. Nonzero at the end of a §7 soak means a
    /// lifecycle path leaks.
    pub fn unbalanced(self: State) i64 {
        return @as(i64, self.suspends) - @as(i64, self.resumes);
    }
};

// ---------------------------------------------------------------------------

test "starts active" {
    const s: State = .{};
    try std.testing.expectEqual(Presentation.active, s.presentation);
    try std.testing.expect(s.mayPresent());
    try std.testing.expect(s.mayUseDevice());
}

test "suspension stops presentation but never simulation" {
    // The rule §1.3 and CONFORMANCE_PROFILES.md §4 both state: cadence does not degrade
    // in any profile or state. A suspended client that stops ticking desynchronizes from
    // the authoritative cell, which is a correctness failure rather than a performance
    // one — and §14.3 then cannot tell it from a host that stalled deliberately.
    var s: State = .{};
    s.apply(.suspended);

    try std.testing.expectEqual(Presentation.suspended, s.presentation);
    try std.testing.expect(!s.mayPresent());
    try std.testing.expect(!s.mayOutputAudio());
    try std.testing.expect(s.mayStepSimulation());
}

test "device loss and backgrounding are independent axes" {
    // The classic bug is one flag for both. An app can be suspended with a live device
    // (home button) and lose its device while foregrounded (TDR, driver update).
    var s: State = .{};

    s.apply(.device_lost);
    try std.testing.expectEqual(Presentation.device_lost, s.presentation);
    try std.testing.expect(s.foreground); // still foregrounded
    try std.testing.expect(s.mustReleaseDeviceResources());

    s.apply(.suspended);
    try std.testing.expectEqual(Presentation.device_lost, s.presentation);
    try std.testing.expect(!s.foreground);
}

test "a restored device does not immediately permit presenting" {
    // `device_restored` says the device is back, not that the swapchain exists.
    // Presenting here draws into a swapchain that has not been recreated.
    var s: State = .{};
    s.apply(.device_lost);
    s.apply(.device_restored);

    try std.testing.expectEqual(Presentation.restoring, s.presentation);
    try std.testing.expect(!s.mayPresent());
    try std.testing.expect(!s.mayUseDevice());
    try std.testing.expect(s.mayStepSimulation());

    // Only the renderer knows when resources actually exist.
    s.finishRestore();
    try std.testing.expectEqual(Presentation.active, s.presentation);
    try std.testing.expect(s.mayPresent());
}

test "restoring while backgrounded lands in suspended, not active" {
    var s: State = .{};
    s.apply(.suspended);
    s.apply(.device_lost);
    s.apply(.device_restored);
    s.finishRestore();

    try std.testing.expectEqual(Presentation.suspended, s.presentation);
    try std.testing.expect(!s.mayPresent());
}

test "repeated events do not inflate the counters" {
    // Platforms send duplicates: Windows sends WM_SIZE with SIZE_MINIMIZED more than
    // once, Android delivers onPause twice across configuration changes. A counter that
    // trusts every event reports a leak that is not there.
    var s: State = .{};
    s.apply(.suspended);
    s.apply(.suspended);
    s.apply(.suspended);
    try std.testing.expectEqual(@as(u32, 1), s.suspends);

    s.apply(.resumed);
    s.apply(.resumed);
    try std.testing.expectEqual(@as(u32, 1), s.resumes);
    try std.testing.expectEqual(@as(i64, 0), s.unbalanced());
}

test "a soak cycle balances" {
    // §7's 45-minute mobile soak backgrounds and foregrounds repeatedly. A lifecycle path
    // that leaks shows up here as an unbalanced count rather than as a mystery OOM at
    // minute 40.
    var s: State = .{};
    for (0..500) |_| {
        s.apply(.suspended);
        s.apply(.resumed);
    }
    try std.testing.expectEqual(@as(u32, 500), s.suspends);
    try std.testing.expectEqual(@as(u32, 500), s.resumes);
    try std.testing.expectEqual(@as(i64, 0), s.unbalanced());
    try std.testing.expectEqual(Presentation.active, s.presentation);
}

test "device loss during a soak is counted and recovers" {
    var s: State = .{};
    for (0..50) |_| {
        s.apply(.device_lost);
        s.apply(.device_restored);
        s.finishRestore();
    }
    try std.testing.expectEqual(@as(u32, 50), s.device_losses);
    try std.testing.expectEqual(@as(u32, 50), s.device_restores);
    try std.testing.expectEqual(Presentation.active, s.presentation);
    try std.testing.expect(s.mayPresent());
}

test "applyAll consumes a pumped event slice" {
    var s: State = .{};
    s.applyAll(&.{
        .focus_lost,
        .suspended,
        .{ .resized = .{ .width = 320, .height = 200 } },
    });
    try std.testing.expectEqual(Presentation.suspended, s.presentation);
}
