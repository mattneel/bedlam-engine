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

    // Deterministic fixed point. ARCHITECTURE.md §7 requires, inside the rollback
    // boundary: fixed point, no FMA contraction, no fast-math, and "own polynomial
    // transcendentals, never platform libm". fpz is exactly that contract — Q40.24 over
    // an i64, integer-only at runtime, float permitted only at comptime, and every
    // operation total (a defined result for all inputs, including overflow).
    //
    // Pinned by commit rather than branch: §14.2 requires reproducible builds, and a
    // moving dependency under a determinism claim is a determinism hazard.
    const fpz = b.dependency("fpz", .{ .target = target, .optimize = optimize });
    const fpz_mod = fpz.module("fpz");

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
    wire_mod.addImport("fpz", fpz_mod);

    mod.addImport("bedlam_schema", schema_mod);
    mod.addImport("bedlam_wire", wire_mod);
    mod.addImport("fpz", fpz_mod);

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

    addCrossStep(b);
}

/// Foreign-architecture verification under qemu.
///
/// `ARCHITECTURE.md` §7 says bit-exact cross-architecture float determinism is folklore
/// and that agreement is constructed, never assumed. Constructing it requires actually
/// running on a foreign architecture, and the CI matrix cannot: **all six shipping
/// targets are little-endian and, apart from wasm32, 64-bit.** So no target Bedlam ships
/// can falsify an endianness bug, and none of the ones that execute tests can falsify a
/// word-size bug.
///
/// Two live claims are currently constructed by comment rather than by test:
///
///   - `src/wire/bits.zig` fixes bit order LSB-first "not derived from host endianness".
///     s390x and mips are big-endian and will say whether that is true.
///   - `src/wire/bits.zig` widened bit offsets to u64 specifically for wasm32, and the
///     regression test asserts type widths rather than behaviour because no 32-bit
///     runner exists. arm and mips are usable word-size proxies for wasm32, which cannot
///     run a Zig test binary directly.
///
/// The mechanism is Zig's own: `enable_qemu` makes foreign `RunArtifact` steps execute
/// under qemu-user instead of being skipped. Nothing here links libc, so the test
/// binaries are static and qemu-user runs them directly.
///
/// Adapted from gkz's `zig build cross` (github.com/mattneel/gkz), which verifies the
/// same property for the same reason.
fn addCrossStep(b: *std.Build) void {
    const cross_step = b.step(
        "cross",
        "Run the test suite on foreign architectures under qemu (big-endian and 32-bit)",
    );

    // Set here rather than requiring `-fqemu` on the command line. Without it, foreign
    // RunArtifact steps are silently SKIPPED, and a skipped step reports success — the
    // failure mode where the gate appears green precisely because it never ran.
    b.enable_qemu = true;

    const triples = [_][]const u8{
        "aarch64-linux-gnu", // the other shipping ISA
        "s390x-linux-gnu", // big-endian, 64-bit
        "arm-linux-gnueabihf", // little-endian, 32-bit — word-size proxy for wasm32
        "mips-linux-gnu", // big-endian, 32-bit — both at once
    };
    const modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };

    // Serialized rather than parallel: qemu-user emulation is slow and these are
    // correctness checks, not a throughput exercise. Chaining also keeps the log
    // readable when one architecture fails and the others do not.
    var prev: ?*std.Build.Step = null;

    for (triples) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            @panic("cross: bad target triple");
        const rt = b.resolveTargetQuery(query);

        for (modes) |mode| {
            const fpz_dep = b.dependency("fpz", .{ .target = rt, .optimize = mode });

            const schema = b.createModule(.{
                .root_source_file = b.path("src/schema/root.zig"),
                .target = rt,
                .optimize = mode,
            });
            schema.addAnonymousImport("registry_text", .{
                .root_source_file = b.path("schema/registry.txt"),
            });

            const wire = b.createModule(.{
                .root_source_file = b.path("src/wire/root.zig"),
                .target = rt,
                .optimize = mode,
            });
            wire.addImport("bedlam_schema", schema);
            wire.addImport("fpz", fpz_dep.module("fpz"));

            for ([_]*std.Build.Module{ schema, wire }) |m| {
                const t = b.addTest(.{ .root_module = m });
                const run = b.addRunArtifact(t);
                // Foreign binaries are cached aggressively; without this a green run can
                // mean "did not execute" rather than "passed".
                run.has_side_effects = true;
                if (prev) |p| run.step.dependOn(p);
                prev = &run.step;
                cross_step.dependOn(&run.step);
            }
        }
    }
}
