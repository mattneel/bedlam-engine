//! Schema, identity, and manifest generation.
//!
//! `docs/SCHEMA_AND_EVOLUTION.md` calls this the lowest-risk, highest-leverage part of
//! the project, and everything else depends on it: connection negotiation, rolling
//! deploys, save migration, replay validation, editor inspection, script bindings,
//! telemetry decoding, authoring validation, and the C-ABI tooling surface.
//!
//! It is also the part that needs no GPU, no device, and no network to verify, which is
//! why it lands first — see `docs/CI_TIERS.md` §4.

pub const wire = @import("wire.zig");
pub const semantic = @import("semantic.zig");
pub const storable = @import("storable.zig");
pub const declare = @import("declare.zig");
pub const registry = @import("registry.zig");
pub const schema = @import("schema.zig");
pub const manifest = @import("manifest.zig");

test {
    _ = wire;
    _ = semantic;
    _ = storable;
    _ = declare;
    _ = registry;
    _ = schema;
    _ = manifest;
}
