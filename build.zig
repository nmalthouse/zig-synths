const std = @import("std");

const system_libs = [_][]const u8{ "jack", "fftw3f" };

//Add a exe with all the libraries linked
fn addExecutable(b: *std.Build, targ: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, ratdep: *std.Build.Module, name: []const u8, main_src: []const u8) void {
    const exe = b.addExecutable(.{
        .name = name,
        .link_libc = true,
        .root_source_file = b.path(main_src),
        .target = targ,
        .optimize = opt,
    });

    exe.root_module.addImport("graph", ratdep);
    exe.addSystemIncludePath(.{ .cwd_relative = "/usr/lib" });
    for (system_libs) |sys| {
        exe.linkSystemLibrary2(sys, .{});
    }
    b.installArtifact(exe);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const ratdep = b.dependency("ratgraph", .{ .target = target, .optimize = optimize });
    const ratmod = ratdep.module("ratgraph");

    addExecutable(b, target, optimize, ratmod, "zig-jack", "src/main.zig");
    addExecutable(b, target, optimize, ratmod, "sinegen", "src/sine_gen.zig");
    addExecutable(b, target, optimize, ratmod, "delay", "src/delay.zig");
    addExecutable(b, target, optimize, ratmod, "filter", "src/filter_test.zig");
}
