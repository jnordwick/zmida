const std = @import("std");
const perf = @import("perf.zig");
const ArrayList = std.array_list.Managed;
const ArgsTuple = std.meta.ArgsTuple;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const out = @import("out.zig");
const runners = @import("runners.zig");
pub const stats = @import("stats.zig");
pub const TrialStats = stats.TrialStats;
const time = @import("time.zig");
const util = @import("util.zig");

const trial = @import("trial.zig");
pub const Trial = trial.Trial;
pub const TrialDef = trial.TrialDef;

pub const PerfLevel = struct {
    cpu: bool = false,
    mem: bool = false,
};

pub const GlobalOpts = struct {
    debug_warn: bool = true,
    verbose: u32 = 1,
    use_tsc: bool = false,
    perf_level: PerfLevel = .{},
};

pub var gopts = GlobalOpts{};

pub fn set_global_opts(opts: GlobalOpts) void {
    gopts = opts;
    time.Clock.setup(if (gopts.use_tsc) .tsc else .monotonic);
    debug_warn();
}

pub fn verbose(comptime lev: u32, comptime fmt: []const u8, p: anytype) void {
    if (lev <= gopts.verbose) {
        std.debug.print(fmt, if (util.is_tuple(@TypeOf(p))) p else .{p});
    }
}

pub inline fn debug_warn() void {
    if (@import("builtin").mode == .Debug and gopts.debug_warn) {
        std.debug.print("!!! WARNING !!! Compiled in debug mode.\n", .{});
        gopts.debug_warn = false;
    }
}

// These are requested parameters exposed through the
// study types. they are easier user facing. from these,
// the argument list, and the environment, a definition
// is made and passed to the trials.
pub const CountConfig = struct {
    warmup_calls: u32 = 5_000,
    trial_samples: u32 = 10_000,
    sample_calls: u32 = 1_000,
    perf_calls: u32 = 1_000_000,
};

pub const TimedConfig = struct {
    warmup_millis: u32 = 100,
    trial_samples: u32 = 250,
    trial_millis: u32 = 2_500,
    perf_millis: u32 = 500,
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
            .def = make_def(config, gopts.perf_level, args),
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
                return .{ .timed = .{
                    .warmup_nanos = c.warmup_millis * 1000,
                    .trial_samples = c.trial_samples,
                    .sample_nanos = util.idiv_up(u64, c.trial_millis * 1000, c.trial_samples),
                    .perf_nanos = c.perf_millis * 1000,
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
            // std.debug.print("\n", .{});
            // std.debug.print("enabled {} running {}\n", .{ st.perf_time_enabled, st.perf_time_running });
            // std.debug.print("instr {} cycles {}\n", .{ st.perf_cpu_cycles, st.perf_instructions });
            // std.debug.print("branch miss {} total {}\n", .{ st.perf_branch_miss, st.perf_branch_total });
            // std.debug.print("\n", .{});
            try this.stats.append(st);
        }
    }

    pub fn write_text(this: *@This(), fname: ?[]const u8, topts: TextOpts) !void {
        const opts = topts;
        try this.statistics();
        const file = try util.get_file(this.env, fname, ".txt");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        if (opts.mode == .lat) {
            try out.text_latency(&writer.interface, this.name, this.stats.items, opts);
        } else {
            try out.text_thruput(&writer.interface, this.name, this.stats.items, opts);
        }
    }

    pub fn write_summary(this: *@This(), fname: ?[]const u8, sopts: SummaryOpts) !void {
        const opts = sopts;
        try this.statistics();
        const file = try util.get_file(this.env, fname, "-summary.csv");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        try out.csv_summary(&writer.interface, this.stats.items, opts);
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
    calls: u64 = 0,

    cpu: CpuCounters = .{},
    memr: MemReadCounters = .{},
    memw: MemWriteCounters = .{},
};

pub const CpuCounters = extern struct {
    pub const events = [_]perf.Event{ .retired_instr, .cpu_cycles, .branch_miss, .branch_total, .l1i_read_miss };
    nrecords: u64 = 0,
    time_enabled: u64 = 0,
    time_running: u64 = 0,
    instructions: u64 = 0,
    cpu_cycles: u64 = 0,
    branch_miss: u64 = 0,
    branch_total: u64 = 0,
    l1i_read_miss: u64 = 0,

    pub fn init(ps: *const perf.Sample) CpuCounters {
        return .{
            .time_enabled = ps.enabled,
            .time_running = ps.running,
            .instructions = ps.records[0],
            .cpu_cycles = ps.records[1],
            .branch_miss = ps.records[2],
            .branch_total = ps.records[3],
            .l1i_read_miss = ps.records[4],
        };
    }

    pub fn as_payload(this: *@This()) []u8 {
        return @as([*]u8, @ptrCast(this))[0..@sizeOf(@This())];
    }
};

pub const MemReadCounters = extern struct {
    pub const events = [_]perf.Event{ .l1d_read, .l1d_read_miss, .ll_read, .ll_read_miss };
    nrecords: u64 = 0,
    time_enabled: u64 = 0,
    time_running: u64 = 0,
    l1d_read: u64 = 0,
    l1d_read_miss: u64 = 0,
    ll_read: u64 = 0,
    ll_read_miss: u64 = 0,

    pub fn init(ps: *const perf.Sample) CpuCounters {
        return .{
            .time_enabled = ps.enabled,
            .time_running = ps.running,
            .l1d_read = ps.record[0],
            .l1d_read_miss = ps.record[1],
            .ll_read = ps.record[2],
            .ll_read_miss = ps.record[3],
        };
    }

    pub fn as_payload(this: *@This()) []u8 {
        return @as([*]u64, @ptrCast(this))[0..@sizeOf(@This())];
    }
};

pub const MemWriteCounters = extern struct {
    pub const events = [_]perf.Event{ .l1d_write, .ll_write, .ll_write_miss };
    nrecords: u64 = 0,
    time_enabled: u64 = 0,
    time_running: u64 = 0,
    l1d_write: u64 = 0,
    ll_write: u64 = 0,
    ll_write_miss: u64 = 0,

    pub fn init(ps: *const perf.Sample) CpuCounters {
        return .{
            .time_enabled = ps.enabled,
            .time_running = ps.running,
            .l1d_write = ps.record[0],
            .ll_write = ps.record[1],
            .ll_write_miss = ps.record[2],
        };
    }

    pub fn as_payload(this: *@This()) []u8 {
        return @as([*]u64, @ptrCast(this))[0..@sizeOf(@This())];
    }
};

test {
    std.testing.refAllDecls(@This());
}
