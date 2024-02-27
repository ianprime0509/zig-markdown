const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-markdown",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/markdown.zig" },
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run", "Run the executable").dependOn(&run.step);

    const tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/markdown.zig" },
    });
    tests.filters = b.option([]const []const u8, "test-filter", "Test filter") orelse &.{};
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);
}
