const std = @import("std");
const root = @import("root.zig");
const util = @import("util.zig");
const runners = @import("runners.zig");
const perf = @import("perf.zig");
const PerfPanel = perf.PerfPanel;
const Sample = root.Sample;
const PerfSample = root.PerfSample;
const PerfTrial = root.PerfTrial;
const Env = root.Env;
const TrialStats = root.TrialStats;
const dno = std.mem.doNotOptimizeAway;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const PerfLevel = root.PerfLevel;

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
    perf_level: PerfLevel,
};

pub const TimedDef = struct {
    warmup_nanos: u64,
    trial_samples: u64,
    sample_nanos: u64,
    perf_nanos: u64,
    perf_level: PerfLevel,
};

pub const TrialDef = union(enum) {
    timed: TimedDef,
    count: CountDef,
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
    env: Env,
    def: TrialDef,
    calls_per_sweep: u64 = 0, // calls per sweep, args.len

    pub fn init(env: Env, def: TrialDef, name: []const u8) Trial {
        return .{
            .env = env,
            .def = def,
            .name = name,
            .data = .init(env.alloc),
            .perf = .{},
        };
    }

    pub fn deinit(this: @This()) void {
        this.data.deinit();
    }

    pub fn run(this: *@This(), func: anytype, args: anytype) !void {
        switch (this.def) {
            .count => try this.timebycount(func, args),
            .timed => try this.timebytimed(func, args),
        }
    }

    pub fn perfbycount(this: *@This(), func: anytype, args: anytype) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        try this.data.ensureTotalCapacity(this.def.count.trial_samples);
        this.data.clearRetainingCapacity();
        this.calls_per_sweep = util.argslen(args);

        root.verbose(1, "  Trial {s} with {d} samples @ {d} calls/sample", .{
            this.name,
            this.def.count.trial_samples,
            this.def.count.sample_sweeps * this.calls_per_sweep,
        });

        // warmup
        dno(try runners.count_sample(
            argstype,
            this.env,
            null,
            this.def.count.warmup_sweeps,
            func,
            args,
        ));

        for (0..this.def.count.trial_samples) |i| {
            root.verbose(2, " {d}", i + 1);
            var res = try runners.count_sample(
                argstype,
                this.env,
                null,
                this.def.count.sample_sweeps,
                func,
                args,
            );
            res.ord = i;
            try this.data.append(res);
        }
        root.verbose(1, "\n", .{});
    }

    pub fn timebycount(this: *@This(), func: anytype, args: anytype) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        try this.data.ensureTotalCapacity(this.def.count.trial_samples);
        this.data.clearRetainingCapacity();
        this.calls_per_sweep = util.argslen(args);

        root.verbose(1, "  Trial {s} with {d} samples @ {d} calls/sample", .{
            this.name,
            this.def.count.trial_samples,
            this.def.count.sample_sweeps * this.calls_per_sweep,
        });

        // warmup
        dno(try runners.count_sample(
            argstype,
            this.env,
            null,
            this.def.count.warmup_sweeps,
            func,
            args,
        ));

        // timed
        for (0..this.def.count.trial_samples) |i| {
            root.verbose(2, " {d}", i + 1);
            var res = try runners.count_sample(
                argstype,
                this.env,
                null,
                this.def.count.sample_sweeps,
                func,
                args,
            );
            res.ord = i;
            try this.data.append(res);
        }
        root.verbose(1, "\n", .{});

        // perf
        if (this.def.count.perf_level.cpu) {
            root.verbose(
                1,
                "Trials {s} cpu perf_events. {d} sweeps\n",
                .{ this.name, this.def.count.perf_sweeps },
            );
            var panel = try make_cpu_panel(this.env.alloc);
            var res = try runners.count_sample(
                argstype,
                this.env,
                &panel,
                this.def.count.perf_sweeps,
                func,
                args,
            );
            res.ord = 0;
            try panel.read(0, this.perf.cpu.as_payload());
            panel.deinit();
        }
    }

    pub fn timebytimed(this: *@This(), func: anytype, args: anytype) !void {
        const argstype = util.argstype_of(@TypeOf(args));
        try this.data.ensureTotalCapacity(this.def.timed.trial_samples);
        this.data.clearRetainingCapacity();
        this.calls_per_sweep = args.len;

        root.verbose(1, "  Trial {s} with {d} samples @ {d:.3}ms", .{
            this.name,
            this.def.timed.trial_samples,
            util.float_div(f64, this.def.timed.sample_nanos, 1e6),
        });

        // warmup
        dno(try runners.timed_sample(
            argstype,
            this.env,
            null,
            this.def.timed.warmup_nanos,
            func,
            args,
        ));

        for (0..this.def.timed.trial_samples) |i| {
            root.verbose(2, " {d}", i + 1);
            var res = try runners.timed_sample(
                argstype,
                this.env,
                null,
                this.def.timed.sample_nanos,
                func,
                args,
            );
            res.ord = i;
            try this.data.append(res);
        }
        root.verbose(1, "\n", .{});
    }

    pub fn statistics(this: *@This(), env: Env) TrialStats {
        return .init(env.alloc, this);
    }
};

fn make_cpu_panel(alloc: Allocator) !PerfPanel {
    var panel: PerfPanel = .init(alloc, true);
    try panel.add(&root.CpuCounters.events);
    return panel;
}

fn make_mem_panel(alloc: Allocator) !PerfPanel {
    var panel: PerfPanel = .init(alloc, false);
    try panel.add(&root.MemReadCounters.events);
    try panel.add(&root.MemWriteCounters.events);
    return panel;
}

test {
    _ = std.testing.refAllDecls(@This());
}
