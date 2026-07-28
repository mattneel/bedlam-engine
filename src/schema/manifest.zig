//! Manifest construction, canonical serialization, and the compatibility fingerprint.
//!
//! `docs/SCHEMA_AND_EVOLUTION.md` §3, §4, §10.
//!
//! The manifest is a build output. The registry is the hand-maintained input. The
//! declarations are the shape. This file joins them, fails the build if they disagree,
//! and emits bytes that are identical for the same commit on every target.
//!
//! Two serializations, and the difference is the whole point:
//!
//!   canonicalFingerprintBytes  — only what §4 says the fingerprint covers. Sorted by
//!                                stable ID. No names, no layout, no panel hints.
//!   render                     — the full human- and tool-readable document.
//!
//! If the fingerprint ever covers something it should not, cross-platform play breaks
//! in a way that looks like a netcode bug for weeks (§10 check 5).

const std = @import("std");
const wire = @import("wire.zig");
const d = @import("declare.zig");
const reg = @import("registry.zig");
const schema = @import("schema.zig");

pub const generator_version = "0.1.0";
pub const schema_version = "1.0";

pub const FieldEntry = struct {
    id: u32,
    name: []const u8,
    wire_type: wire.WireType,
    quant: wire.Quantization,
    priority_weight: u8,
    interest_sensitive: bool,
    introduced: []const u8,
    deprecated: ?[]const u8,
};

pub const ComponentEntry = struct {
    id: u32,
    name: []const u8,
    namespace: []const u8,
    class: d.Class,
    projections: d.Projections,
    script: d.ScriptExposure,
    contention: d.ContentionKey,
    introduced: []const u8,
    deprecated: ?[]const u8,
    fields: []const FieldEntry,
};

pub const EventEntry = struct {
    id: u32,
    name: []const u8,
    channel: d.Channel,
    introduced: []const u8,
};

pub const RpcEntry = struct {
    id: u32,
    name: []const u8,
    channel: d.Channel,
    requires_authority: bool,
    introduced: []const u8,
};

pub const Tombstone = struct {
    id: u32,
    name: []const u8,
    retired: []const u8,
};

pub const Manifest = struct {
    components: []const ComponentEntry,
    events: []const EventEntry,
    rpcs: []const RpcEntry,
    tombstones: []const Tombstone,
};

