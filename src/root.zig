const builtin = @import("builtin");
const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const gen = @import("gen.zig");
const out = @import("out.zig");
const perf = @import("perf.zig");
const stats = @import("stats.zig");
const time = @import("time.zig");
const trial = @import("trial.zig");
const util = @import("util.zig");
const sys = @import("sys.zig");

pub const Trial = trial.Trial;
pub const TrialDef = trial.TrialDef;
pub const TrialStats = stats.TrialStats;

const verbose = util.verbose;
const errexit = util.errexit;
const argslen = util.argslen;
const argstype_of = util.argstype_of;
const is_tuple = util.is_tuple;
const get_fname = util.get_fname;
const get_file = util.get_file;
const idiv_up = util.idiv_up;
const parse_opts = util.parse_opts;
const check_cpu_files = util.check_cpu_files;

// last TODO:
// regen pngs

/// A slightly modified version of std.mem.doNotOptimizeAway that tries to work
/// around compiler issues around passing floats or vectors. For regular use,
/// you do not need to use this; it is done internally. But, if you need to make
/// your own loop (see examples/loop.zig), you will likely need to use this to
/// prevent the compiler from dead code eliminating your function.
pub const dno = util.dno;

/// The environment for the runners. Don't touch this. Use EnvOpts instead.
pub const Env = struct {
    pub const callmod: std.builtin.CallModifier = b: {
        if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64)
            @compileError("Currently only supports Linux x64.");
        const that = @import("root");
        const ne = @hasDecl(that, "__zm__callmod__");
        break :b if (ne) that.__zm__callmod__ else .auto;
    };
    pub var alloc: Allocator = undefined;
    pub var io: Io = undefined;
    pub var debug_warn: bool = true;
    pub var verbose: i32 = 1;
    pub var use_tsc: bool = true;
    pub var pin_cpu: ?u32 = null;
    pub var set_prio: ?i32 = null;
    pub var perf_cpu: bool = false;
    pub var perf_mem: bool = false;
    pub var already_init: bool = false;
    pub var orig_cpu_set: ?sys.cpu_set = null;

    pub fn check_init() void {
        if (!already_init) errexit("Did not zmida.init()", .{});
    }
};

/// Global options for all runners
pub const EnvOpts = struct {
    /// verbose level. 0 is silent, 1 is normal, 2 is trace
    verbose: i32 = 1,
    /// use RDTSC if available
    use_tsc: bool = true,
    /// pin to a cpu
    pin_cpu: ?u32 = null,
    /// set priority niceness level
    set_prio: ?i32 = null,
    /// collect cpu instruction performance counters
    perf_cpu: bool = false,
    /// collect cache performance counters
    perf_mem: bool = false,
};

/// trial based on the number of calls to execute
pub const CountConfig = struct {
    /// number of calls in warmup
    warmup_calls: u32 = 100_000,
    /// number of samples in a trial
    trial_samples: u32 = 10_000,
    /// number of calls in a sample
    sample_calls: u32 = 1_000,
    /// number of calls in a performance counter collection
    perf_calls: u32 = 1_000_000,
    /// if each call rerpesents multiple units of work (mostly for vector code)
    work_units: u64 = 1,
};

/// trial based on amount of time for each trial. best used for fewer samples over longer
/// periods of time.  The longer samples might help if you the OS aggressive throttles the
/// cpy between sample runs.
pub const TimedConfig = struct {
    /// millisecond in warmup
    warmup_millis: u32 = 1000,
    /// number of samples in a trial
    trial_samples: u32 = 100,
    /// total milliseonds in trial (sample millis = trials millis / numer of samples)
    trial_millis: u32 = 2000,
    /// number milliseconds in a performance counter collection
    perf_millis: u32 = 2000,
    /// if each call rerpesents multiple units of work (mostly for vector code)
    work_units: u64 = 1,
};

/// trial based on time per trial, but an estimate is made for how many calls that takes,
/// and the trial is run by count. this has a little less machinery and doesn't interfere
/// with execution as much or on a machine with limited resources. This is the default.
pub const AdaptConfig = struct {
    /// milliseconds in warmup
    warmup_millis: u32 = 1000,
    /// number of samples in a trial
    trial_samples: u32 = 100,
    /// total milliseonds in trial (sample millis = trials millis / numer of samples)
    trial_millis: u32 = 2000,
    /// number milliseconds in a performance counter collection
    perf_millis: u32 = 2000,
    /// if each call rerpesents multiple units of work (mostly for vector code)
    work_units: u64 = 1,
};

