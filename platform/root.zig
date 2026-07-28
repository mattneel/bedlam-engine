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
pub const audio_ring = @import("audio_ring.zig");
pub const mixer = @import("mixer.zig");
pub const crash = @import("crash.zig");
pub const lifecycle = @import("lifecycle.zig");

/// The implementation for the target being built. Selected at comptime so an unsupported
/// target is a build error naming the gap, not a link error naming a symbol.
pub const backend = switch (builtin.os.tag) {
    .windows => @import("windows/window.zig"),
    // Every target family in §4.1 that does not yet have a backend gets the stub, which
    // claims nothing. `wasi` is here because it is a second wasm configuration used as a
    // codegen canary (docs/CI_TIERS.md §4), not a shipping target.
    .linux, .macos, .ios, .freestanding, .wasi => @import("stub.zig"),
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
}
