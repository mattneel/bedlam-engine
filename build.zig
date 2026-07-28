const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const m = engineModules(b, target, optimize, true);
    const mod = m.engine;
    const schema_mod = m.schema;
    const wire_mod = m.wire;
    const world_mod = m.world;
    const sim_mod = m.sim;
    const net_mod = m.net;
    // Platform shims. ARCHITECTURE.md §4.1 and AGENTS.md §4's M0 criteria.
    //
    // Deliberately NOT imported by src/root.zig: §18.9 forbids platform SDK types in
    // portable code, and the dependency running one way is what makes that structural
    // rather than aspirational.
    const platform_mod = b.addModule("bedlam_platform", .{
        .root_source_file = b.path("platform/root.zig"),
        .target = target,
        .optimize = optimize,
        // libc on Linux, for `dlopen` only.
        //
        // `platform/linux/window.zig` loads X11 at RUNTIME rather than linking it, which
        // is what keeps the Linux row cross-compilable from a host with no X11 headers
        // (docs/CI_TIERS.md §4). `dlopen` itself lives in libc, so libc must be linked —
        // but Zig bundles glibc stubs, so this costs nothing in cross-compilability and
        // is a much smaller dependency than libX11 development headers.
        //
        // Not set on other targets: Windows reaches the OS through its own DLL imports,
        // and freestanding wasm has no libc at all.
        //
        // **Android is excluded, and it is `os.tag == .linux` too.** Zig cannot provide
        // libc for `aarch64-linux-android` without the NDK, so including it here turned
        // the Android build row red — a row that had been green precisely because it
        // needed no SDK. Android's backend is not X11 either; it gets its own when
        // GameActivity lands.
        .link_libc = target.result.os.tag == .linux and target.result.abi != .android,
        .imports = &.{.{ .name = "bedlam_audio", .module = m.audio }},
    });

    // Kept in step with `src/root.zig` by a test, not by build.zig cleverness.
    //
    // Reading it out of the source with `@embedFile` was the first attempt and it does not
    // work from the build runner. A test that asserts the two agree is better anyway: it
    // fails with a message naming both values, where a build-graph trick fails with a
    // compile error about a marker string.
    const engine_version = "0.0.0-M0";

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
            .imports = &.{
                .{ .name = "bedlam_engine", .module = mod },
                // main.zig is the platform entry point, so it may see the platform layer.
                // src/root.zig may not — §18.9, and the dependency running one way is
                // what makes that structural.
                .{ .name = "bedlam_platform", .module = platform_mod },
            },
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

    // AGENTS.md §3 and ARCHITECTURE.md §7. A build step rather than only a library
    // function, because §7 requires this to run in CI and a check nobody invokes is not
    // a check.
    if (!hosts_own_entry_point) {
        const verify = b.addRunArtifact(artifact);
        verify.addArg("--verify-determinism");
        verify.has_side_effects = true;
        const verify_step = b.step("verify-determinism", "Hash every tick and require identical results under schedule permutation");
        verify_step.dependOn(&verify.step);
    }

    // wasm32 conformance probe. ARCHITECTURE.md §7's claim is hardest to hold on this
    // target — 32-bit, a different ISA, a different backend — so it is the one worth
    // checking against the native build automatically.
    const wasm_target = b.resolveTargetQuery(std.Target.Query.parse(
        .{ .arch_os_abi = "wasm32-freestanding" },
    ) catch @panic("bad wasm triple"));
    const wasm_mods = engineModules(b, wasm_target, .ReleaseSmall, false);

    const web_wasm = b.addExecutable(.{
        .name = "bedlam_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "bedlam_engine", .module = wasm_mods.engine }},
        }),
    });
    web_wasm.entry = .disabled;
    web_wasm.rdynamic = true;

    const install_wasm = b.addInstallFileWithDir(
        web_wasm.getEmittedBin(),
        .{ .custom = "../tools/web" },
        "bedlam_engine.wasm",
    );
    const web_step = b.step("web", "Build the wasm32 module into tools/web");
    web_step.dependOn(&install_wasm.step);

    // The archive itself. Built only where there is an executable to package — the Web
    // and iOS rows produce a module and a static library, and "package" means something
    // different for each (a served bundle, an Xcode app target). Pretending one step
    // covers all three is how criterion 10 would look done without being.
    if (!hosts_own_entry_point) {
        const emit_pkg = b.addExecutable(.{
            .name = "emit_package",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/emit_package.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
                .imports = &.{.{ .name = "bedlam_schema", .module = schema_mod }},
            }),
        });

        const run_pkg = b.addRunArtifact(emit_pkg);
        const archive = run_pkg.addOutputFileArg("bedlam.tar");
        run_pkg.addArg(engine_version);
        run_pkg.addArg(b.fmt("{s}-{s}", .{ @tagName(t.cpu.arch), @tagName(t.os.tag) }));
        run_pkg.addArtifactArg(artifact);
        run_pkg.addFileArg(manifest_file);

        const install_pkg = b.addInstallFileWithDir(archive, .prefix, b.fmt(
            "package/bedlam-{s}-{s}-{s}.tar",
            .{ engine_version, @tagName(t.cpu.arch), @tagName(t.os.tag) },
        ));
        const package_step = b.step("package", "Assemble a reproducible distributable archive");
        package_step.dependOn(&install_pkg.step);
    }

    const schema_step = b.step("schema", "Emit the canonical schema manifest");
    schema_step.dependOn(&install_manifest.step);

    // Test executables cover one module each.
    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // The package builder is a host tool and its tests run with everything else: a package
    // that is not reproducible cannot be verified, and that deserves a test, not a hope.
    //
    // The version build.zig uses for the archive name is passed in, so a test can assert it
    // matches the engine's. Two copies is how a package ends up labelled with a version the
    // binary inside it disagrees on, and that surfaces to whoever is trying to reproduce a
    // bug from a release. `@embedFile("../build.zig")` was the first attempt and is refused
    // — a module may not embed outside its own path.
    const pkg_opts = b.addOptions();
    pkg_opts.addOption([]const u8, "engine_version", engine_version);

    const package_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/package.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "bedlam_engine", .module = mod },
            .{ .name = "build_options", .module = pkg_opts.createModule() },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(package_tests).step);

    const artifact_tests = b.addTest(.{ .root_module = artifact.root_module });
    test_step.dependOn(&b.addRunArtifact(artifact_tests).step);

    const schema_tests = b.addTest(.{ .root_module = schema_mod });
    test_step.dependOn(&b.addRunArtifact(schema_tests).step);

    const wire_tests = b.addTest(.{ .root_module = wire_mod });
    test_step.dependOn(&b.addRunArtifact(wire_tests).step);

    const platform_tests = b.addTest(.{ .root_module = platform_mod });
    test_step.dependOn(&b.addRunArtifact(platform_tests).step);

    const sim_tests = b.addTest(.{ .root_module = sim_mod });
    test_step.dependOn(&b.addRunArtifact(sim_tests).step);

    const world_tests = b.addTest(.{ .root_module = world_mod });
    test_step.dependOn(&b.addRunArtifact(world_tests).step);

    const audio_tests = b.addTest(.{ .root_module = m.audio });
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);

    const net_tests = b.addTest(.{ .root_module = net_mod });
    test_step.dependOn(&b.addRunArtifact(net_tests).step);

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
            const mods = engineModules(b, rt, mode, false);

            // `bedlam_audio` belongs in this gate: the mixer is integer Q16 arithmetic
            // over a comptime-built pan table with a `usize` sample cursor, and a
            // byte-order or word-size bug there is exactly the class this step catches.
            for ([_]*std.Build.Module{ mods.schema, mods.wire, mods.sim, mods.world, mods.net, mods.audio }) |m| {
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

/// Every engine module, wired for one target and optimize mode.
///
/// One definition used by the default build, the `web` step and the `cross` gate. Three
/// hand-maintained copies is how a module acquires an import in one place and not the
/// others — which is exactly the failure that broke the cross gate when `sim` started
/// depending on `world`.
const Modules = struct {
    schema: *std.Build.Module,
    audio: *std.Build.Module,
    wire: *std.Build.Module,
    world: *std.Build.Module,
    sim: *std.Build.Module,
    net: *std.Build.Module,
    engine: *std.Build.Module,
};

fn engineModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Named modules are visible to consumers of this package; anonymous ones are not.
    /// Only the default build should name them, or a second call collides.
    comptime named: bool,
) Modules {
    const create = struct {
        fn f(bb: *std.Build, comptime nm: bool, name: []const u8, opts: std.Build.Module.CreateOptions) *std.Build.Module {
            return if (nm) bb.addModule(name, opts) else bb.createModule(opts);
        }
    }.f;

    // ARCHITECTURE.md §7's fixed-point contract, pinned by commit (§14.2).
    const fpz = b.dependency("fpz", .{ .target = target, .optimize = optimize }).module("fpz");

    // The registry is embedded rather than read at runtime: parsing it at comptime is
    // what makes SCHEMA_AND_EVOLUTION.md §10 checks 1, 2, 3, 9 and 10 build failures
    // instead of test failures. An engine that compiles with a reused tombstone ships
    // with one.
    const schema = create(b, named, "bedlam_schema", .{
        .root_source_file = b.path("src/schema/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    schema.addAnonymousImport("registry_text", .{
        .root_source_file = b.path("schema/registry.txt"),
    });

    // AGENTS.md §3 puts packet parse in ReleaseSafe regardless of the surrounding build
    // mode: this is the untrusted side of a trust boundary (§14.2) and Zig's safety
    // checks are cheaper than the CVE. Set here so the rule lives in the build graph
    // rather than in a convention.
    const wire = create(b, named, "bedlam_wire", .{
        .root_source_file = b.path("src/wire/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    wire.addImport("bedlam_schema", schema);
    wire.addImport("fpz", fpz);

    const world = create(b, named, "bedlam_world", .{
        .root_source_file = b.path("src/world/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    world.addImport("bedlam_schema", schema);
    world.addImport("fpz", fpz);

    const sim = create(b, named, "bedlam_sim", .{
        .root_source_file = b.path("src/sim/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim.addImport("fpz", fpz);
    sim.addImport("bedlam_world", world);

    const net = create(b, named, "bedlam_net", .{
        .root_source_file = b.path("src/net/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    net.addImport("bedlam_wire", wire);
    net.addImport("bedlam_world", world);
    net.addImport("bedlam_schema", schema);
    net.addImport("fpz", fpz);

    // Portable audio: the SPSC command ring and the integer mixer. Engine code, not
    // platform code — see src/audio/root.zig. Depends on nothing, which is what lets it be
    // compiled into the browser module as well as linked by a native device backend.
    const audio = create(b, named, "bedlam_audio", .{
        .root_source_file = b.path("src/audio/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const engine = create(b, named, "bedlam_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("bedlam_schema", schema);
    engine.addImport("bedlam_wire", wire);
    engine.addImport("bedlam_world", world);
    engine.addImport("bedlam_sim", sim);
    engine.addImport("bedlam_net", net);
    engine.addImport("bedlam_audio", audio);
    engine.addImport("fpz", fpz);

    return .{ .schema = schema, .wire = wire, .world = world, .sim = sim, .net = net, .audio = audio, .engine = engine };
}