/// one of the trial configs.
pub const Config = union(enum) {
    timed: TimedConfig,
    count: CountConfig,
    adapt: AdaptConfig,

    /// default is adaptive
    pub const default = Config.byadapt(.{});

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

/// options for text table output
pub const TextOpts = struct {
    /// display mode, by latency or throughput
    mode: enum { lat, thru } = .lat,
    /// use ascii, false allows use of UNICOE and ANSI codes
    ascii: bool = true,
    /// print info header before tables
    with_header: bool = true,
    /// print performance counters, if they were recorded
    with_perf: bool = true,
};

/// print timing summary in structured format, numbers are per call (latency)
pub const SummaryOpts = struct {
    /// file format, currently only csv-like supporter
    format: enum { csv } = .csv,
    /// separator (only used for csv)
    separator: u8 = ',',
    /// print header row
    with_header: bool = true,
    /// also print performance counter summaries too
    with_perf: bool = true,
    /// percentile columns to include (0 = min, 100 = max)
    pctiles: []const u32 = &[_]u32{ 0, 25, 50, 75, 100 },
};

/// print all unaggregared sample data
pub const SamplesOpts = struct {
    /// file format, currently only csv-like supporter
    format: enum { csv } = .csv,
    /// separator (only used for csv)
    separator: u8 = ',',
};

/// gnuplot output
pub const GnuplotOpts = struct {
    /// plot title
    title: ?[]const u8 = null,
    typ: enum { candles, bars } = .bars,
    width: u16 = 800,
    height: u16 = 600,
};

/// quick shot bench. Uses the default value for adaptve trials
/// pinit: the init from main. The only parts that matter are gpa, io, and args.
/// funcs: either an indivdual function or a tuple of functions
/// args: any appropropriate args argument. see the readme for a description.
/// prints text tables to stdout
pub fn bench(pinit: *const std.process.Init, funcs: anytype, args: anytype) !void {
    try bench_ex(pinit, .{}, .byadapt(.{}), funcs, args);
}

/// a slightly extended simple interface.
/// pinit: the init from main. The only parts that matter are gpa, io, and args.
/// env_opts: global options overrides
/// config: trial configuration
/// funcs: either an indivdual function or a tuple of functions
/// args: any appropropriate args argument. see the readme for a description.
/// prints text tables to stdout
pub fn bench_ex(pinit: *const std.process.Init, env_opts: EnvOpts, config: Config, funcs: anytype, args: anytype) !void {
    if (!Env.already_init) init(pinit, env_opts);
    const ftuple = if (is_tuple(@TypeOf(funcs))) funcs else .{funcs};
    var study = try Study.run(null, config, ftuple, args);
    defer study.deinit();
    try study.write_text(null, .{ .mode = .lat });
}

/// A collection of trials with the same configuration over the same arguments
/// you create a study by using the run() method
pub const Study = struct {
    /// only used for output
    name: []const u8,
    /// shared trial definition
    def: TrialDef,
    /// results already run trials
    trials: ArrayList(Trial),
    /// statistics generated from trials
    stats: ArrayList(TrialStats),

    /// clean up memory and any open handles
    pub fn deinit(this: *@This()) void {
        this.clear_stats();
        this.stats.deinit();
        this.trials.deinit();
    }

    fn clear_stats(this: *@This()) void {
        for (this.trials.items) |*t| {
            t.deinit();
        }
        this.stats.clearRetainingCapacity();
    }

    /// create and run a study
    /// name: used for output, null uses a default name
    /// config: a trial configuration
    /// funcs: the function or tuple of functions to bench
    /// args: any of appropriate argument types. See readme or documentation for full details
    pub fn run(name: ?[]const u8, config: Config, funcs: anytype, args: anytype) !Study {
        switch (argstype_of(@TypeOf(args))) {
            .slice_tuple, .slice_naked, .ptrarray_tuple, .ptrarray_naked => {
                if (argslen(args) == 0) errexit("no arguments, use {{}} for niladic function.", .{});
            },
            else => {},
        }
        const functuple = if (is_tuple(@TypeOf(funcs))) funcs else .{funcs};
        Env.check_init();
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
                if (std.Thread.use_pthreads) {
                    verbose(0, "--- warn --- pthreads and Timed Config conflic.", .{});
                }
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
        this.clear_stats();
        inline for (0..functuple.len) |i| {
            verbose(1, "Running trial {d}/{d}\n", .{ i + 1, functuple.len });
            var t = Trial.init(this.def, get_fname(funcs[i]));
            try t.run(functuple[i], args);
            try this.trials.append(t);
        }
        return this;
    }

    fn make_def(config: Config, args: anytype) TrialDef {
        const nargs = argslen(args);
        switch (config) {
            .count => |c| {
                return .{ .count = .{
                    .warmup_sweeps = idiv_up(u64, c.warmup_calls, nargs),
                    .trial_samples = c.trial_samples,
                    .sample_sweeps = idiv_up(u64, c.sample_calls, nargs),
                    .perf_sweeps = idiv_up(u64, c.perf_calls, nargs),
                    .work_units = c.work_units,
                } };
            },
            .timed => |c| {
                const millis: u64 = @intCast(c.trial_millis);
                return .{ .timed = .{
                    .warmup_nanos = @as(u64, c.warmup_millis) * 1_000_000,
                    .trial_samples = c.trial_samples,
                    .sample_nanos = idiv_up(u64, @as(u64, millis) * 1_000_000, c.trial_samples),
                    .perf_nanos = @as(u64, c.perf_millis) * 1_000_000,
                    .work_units = c.work_units,
                } };
            },
            .adapt => |c| {
                const millis: u64 = @intCast(c.trial_millis);
                return .{ .adapt = .{
                    .warmup_nanos = @as(u64, c.warmup_millis) * 1_000_000,
                    .trial_samples = c.trial_samples,
                    .sample_nanos = idiv_up(u64, @as(u64, millis) * 1_000_000, c.trial_samples),
                    .perf_nanos = @as(u64, c.perf_millis) * 1_000_000,
                    .est_sample_sweeps = 0,
                    .est_perf_sweeps = 0,
                    .work_units = c.work_units,
                } };
            },
        }
    }

    /// run statistics for already run trials
    pub fn statistics(this: *@This()) !void {
        if (this.stats.items.len != 0) return;
        verbose(1, "Generating stats for study {s}\n", this.name);
        for (this.trials.items) |*t| {
            const st = t.statistics();
            try this.stats.append(st);
        }
    }

    /// write out results in text tables
    /// fname: filename or stdout if null
    /// toptts: output options
    pub fn write_text(this: *@This(), fname: ?[]const u8, topts: TextOpts) !void {
        const opts = topts;
        try this.statistics();
        const file = try get_file(fname, this.name, ".txt");
        defer if (fname != null) file.close(Env.io);
        if (fname) |f| {
            verbose(1, "writing text output to file: {s}.txt\n", .{
                if (f.len > 0) f else this.name,
            });
        }
        var writer = file.writer(Env.io, &.{});
        const iface = &writer.interface;
        if (opts.mode == .lat) {
            try out.text_latency(iface, this.name, this.stats.items, opts);
        } else {
            try out.text_thruput(iface, this.name, this.stats.items, opts);
        }
        if (topts.with_perf) {
            if (Env.perf_cpu) {
                try iface.writeByte('\n');
                try out.text_perf_cpu(iface, this.stats.items, opts);
            }
            if (Env.perf_mem) {
                try iface.writeByte('\n');
                try out.text_perf_mem(iface, this.stats.items, opts);
            }
        }
    }

    /// write ingestable format of summary data (currently only support csv/tsv)
    /// fname: filename or null for stdout
    /// sopts: output options
    pub fn write_summary(this: *@This(), fname: ?[]const u8, sopts: SummaryOpts) !void {
        const opts = sopts;
        try this.statistics();
        const file = try get_file(fname, this.name, "-summary.csv");
        defer if (fname != null) file.close(Env.io);
        if (fname) |f| {
            verbose(1, "writing summary data to file: {s}-summary.csv\n", .{
                if (f.len > 0) f else this.name,
            });
        }
        var writer = file.writer(Env.io, &.{});
        try out.csv_summary(&writer.interface, this.stats.items, opts);
    }

    /// write ingestable format of detailed sample data (no performance data)
    /// fname: filename or null for stdout
    /// sopts: output options
    pub fn write_samples(this: *@This(), fname: ?[]const u8, sopts: SamplesOpts) !void {
        const opts = sopts;
        try this.statistics();
        const file = try get_file(fname, this.name, "-samples.csv");
        defer if (fname != null) file.close(Env.io);
        if (fname) |f| {
            verbose(1, "writing all sample data to file: {s}-samples.csv\n", .{
                if (f.len > 0) f else this.name,
            });
        }
        var writer = file.writer(Env.io, &.{});
        try out.csv_samples(&writer.interface, this.stats.items, opts);
    }

    /// write gnuplot of timing summary. the file includes both gnuplot instructions and data.
    /// fname: filename or null for stdout
    /// sopts: output options
    pub fn write_gnuplot(this: *@This(), fname: ?[]const u8, sopts: GnuplotOpts) !void {
        var opts = sopts;
        opts.title = opts.title orelse this.name;
        try this.statistics();
        const file = try get_file(fname, this.name, ".gp");
        defer if (fname != null) file.close(Env.io);
        if (fname) |f| {
            verbose(1, "writing gnuplot timing data to file: {s}-perf.gp\n", .{
                if (f.len > 0) f else this.name,
            });
        }
        var writer = file.writer(Env.io, &.{});
        try out.gnuplot(&writer.interface, this.stats.items, opts);
    }

    /// write gnuplot of performance counter data.
    /// the file includes both gnuplot instructions and data.
    /// fname: filename or null for stdout
    /// sopts: output options
    pub fn write_gnuplot_perf(this: *@This(), fname: ?[]const u8, sopts: GnuplotOpts) !void {
        var opts = sopts;
        opts.title = opts.title orelse this.name;
        try this.statistics();
        const file = try get_file(fname, this.name, "-perf.gp");
        defer if (fname != null) file.close(Env.io);
        if (fname) |f| {
            verbose(1, "writing gnuplot perf counters to file: {s}-perf.gp\n", .{
                if (f.len > 0) f else this.name,
            });
        }
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

/// A single sample of the performance counters.
pub const PerfSample = struct {
    ord: u64 = 0,
    cpu_calls: u64 = 0,
    mem_calls: u64 = 0,

    cpu: perf.CpuCounters = .{},
    memr: perf.MemReadCounters = .{},
    memw: perf.MemWriteCounters = .{},
};

/// Must be called to intialize the library. This checks for clocks, pins the cpu,
/// sets niceness, and processes command line switches.
/// pinit: The int from the main. only 3 fields are required: gpa, io. and minimal.args.
/// env_opts: override options. command line switches take precendece.
pub fn init(pinit: *const std.process.Init, env_opts: EnvOpts) void {
    if (Env.already_init) errexit("Can only call zminda.init once", .{});
    Env.io = pinit.io;
    Env.alloc = pinit.gpa;

    const opts = parse_opts(pinit, env_opts);
    Env.verbose = opts.verbose;

    if (@import("builtin").mode == .Debug and Env.debug_warn) {
        verbose(0, "--- warn --- Compiled in debug mode.\n", .{});
        if (!util.use_llvm_asm) {
            verbose(0, "--- warn --- non-LLVM backend: vector/float barriers may add memory traffic\n", .{});
        }
        Env.debug_warn = false;
    }

    if (Env.callmod != .auto) {
        verbose(1, "overriding @call modifier {}\n", .{Env.callmod});
    }
    verbose(2, "compiler backend: {}\n", .{builtin.zig_backend});
    verbose(2, "optimization mode: {}\n", .{builtin.mode});

    Env.use_tsc = opts.use_tsc;
    time.Clock.setup(if (Env.use_tsc) .tsc else .monotonic) catch {
        verbose(0, "--- warnng --- No capable TSC. using monotonic clock.\n", .{});
    };
    Env.pin_cpu = opts.pin_cpu;
    if (Env.pin_cpu) |cpu| {
        var orig_set: sys.cpu_set = .{};
        sys.sched_getaffinity(0, &orig_set) catch |e| {
            errexit("count no get cpu affinity: {}\n", .{e});
        };
        orig_set.clear(cpu);
        Env.orig_cpu_set = orig_set;
        const cpu_set: sys.cpu_set = .init(cpu);
        sys.sched_setaffinity(0, &cpu_set) catch |e| {
            errexit("could not set cpu affinity to {}: {}\n", .{ cpu, e });
        };
        verbose(1, "set cpu affinity to {}\n", cpu);
        check_cpu_files(cpu);
    }
    Env.set_prio = opts.set_prio;
    if (Env.set_prio) |prio| {
        const res = sys.setpriority(sys.PRIO.PROCESS, 0, prio);
        if (res) {
            verbose(1, "set priority to {}\n", prio);
        } else |err| {
            if (err == error.errno_acces) {
                verbose(0, "--- warn --- could not set priority to {} must be root: {}\n", .{ prio, err });
            } else {
                verbose(0, "--- warn --- could not set priority to {}: {}\n", .{ prio, err });
            }
        }
    }
    Env.perf_cpu = opts.perf_cpu;
    Env.perf_mem = opts.perf_mem;
    Env.already_init = true;
}

test {
    std.testing.refAllDecls(@This());
}
