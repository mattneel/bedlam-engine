//! Replication. `ARCHITECTURE.md` §9.4.
//!
//! Per-client canonical baselines, delta against the last ACKED baseline, interest
//! filtering, and the byte budget `BENCHMARK_CONTRACT.md` §4.1 computes: ~1,500 bytes per
//! snapshot per client for ~180 entity updates.
//!
//! §5.1 is explicit that a replication baseline is not a physical world snapshot, which is
//! why this lives apart from `world` rather than inside it.

pub const baseline = @import("baseline.zig");

test {
    _ = baseline;
}
