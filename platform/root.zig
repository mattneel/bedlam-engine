//! Platform shims. `ARCHITECTURE.md` §4.1, `AGENTS.md` §4's M0 exit criteria.
//!
//! **This module is the boundary §18.9 draws.** "No platform SDK types leaking into
//! portable simulation code" — so every Win32 `HWND`, every `UIWindow`, every
//! `ANativeWindow` stops here. The portable engine sees the types in `iface.zig` and
//! nothing else, which is why `src/root.zig` does not import this module at all: the
//! dependency runs one way, and the `web` and `ios` build rows are what keep it honest.
//!
//! The split matters more than it looks. M0's ten criteria are all platform criteria, and
//! the standard way an engine loses portability is not a deliberate decision — it is one
//! `HWND` in a struct that a system happens to read, and then the simulation cannot be
//! compiled for a target that has no `HWND`.

const builtin = @import("builtin");

pub const iface = @import("iface.zig");
pub const assets = @import("assets.zig");
/// Re-exported so callers reach one platform namespace. The implementations live in
/// `src/audio/` because they are engine code — see that module's header.
pub const audio_ring = @import("bedlam_audio").ring;
pub const mixer = @import("bedlam_audio").mixer;
pub const crash = @import("crash.zig");
pub const lifecycle = @import("lifecycle.zig");

/// The implementation for the target being built. Selected at comptime so an unsupported
/// target is a build error naming the gap, not a link error naming a symbol.
pub const backend = switch (builtin.os.tag) {
    .windows => @import("windows/window.zig"),
    // Desktop Linux only. Android reports `os.tag == .linux` and is not X11 — it needs
    // GameActivity and an ANativeWindow, which is its own backend.
    .linux => if (builtin.abi == .android) @import("stub.zig") else @import("linux/window.zig"),
    // Every target family in §4.1 that does not yet have a backend gets the stub, which
    // claims nothing. `wasi` is here because it is a second wasm configuration used as a
    // codegen canary (docs/CI_TIERS.md §4), not a shipping target.
    .macos, .ios, .freestanding, .wasi => @import("stub.zig"),
    else => @compileError("no platform backend for " ++ @tagName(builtin.os.tag) ++
        ". Add one under platform/, or add the tag to the stub list if it is not a " ++
        "shipping target — silence here would mean a target with no platform layer at all."),
};

/// The audio render device, or `null` where none is implemented.
///
/// Optional rather than stubbed, because a stub `Device` that silently does nothing is the
/// shape that lets a target ship with no audio and nothing noticing. A caller must handle
/// `null`, which forces the absence to be visible at the call site.
pub const audio_backend: ?type = switch (builtin.os.tag) {
    .windows => @import("windows/audio.zig"),
    // Desktop Linux only, for the reason above: Android's audio is AAudio/OpenSL, not
    // PulseAudio.
    .linux => if (builtin.abi == .android) null else @import("linux/audio.zig"),
    else => null,
};

/// The datagram transport, or `null` where the target has no sockets.
///
/// Optional for the same reason `audio_backend` is, plus a harder one: `std.net` does not
/// exist on `freestanding`, so this is not merely unimplemented on wasm32 — it is
/// unbuildable, and the browser's transport is WebTransport rather than a socket anyway.
/// `src/net/session.zig` is transport-agnostic precisely so that this can be null.
/// The browser transport, or `null` where the target has no sockets.
///
/// Optional for the same reason `udp_backend` is: `std.http` and `std.Io.net` do not exist
/// on freestanding, and a browser client obviously does not host one.
pub const websocket_backend: ?type = switch (builtin.os.tag) {
    .windows, .linux, .macos => if (builtin.abi == .android) null else @import("websocket.zig"),
    else => null,
};

pub const udp_backend: ?type = switch (builtin.os.tag) {
    .windows, .linux, .macos, .ios => @import("udp.zig"),
    else => null,
};

comptime {
    // The contract, checked at the boundary. A backend that drifts fails here, naming
    // itself, rather than at a call site in main.zig naming a target nobody was building.
    iface.assertSurfaceContract(backend);
}

test {
    _ = iface;
    _ = assets;
    _ = audio_ring;
    _ = mixer;
    _ = crash;
    _ = lifecycle;
    _ = backend;
    if (audio_backend) |a| _ = a;
    if (udp_backend) |u| _ = u;
    if (websocket_backend) |w| _ = w;
}