/// Build the manifest from declarations plus registry, at comptime.
///
/// Every failure here is a `@compileError`, which is what makes the §10 checks build
/// failures rather than warnings. A warning about a reused tombstone is not a check.
pub fn build() Manifest {
    comptime {
        @setEvalBranchQuota(200_000);

        var components: []const ComponentEntry = &.{};

        for (schema.components) |c| {
            // §10 check 1 — a retired identity is being re-declared. Reported before
            // check 2, because "no registry entry" would invite exactly the wrong fix.
            if (reg.registry.findTombstoned(.component, c.name)) |dead|
                @compileError("schema: component '" ++ c.name ++ "' was retired in " ++
                    (dead.retired orelse "an earlier version") ++
                    " and its ID is tombstoned permanently. Do not re-add it to the registry — " ++
                    "allocate a new name and ID, and add a migration edge (§5). There is no override flag.");

            // §10 check 2 — ID allocated without a registry entry.
            const centry = reg.registry.find(.component, c.name) orelse
                @compileError("schema: component '" ++ c.name ++
                    "' has no registry entry. IDs are allocated in schema/registry.txt, never derived.");

            // §10 check 1 — tombstoned ID reuse. No override flag exists.
            if (reg.registry.isTombstoned(centry.id))
                @compileError("schema: component '" ++ c.name ++ "' reuses a tombstoned ID.");

            var fields: []const FieldEntry = &.{};
            for (c.fields) |f| {
                const qualified = c.name ++ "." ++ f.name;

                if (reg.registry.findTombstoned(.field, qualified)) |dead|
                    @compileError("schema: field '" ++ qualified ++ "' was retired in " ++
                        (dead.retired orelse "an earlier version") ++
                        " and its ID is tombstoned permanently. Do not re-add it to the registry — " ++
                        "allocate a new field name and ID, and add a migration edge (§5).");

                const fentry = reg.registry.find(.field, qualified) orelse
                    @compileError("schema: field '" ++ qualified ++ "' has no registry entry.");

                if (reg.registry.isTombstoned(fentry.id))
                    @compileError("schema: field '" ++ qualified ++ "' reuses a tombstoned ID.");

                // §10 check 3 — wire type changed without a new ID and a tombstone.
                if (fentry.wire_type) |pinned| {
                    if (pinned != f.wire)
                        @compileError("schema: field '" ++ qualified ++
                            "' changed wire type. That is a new identity: tombstone the old ID, " ++
                            "allocate a new one, and add a migration edge (§5).");
                } else {
                    @compileError("schema: field '" ++ qualified ++ "' has no wire= in the registry.");
                }

                // A field ID must sit in its component's subspace, or the ID encoding
                // is lying about ownership.
                if (fentry.id >> 16 != centry.id)
                    @compileError("schema: field '" ++ qualified ++
                        "' has an ID outside its component's subspace.");

                fields = fields ++ [_]FieldEntry{.{
                    .id = fentry.id,
                    .name = f.name,
                    .wire_type = f.wire,
                    .quant = f.quant,
                    .priority_weight = f.priority_weight,
                    .interest_sensitive = f.interest_sensitive,
                    .introduced = fentry.introduced,
                    .deprecated = fentry.deprecated,
                }};
            }

            const proj = d.projectionsFor(c.class);

            // §10 check 10 — a component declared with a class its usage contradicts.
            if (c.class == .derived and proj.replication)
                @compileError("schema: derived component '" ++ c.name ++ "' is in the replication projection.");
            if (c.script == .read_write and !d.scriptMayWrite(c.class))
                @compileError("schema: component '" ++ c.name ++ "' is script-writable but its class " ++
                    "is on the prediction path. Rollback never re-invokes JS (§10.1), so script output " ++
                    "is authoritative-only.");

            components = components ++ [_]ComponentEntry{.{
                .id = centry.id,
                .name = c.name,
                .namespace = c.namespace,
                .class = c.class,
                .projections = proj,
                .script = c.script,
                .contention = c.contention,
                .introduced = centry.introduced,
                .deprecated = centry.deprecated,
                .fields = fields,
            }};
        }

        var events: []const EventEntry = &.{};
        for (schema.events) |e| {
            const entry = reg.registry.find(.event, e.name) orelse
                @compileError("schema: event '" ++ e.name ++ "' has no registry entry.");
            events = events ++ [_]EventEntry{.{
                .id = entry.id,
                .name = e.name,
                .channel = e.channel,
                .introduced = entry.introduced,
            }};
        }

        var rpcs: []const RpcEntry = &.{};
        for (schema.rpcs) |r| {
            const entry = reg.registry.find(.rpc, r.name) orelse
                @compileError("schema: rpc '" ++ r.name ++ "' has no registry entry.");
            rpcs = rpcs ++ [_]RpcEntry{.{
                .id = entry.id,
                .name = r.name,
                .channel = r.channel,
                .requires_authority = r.requires_authority,
                .introduced = entry.introduced,
            }};
        }

        var tombs: []const Tombstone = &.{};
        for (reg.registry.entries) |e| {
            if (!e.tombstoned) continue;
            tombs = tombs ++ [_]Tombstone{.{
                .id = e.id,
                .name = e.name,
                .retired = e.retired orelse "unknown",
            }};
        }

        const c = components;
        const ev = events;
        const rp = rpcs;
        const tb = tombs;
        return .{ .components = c, .events = ev, .rpcs = rp, .tombstones = tb };
    }
}

pub const manifest: Manifest = build();

fn lessById(_: void, a: u32, b: u32) bool {
    return a < b;
}

