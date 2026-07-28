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

const bedlam_engine = @import("bedlam_engine");

export fn bedlamAdd(a: i32, b: i32) i32 {
    return bedlam_engine.add(a, b);
}
