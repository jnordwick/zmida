const std = @import("std");

const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

var ex_build_step: *std.Build.Step = undefined;
var ex_run_step: *std.Build.Step = undefined;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zmida", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // main.zig
    const exe = b.addExecutable(.{
        .name = "zmida",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zmida", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // examples
    ex_build_step = b.step("examples", "Build all examples");
    ex_run_step = b.step("run-examples", "Run all examples");

    // tried to automate this build way too much of a hassle having to basically,
    // use C to write a build script.
    add_example(b, mod, &target, &optimize, "basic");
    add_example(b, mod, &target, &optimize, "simple");
    add_example(b, mod, &target, &optimize, "gendata");

    // build test
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn add_example(
    b: *std.Build,
    mod: *std.Build.Module,
    target: *const ResolvedTarget,
    optimize: *const OptimizeMode,
    name: anytype,
) void {
    const example = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/" ++ name ++ ".zig"),
            .target = target.*,
            .optimize = optimize.*,
            .imports = &.{
                .{ .name = "zmida", .module = mod },
            },
        }),
    });

    const build_step = b.step(
        "build-" ++ name,
        "Build " ++ name ++ " example",
    );
    build_step.dependOn(&example.step);
    ex_build_step.dependOn(build_step);

    const run_step = b.step(
        "run-" ++ name,
        "Run " ++ name ++ " example",
    );
    const run_cmd = b.addRunArtifact(example);
    run_step.dependOn(&run_cmd.step);
    ex_run_step.dependOn(run_step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
