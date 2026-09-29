const std = @import("std");
const ArrayList = std.array_list.Managed;
const ArgsTuple = std.meta.ArgsTuple;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const gen = @import("gen.zig");
const out = @import("out.zig");
const perf = @import("perf.zig");
const runners = @import("runners.zig");
const stats = @import("stats.zig");
const time = @import("time.zig");
const trial = @import("trial.zig");
const util = @import("util.zig");

pub const Trial = trial.Trial;
pub const TrialDef = trial.TrialDef;
pub const TrialStats = stats.TrialStats;

const debug_warn = util.debug_warn;
const verbose = util.verbose;
pub const set_global_opts = util.set_global_opts;

pub const PerfLevel = struct {
    cpu: bool = false,
    mem: bool = false,
};

pub const GlobalOpts = struct {
    debug_warn: bool = true,
    verbose: u32 = 1,
    use_tsc: bool = true,
    pin_cpu: ?u32 = null,
    set_prio: ?i32 = null,
    perf_level: PerfLevel = .{},
};

pub const CountConfig = struct {
    warmup_calls: u32 = 100_000,
    trial_samples: u32 = 10_000,
    sample_calls: u32 = 1_000,
    perf_calls: u32 = 1_000_000,
};

pub const TimedConfig = struct {
    warmup_millis: u32 = 1000,
    trial_samples: u32 = 100,
    trial_millis: u32 = 2000,
    perf_millis: u32 = 2000,
};

pub const Config = union(enum) {
    timed: TimedConfig,
    count: CountConfig,

    pub fn bycount(config: CountConfig) Config {
        return .{ .count = config };
    }

    pub fn bytime(config: TimedConfig) Config {
        return .{ .timed = config };
    }
};

pub const TextOpts = struct {
    mode: enum { lat, thru } = .lat,
    ascii: bool = true,
    with_header: bool = true,
    with_perf: bool = true,
};

pub const SummaryOpts = struct {
    format: enum { csv } = .csv,
    separator: u8 = ',',
    with_header: bool = true,
    with_perf: bool = true,
    pctiles: []const u32 = &[_]u32{ 0, 25, 50, 75, 100 },
};

pub const SamplesOpts = struct {
    format: enum { csv } = .csv,
    separator: u8 = ',',
};

pub const GnuplotOpts = struct {
    title: ?[]const u8 = null,
};

pub const Env = struct {
    alloc: Allocator,
    io: Io,
};

