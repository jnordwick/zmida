const std = @import("std");
pub const stats = @import("stats.zig");
pub const TrialStats = stats.TrialStats;
pub const out = @import("out.zig");
const util = @import("util.zig");
const runners = @import("runners.zig");
const ArrayList = std.array_list.Managed;
const ArgsTuple = std.meta.ArgsTuple;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub var gopts = struct {
    verbose: u32 = 1,
    use_rdtsc: bool = false,
}{};

pub fn verbose(comptime lev: u32, comptime fmt: []const u8, p: anytype) void {
    if (lev <= gopts.verbose) {
        std.debug.print(fmt, if (util.is_tuple(@TypeOf(p))) p else .{p});
    }
}

/// trial with set number of samples and set number of sweeps per sample
pub const CountConfig = struct {
    warmup_sweeps: u32 = 5000,
    trial_samples: u32 = 10000,
    sample_sweeps: u32 = 20,
};

pub const TimedConfig = struct {
    warmup_nanos: u32 = 100 * 1e6, // 100 milliseconds
    trial_nanos: u64 = 1 * 1e9, // 1 second
    trial_samples: u32 = 250,
};

const Config = union(enum) {
    count: CountConfig,
    timed: TimedConfig,
    none: void,
};

pub const TextOpts = struct {
    mode: enum { lat, thru } = .lat,
    header: bool = true,
    ascii: bool = true,
};

pub const SummaryOpts = struct {
    format: enum { csv } = .csv,
    pctiles: []const u32 = &[_]u32{ 0, 25, 50, 75, 100 },
};

pub const DetailsOpts = struct {
    format: enum { csv } = .csv,
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
    config: Config,
    trials: ArrayList(Trial),
    stats: ArrayList(TrialStats),

    pub fn deinit(this: @This()) void {
        for (this.trials.items) |*t| {
            t.deinit();
        }
        this.trials.deinit();
        this.stats.deinit();
    }

    pub fn run(alloc: Allocator, io: Io, name: ?[]const u8, config: anytype, funcs: anytype, args: anytype) !Study {
        var this = Study{
            .env = .{ .alloc = alloc, .io = io },
            .name = name orelse "zmida",
            .config = .{ .none = {} },
            .trials = .init(alloc),
            .stats = .init(alloc),
        };
        this.config = switch (@TypeOf(config)) {
            CountConfig => .{ .count = config },
            TimedConfig => .{ .timed = config },
            else => @compileError("config unexpected type"),
        };
        verbose(1, "Running study {s}\n", this.name);
        verbose(1, "{s}: {any}\n", .{ @typeName(@TypeOf(config)), config });
        inline for (0..funcs.len) |i| {
            verbose(1, "  Running trial {d}/{d}\n", .{ i, funcs.len });
            const t = try Trial.run(this.env, config, funcs[i], args);
            try this.trials.append(t);
        }
        return this;
    }

    pub fn statistics(this: *@This()) !void {
        if (this.stats.items.len != 0) return;
        verbose(1, "Generating stats for study {s}\n", this.name);
        for (this.trials.items) |*t| {
            const st = t.statistics(this.env);
            try this.stats.append(st);
        }
    }

    pub fn write_text(this: *@This(), fname: ?[]const u8, opts: TextOpts) !void {
        try this.statistics();
        const file = try util.get_file(this.env, fname, ".txt");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        if (opts.mode == .lat) {
            try out.text_out_latency(&writer.interface, this.stats.items, opts);
        } else {
            try out.text_out_thruput(&writer.interface, this.stats.items, opts);
        }
    }

    pub fn write_summary(this: *@This(), fname: ?[]const u8, _: SummaryOpts) !void {
        try this.statistics();
        const file = try util.get_file(this.env, fname, "-summary.csv");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        try out.csv_out_summary(&writer.interface, this.stats.items);
    }

    pub fn write_samples(this: *@This(), fname: ?[]const u8, _: DetailsOpts) !void {
        this.statistics();
        const file = try util.get_file(this.env, fname, "-samples.csv");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        try out.csv_out_samples(&writer.interface, this.stats.items);
    }

    pub fn write_gnuplot(this: *@This(), fname: ?[]const u8, _: GnuplotOpts) !void {
        try this.statistics();
        const file = try util.get_file(this.env, fname, ".gp");
        defer if (fname != null) file.close(this.env.io);
        var writer = file.writer(this.env.io, &.{});
        try out.gnuplot_out(&writer.interface, this.stats.items);
    }
};

/// A trial is the result of a series of samples. A sample is
/// a number of sweeps over the args slice given
pub const Trial = struct {
    name: []const u8,
    samples: u64 = 0, // samples per trial, data.len
    sweeps: u64 = 0, // sweeps per sample, 0 = dynamic
    calls: u64 = 0, // calls per sweep, args.len
    data: ArrayList(Sample),

    pub fn init(env: Env, name: []const u8) Trial {
        return .{
            .name = name,
            .data = .init(env.alloc),
        };
    }

    pub fn deinit(this: @This()) void {
        this.data.deinit();
    }

    pub fn run(env: Env, config: anytype, func: anytype, args: anytype) !Trial {
        const Elem_t = std.meta.Elem(@TypeOf(args));
        const args_slice: []const Elem_t = util.from_slice_like(Elem_t, args);
        return switch (@TypeOf(config)) {
            CountConfig => runners.count_trial(env, config, func, Elem_t, args_slice),
            TimedConfig => runners.timed_trial(env, config, func, Elem_t, args_slice),
            else => @compileError("bench passed unknown config type"),
        };
    }

    pub fn statistics(this: *@This(), env: Env) TrialStats {
        return .init(env.alloc, this);
    }
};

/// the results of a single sample.
/// calls should be a multiple of the number of arguments (sweeps)
pub const Sample = struct {
    ord: u64,
    calls: u64,
    nanos: u64,
};

test "refalldecls" {
    std.testing.refAllDecls(@This());
}
