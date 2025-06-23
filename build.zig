const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "libgifsample",
        .root_source_file = b.path("main.zig"),
        .optimize = optimize,
        .target = target,
    });

    const run_step = b.step("run", "run");
    const run_artifact = b.addRunArtifact(exe);
    const pixman = b.dependency("pixman", .{}).module("pixman");
    run_step.dependOn(&run_artifact.step);
    const gif = b.addTranslateC(.{
        .root_source_file = b.path("gif_lib.h"),
        .target = target,
        .optimize = optimize,
    });
    const cairo = b.addTranslateC(.{
        .root_source_file = b.path("cairo.h"),
        .target = target,
        .optimize = optimize,
    });
    const ffmpeg = b.addTranslateC(.{
        .root_source_file = b.path("ffmpeg.h"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("gif", gif.createModule());
    exe.root_module.addImport("ffmpeg", ffmpeg.createModule());
    exe.root_module.addImport("pixman", pixman);
    exe.root_module.addImport("cairo", cairo.createModule());
    b.installArtifact(exe);
    exe.linkSystemLibrary("gif");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("cairo");
    exe.linkSystemLibrary("libswscale");
    exe.linkSystemLibrary("avformat");
    exe.linkSystemLibrary("avcodec");
    exe.linkSystemLibrary("avutil");
    exe.linkLibC();
}
