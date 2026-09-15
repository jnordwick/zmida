const std = @import("std");
const root = @import("root.zig");
pub const util = @import("util.zig");
pub const time = @import("time.zig");
pub const stats = @import("stats.zig");
pub const out = @import("out.zig");
const perf = @import("perf.zig");
const ArrayList = std.array_list.Managed;
const ArgsTuple = std.meta.ArgsTuple;
const Allocator = std.mem.Allocator;
const TimedConfig = root.TimedConfig;
const CountConfig = root.CountConfig;
const Trial = root.Trial;
const Env = root.Env;
const Sample = root.Sample;
const Clock = time.Clock;
const Timer = time.Timer;
const dno = std.mem.doNotOptimizeAway;

inline fn call(func: anytype, arg: anytype, comptime as_tuple: bool) void {
    dno(arg);
    dno(@call(.auto, func, if (as_tuple) arg.* else .{arg.*}));
}

fn assign_sample(sample: *Sample, ps: *perf.Sample) void {
    sample.cpu_perf.time_enabled = ps.enabled;
    sample.cpu_perf.time_running = ps.running;
    sample.cpu_perf.instructions = ps.records[0];
    sample.cpu_perf.cpu_cycles = ps.records[1];
    sample.cpu_perf.branch_miss = ps.records[2];
    sample.cpu_perf.branch_total = ps.records[3];
}

pub fn count_sample(env: Env, sweeps: u64, func: anytype, args: anytype, comptime as_tuple: bool) !Sample {
    var sample: Sample = .{};
    var timer: Timer = undefined;
    if (env.perf) |e| {
        try e.reset();
        try e.enable();
    }
    timer.start();
    for (0..sweeps) |_| {
        for (args) |*a| {
            call(func, a, as_tuple);
        }
    }
    timer.stop();
    if (env.perf) |p| {
        try p.disable();
        var ps: perf.Sample = .{};
        try p.read(&ps);
        assign_sample(&sample, &ps);
    }
    sample.calls = sweeps * args.len;
    sample.nanos = timer.nanos();
    return sample;
}

pub fn set_bool(start: *std.atomic.Value(bool), stop: *std.atomic.Value(bool), nanos: u64) void {
    while (!start.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    time.pause_for(nanos);
    stop.store(true, .release);
}

pub fn timed_sample(env: Env, nanos: u64, func: anytype, args: anytype, comptime as_tuple: bool) !Sample {
    var sample: Sample = .{};
    var start: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var timer_thread = std.Thread.spawn(
        .{},
        set_bool,
        .{ &start, &done, nanos },
    ) catch @panic("could not spawn");
    var timer: Timer = undefined;
    var sweeps: u64 = 0;
    start.store(true, .release);
    if (env.perf) |e| {
        try e.reset();
        try e.enable();
    }
    timer.start();
    while (!done.load(.acquire)) {
        for (args) |*a| {
            call(func, a, as_tuple);
        }
        sweeps += 1;
    }
    timer.stop();
    if (env.perf) |p| {
        try p.disable();
        var ps: perf.Sample = .{};
        try p.read(&ps);
        assign_sample(&sample, &ps);
    }
    sample.calls = sweeps * args.len;
    sample.nanos = timer.nanos();
    timer_thread.join();

    return sample;
}

pub fn timed_trial(env: Env, config: TimedConfig, func: anytype, Elem_t: type, args: []const Elem_t) !Trial {
    const as_tuple = util.is_tuple(Elem_t);
    var trial: Trial = .init(env, util.get_fname(func));
    trial.samples = config.trial_samples;
    try trial.data.ensureTotalCapacity(config.trial_samples);
    trial.sweeps = 0;
    trial.calls = args.len;

    // warmup
    if (env.perf) |e| try e.enable();
    const sample_nanos = try std.math.divCeil(u64, config.trial_nanos, config.trial_samples);
    const sample_millis: f64 = @as(f64, @floatFromInt(sample_nanos)) / 1e6;
    root.verbose(1, "  Trial {s} with {d} samples @ {d:.3}ms", .{ trial.name, trial.samples, sample_millis });
    dno(try timed_sample(env, config.warmup_nanos, func, args, as_tuple));
    // reinstall to clear time counters
    if (env.perf) |e| try e.reinstall();
    for (0..trial.samples) |i| {
        root.verbose(2, " {d}", i + 1);
        var res = try timed_sample(env, sample_nanos, func, args, as_tuple);
        res.ord = i;
        try trial.data.append(res);
    }
    root.verbose(1, "\n", .{});

    if (env.perf) |_| {
        const tdlen = trial.data.items.len;
        for (1..tdlen) |i| {
            trial.data.items[tdlen - i].cpu_perf.time_enabled -= trial.data.items[tdlen - i - 1].cpu_perf.time_enabled;
            trial.data.items[tdlen - i].cpu_perf.time_running -= trial.data.items[tdlen - i - 1].cpu_perf.time_running;
        }
    }

    return trial;
}

pub fn count_trial(env: Env, config: CountConfig, func: anytype, Elem_t: type, args: []const Elem_t) !Trial {
    const as_tuple = util.is_tuple(Elem_t);
    var trial: Trial = .init(env, util.get_fname(func));
    trial.samples = config.trial_samples;
    try trial.data.ensureTotalCapacity(config.trial_samples);
    trial.sweeps = config.sample_sweeps;
    trial.calls = args.len;
    // warmup
    if (env.perf) |e| try e.enable();
    dno(try count_sample(env, config.warmup_sweeps, func, args, as_tuple));
    // reinstall to clear time counters
    if (env.perf) |e| try e.reinstall();
    for (0..trial.samples) |i| {
        var res = try count_sample(env, trial.sweeps, func, args, as_tuple);
        res.ord = i;
        try trial.data.append(res);
    }
    if (env.perf) |_| {
        const tdlen = trial.data.items.len;
        for (1..tdlen) |i| {
            trial.data.items[tdlen - i].cpu_perf.time_enabled -= trial.data.items[tdlen - i - 1].cpu_perf.time_enabled;
            trial.data.items[tdlen - i].cpu_perf.time_running -= trial.data.items[tdlen - i - 1].cpu_perf.time_running;
        }
    }
    return trial;
}

const tt = std.testing;

test "refalldecls" {
    std.testing.refAllDecls(@This());
}

test "count_samples single" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }
    const args_slice: []f64 = &args;

    const t = try count_sample(env, 10, std.math.sin, args_slice, false);
    try tt.expect(t.calls == 10000);
}

test "count_samples multiple" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const arg_t = struct { comptime type = f64, f64, f64 };

    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]arg_t = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }
    const args_slice: []arg_t = &args;

    const t = try count_sample(env, 10, std.math.log, args_slice, true);
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
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }
    const args_slice: []f64 = &args;

    const t = try timed_sample(env, 50 * 1000 * 1000, std.math.sin, args_slice, false);
    try tt.expect(t.calls % 1000 == 0);
    try tt.expect(t.nanos > 50 * 1000 * 1000);
    try tt.expect(t.nanos < 51 * 1000 * 1000);
}

test "timed_samples multiple" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const arg_t = struct { comptime type = f64, f64, f64 };

    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]arg_t = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }
    const args_slice: []arg_t = &args;

    const t = try timed_sample(env, 50 * 1000 * 1000, std.math.log, args_slice, true);
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
