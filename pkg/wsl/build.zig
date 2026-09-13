const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The Windows-side half, imported by libghostty as `wsl`.
    _ = b.addModule("wsl", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The in-distro half runs inside the WSL distro, so it is a static
    // Linux binary whatever the host targets.
    const helper = b.addExecutable(.{
        .name = "ghostty-wsl-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bridge/helper.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .musl,
            }),
            .optimize = optimize,
        }),
    });
    b.installArtifact(helper);

    // The protocol is the part both halves share and the only part
    // that builds on any host, so it is what the tests cover.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bridge/protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
