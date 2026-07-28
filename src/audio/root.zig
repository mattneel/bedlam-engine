//! Portable audio: the command queue and the mixer.
//!
//! **Engine code, not platform code, and it moved here to prove it.** Both files were under
//! `platform/` because audio *devices* are platform-specific. Neither of these is a device:
//! `ring.zig` is a lock-free SPSC queue and `mixer.zig` is integer Q16 arithmetic over a
//! comptime table. Neither names a platform type, and both are already verified on s390x,
//! arm and mips by the cross gate — which is a stronger statement about portability than
//! their directory was making.
//!
//! The split that matters is the one that remains: **the mixer renders, the device plays.**
//! `platform/windows/audio.zig` and `platform/linux/audio.zig` own a real endpoint and a
//! real deadline; they call in here and nothing here calls out. That is also what lets
//! `src/web.zig` reach the mixer at all — §18.9 forbids `src/` from importing `platform/`,
//! so a mixer living under `platform/` could not be compiled into the browser module, and
//! the Web target would have needed a second implementation of the thing least worth
//! duplicating.

pub const ring = @import("ring.zig");
pub const mixer = @import("mixer.zig");

test {
    _ = ring;
    _ = mixer;
}
