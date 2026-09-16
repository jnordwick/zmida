const std = @import("std");
const root = @import("root.zig");
const util = @import("util.zig");
const runners = @import("runners.zig");
const Sample = root.Sample;
const Env = root.Env;
const TrialStats = root.TrialStats;
const dno = std.mem.doNotOptimizeAway;
const ArrayList = std.array_list.Managed;

// Definitions are the actual parameters for a trial.
// these are concrete and what are the repeatable pieces.
// I plan to move some other pieces into these such as
// perf and timing options so trials can be indepedant
// of the studies. this should clean up the interace
// a little.
pub const CountDef = struct {
    warmup_sweeps: u64,
    trial_samples: u64,
    sample_sweeps: u64,
};

pub const TimedDef = struct {
    warmup_nanos: u64,
    trial_samples: u64,
    sample_nanos: u64,
};

pub const TrialDef = union(enum) {
    timed: TimedDef,
    count: CountDef,
};

pub const ArgsType = enum {
    slice_naked,
    slice_tuple,
};

/// A trial is the result of a series of samples. A sample is
/// a number of sweeps over the args slice given
pub const Trial = struct {
    name: []const u8,
    data: ArrayList(Sample),
    env: Env,
    def: TrialDef,
    calls_per_sweep: u64 = 0, // calls per sweep, args.len

    pub fn init(env: Env, def: TrialDef, name: []const u8) Trial {
        return .{
            .env = env,
            .def = def,
            .name = name,
            .data = .init(env.alloc),
        };
    }

    pub fn deinit(this: @This()) void {
        this.data.deinit();
    }

    pub fn run(this: *@This(), func: anytype, args: anytype) !void {
        switch (this.def) {
            .count => try this.bycount(func, args),
            .timed => try this.bytimed(func, args),
        }
    }

    pub fn bycount(this: *@This(), func: anytype, args: anytype) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        try this.data.ensureTotalCapacity(this.def.count.trial_samples);
        this.data.clearRetainingCapacity();
        this.calls_per_sweep = switch (argstype) {
            .slice_naked => args.len,
            .slice_tuple => args.len,
        };

        root.verbose(1, "  Trial {s} with {d} samples @ {d} calls each", .{
            this.name,
            this.def.count.trial_samples,
            this.def.count.sample_sweeps * this.calls_per_sweep,
        });

        // warmup
        if (this.env.perf) |e| try e.enable();
        dno(try runners.count_sample(
            argstype,
            this.env,
            this.def.count.warmup_sweeps,
            func,
            args,
        ));

        // reinstall to clear time counters
        if (this.env.perf) |e| try e.reinstall();
        for (0..this.def.count.trial_samples) |i| {
            root.verbose(2, " {d}", i + 1);
            var res = try runners.count_sample(
                argstype,
                this.env,
                this.def.count.sample_sweeps,
                func,
                args,
            );
            res.ord = i;
            try this.data.append(res);
        }
        root.verbose(1, "\n", .{});

        if (this.env.perf) |_| {
            // adjust cumulative cpu times back to individual
            const tdlen = this.data.items.len;
            for (1..tdlen) |i| {
                this.data.items[tdlen - i].cpu_perf.time_enabled -=
                    this.data.items[tdlen - i - 1].cpu_perf.time_enabled;

                this.data.items[tdlen - i].cpu_perf.time_running -=
                    this.data.items[tdlen - i - 1].cpu_perf.time_running;
            }
        }
    }

    pub fn bytimed(this: *@This(), func: anytype, args: anytype) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        try this.data.ensureTotalCapacity(this.def.timed.trial_samples);
        this.data.clearRetainingCapacity();
        this.calls_per_sweep = switch (argstype) {
            .slice_naked => args.len,
            .slice_tuple => args.len,
        };

        root.verbose(1, "  Trial {s} with {d} samples @ {d:.3}ms", .{
            this.name,
            this.def.timed.trial_samples,
            util.float_div(f64, this.def.timed.sample_nanos, 1e6),
        });

        // warmup
        if (this.env.perf) |e| try e.enable();
        dno(try runners.timed_sample(
            argstype,
            this.env,
            this.def.timed.warmup_nanos,
            func,
            args,
        ));

        // reinstall to clear time counters
        if (this.env.perf) |e| try e.reinstall();
        for (0..this.def.timed.trial_samples) |i| {
            root.verbose(2, " {d}", i + 1);
            var res = try runners.timed_sample(
                argstype,
                this.env,
                this.def.timed.sample_nanos,
                func,
                args,
            );
            res.ord = i;
            try this.data.append(res);
        }
        root.verbose(1, "\n", .{});

        if (this.env.perf) |_| {
            const tdlen = this.data.items.len;
            for (1..tdlen) |i| {
                this.data.items[tdlen - i].cpu_perf.time_enabled -=
                    this.data.items[tdlen - i - 1].cpu_perf.time_enabled;
                this.data.items[tdlen - i].cpu_perf.time_running -=
                    this.data.items[tdlen - i - 1].cpu_perf.time_running;
            }
        }
    }

    pub fn statistics(this: *@This(), env: Env) TrialStats {
        return .init(env.alloc, this);
    }
};

test {
    _ = std.testing.refAllDecls(@This());
}
