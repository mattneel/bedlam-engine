//! The world database. `ARCHITECTURE.md` §5.
//!
//! Components live in archetype chunks, SoA per family, with layout permitted to differ
//! per target (§0 P1) and semantic schema that may not. Chunks carry no per-field
//! metadata from any subsystem, ever (§18.5) — enforced by `schema.storable`, not by
//! convention.

pub const entity = @import("entity.zig");
pub const archetype = @import("archetype.zig");
pub const chunk = @import("chunk.zig");
pub const page = @import("page.zig");
pub const table = @import("table.zig");
pub const journal = @import("journal.zig");
pub const world = @import("world.zig");
pub const hash = @import("hash.zig");

test {
    _ = entity;
    _ = archetype;
    _ = chunk;
    _ = page;
    _ = table;
    _ = journal;
    _ = world;
    _ = hash;
}
