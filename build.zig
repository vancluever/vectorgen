// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2026 Chris Marchesi
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const skip_deps = b.option(
        bool,
        "skip_deps",
        "Skip loading in module dependencies (e.g., z2d; addImport must be run on loaded modules if true)",
    ) orelse false;

    const z2d_dep: ?*std.Build.Dependency = if (!skip_deps)
        b.dependency("z2d", .{
            .target = target,
            .optimize = optimize,
            .float_precision = .single,
        })
    else
        null;

    const vectorgen_mod = b.addModule("vectorgen", .{
        .root_source_file = b.path("src/vectorgen.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (z2d_dep) |dep| vectorgen_mod.addImport("z2d", dep.module("z2d"));

    const vectorgen_test = b.addTest(.{
        .name = "vectorgen-test",
        .root_module = vectorgen_mod,
        .use_llvm = true,
    });

    b.step("test", "run tests").dependOn(&b.addRunArtifact(vectorgen_test).step);
    const check_step = b.step("check", "build, but don't run tests");
    check_step.dependOn(&vectorgen_test.step);

    if (z2d_dep) |dep| {
        const reserialize = b.addExecutable(.{
            .name = "reserialize",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cmd/reserialize.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        reserialize.root_module.addImport("vectorgen", vectorgen_mod);
        reserialize.root_module.addImport("z2d", dep.module("z2d"));
        b.installArtifact(reserialize);
        check_step.dependOn(&reserialize.step);

        const text2vec = b.addExecutable(.{
            .name = "text2vec",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cmd/text2vec.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        text2vec.root_module.addImport("vectorgen", vectorgen_mod);
        text2vec.root_module.addImport("z2d", dep.module("z2d"));
        b.installArtifact(text2vec);
        check_step.dependOn(&text2vec.step);
    }
}
