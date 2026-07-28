const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The portable engine. Its imports are wired after the modules it depends on.
    const mod = b.addModule("bedlam_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Schema, identity, and manifest generation. docs/SCHEMA_AND_EVOLUTION.md.
    //
    // The registry is embedded rather than read at runtime: parsing it at comptime is
    // what makes §10 checks 1, 2, 3, 9 and 10 build failures instead of test failures.
    // A violation produces no binary, which is the point — an engine that compiles with
    // a reused tombstone will ship with one.
    const schema_mod = b.addModule("bedlam_schema", .{
        .root_source_file = b.path("src/schema/root.zig"),
        .target = target,
    });
    schema_mod.addAnonymousImport("registry_text", .{
        .root_source_file = b.path("schema/registry.txt"),
    });

    // Wire format: bit packing, quantization, generated codecs.
    //
    // AGENTS.md §3 puts packet parse in ReleaseSafe regardless of the surrounding build
    // mode. This is the untrusted side of a trust boundary (§14.2) and Zig's safety
    // checks are cheaper than the CVE. The optimize mode is set here rather than left to
    // the caller so the rule is enforced by the build graph, not by convention.
    const wire_mod = b.addModule("bedlam_wire", .{
        .root_source_file = b.path("src/wire/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    wire_mod.addImport("bedlam_schema", schema_mod);

    mod.addImport("bedlam_schema", schema_mod);
    mod.addImport("bedlam_wire", wire_mod);

    const t = target.result;
    const is_wasm_freestanding = t.cpu.arch.isWasm() and t.os.tag == .freestanding;
    const is_ios = t.os.tag == .ios;
    const hosts_own_entry_point = is_wasm_freestanding or is_ios;

    // Neither the browser nor an iOS app owns its own entry point, so neither target
    // is an executable:
    //
    //   Web — a module the TypeScript bootstrap instantiates inside a Worker
    //         (docs/ARCHITECTURE.md §2, §4.1). Rooting it at src/main.zig pulls
    //         std.process.Init -> std.Io.Threaded -> posix.getrandom and IOV_MAX,
    //         none of which exist on freestanding wasm. See src/web.zig.
    //
    //   iOS — a static library an Xcode app target links, with UIApplicationMain
    //         living in a thin Objective-C TU (§2, §4.1). A static archive has no
    //         link step, so it never needs libSystem at all. Linking an iOS
    //         *executable* additionally requires a --libc file naming the SDK's
    //         usr/include; --sysroot alone does not work (ziglang/zig#19217). CI
    //         supplies that via ZIG_LIBC so the row stays honest once C or
    //         Objective-C translation units appear.
    //
    // Building either as an executable would yield a green check for an artifact
    // that cannot launch, which §18.20 exists to forbid.
    const artifact = if (is_wasm_freestanding) blk: {
        const web = b.addExecutable(.{
            .name = "bedlam_engine",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/web.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "bedlam_engine", .module = mod }},
            }),
        });
        web.entry = .disabled;
        web.rdynamic = true;
        break :blk web;
    } else if (is_ios) b.addLibrary(.{
        .name = "bedlam_engine",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }) else b.addExecutable(.{
        .name = "bedlam_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bedlam_engine", .module = mod }},
        }),
    });

    b.installArtifact(artifact);

    // `zig build run` is meaningless without an entry point.
    if (!hosts_own_entry_point) {
        const run_cmd = b.addRunArtifact(artifact);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // The manifest generator. A host tool: it always runs natively, so per-target
    // physical layout cannot reach the manifest even by accident (§10 check 5).
    const emit = b.addExecutable(.{
        .name = "emit_manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/emit_manifest.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "bedlam_schema", .module = schema_mod }},
        }),
    });

    const emit_run = b.addRunArtifact(emit);
    const manifest_file = emit_run.addOutputFileArg("manifest.txt");
    const install_manifest = b.addInstallFileWithDir(manifest_file, .prefix, "schema/manifest.txt");

    const schema_step = b.step("schema", "Emit the canonical schema manifest");
    schema_step.dependOn(&install_manifest.step);

    // Test executables cover one module each.
    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const artifact_tests = b.addTest(.{ .root_module = artifact.root_module });
    test_step.dependOn(&b.addRunArtifact(artifact_tests).step);

    const schema_tests = b.addTest(.{ .root_module = schema_mod });
    test_step.dependOn(&b.addRunArtifact(schema_tests).step);

    const wire_tests = b.addTest(.{ .root_module = wire_mod });
    test_step.dependOn(&b.addRunArtifact(wire_tests).step);
}
