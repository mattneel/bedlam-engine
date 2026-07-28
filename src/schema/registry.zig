//! Parser for the checked-in ID registry.
//!
//! Runs at comptime over an `@embedFile`, so the registry is a compile-time constant and
//! every identity check in `manifest.zig` is a build error rather than a runtime one.
//! `AGENTS.md` §3: comptime over codegen — there is no external generator to run, forget
//! to run, or run against a stale registry.
//!
//! The registry is the only mutable input to the manifest that is not derived from the
//! declarations (`docs/SCHEMA_AND_EVOLUTION.md` §1).

const std = @import("std");
const wire = @import("wire.zig");

pub const Kind = enum { component, field, event, rpc, lease };

pub const Entry = struct {
    kind: Kind,
    /// "Transform", or "Transform.position" for a field.
    name: []const u8,
    id: u32,
    introduced: []const u8,
    deprecated: ?[]const u8 = null,
    /// Pinned encoding for fields. See registry.txt on §10 check 3.
    wire_type: ?wire.WireType = null,
    /// Permanently retired. Reuse is a build error with no override.
    tombstoned: bool = false,
    retired: ?[]const u8 = null,

    /// For a field, the owning component's name.
    pub fn owner(self: Entry) ?[]const u8 {
        const dot = std.mem.indexOfScalar(u8, self.name, '.') orelse return null;
        return self.name[0..dot];
    }

    /// For a field, the bare field name.
    pub fn leaf(self: Entry) []const u8 {
        const dot = std.mem.indexOfScalar(u8, self.name, '.') orelse return self.name;
        return self.name[dot + 1 ..];
    }
};

pub const Registry = struct {
    entries: []const Entry,

    pub fn find(self: Registry, kind: Kind, name: []const u8) ?Entry {
        for (self.entries) |e| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name) and !e.tombstoned) return e;
        }
        return null;
    }

    pub fn isTombstoned(self: Registry, id: u32) bool {
        for (self.entries) |e| if (e.tombstoned and e.id == id) return true;
        return false;
    }

    /// Look up a retired identity by name.
    ///
    /// Exists purely so the diagnostic can be correct. `find` skips tombstoned entries,
    /// so re-declaring a retired name would otherwise report "no registry entry" — and
    /// the obvious response to that message is to add one, which means reallocating a
    /// permanently retired ID. The error has to say the opposite of what the reader is
    /// about to do.
    pub fn findTombstoned(self: Registry, kind: Kind, name: []const u8) ?Entry {
        for (self.entries) |e| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name) and e.tombstoned) return e;
        }
        return null;
    }
};

fn valueOf(tokens: []const []const u8, key: []const u8) ?[]const u8 {
    for (tokens) |tok| {
        if (std.mem.startsWith(u8, tok, key) and
            tok.len > key.len and tok[key.len] == '=')
        {
            return tok[key.len + 1 ..];
        }
    }
    return null;
}

/// Parse the registry text. Intended for comptime use; `@compileError` on malformed
/// input, because a registry that does not parse must never produce a partial manifest.
pub fn parse(comptime text: []const u8) Registry {
    comptime {
        @setEvalBranchQuota(200_000);

        var entries: []const Entry = &.{};
        var lines = std.mem.splitScalar(u8, text, '\n');

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var tok_iter = std.mem.tokenizeAny(u8, line, " \t");
            var tokens: []const []const u8 = &.{};
            while (tok_iter.next()) |t| tokens = tokens ++ [_][]const u8{t};
            if (tokens.len < 3) @compileError("registry: malformed line: " ++ line);

            var idx: usize = 0;
            var tombstoned = false;
            if (std.mem.eql(u8, tokens[0], "tombstone")) {
                tombstoned = true;
                idx = 1;
            }

            const kind_text = tokens[idx];
            const name = tokens[idx + 1];

            const is_field = std.mem.indexOfScalar(u8, name, '.') != null;
            const kind: Kind = if (std.mem.eql(u8, kind_text, "component"))
                (if (is_field) .field else .component)
            else if (std.mem.eql(u8, kind_text, "event"))
                .event
            else if (std.mem.eql(u8, kind_text, "rpc"))
                .rpc
            else if (std.mem.eql(u8, kind_text, "lease"))
                .lease
            else
                @compileError("registry: unknown kind '" ++ kind_text ++ "' on line: " ++ line);

            const id_text = valueOf(tokens, "id") orelse
                @compileError("registry: missing id= on line: " ++ line);
            const id = std.fmt.parseInt(u32, id_text, 0) catch
                @compileError("registry: bad id '" ++ id_text ++ "' on line: " ++ line);

            const wire_text = valueOf(tokens, "wire");
            const wire_type: ?wire.WireType = if (wire_text) |wt|
                wire.WireType.parse(wt) orelse
                    @compileError("registry: unknown wire type '" ++ wt ++ "' on line: " ++ line)
            else
                null;

            entries = entries ++ [_]Entry{.{
                .kind = kind,
                .name = name,
                .id = id,
                .introduced = valueOf(tokens, "introduced") orelse "0.0",
                .deprecated = valueOf(tokens, "deprecated"),
                .wire_type = wire_type,
                .tombstoned = tombstoned,
                .retired = valueOf(tokens, "retired"),
            }};
        }

        // No duplicate live identities, and no ID issued twice within one space.
        for (entries, 0..) |a, i| {
            for (entries[i + 1 ..]) |b| {
                if (a.kind == b.kind and std.mem.eql(u8, a.name, b.name) and
                    !a.tombstoned and !b.tombstoned)
                {
                    @compileError("registry: duplicate identity '" ++ a.name ++ "'");
                }
                if (a.kind == b.kind and a.id == b.id) {
                    @compileError("registry: id collision on '" ++ a.name ++ "' and '" ++ b.name ++ "'");
                }
            }
        }

        const frozen = entries;
        return .{ .entries = frozen };
    }
}

/// The project's registry.
pub const registry: Registry = parse(@embedFile("registry_text"));

test "registry parses and exposes the spec's worked example" {
    const t = registry.find(.component, "Transform").?;
    try std.testing.expectEqual(@as(u32, 0x0041), t.id);

    const pos = registry.find(.field, "Transform.position").?;
    try std.testing.expectEqual(@as(u32, 0x00410001), pos.id);
    try std.testing.expectEqual(wire.WireType.vec3_quantized, pos.wire_type.?);
    try std.testing.expectEqualStrings("Transform", pos.owner().?);
    try std.testing.expectEqualStrings("position", pos.leaf());
}

test "tombstoned identities are not findable and their ids are burned" {
    // Health.value was u16 and became q16.16, which is a new identity per §2.
    try std.testing.expect(registry.find(.field, "Health.value") == null);
    try std.testing.expect(registry.isTombstoned(0x00550002));
    try std.testing.expect(registry.isTombstoned(0x00410003));
    try std.testing.expect(!registry.isTombstoned(0x00550007));
}

test "events and rpcs occupy separate id spaces from components" {
    const fired = registry.find(.event, "WeaponFired").?;
    const extract = registry.find(.rpc, "RequestExtraction").?;
    try std.testing.expectEqual(@as(u32, 0x0102), fired.id);
    try std.testing.expectEqual(@as(u32, 0x0301), extract.id);
}
