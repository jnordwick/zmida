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
const sys = @import("sys.zig");

pub const Trial = trial.Trial;
pub const TrialDef = trial.TrialDef;
pub const TrialStats = stats.TrialStats;

const debug_warn = util.debug_warn;
const verbose = util.verbose;
const panic = util.panic;

pub const Env = struct {
    pub const call_mod: std.builtin.CallModifier = b: {
        const that = @import("root");
        const ne = @hasDecl(that, "zm__call_mod");
        break :b if (ne) that.zmida_call_mod else .auto;
    };
    pub var alloc: Allocator = undefined;
    pub var io: Io = undefined;
    pub var debug_warn: bool = true;
    pub var verbose: u32 = 1;
    pub var use_tsc: bool = true;
    pub var pin_cpu: ?u32 = null;
    pub var set_prio: ?i32 = null;
    pub var perf_cpu: bool = false;
    pub var perf_mem: bool = false;
    pub var already_init: bool = false;
    pub var orig_cpu_set: ?sys.cpu_set = null;

    pub fn check_init() void {
        if (!already_init) panic("Did not zmida.init()", .{});
    }
};

pub const EnvOpts = struct {
    debug_warn: bool = true,
    verbose: u32 = 1,
    use_tsc: bool = true,
    pin_cpu: ?u32 = null,
    set_prio: ?i32 = null,
    perf_cpu: bool = false,
    perf_mem: bool = false,
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

pub const AdaptConfig = struct {
    warmup_millis: u32 = 1000,
    trial_samples: u32 = 100,
    trial_millis: u32 = 2000,
    perf_millis: u32 = 2000,
};

pub const Config = union(enum) {
    timed: TimedConfig,
    count: CountConfig,
    adapt: AdaptConfig,

    pub fn bycount(config: CountConfig) Config {
        return .{ .count = config };
    }

    pub fn bytime(config: TimedConfig) Config {
        return .{ .timed = config };
    }

    pub fn byadapt(config: AdaptConfig) Config {
        return .{ .adapt = config };
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

pub const Study = struct {
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

    pub fn run(name: ?[]const u8, config: Config, funcs: anytype, args: anytype) !Study {
        var this = Study{
            .name = name orelse "zmida",
            .def = make_def(config, args),
            .trials = .init(Env.alloc),
            .stats = .init(Env.alloc),
        };
        errdefer this.deinit();
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
            .adapt => |c| {
                verbose(1, "Adapt:\n", .{});
                verbose(1, "\t- warmup millis: {d}\n", .{c.warmup_millis});
                verbose(1, "\t- trial samples: {d}\n", .{c.trial_samples});
                verbose(1, "\t- trial millis: {d}\n", .{c.trial_millis});
                verbose(1, "\t- perf millis: {d}\n", .{c.perf_millis});
            },
        }
        inline for (0..funcs.len) |i| {
            verbose(1, "Running trial {d}/{d}\n", .{ i + 1, funcs.len });
            var t = Trial.init(this.def, util.get_fname(funcs[i]));
            try t.run(funcs[i], args);
            try this.trials.append(t);
        }
        return this;
    }

    fn make_def(config: Config, args: anytype) TrialDef {
        const nargs = util.argslen(args);
        switch (config) {
            .count => |c| {
                return .{ .count = .{
                    .warmup_sweeps = util.idiv_up(u64, c.warmup_calls, nargs),
                    .trial_samples = c.trial_samples,
                    .sample_sweeps = util.idiv_up(u64, c.sample_calls, nargs),
                    .perf_sweeps = util.idiv_up(u64, c.perf_calls, nargs),
                } };
            },
            .timed => |c| {
                const millis: u64 = @intCast(c.trial_millis);
                return .{ .timed = .{
                    .warmup_nanos = c.warmup_millis * 1_000_000,
                    .trial_samples = c.trial_samples,
                    .sample_nanos = util.idiv_up(u64, millis * 1_000_000, c.trial_samples),
                    .perf_nanos = c.perf_millis * 1_000_000,
                } };
            },
            .adapt => |c| {
                const millis: u64 = @intCast(c.trial_millis);
                return .{ .adapt = .{
                    .warmup_nanos = c.warmup_millis * 1_000_000,
                    .trial_samples = c.trial_samples,
                    .sample_nanos = util.idiv_up(u64, millis * 1_000_000, c.trial_samples),
                    .perf_nanos = c.perf_millis * 1_000_000,
                    .est_sample_sweeps = 0,
                    .est_perf_sweeps = 0,
                } };
            },
        }
    }

    pub fn statistics(this: *@This()) !void {
        if (this.stats.items.len != 0) return;
        verbose(1, "Generating stats for study {s}\n", this.name);
        for (this.trials.items) |*t| {
            const st = t.statistics();
            try this.stats.append(st);
        }
    }

    pub fn write_text(this: *@This(), fname: ?[]const u8, topts: TextOpts) !void {
        const opts = topts;
        try this.statistics();
        const file = try util.get_file(fname, ".txt");
        defer if (fname != null) file.close(Env.io);
        var writer = file.writer(Env.io, &.{});
        const iface = &writer.interface;
        if (opts.mode == .lat) {
            try out.text_latency(iface, this.name, this.stats.items, opts);
        } else {
            try out.text_thruput(iface, this.name, this.stats.items, opts);
        }
        if (topts.with_perf) {
            try iface.writeByte('\n');
            if (Env.perf_cpu) try out.text_perf_cpu(iface, this.stats.items, opts);
            try iface.writeByte('\n');
            if (Env.perf_mem) try out.text_perf_mem(iface, this.stats.items, opts);
        }
    }

    pub fn write_summary(this: *@This(), fname: ?[]const u8, sopts: SummaryOpts) !void {
        const opts = sopts;
        try this.statistics();
        const file = try util.get_file(fname, "-summary.csv");
        defer if (fname != null) file.close(Env.io);
        var writer = file.writer(Env.io, &.{});
        try out.csv_summary(&writer.interface, this.stats.items, opts);
    }

    pub fn write_samples(this: *@This(), fname: ?[]const u8, sopts: SamplesOpts) !void {
        const opts = sopts;
        try this.statistics();
        const file = try util.get_file(fname, "-samples.csv");
        defer if (fname != null) file.close(Env.io);
        var writer = file.writer(Env.io, &.{});
        try out.csv_samples(&writer.interface, this.stats.items, opts);
    }

    pub fn write_gnuplot(this: *@This(), fname: ?[]const u8, opts: GnuplotOpts) !void {
        try this.statistics();
        const file = try util.get_file(fname, ".gp");
        defer if (fname != null) file.close(Env.io);
        var writer = file.writer(Env.io, &.{});
        try out.gnuplot(&writer.interface, this.stats.items, opts);
    }

    pub fn write_gnuplot_perf(this: *@This(), fname: ?[]const u8, opts: GnuplotOpts) !void {
        try this.statistics();
        const file = try util.get_file(fname, "-perf.gp");
        defer if (fname != null) file.close(Env.io);
        var writer = file.writer(Env.io, &.{});
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

pub fn init(pinit: std.process.Init, env_opts: EnvOpts) void {
    if (Env.already_init) panic("Can only call zminda.init once", .{});
    Env.already_init = true;
    if (Env.call_mod != .auto) {
        verbose(1, "Overriding @call modifier {}\n", .{Env.call_mod});
    }

    const opts = util.parse_opts(&pinit, env_opts);
    Env.debug_warn = opts.debug_warn;
    debug_warn();

    Env.verbose = opts.verbose;
    Env.alloc = pinit.gpa;
    Env.io = pinit.io;
    Env.use_tsc = opts.use_tsc;
    time.Clock.setup(if (Env.use_tsc) .tsc else .monotonic) catch {
        std.debug.print("!!! WARNING !!! No capable TSC. using monotonic.\n", .{});
    };
    Env.pin_cpu = opts.pin_cpu;
    if (Env.pin_cpu) |cpu| {
        var orig_set: sys.cpu_set = .{};
        sys.sched_getaffinity(0, &orig_set) catch |e| {
            panic("count no get cpu affinity: {}\n", .{e});
        };
        Env.orig_cpu_set = orig_set;
        const cpu_set: sys.cpu_set = .init(cpu);
        sys.sched_setaffinity(0, &cpu_set) catch |e| {
            panic("could not set cpu affinity to {}: {}\n", .{ cpu, e });
        };
        verbose(1, "set cpu affinity to {}\n", .{cpu});
    }
    Env.set_prio = opts.set_prio;
    if (Env.set_prio) |prio| {
        sys.setpriority(sys.PRIO.PROCESS, 0, prio) catch |e| {
            panic("could not set priority (must be root for < 0) to {}: {}", .{ prio, e });
        };
        verbose(1, "set priority to {}\n", .{prio});
    }
    Env.perf_cpu = opts.perf_cpu;
    Env.perf_mem = opts.perf_mem;
    Env.already_init = true;
}

test {
    std.testing.refAllDecls(@This());
}
