const std = @import("std");
pub const util = @import("util.zig");
pub const stats = @import("stats.zig");
pub const out = @import("out.zig");
const ArrayList = std.array_list.Managed;
const ArgsTuple = std.meta.ArgsTuple;
const Allocator = std.mem.Allocator;

pub const TrialStats = stats.TrialStats;

/// A trial is the result of a series of samples. A sample is
/// a number of sweeps over the args slice given
pub const Trial = struct {
    name: []const u8 = "(none)",
    samples: u64 = 0, // samples per trial, data.len
    sweeps: u64 = 0, // sweeps per sample, 0 = dynamic
    calls: u64 = 0, // calls per sweep, args.len

    data: ArrayList(Sample),

    pub fn init(alloc: Allocator) Trial {
        return .{ .data = .init(alloc) };
    }

    pub fn deinit(this: @This()) void {
        this.data.deinit();
    }
};

/// trial with set number of samples and set number of sweeps per sample
pub const CountConfig = struct {
    warmup_sweeps: u32 = 5000,
    trial_samples: u32 = 10000,
    sample_sweeps: u32 = 20,
};

/// trial for a set number of seconds and set number of samples
pub const TimedConfig = struct {
    warmup_nanos: u32 = 100 * 1e6, // 100 milliseconds
    trial_nanos: u64 = 1 * 1e9, // 1 second
    trial_samples: u32 = 1000,
};

/// the results of a single sample.
/// calls should be a multiple of the number of arguments (sweeps)
pub const Sample = struct {
    calls: u64,
    nanos: u64,
};

inline fn call(func: anytype, arg: anytype, comptime as_tuple: bool) void {
    util.dno(arg);
    util.dno(@call(.auto, func, if (as_tuple) arg.* else .{arg.*}));
}

inline fn is_tuple(T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

pub fn run_count_samples(sweeps: u64, func: anytype, args: anytype, comptime as_tuple: bool) Sample {
    const start = util.now();
    for (0..sweeps) |_| {
        for (args) |*a| {
            call(func, a, as_tuple);
        }
    }
    const stop = util.now();
    return .{ .calls = sweeps * args.len, .nanos = stop - start };
}

pub fn run_timed_sample(nanos: u64, func: anytype, args: anytype, comptime as_tuple: bool) Sample {
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

    return .{ .calls = sweeps * args.len, .nanos = stop - start.raw };
}

pub fn bench(alloc: Allocator, config: anytype, func: anytype, args: anytype) !Trial {
    const Elem_t = std.meta.Elem(@TypeOf(args));
    const args_slice: []const Elem_t = util.from_slice_like(Elem_t, args);
    return switch (@TypeOf(config)) {
        CountConfig => run_count_trial(alloc, config, func, Elem_t, args_slice),
        TimedConfig => run_timed_trial(alloc, config, func, Elem_t, args_slice),
        else => @compileError("bench passed unknown config type"),
    };
}

pub fn run_timed_trial(alloc: Allocator, config: TimedConfig, func: anytype, Elem_t: type, args: []const Elem_t) !Trial {
    const as_tuple = is_tuple(Elem_t);
    var trial: Trial = .init(alloc);
    trial.name = util.get_fname(func);
    trial.samples = config.trial_samples;
    try trial.data.ensureTotalCapacity(config.trial_samples);
    trial.sweeps = 0;
    trial.calls = args.len;

    _ = run_timed_sample(config.warmup_nanos, func, args, as_tuple);
    const sample_nanos = try std.math.divCeil(u64, config.trial_nanos, config.trial_samples);
    for (0..trial.samples) |_| {
        const res = run_timed_sample(sample_nanos, func, args, as_tuple);
        try trial.data.append(res);
    }
    return trial;
}

pub fn run_count_trial(alloc: Allocator, config: CountConfig, func: anytype, Elem_t: type, args: []const Elem_t) !Trial {
    const as_tuple = is_tuple(Elem_t);
    var trial: Trial = .init(alloc);
    trial.name = util.get_fname(func);
    trial.samples = config.trial_samples;
    try trial.data.ensureTotalCapacity(config.trial_samples);
    trial.sweeps = config.sample_sweeps;
    trial.calls = args.len;

    const warmres = run_count_samples(config.warmup_sweeps, func, args, as_tuple);
    util.dno(warmres);
    try trial.data.append(warmres);
    trial.data.clearRetainingCapacity();
    for (0..trial.samples) |_| {
        const res = run_count_samples(trial.sweeps, func, args, as_tuple);
        try trial.data.append(res);
    }
    return trial;
}

const tt = std.testing;

test "refalldecls" {
    std.testing.refAllDecls(@This());
}

test "run_count_samples single" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }
    const args_slice: []f64 = &args;

    const t = run_count_samples(10, std.math.sin, args_slice, false);
    try tt.expect(t.calls == 10000);
}

test "run_count_samples multiple" {
    const arg_t = struct { comptime type = f64, f64, f64 };

    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]arg_t = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }
    const args_slice: []arg_t = &args;

    const t = run_count_samples(10, std.math.log, args_slice, true);
    try tt.expect(t.calls == 10000);
}

test "run_count_trial single" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }

    var t = try bench(tt.allocator, CountConfig{
        .warmup_sweeps = 3,
        .trial_samples = 10,
        .sample_sweeps = 5,
    }, std.math.sin, args);
    defer t.deinit();
    try tt.expect(t.data.items.len > 0);
}

test "run_count_trial multiple" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]struct { comptime type = f64, f64, f64 } = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }

    var t = try bench(tt.allocator, CountConfig{
        .warmup_sweeps = 3,
        .trial_samples = 10,
        .sample_sweeps = 5,
    }, std.math.log, args);
    defer t.deinit();
    try tt.expect(t.data.items.len > 0);
}

test "run_timed_samples single" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }
    const args_slice: []f64 = &args;

    const t = run_timed_sample(50 * 1000 * 1000, std.math.sin, args_slice, false);
    try tt.expect(t.calls % 1000 == 0);
    try tt.expect(t.nanos > 50 * 1000 * 1000);
    try tt.expect(t.nanos < 51 * 1000 * 1000);
}

test "run_timed_samples multiple" {
    const arg_t = struct { comptime type = f64, f64, f64 };

    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]arg_t = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }
    const args_slice: []arg_t = &args;

    const t = run_timed_sample(50 * 1000 * 1000, std.math.log, args_slice, true);
    try tt.expect(t.calls % 1000 == 0);
    try tt.expect(t.nanos > 50 * 1000 * 1000);
    try tt.expect(t.nanos < 51 * 1000 * 1000);
}

test "run_timed_trial single" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }

    var t = try bench(tt.allocator, TimedConfig{
        .warmup_nanos = 50 * 1e6,
        .trial_nanos = 100 * 1e6,
        .trial_samples = 10,
    }, std.math.sin, args);
    defer t.deinit();
}

test "run_timed_trial multiple" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]struct { comptime type = f64, f64, f64 } = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }

    var t = try bench(tt.allocator, TimedConfig{
        .warmup_nanos = 50 * 1e6,
        .trial_nanos = 100 * 1e6,
        .trial_samples = 10,
    }, std.math.log, args);
    defer t.deinit();
    try tt.expect(t.data.items.len > 0);
}
