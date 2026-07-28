//! Web entry point.
//!
//! The browser build is a module the TypeScript bootstrap instantiates inside a
//! Worker (`docs/ARCHITECTURE.md` §2, §4.1), not a program with a `main()`. It has
//! no entry point, no stdio, and no process arguments.
//!
//! **Nothing reachable from this file may touch `std.process` or the OS-backed
//! parts of `std.Io`.** Freestanding wasm has no syscalls behind them:
//! `std.Io.Threaded` reaches for `posix.getrandom` and `posix.IOV_MAX`, neither of
//! which exists on this target. That is what kept the `wasm32-freestanding` row
//! dark, and it is why this root exists instead of a conditional inside
//! `src/main.zig` — the constraint is structural and should be enforced by which
//! file the artifact is rooted at, not by a branch someone can wander past.
//!
//! Host imports and the exported surface are generated from `comptime`
//! declarations per §2; this is a placeholder proving the module links and
//! exports.

const bedlam = @import("bedlam_engine");

/// Bits a Transform occupies on the wire. Exported so the TypeScript bootstrap can size
/// its receive buffers from the engine rather than from a duplicated constant — §18.4
/// forbids duplicated definitions, and a hand-copied number in TypeScript is exactly
/// that.
export fn bedlamTransformBits() u32 {
    return comptime bedlam.wire.codec.componentBits(bedlam.schema.schema.components[0]);
}

/// Component count in the active schema. A placeholder consumer proving the engine's
/// comptime schema layer reaches the wasm artifact.
export fn bedlamComponentCount() u32 {
    return @intCast(bedlam.schema.manifest.manifest.components.len);
}
