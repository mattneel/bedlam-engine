//! Bedlam engine — portable core.
//!
//! Everything reachable from here compiles for all six targets in `ARCHITECTURE.md`
//! §4.1, including freestanding wasm32 and iOS. Nothing here may reference
//! `std.process`, the OS-backed parts of `std.Io`, or any platform SDK type — §18.9
//! forbids platform types in portable code, and the `web` and `ios` CI rows are what
//! enforce it continuously.

const std = @import("std");

pub const schema = @import("bedlam_schema");
pub const wire = @import("bedlam_wire");
pub const sim = @import("bedlam_sim");
pub const world = @import("bedlam_world");
pub const net = @import("bedlam_net");

/// Pre-1.0. `ARCHITECTURE.md` §19 states exit criteria rather than versions, so this
/// tracks milestones and not semver promises.
pub const version = "0.0.0-M0";

test {
    _ = schema;
    _ = wire;
    _ = sim;
    _ = world;
    _ = net;
}
