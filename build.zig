const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The portable engine.
    const mod = b.addModule("bedlam_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const t = target.result;
    const is_wasm_freestanding = t.cpu.arch.isWasm() and t.os.tag == .freestanding;

    // The browser artifact is a module, not a program. Rooting it at src/main.zig
    // pulls std.process.Init, which pulls std.Io.Threaded, which needs posix
    // getrandom and IOV_MAX — none of which exist on freestanding wasm. See
    // src/web.zig.
    const exe = if (is_wasm_freestanding) blk: {
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
    } else b.addExecutable(.{
        .name = "bedlam_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bedlam_engine", .module = mod }},
        }),
    });

    b.installArtifact(exe);

    // `zig build run` is meaningless for a module with no entry point.
    if (!is_wasm_freestanding) {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // Test executables cover one module each, hence two.
    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
