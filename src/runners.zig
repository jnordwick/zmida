const std = @import("std");
const gen = @import("gen.zig");
const dno = std.mem.doNotOptimizeAway;
const tt = std.testing;

const ArgsType = @import("trial.zig").ArgsType;
const root = @import("root.zig");
const util = @import("util.zig");
const Env = root.Env;
const Sample = root.Sample;
const MemSample = root.MemSample;
const time = @import("time.zig");
const Timer = time.Timer;
const perf = @import("perf.zig");
const PerfPanel = perf.PerfPanel;
const Event = perf.Event;

const AtomicBool = std.atomic.Value(bool);

const events_cpu = [_]Event{ .retired_instr, .cpu_cycles, .branch_miss, .branch_total, .l1i_read_miss };
const events_memr = [_]Event{ .l1d_read, .l1d_read_miss, .ll_read, .ll_read_miss };
const events_memw = [_]Event{ .l1d_write, .ll_write, .ll_write_miss };

inline fn call(func: anytype, arg: anytype) void {
    dno(&arg);
    dno(@call(.auto, func, arg));
}

inline fn sweep(comptime argstype: ArgsType, func: anytype, args: anytype) void {
    switch (argstype) {
        .single_tuple => call(func, args),
        .niladic => call(func, .{}),
        .generator => {
            var gener = args;
            while (gener.next()) |a| {
                call(func, a);
            }
        },
        else => {
            for (args) |*a| {
                switch (argstype) {
                    .slice_naked, .ptrarray_naked => call(func, .{a.*}),
                    .slice_tuple, .ptrarray_tuple => call(func, a.*),
                    else => @panic("unexpected type"),
                }
            }
        },
    }
}

// -----------
// Count Based
// -----------

inline fn count_loop(
    comptime argstype: ArgsType,
    sweeps: u64,
    func: anytype,
    args: anytype,
) void {
    for (0..sweeps) |_| {
        sweep(argstype, func, args);
    }
}

pub fn count_sample(
    comptime argstype: ArgsType,
    _: Env,
    panel: ?*PerfPanel,
    sweeps: u64,
    func: anytype,
    args: anytype,
) !Sample {
    var sample: Sample = .{};
    var timer: Timer = undefined;
    if (panel) |p| {
        try p.open();
        try p.enable();
    }
    timer.start();
    count_loop(argstype, sweeps, func, args);
    timer.stop();
    if (panel) |p| try p.disable();
    sample.calls = sweeps * util.argslen(args);
    sample.nanos = timer.nanos();
    return sample;
}

// -----------
// Timed Based
// -----------

inline fn timed_loop(
    comptime argstype: ArgsType,
    done: *AtomicBool,
    func: anytype,
    args: anytype,
) u64 {
    var sweeps: u64 = 0;
    while (!done.load(.acquire)) {
        sweep(argstype, func, args);
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

pub fn timed_sample(
    comptime argstype: ArgsType,
    _: Env,
    panel: ?*PerfPanel,
    nanos: u64,
    func: anytype,
    args: anytype,
) !Sample {
    var sample: Sample = .{};
    var start: AtomicBool = .init(false);
    var done: AtomicBool = .init(false);
    var timer_thread = std.Thread.spawn(
        .{},
        set_bool,
        .{ &start, &done, nanos },
    ) catch @panic("could not spawn");
    var timer: Timer = undefined;
    if (panel) |p| {
        try p.open();
        try p.enable();
    }
    start.store(true, .release);
    timer.start();
    const sweeps = timed_loop(argstype, &done, func, args);
    timer.stop();
    if (panel) |p| try p.disable();
    timer_thread.join();
    sample.calls = sweeps * util.argslen(args);
    sample.nanos = timer.nanos();
    return sample;
}

// ----------------
// |     Test     |
// ----------------

test {
    std.testing.refAllDecls(@This());
}

fn mktuple(comptime n: u64, from: f64, to: f64) [n]struct { comptime type = f64, f64, f64 } {
    const x = gen.uniform(f64, n, from, to, 0);
    const y = gen.uniform(f64, n, from, to, 0);
    return gen.tie2t(f64, n, x, y);
}

test "count_sample slice naked" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const args = gen.uniform(f64, 5, 0, 20, 0);
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

test "count_sample single tuple" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const arg: f64 = 0.6;
    const t = try count_sample(
        .single_tuple,
        env,
        30,
        std.math.sin,
        .{arg},
    );
    try tt.expect(t.calls == 30);
}

test "count_sample generator" {
    const test_gen = struct {
        pub const _zmida_generator_ = true;
        begin: u64,
        end: u64,
        step: u64,
        cur: u64,
        len: u64,

        pub fn init(begin: u64, end: u64, step: u64) @This() {
            const len = (step - 1 + end - begin) / step;
            return .{
                .begin = begin,
                .end = end,
                .step = step,
                .cur = begin,
                .len = len,
            };
        }

        pub fn next(this: *@This()) ?struct { f64 } {
            if (this.cur >= this.end) return null;
            const tmp = this.cur;
            this.cur += this.step;
            return .{@as(f64, @floatFromInt(tmp))};
        }
    };

    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const arg: test_gen = .init(0, 10, 2);
    const t = try count_sample(
        .generator,
        env,
        5,
        std.math.sin,
        arg,
    );
    try tt.expect(t.calls == 25);
}

test "count_sample nil" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const func = struct {
        pub fn sin45() f64 {
            var x: f64 = 0;
            std.mem.doNotOptimizeAway(&x);
            return std.math.sin(x);
        }
    }.sin45;
    const t = try count_sample(.niladic, env, 30, func, {});
    try tt.expect(t.calls == 30);
}

test "count_samples multiple" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const args = mktuple(10, 2, 20);
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
    const args = gen.uniform(f64, 100, 0, 1000, 0);
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

test "timed_sample nil" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const func = struct {
        pub fn sin45() f64 {
            var x: f64 = 0;
            std.mem.doNotOptimizeAway(&x);
            return std.math.sin(x);
        }
    }.sin45;
    const t = try timed_sample(.niladic, env, 10 * 1e6, func, {});
    try tt.expect(t.calls > 100);
}

test "timed_sample single tuple" {
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const arg: f64 = 0.6;
    const t = try timed_sample(
        .single_tuple,
        env,
        5 * 1e6,
        std.math.sin,
        .{arg},
    );
    try tt.expect(t.calls > 100); // prob much more
}

test "timed_samples multiple" {
    const arg_t = struct { comptime type = f64, f64, f64 };
    const env = Env{ .alloc = tt.allocator, .io = tt.io };
    const args = mktuple(100, 2, 20);
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