/// Bytes the fingerprint is computed over. §4's covered set, and nothing else.
///
/// Covered: component and field IDs, wire types, quantization policy, channel
/// assignments, event and RPC signatures, tombstone list.
///
/// NOT covered: names, namespaces, comments, physical layout, alignment, chunk size,
/// editor panel hints, and anything in a class that never crosses the wire.
///
/// The `layout` parameter is accepted and deliberately unused. It exists so the test
/// that varies it can demonstrate §10 check 5 rather than merely assert it.
pub fn canonicalFingerprintBytes(
    gpa: std.mem.Allocator,
    m: Manifest,
    layout: wire.Layout,
) ![]u8 {
    _ = layout; // Per ARCHITECTURE.md §0 P1. If this is ever read, check 5 fails.

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [256]u8 = undefined;

    // Sorted by stable ID so declaration order cannot affect the hash.
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    for (m.components) |c| try ids.append(gpa, c.id);
    std.mem.sort(u32, ids.items, {}, lessById);

    for (ids.items) |id| {
        const c = for (m.components) |x| {
            if (x.id == id) break x;
        } else unreachable;

        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "C {x:0>8} {s} {s} {s} {s} {s}\n", .{
            c.id,
            @tagName(c.class),
            @tagName(c.contention),
            if (c.projections.replication) "R" else "-",
            if (c.projections.rollback) "B" else "-",
            if (c.projections.save) "S" else "-",
        }));

        var field_ids: std.ArrayList(u32) = .empty;
        defer field_ids.deinit(gpa);
        for (c.fields) |f| try field_ids.append(gpa, f.id);
        std.mem.sort(u32, field_ids.items, {}, lessById);

        for (field_ids.items) |fid| {
            const f = for (c.fields) |x| {
                if (x.id == fid) break x;
            } else unreachable;

            try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "F {x:0>8} {s} {d} {d}", .{
                f.id,
                @tagName(f.wire_type),
                f.priority_weight,
                @intFromBool(f.interest_sensitive),
            }));
            switch (f.quant) {
                .none => try out.appendSlice(gpa, " q none\n"),
                .bounded => |q| try out.appendSlice(gpa, try std.fmt.bufPrint(
                    &buf,
                    " q bounded {d} {d:.6} {d:.6}\n",
                    .{ q.bits, q.min, q.max },
                )),
                .angular => |q| try out.appendSlice(gpa, try std.fmt.bufPrint(
                    &buf,
                    " q angular {d}\n",
                    .{q.bits},
                )),
            }
        }
    }

    var event_ids: std.ArrayList(u32) = .empty;
    defer event_ids.deinit(gpa);
    for (m.events) |e| try event_ids.append(gpa, e.id);
    std.mem.sort(u32, event_ids.items, {}, lessById);
    for (event_ids.items) |id| {
        const e = for (m.events) |x| {
            if (x.id == id) break x;
        } else unreachable;
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "E {x:0>8} {s}\n", .{ e.id, @tagName(e.channel) }));
    }

    var rpc_ids: std.ArrayList(u32) = .empty;
    defer rpc_ids.deinit(gpa);
    for (m.rpcs) |r| try rpc_ids.append(gpa, r.id);
    std.mem.sort(u32, rpc_ids.items, {}, lessById);
    for (rpc_ids.items) |id| {
        const r = for (m.rpcs) |x| {
            if (x.id == id) break x;
        } else unreachable;
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "P {x:0>8} {s} {d}\n", .{
            r.id,
            @tagName(r.channel),
            @intFromBool(r.requires_authority),
        }));
    }

    // Tombstones are covered: a build that has forgotten a retirement is not
    // compatible with one that remembers it.
    var tomb_ids: std.ArrayList(u32) = .empty;
    defer tomb_ids.deinit(gpa);
    for (m.tombstones) |t| try tomb_ids.append(gpa, t.id);
    std.mem.sort(u32, tomb_ids.items, {}, lessById);
    for (tomb_ids.items) |id| {
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "X {x:0>8}\n", .{id}));
    }

    return out.toOwnedSlice(gpa);
}

pub const Fingerprint = [64]u8;

