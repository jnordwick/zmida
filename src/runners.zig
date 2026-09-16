const std = @import("std");
const dno = std.mem.doNotOptimizeAway;
const tt = std.testing;

const ArgsType = @import("trial.zig").ArgsType;
const perf = @import("perf.zig");
const root = @import("root.zig");
const Env = root.Env;
const Sample = root.Sample;
const time = @import("time.zig");
const Timer = time.Timer;

const AtomicBool = std.atomic.Value(bool);

inline fn call(func: anytype, arg: anytype) void {
    dno(arg);
    dno(@call(.auto, func, arg));
}

// -----------
// Count Based
// -----------

inline fn count_loop(comptime argstype: ArgsType, sweeps: u64, func: anytype, args: anytype) void {
    for (0..sweeps) |_| {
        for (args) |*a| {
            switch (argstype) {
                .slice_tuple => call(func, a.*),
                .slice_naked => call(func, .{a.*}),
            }
        }
    }
}

pub fn count_sample(comptime argstype: ArgsType, env: Env, sweeps: u64, func: anytype, args: anytype) !Sample {
    var sample: Sample = .{};
    var timer: Timer = undefined;
    if (env.perf) |e| {
        try e.reset();
        try e.enable();
    }
    timer.start();
    count_loop(argstype, sweeps, func, args);
    timer.stop();
    if (env.perf) |p| {
        try p.disable();
        var ps: perf.Sample = .{};
        try p.read(&ps);
        sample.cpu_perf = .init(&ps);
    }
    sample.calls = sweeps * args.len;
    sample.nanos = timer.nanos();
    return sample;
}

// -----------
// Timed Based
// -----------

inline fn timed_loop(comptime argstype: ArgsType, done: *AtomicBool, func: anytype, args: anytype) u64 {
    var sweeps: u64 = 0;
    while (!done.load(.acquire)) {
        for (args) |*a| {
            switch (argstype) {
                .slice_tuple => call(func, a.*),
                .slice_naked => call(func, .{a.*}),
            }
        }
        sweeps += 1;
    }
    return sweeps;
}

pub fn set_bool(start: *AtomicBool, stop: *AtomicBool, nanos: u64) void {
    while (!start.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    time.pause_for(nanos);
    stop.store(true, .release);
}

pub fn timed_sample(comptime argstype: ArgsType, env: Env, nanos: u64, func: anytype, args: anytype) !Sample {
    var sample: Sample = .{};
    var start: AtomicBool = .init(false);
    var done: AtomicBool = .init(false);
    var timer_thread = std.Thread.spawn(
        .{},
        set_bool,
        .{ &start, &done, nanos },
    ) catch @panic("could not spawn");
    var timer: Timer = undefined;
    start.store(true, .release);
    if (env.perf) |e| {
        try e.reset();
        try e.enable();
    }
    timer.start();
    const sweeps = timed_loop(argstype, &done, func, args);
    timer.stop();
    if (env.perf) |p| {
        try p.disable();
        var ps: perf.Sample = .{};
        try p.read(&ps);
        sample.cpu_perf = .init(&ps);
    }
    sample.calls = sweeps * args.len;
    sample.nanos = timer.nanos();
    timer_thread.join();

    return sample;
}

// --------------------
// Test
// --------------------
test {
    std.testing.refAllDecls(@This());
}

fn make_floats(comptime n: u64, comptime from: f64, comptime to: f64) [n]f64 {
    var arr: [n]f64 = undefined;
    const diff = to - from;
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    for (&arr) |*a| {
        a.* = from + diff * rr.float(f64);
    }
    return arr;
}

fn make_tuples(comptime n: u64, comptime from: f64, comptime to: f64) [n]struct { comptime type = f64, f64, f64 } {
    var arr: [n]struct { comptime type = f64, f64, f64 } = undefined;
    const diff = to - from;
    var rand: std.Random.Xoshiro256 = .init(0);
    var rr = rand.random();
    for (&arr) |*a| {
        a.* = .{ f64, from + diff * rr.float(f64) * 100, from + diff * rr.float(f64) };
    }
    return arr;
}

test "count_sample single" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const args = make_floats(5, 0.0, 20.0);
    const args_slice: []const f64 = @ptrCast(&args);

    const t = try count_sample(
        .slice_naked,
        env,
        3,
        std.math.sin,
        args_slice,
    );
    try tt.expect(t.calls == 15);
}

test "count_samples multiple" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const args = make_tuples(10, 2, 20);
    const arg_t = struct { comptime type = f64, f64, f64 };
    const args_slice: []const arg_t = @ptrCast(&args);

    const t = try count_sample(
        .slice_tuple,
        env,
        3,
        std.math.log,
        args_slice,
    );
    try tt.expect(t.calls == 30);
}

test "timed_samples single" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const args = make_floats(100, 0.0, 1000.0);
    const args_slice: []const f64 = @ptrCast(&args);

    const t = try timed_sample(
        .slice_naked,
        env,
        50 * 1000 * 1000,
        std.math.sin,
        args_slice,
    );
    try tt.expect(t.calls % 100 == 0);
    try tt.expect(t.nanos > 50 * 1000 * 1000);
    try tt.expect(t.nanos < 51 * 1000 * 1000);
}

test "timed_samples multiple" {
    const arg_t = struct { comptime type = f64, f64, f64 };
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const args = make_tuples(100, 2, 20);
    const args_slice: []const arg_t = @ptrCast(&args);

    const t = try timed_sample(
        .slice_tuple,
        env,
        50 * 1000 * 1000,
        std.math.log,
        args_slice,
    );
    try tt.expect(t.calls % 100 == 0);
    try tt.expect(t.nanos > 50 * 1000 * 1000);
    try tt.expect(t.nanos < 51 * 1000 * 1000);
}
