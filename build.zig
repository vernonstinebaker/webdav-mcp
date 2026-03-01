const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "webdav-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Cross-compilation targets for release distribution
    const cross_targets = [_]struct {
        name: []const u8,
        triple: []const u8,
    }{
        .{ .name = "macos-arm64", .triple = "aarch64-macos-none" },
        .{ .name = "macos-x86_64", .triple = "x86_64-macos-none" },
        .{ .name = "linux-arm64", .triple = "aarch64-linux-musl" },
        .{ .name = "linux-x86_64", .triple = "x86_64-linux-musl" },
        .{ .name = "linux-armv7", .triple = "arm-linux-musleabihf" },
        .{ .name = "windows-x86_64", .triple = "x86_64-windows-gnu" },
    };

    const cross_step = b.step("cross", "Build release binaries for all platforms");

    inline for (cross_targets) |ct| {
        const cross_target = b.resolveTargetQuery(
            std.Target.Query.parse(.{ .arch_os_abi = ct.triple }) catch @panic("bad target"),
        );
        const cross_exe = b.addExecutable(.{
            .name = "webdav-mcp-" ++ ct.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = cross_target,
                .optimize = .ReleaseSmall,
            }),
        });
        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        });
        cross_step.dependOn(&install.step);
    }
}