pub const Study = struct {
    env: Env,
    name: []const u8,
    def: TrialDef,
    trials: ArrayList(Trial),
    stats: ArrayList(TrialStats),

    pub fn deinit(this: @This()) void {
        for (this.trials.items) |*t| {
            t.deinit();
        }
        this.trials.deinit();
        this.stats.deinit();
    }

    pub fn run(alloc: Allocator, io: Io, name: ?[]const u8, config: Config, funcs: anytype, args: anytype) !Study {
        debug_warn();
        var this = Study{
            .env = .{ .alloc = alloc, .io = io },
            .name = name orelse "zmida",
            .def = make_def(config, util.gopts.perf_level, args),
            .trials = .init(alloc),
            .stats = .init(alloc),
        };
        verbose(1, "Running study {s}\n", this.name);
        switch (config) {
            .count => |c| {
                verbose(1, "Count:\n", .{});
                verbose(1, "\t- warmup calls: {d}\n", .{c.warmup_calls});
                verbose(1, "\t- trial samples: {d}\n", .{c.trial_samples});
                verbose(1, "\t- sample calls: {d}\n", .{c.sample_calls});
                verbose(1, "\t- perf calls: {d}\n", .{c.perf_calls});
            },
            .timed => |c| {
                verbose(1, "Timed:\n", .{});
                verbose(1, "\t- warmup millis: {d}\n", .{c.warmup_millis});
                verbose(1, "\t- trial samples: {d}\n", .{c.trial_samples});
                verbose(1, "\t- trial millis: {d}\n", .{c.trial_millis});
                verbose(1, "\t- perf millis: {d}\n", .{c.perf_millis});
            },
        }
        inline for (0..funcs.len) |i| {
            verbose(1, "Running trial {d}/{d}\n", .{ i + 1, funcs.len });
            var t = Trial.init(this.env, this.def, util.get_fname(funcs[i]));
            try t.run(funcs[i], args);
            try this.trials.append(t);
        }
        return this;
    }

    fn make_def(config: Config, plevel: PerfLevel, args: anytype) TrialDef {
        const nargs = util.argslen(args);
        switch (config) {
            .count => |c| {
                return .{ .count = .{
                    .warmup_sweeps = util.idiv_up(u64, c.warmup_calls, nargs),
                    .trial_samples = c.trial_samples,
                    .sample_sweeps = util.idiv_up(u64, c.sample_calls, nargs),
                    .perf_sweeps = util.idiv_up(u64, c.perf_calls, nargs),
                    .perf_level = plevel,
                } };
            },
            .timed => |c| {
                const millis: u64 = @intCast(c.trial_millis);
                return .{ .timed = .{
                    .warmup_nanos = c.warmup_millis * 1_000_000,
                    .trial_samples = c.trial_samples,
                    .sample_nanos = util.idiv_up(u64, millis * 1_000_000, c.trial_samples),
                    .perf_nanos = c.perf_millis * 1_000_000,
                    .perf_level = plevel,
                } };
            },
        }
    }

    pub fn statistics(this: *@This()) !void {
        if (this.stats.items.len != 0) return;
        verbose(1, "Generating stats for study {s}\n", this.name);
        for (this.trials.items) |*t| {
            const st = t.statistics(this.env);
            try this.stats.append(st);
        }
    }

    pub fn write_text(this: *@This(), fname: ?[]const u8, topts: TextOpts) !void {
        const opts = topts;
        try this.statistics();
        const file = try util.get_file(this.env, fname, ".txt");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        const iface = &writer.interface;
        if (opts.mode == .lat) {
            try out.text_latency(iface, this.name, this.stats.items, opts);
        } else {
            try out.text_thruput(iface, this.name, this.stats.items, opts);
        }
        if (topts.with_perf) {
            try iface.writeByte('\n');
            if (util.gopts.perf_level.cpu) try out.text_perf_cpu(iface, this.stats.items, opts);
            try iface.writeByte('\n');
            if (util.gopts.perf_level.mem) try out.text_perf_mem(iface, this.stats.items, opts);
        }
    }

    pub fn write_summary(this: *@This(), fname: ?[]const u8, sopts: SummaryOpts) !void {
        const opts = sopts;
        try this.statistics();
        const file = try util.get_file(this.env, fname, "-summary.csv");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        try out.csv_summary(&writer.interface, this.stats.items, opts, util.gopts.perf_level);
    }

    pub fn write_samples(this: *@This(), fname: ?[]const u8, sopts: SamplesOpts) !void {
        const opts = sopts;
        try this.statistics();
        const file = try util.get_file(this.env, fname, "-samples.csv");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        try out.csv_samples(&writer.interface, this.stats.items, opts);
    }

    pub fn write_gnuplot(this: *@This(), fname: ?[]const u8, opts: GnuplotOpts) !void {
        try this.statistics();
        const file = try util.get_file(this.env, fname, ".gp");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        try out.gnuplot(&writer.interface, this.stats.items, opts);
    }

    pub fn write_gnuplot_perf(this: *@This(), fname: ?[]const u8, opts: GnuplotOpts) !void {
        try this.statistics();
        const file = try util.get_file(this.env, fname, "-perf.gp");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        try out.gnuplot_perf(&writer.interface, this.stats.items, opts);
    }
};

/// the results of a single sample.
/// calls should be a multiple of the number of arguments (sweeps)
pub const Sample = struct {
    ord: u64 = 0,
    calls: u64 = 0,
    nanos: f64 = 0,
};

pub const PerfSample = struct {
    ord: u64 = 0,
    cpu_calls: u64 = 0,
    mem_calls: u64 = 0,

    cpu: perf.CpuCounters = .{},
    memr: perf.MemReadCounters = .{},
    memw: perf.MemWriteCounters = .{},
};

test {
    std.testing.refAllDecls(@This());
}
