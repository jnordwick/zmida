const std = @import("std");
const dno = std.mem.doNotOptimizeAway;
const ArrayList = std.array_list.Managed;

const root = @import("root.zig");
const Sample = root.Sample;
const PerfSample = root.PerfSample;
const Env = root.Env;
const TrialStats = root.TrialStats;
const runners = @import("runners.zig");
const util = @import("util.zig");
const float_div = util.float_div;
const to_float = util.to_float;
const verbose = util.verbose;

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
    perf_sweeps: u64,
};

pub const TimedDef = struct {
    warmup_nanos: u64,
    trial_samples: u64,
    sample_nanos: u64,
    perf_nanos: u64,
};

pub const AdaptDef = struct {
    warmup_nanos: u64,
    trial_samples: u64,
    sample_nanos: u64,
    perf_nanos: u64,
    est_sample_sweeps: u64,
    est_perf_sweeps: u64,
};

pub const TrialDef = union(enum) {
    timed: TimedDef,
    count: CountDef,
    adapt: AdaptDef,
};

pub const ArgsType = enum {
    slice_naked,
    slice_tuple,
    ptrarray_naked,
    ptrarray_tuple,
    single_tuple,
    niladic,
    generator,
};

/// A trial is the result of a series of samples. A sample is
/// a number of sweeps over the args slice given
pub const Trial = struct {
    name: []const u8,
    data: ArrayList(Sample),
    perf: PerfSample,
    def: TrialDef,
    calls_per_sweep: u64 = 0, // calls per sweep, args.len

    pub fn init(def: TrialDef, name: []const u8) Trial {
        return .{
            .def = def,
            .name = name,
            .data = .init(Env.alloc),
            .perf = .{},
        };
    }

    pub fn deinit(this: @This()) void {
        this.data.deinit();
    }

    pub fn run(this: *@This(), func: anytype, args: anytype) !void {
        const nsamples = switch (this.def) {
            .timed => |d| d.trial_samples,
            .count => |d| d.trial_samples,
            .adapt => |d| d.trial_samples,
        };
        try this.data.ensureTotalCapacity(nsamples);
        this.data.clearRetainingCapacity();
        this.calls_per_sweep = util.argslen(args);

        switch (this.def) {
            .count => try this.bycount(func, args),
            .timed => try this.bytimed(func, args),
            .adapt => try this.byadapt(func, args),
        }
    }

    pub fn bycount(this: *@This(), func: anytype, args: anytype) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        verbose(1, "Trial {s}", .{
            this.name,
        });

        // warmup
        verbose(1, " warmup {d}k calls", .{
            float_div(f64, this.def.count.warmup_sweeps * this.calls_per_sweep, 1000),
        });
        dno(try runners.count_sample(
            argstype,
            null,
            this.def.count.warmup_sweeps,
            func,
            args,
        ));
        try this.bycount_samples(
            func,
            args,
            this.def.count.trial_samples,
            this.def.count.sample_sweeps,
            this.def.count.perf_sweeps,
        );
    }

    pub fn byadapt(this: *@This(), func: anytype, args: anytype) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        verbose(1, "Trial {s}", .{this.name});

        // warmup
        verbose(1, " warmup ({d:.3}ms)\n", .{float_div(f64, this.def.adapt.warmup_nanos, 1e6)});
        dno(try runners.timed_sample(argstype, null, this.def.adapt.warmup_nanos, func, args));

        // estimate sample sweep count
        const pre_est = try runners.timed_sample(argstype, null, this.def.adapt.sample_nanos, func, args);
        const est_sweeps = util.idiv_up(u64, pre_est.calls, this.calls_per_sweep);

        verbose(2, "pre-estimate {} calls in {d:.1} nanos, running {} sweeps\n", .{ pre_est.calls, pre_est.nanos, est_sweeps });
        const verify = try runners.count_sample(argstype, null, est_sweeps, func, args);
        const diff = util.rel_diff(this.def.adapt.sample_nanos, verify.nanos);

        verbose(2, "pre-estimate off by {d:.2}% adjusting\n", .{100 * diff});
        const ftimecalls = float_div(f64, this.def.adapt.sample_nanos, verify.nanos) * to_float(f64, verify.calls);
        const fperfcalls = float_div(f64, this.def.adapt.perf_nanos, verify.nanos) * to_float(f64, verify.calls);
        const ftimesweeps = @ceil(ftimecalls / to_float(f64, this.calls_per_sweep));
        const fperfsweeps = @ceil(fperfcalls / to_float(f64, this.calls_per_sweep));
        this.def.adapt.est_sample_sweeps = @intFromFloat(ftimesweeps);
        this.def.adapt.est_perf_sweeps = @intFromFloat(fperfsweeps);

        try this.bycount_samples(
            func,
            args,
            this.def.adapt.trial_samples,
            this.def.adapt.est_sample_sweeps,
            this.def.adapt.est_perf_sweeps,
        );
    }

    fn bycount_samples(this: *@This(), func: anytype, args: anytype, trial_samples: u64, sample_sweeps: u64, perf_sweeps: u64) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        // timed
        verbose(1, "timing samples {d} sweeps @ {d} calls", .{
            trial_samples,
            sample_sweeps * this.calls_per_sweep,
        });
        for (0..trial_samples) |i| {
            verbose(2, " {d}", i + 1);
            var res = try runners.count_sample(argstype, null, sample_sweeps, func, args);
            res.ord = i;
            try this.data.append(res);
        }
        verbose(1, "\n", .{});

        // perf
        if (Env.perf_cpu) {
            verbose(
                1,
                "Trial {s} cpu perf_events. {d} sweeps\n",
                .{ this.name, perf_sweeps },
            );
            var panel = try util.make_cpu_panel(Env.alloc);
            const res = try runners.count_sample(
                argstype,
                &panel,
                perf_sweeps,
                func,
                args,
            );
            this.perf.cpu_calls = res.calls;
            try panel.read(0, this.perf.cpu.as_payload());
            panel.deinit();
        }

        if (Env.perf_mem) {
            verbose(
                1,
                "Trial {s} mem perf_events. {d} sweeps\n",
                .{ this.name, perf_sweeps },
            );
            var panel = try util.make_mem_panel(Env.alloc);
            const res = try runners.count_sample(
                argstype,
                &panel,
                perf_sweeps,
                func,
                args,
            );
            this.perf.mem_calls = res.calls;
            try panel.read(0, this.perf.memr.as_payload());
            try panel.read(1, this.perf.memw.as_payload());
            panel.deinit();
        }
    }

    pub fn bytimed(this: *@This(), func: anytype, args: anytype) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        verbose(1, "Trial {s}", .{this.name});

        // warmup
        verbose(1, " warmup ({d:.3}ms)", .{
            float_div(f64, this.def.timed.warmup_nanos, 1e6),
        });
        dno(try runners.timed_sample(
            argstype,
            null,
            this.def.timed.warmup_nanos,
            func,
            args,
        ));

        verbose(1, " samples @ {d:.3}ms", .{
            float_div(f64, this.def.timed.sample_nanos, 1e6),
        });
        for (0..this.def.timed.trial_samples) |i| {
            verbose(2, " {d}", i + 1);
            var res = try runners.timed_sample(
                argstype,
                null,
                this.def.timed.sample_nanos,
                func,
                args,
            );
            res.ord = i;
            try this.data.append(res);
        }
        verbose(1, "\n", .{});

        // perf
        if (Env.perf_cpu) {
            verbose(
                1,
                "Trial {s} cpu perf_events. {d} ns\n",
                .{ this.name, this.def.timed.perf_nanos },
            );
            var panel = try util.make_cpu_panel(Env.alloc);
            const res = try runners.timed_sample(
                argstype,
                &panel,
                this.def.timed.perf_nanos,
                func,
                args,
            );
            this.perf.cpu_calls = res.calls;
            try panel.read(0, this.perf.cpu.as_payload());
            panel.deinit();
        }

        if (Env.perf_mem) {
            verbose(
                1,
                "Trial {s} mem perf_events. {d} ns\n",
                .{ this.name, this.def.timed.perf_nanos },
            );
            var panel = try util.make_mem_panel(Env.alloc);
            const res = try runners.timed_sample(
                argstype,
                &panel,
                this.def.timed.perf_nanos,
                func,
                args,
            );
            this.perf.mem_calls = res.calls;
            try panel.read(0, this.perf.memr.as_payload());
            try panel.read(1, this.perf.memw.as_payload());
            panel.deinit();
        }
    }

    pub fn statistics(this: *@This()) TrialStats {
        return .init(this);
    }
};

test {
    _ = std.testing.refAllDecls(@This());
}
