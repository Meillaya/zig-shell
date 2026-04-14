const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zig_shell", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zig-shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig_shell", .module = mod },
            },
        }),
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zig-shell");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = mod });
    lib_tests.linkLibC();
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.linkLibC();
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const pty_smoke = b.addExecutable(.{
        .name = "pty-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/pty_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig_shell", .module = mod },
            },
        }),
    });
    pty_smoke.linkLibC();
    const run_pty_smoke = b.addRunArtifact(pty_smoke);
    run_pty_smoke.step.dependOn(b.getInstallStep());
    run_pty_smoke.addFileArg(exe.getEmittedBin());
    const pty_step = b.step("pty-smoke", "Run PTY smoke checks");
    pty_step.dependOn(&run_pty_smoke.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
