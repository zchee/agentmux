const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link ncurses/tinfo for terminfo
    root_mod.linkSystemLibrary("ncurses", .{});

    // Link freetype for font rasterization
    root_mod.linkSystemLibrary("freetype", .{});

    // Platform-specific linking
    if (root_mod.resolved_target) |resolved| {
        switch (resolved.result.os.tag) {
            .macos => {
                root_mod.linkFramework("CoreFoundation", .{});
                root_mod.linkFramework("CoreGraphics", .{});
                root_mod.linkFramework("Metal", .{});
                root_mod.linkFramework("QuartzCore", .{});
                root_mod.linkFramework("IOKit", .{});
            },
            .linux => {
                root_mod.linkSystemLibrary("vulkan", .{});
            },
            else => {},
        }
    }

    const exe = b.addExecutable(.{
        .name = "agentmux",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run agentmux");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkSystemLibrary("ncurses", .{});
    test_mod.linkSystemLibrary("freetype", .{});

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
