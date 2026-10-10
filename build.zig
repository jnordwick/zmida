const std = @import("std");

const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

var ex_build_step: *std.Build.Step = undefined;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zmida", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const inc_examples = b.option(bool, "examples", "Build the example programs [default: false]") orelse false;
    // examples
    if (inc_examples) {
        ex_build_step = b.step("examples", "Build all examples");
        add_example(b, mod, &target, optimize, "readme");
        add_example(b, mod, &target, optimize, "basic");
        add_example(b, mod, &target, optimize, "simple");
        add_example(b, mod, &target, optimize, "gendata");
        add_example(b, mod, &target, optimize, "plots");
        add_example(b, mod, &target, optimize, "full");
        add_example(b, mod, &target, optimize, "loop");
    }

    // build test
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

fn add_example(
    b: *std.Build,
    mod: *std.Build.Module,
    target: *const ResolvedTarget,
    optimize: OptimizeMode,
    name: anytype,
) void {
    const example = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/" ++ name ++ ".zig"),
            .target = target.*,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zmida", .module = mod },
            },
        }),
    });
    const install_step = b.addInstallArtifact(example, .{});

    const build_step = b.step(
        "build-" ++ name,
        "Build and install " ++ name ++ " example",
    );
    build_step.dependOn(&install_step.step);
    ex_build_step.dependOn(build_step);

    const run_step = b.step(
        "run-" ++ name,
        "Run " ++ name ++ " example",
    );
    const run_cmd = b.addRunArtifact(example);
    run_step.dependOn(&run_cmd.step);

    run_cmd.addPassthruArgs();
}
