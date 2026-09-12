const std = @import("std");
const root = @import("root.zig");
pub const util = @import("util.zig");
pub const stats = @import("stats.zig");
pub const out = @import("out.zig");
const ArrayList = std.array_list.Managed;
const ArgsTuple = std.meta.ArgsTuple;
const Allocator = std.mem.Allocator;
const TimedConfig = root.TimedConfig;
const CountConfig = root.CountConfig;
const Trial = root.Trial;
const Env = root.Env;
const Sample = root.Sample;

inline fn call(func: anytype, arg: anytype, comptime as_tuple: bool) void {
    util.dno(arg);
    util.dno(@call(.auto, func, if (as_tuple) arg.* else .{arg.*}));
}

pub fn count_samples(sweeps: u64, func: anytype, args: anytype, comptime as_tuple: bool) Sample {
    const start = util.now();
    for (0..sweeps) |_| {
        for (args) |*a| {
            call(func, a, as_tuple);
        }
    }
    const stop = util.now();
    return .{ .ord = 0, .calls = sweeps * args.len, .nanos = stop - start };
}

pub fn timed_sample(nanos: u64, func: anytype, args: anytype, comptime as_tuple: bool) Sample {
    var done: std.atomic.Value(bool) = .init(false);
    var start: std.atomic.Value(u64) = .init(0);
    var timer = std.Thread.spawn(
        .{},
        util.set_bool,
        .{ &done, &start, nanos },
    ) catch @panic("could not spawn");

    var sweeps: u64 = 0;
    start.store(util.now(), .release);
    while (!done.load(.acquire)) {
        for (args) |*a| {
            call(func, a, as_tuple);
        }
        sweeps += 1;
    }
    const stop = util.now();
    timer.join();

    return .{ .ord = 0, .calls = sweeps * args.len, .nanos = stop - start.raw };
}

pub fn timed_trial(env: root.Env, config: TimedConfig, func: anytype, Elem_t: type, args: []const Elem_t) !Trial {
    const as_tuple = util.is_tuple(Elem_t);
    var trial: Trial = .init(env, util.get_fname(func));
    trial.samples = config.trial_samples;
    try trial.data.ensureTotalCapacity(config.trial_samples);
    trial.sweeps = 0;
    trial.calls = args.len;

    _ = timed_sample(config.warmup_nanos, func, args, as_tuple);
    const sample_nanos = try std.math.divCeil(u64, config.trial_nanos, config.trial_samples);
    root.verbose(1, "  Trial {s} with {d} samples:", .{ trial.name, trial.samples });
    for (0..trial.samples) |i| {
        root.verbose(2, " {d}", i + 1);
        var res = timed_sample(sample_nanos, func, args, as_tuple);
        res.ord = i;
        try trial.data.append(res);
    }
    root.verbose(1, "\n", .{});
    return trial;
}

pub fn count_trial(env: Env, config: CountConfig, func: anytype, Elem_t: type, args: []const Elem_t) !Trial {
    const as_tuple = util.is_tuple(Elem_t);
    var trial: Trial = .init(env, util.get_fname(func));
    trial.samples = config.trial_samples;
    try trial.data.ensureTotalCapacity(config.trial_samples);
    trial.sweeps = config.sample_sweeps;
    trial.calls = args.len;

    const warmres = count_samples(config.warmup_sweeps, func, args, as_tuple);
    util.dno(warmres);
    try trial.data.append(warmres);
    trial.data.clearRetainingCapacity();
    for (0..trial.samples) |i| {
        var res = count_samples(trial.sweeps, func, args, as_tuple);
        res.ord = i;
        try trial.data.append(res);
    }
    return trial;
}

const tt = std.testing;

test "refalldecls" {
    std.testing.refAllDecls(@This());
}

test "count_samples single" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }
    const args_slice: []f64 = &args;

    const t = count_samples(10, std.math.sin, args_slice, false);
    try tt.expect(t.calls == 10000);
}

test "count_samples multiple" {
    const arg_t = struct { comptime type = f64, f64, f64 };

    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]arg_t = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }
    const args_slice: []arg_t = &args;

    const t = count_samples(10, std.math.log, args_slice, true);
    try tt.expect(t.calls == 10000);
}

test "count_trial single" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }

    var t = try Trial.run(env, CountConfig{
        .warmup_sweeps = 3,
        .trial_samples = 10,
        .sample_sweeps = 5,
    }, std.math.sin, args);
    defer t.deinit();
    try tt.expect(t.data.items.len > 0);
}

test "count_trial multiple" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]struct { comptime type = f64, f64, f64 } = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }

    var t = try Trial.run(env, CountConfig{
        .warmup_sweeps = 3,
        .trial_samples = 10,
        .sample_sweeps = 5,
    }, std.math.log, args);
    defer t.deinit();
    try tt.expect(t.data.items.len > 0);
}

test "timed_samples single" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }
    const args_slice: []f64 = &args;

    const t = timed_sample(50 * 1000 * 1000, std.math.sin, args_slice, false);
    try tt.expect(t.calls % 1000 == 0);
    try tt.expect(t.nanos > 50 * 1000 * 1000);
    try tt.expect(t.nanos < 51 * 1000 * 1000);
}

test "timed_samples multiple" {
    const arg_t = struct { comptime type = f64, f64, f64 };

    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]arg_t = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }
    const args_slice: []arg_t = &args;

    const t = timed_sample(50 * 1000 * 1000, std.math.log, args_slice, true);
    try tt.expect(t.calls % 1000 == 0);
    try tt.expect(t.nanos > 50 * 1000 * 1000);
    try tt.expect(t.nanos < 51 * 1000 * 1000);
}

test "timed_trial single" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }

    var t = try Trial.run(env, TimedConfig{
        .warmup_nanos = 50 * 1e6,
        .trial_nanos = 100 * 1e6,
        .trial_samples = 10,
    }, std.math.sin, args);
    defer t.deinit();
}

test "timed_trial multiple" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]struct { comptime type = f64, f64, f64 } = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }

    var t = try Trial.run(env, TimedConfig{
        .warmup_nanos = 50 * 1e6,
        .trial_nanos = 100 * 1e6,
        .trial_samples = 10,
    }, std.math.log, args);
    defer t.deinit();
    try tt.expect(t.data.items.len > 0);
}
