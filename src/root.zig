const std = @import("std");
pub const util = @import("util.zig");
pub const stats = @import("stats.zig");
pub const out = @import("out.zig");
const ArrayList = std.array_list.Managed;
const ArgsTuple = std.meta.ArgsTuple;
const Allocator = std.mem.Allocator;

pub const TrialStats = stats.TrialStats;

/// A trial is the result of a series of batches run. A batch is
/// a number of passes over the args slice given
pub const Trial = struct {
    name: []const u8 = "(none)",
    batches: u64 = 0, // batches per trial, runs.len
    passes: u64 = 0, // passes per batch, 0 = dynamic
    calls: u64 = 0, // calls per pass, args.len

    runs: ArrayList(BatchResults),

    pub fn init(alloc: Allocator) Trial {
        return .{ .runs = .init(alloc) };
    }

    pub fn deinit(this: @This()) void {
        this.runs.deinit();
    }
};

/// trial with set number of batches and set number of passes per batch
pub const CountConfig = struct {
    warmup_passes: u32 = 10,
    trial_batches: u32 = 1000,
    batch_passes: u32 = 10,
};

/// trial for a set number of seconds and set number of batches
pub const TimedConfig = struct {
    warmup_nanos: u32 = 50 * 1e6, // 50 milliseconds
    trial_nanos: u64 = 5 * 1e9, // 5 seconds
    trial_batches: u32 = 1000,
};

/// the results of a single batch. calls should be a multiple of the number
/// of arguments
pub const BatchResults = struct {
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

pub fn run_count_batch(passes: u64, func: anytype, args: anytype, comptime as_tuple: bool) BatchResults {
    const start = util.now();
    for (0..passes) |_| {
        for (args) |*a| {
            call(func, a, as_tuple);
        }
    }
    const stop = util.now();
    return .{ .calls = passes * args.len, .nanos = stop - start };
}

pub fn run_timed_batch(nanos: u64, func: anytype, args: anytype, comptime as_tuple: bool) BatchResults {
    var done: std.atomic.Value(bool) = .init(false);
    var start: std.atomic.Value(u64) = .init(0);
    var timer = std.Thread.spawn(
        .{},
        util.set_bool,
        .{ &done, &start, nanos },
    ) catch @panic("could not spawn");

    var passes: u64 = 0;
    start.store(util.now(), .release);
    while (!done.load(.acquire)) {
        for (args) |*a| {
            call(func, a, as_tuple);
        }
        passes += 1;
    }
    const stop = util.now();
    timer.join();

    return .{ .calls = passes * args.len, .nanos = stop - start.raw };
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
    trial.batches = config.trial_batches;
    try trial.runs.ensureTotalCapacity(config.trial_batches);
    trial.passes = 0;
    trial.calls = args.len;

    _ = run_timed_batch(config.warmup_nanos, func, args, as_tuple);
    const batch_nanos = try std.math.divCeil(u64, config.trial_nanos, config.trial_batches);
    for (0..trial.batches) |_| {
        const res = run_timed_batch(batch_nanos, func, args, as_tuple);
        try trial.runs.append(res);
    }
    return trial;
}

pub fn run_count_trial(alloc: Allocator, config: CountConfig, func: anytype, Elem_t: type, args: []const Elem_t) !Trial {
    const as_tuple = is_tuple(Elem_t);
    var trial: Trial = .init(alloc);
    trial.name = util.get_fname(func);
    trial.batches = config.trial_batches;
    try trial.runs.ensureTotalCapacity(config.trial_batches);
    trial.passes = config.batch_passes;
    trial.calls = args.len;

    const warmres = run_count_batch(config.warmup_passes, func, args, as_tuple);
    util.dno(warmres);
    try trial.runs.append(warmres);
    trial.runs.clearRetainingCapacity();
    for (0..trial.batches) |_| {
        const res = run_count_batch(trial.passes, func, args, as_tuple);
        try trial.runs.append(res);
    }
    return trial;
}

const tt = std.testing;

test "refalldecls" {
    std.testing.refAllDecls(@This());
}

test "run_count_batches single" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }
    const args_slice: []f64 = &args;

    const t = run_count_batch(10, std.math.sin, args_slice, false);
    try tt.expect(t.calls == 10000);
}

test "run_count_batches multiple" {
    const arg_t = struct { comptime type = f64, f64, f64 };

    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]arg_t = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }
    const args_slice: []arg_t = &args;

    const t = run_count_batch(10, std.math.log, args_slice, true);
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
        .warmup_passes = 3,
        .trial_batches = 10,
        .batch_passes = 5,
    }, std.math.sin, args);
    defer t.deinit();
    try tt.expect(t.runs.items.len > 0);
}

test "run_count_trial multiple" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]struct { comptime type = f64, f64, f64 } = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }

    var t = try bench(tt.allocator, CountConfig{
        .warmup_passes = 3,
        .trial_batches = 10,
        .batch_passes = 5,
    }, std.math.log, args);
    defer t.deinit();
    try tt.expect(t.runs.items.len > 0);
}

test "run_timed_batches single" {
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]f64 = undefined;
    for (&args) |*a| {
        a.* = rr.float(f64) * 1000;
    }
    const args_slice: []f64 = &args;

    const t = run_timed_batch(50 * 1000 * 1000, std.math.sin, args_slice, false);
    try tt.expect(t.calls % 1000 == 0);
    try tt.expect(t.nanos > 50 * 1000 * 1000);
    try tt.expect(t.nanos < 51 * 1000 * 1000);
}

test "run_timed_batches multiple" {
    const arg_t = struct { comptime type = f64, f64, f64 };

    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    var args: [1000]arg_t = undefined;
    for (&args) |*a| {
        a.* = .{ f64, 2 + rr.float(f64) * 100, 2 + rr.float(f64) * 1000 };
    }
    const args_slice: []arg_t = &args;

    const t = run_timed_batch(50 * 1000 * 1000, std.math.log, args_slice, true);
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
        .trial_batches = 10,
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
        .trial_batches = 10,
    }, std.math.log, args);
    defer t.deinit();
    try tt.expect(t.runs.items.len > 0);
}