/// SHA-256 over the canonical bytes, rendered as lowercase hex.
///
/// Standard construction only — `ARCHITECTURE.md` §18.13. This is a compatibility
/// check, not a security boundary, but the rule has no exceptions and reaching for
/// something bespoke here is how the habit starts.
pub fn fingerprint(gpa: std.mem.Allocator, m: Manifest, layout: wire.Layout) !Fingerprint {
    const bytes = try canonicalFingerprintBytes(gpa, m, layout);
    defer gpa.free(bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    var hex: Fingerprint = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

/// The full manifest document. Deterministic: same commit, same bytes.
pub fn render(gpa: std.mem.Allocator, m: Manifest, layout: wire.Layout) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [512]u8 = undefined;

    const fp = try fingerprint(gpa, m, layout);

    try out.appendSlice(gpa, "# Bedlam schema manifest — generated, do not edit\n");
    try out.appendSlice(gpa, "# docs/SCHEMA_AND_EVOLUTION.md §3\n\n");
    try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "schema_version {s}\n", .{schema_version}));
    try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "generator_version {s}\n", .{generator_version}));
    try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "fingerprint {s}\n\n", .{&fp}));

    for (m.components) |c| {
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "component {s}.{s} id=0x{x:0>8} class={s}\n", .{
            c.namespace, c.name, c.id, @tagName(c.class),
        }));
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "  projections replication={} rollback={} save={} replay={}\n", .{
            c.projections.replication, c.projections.rollback, c.projections.save, c.projections.replay,
        }));
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "  script={s} contention={s} introduced={s}\n", .{
            @tagName(c.script), @tagName(c.contention), c.introduced,
        }));
        for (c.fields) |f| {
            try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "  field {s} id=0x{x:0>8} wire={s} priority={d} interest={}\n", .{
                f.name, f.id, @tagName(f.wire_type), f.priority_weight, f.interest_sensitive,
            }));
        }
    }

    try out.appendSlice(gpa, "\n");
    for (m.events) |e| {
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "event {s} id=0x{x:0>8} channel={s}\n", .{
            e.name, e.id, @tagName(e.channel),
        }));
    }
    for (m.rpcs) |r| {
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "rpc {s} id=0x{x:0>8} channel={s}\n", .{
            r.name, r.id, @tagName(r.channel),
        }));
    }

    try out.appendSlice(gpa, "\n# Tombstones. Permanent.\n");
    for (m.tombstones) |t| {
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "tombstone {s} id=0x{x:0>8} retired={s}\n", .{
            t.name, t.id, t.retired,
        }));
    }

    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// docs/SCHEMA_AND_EVOLUTION.md §10 — CI enforcement.
//
// Checks 1, 2, 3, 9 and 10 are @compileError inside build(): a violation does not
// produce a failing test, it produces no binary at all. The rest are tests.
// ---------------------------------------------------------------------------

