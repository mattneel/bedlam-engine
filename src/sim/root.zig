//! Simulation core.
//!
//! `ARCHITECTURE.md` §7 profile 3 territory: no float on the simulation path, no ambient
//! state, and every result a pure function of explicit inputs. What lives here must be
//! re-runnable — by rollback (§6), by replay validation (§16), and by
//! `--verify-determinism` — which is why nothing in it may read a clock, an allocator,
//! or a global.

pub const rng = @import("rng.zig");

test {
    _ = rng;
}