test "check 4 — manifest is byte-identical across two runs of the same commit" {
    const gpa = std.testing.allocator;
    const a = try render(gpa, manifest, wire.Layout.desktop);
    defer gpa.free(a);
    const b = try render(gpa, manifest, wire.Layout.desktop);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

/// The fingerprint of the schema as currently declared.
///
/// Pinned deliberately. `SCHEMA_AND_EVOLUTION.md` §4 says the fingerprint answers one
/// question at connection time — can these two builds exchange state — so a change to it
/// is a change to who can talk to whom. Pinning turns that into an explicit diff instead
/// of a value nobody looks at, which is the same argument §13 makes for change-controlling
/// benchmark parameters.
///
/// **Updating this constant is correct when the schema genuinely changed, and is a
/// mistake otherwise.** If it moves without a registry diff in the same commit, something
/// that §4 says is not covered has leaked into the covered set.
pub const pinned_fingerprint: *const [64]u8 =
    "ca80a08a6cea22036cff9d6c529992e925e56dc953afe1cc0c5a43a41044d8f4";

test "check 5, strongest form — the fingerprint is one value on every architecture" {
    // The in-process test below varies `Layout` and proves layout does not leak. This
    // one pins the actual digest, so `zig build cross` re-checks it on s390x and mips
    // (big-endian) and on arm and mips (32-bit).
    //
    // That matters because none of Bedlam's six shipping targets can falsify an
    // endianness bug — all of them are little-endian. A canonical serialization that
    // silently depended on host byte order would produce a different fingerprint on a
    // big-endian host, two builds of the same commit would refuse to connect, and
    // nothing in the shipping matrix would ever notice.
    const gpa = std.testing.allocator;
    const fp = try fingerprint(gpa, manifest, wire.Layout.desktop);
    try std.testing.expectEqualStrings(pinned_fingerprint, &fp);
}

test "check 5 — fingerprint is identical across per-target physical layouts" {
    // The subtle one. ARCHITECTURE.md §0 P1 permits layout to differ per target and
    // forbids semantic schema from differing. If layout leaks into the fingerprint,
    // cross-platform play breaks in a way that looks like a netcode bug for weeks.
    const gpa = std.testing.allocator;
    const web = try fingerprint(gpa, manifest, wire.Layout.wasm32);
    const mob = try fingerprint(gpa, manifest, wire.Layout.mobile);
    const desk = try fingerprint(gpa, manifest, wire.Layout.desktop);

    try std.testing.expectEqualStrings(&web, &mob);
    try std.testing.expectEqualStrings(&mob, &desk);
}

test "check 9 — declaration and manifest agree on shape" {
    inline for (schema.components, 0..) |decl, i| {
        const entry = manifest.components[i];
        try std.testing.expectEqualStrings(decl.name, entry.name);
        try std.testing.expectEqual(decl.fields.len, entry.fields.len);
        inline for (decl.fields, 0..) |f, j| {
            try std.testing.expectEqualStrings(f.name, entry.fields[j].name);
            try std.testing.expectEqual(f.wire, entry.fields[j].wire_type);
        }
    }
}

test "check 10 — no derived component reaches the replication projection" {
    for (manifest.components) |c| {
        if (c.class == .derived) try std.testing.expect(!c.projections.replication);
    }
}

test "fingerprint changes when a wire-affecting fact changes" {
    // A fingerprint that never changes is not a fingerprint. Mutate a copy's
    // quantization and confirm the hash moves.
    const gpa = std.testing.allocator;
    const before = try fingerprint(gpa, manifest, wire.Layout.desktop);

    var fields = try gpa.alloc(FieldEntry, manifest.components[0].fields.len);
    defer gpa.free(fields);
    @memcpy(fields, manifest.components[0].fields);
    fields[0].quant = .{ .bounded = .{ .bits = 14, .min = -4096, .max = 4096 } };

    var comps = try gpa.alloc(ComponentEntry, manifest.components.len);
    defer gpa.free(comps);
    @memcpy(comps, manifest.components);
    comps[0].fields = fields;

    const mutated: Manifest = .{
        .components = comps,
        .events = manifest.events,
        .rpcs = manifest.rpcs,
        .tombstones = manifest.tombstones,
    };
    const after = try fingerprint(gpa, mutated, wire.Layout.desktop);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "fingerprint does not change when a name changes" {
    // §4: names are explicitly not covered. A rename preserves identity (§2), so a
    // rename must not refuse a connection.
    const gpa = std.testing.allocator;
    const before = try fingerprint(gpa, manifest, wire.Layout.desktop);

    var comps = try gpa.alloc(ComponentEntry, manifest.components.len);
    defer gpa.free(comps);
    @memcpy(comps, manifest.components);
    comps[0].name = "RenamedButSameIdentity";
    comps[0].namespace = "elsewhere";

    const renamed: Manifest = .{
        .components = comps,
        .events = manifest.events,
        .rpcs = manifest.rpcs,
        .tombstones = manifest.tombstones,
    };
    const after = try fingerprint(gpa, renamed, wire.Layout.desktop);
    try std.testing.expectEqualStrings(&before, &after);
}

test "tombstones are covered by the fingerprint" {
    const gpa = std.testing.allocator;
    const before = try fingerprint(gpa, manifest, wire.Layout.desktop);
    const fewer: Manifest = .{
        .components = manifest.components,
        .events = manifest.events,
        .rpcs = manifest.rpcs,
        .tombstones = manifest.tombstones[0 .. manifest.tombstones.len - 1],
    };
    const after = try fingerprint(gpa, fewer, wire.Layout.desktop);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "manifest covers every declared identity" {
    try std.testing.expectEqual(schema.components.len, manifest.components.len);
    try std.testing.expectEqual(schema.events.len, manifest.events.len);
    try std.testing.expectEqual(schema.rpcs.len, manifest.rpcs.len);
    try std.testing.expect(manifest.tombstones.len >= 2);
}
