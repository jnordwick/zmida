const std = @import("std");
const floor = std.math.floor;
const log = std.math.log;

const root = @import("root.zig");
const time = @import("time.zig");
const Env = root.Env;

const text_header =
    \\study: {[name]s}
    \\compile: {[mode]}
    \\units: {[longunits]s}
    \\clock: {[clkname]} @ {[clkfreq]d} Hz
    \\display: {[disp]s}
    \\
;

fn write_n(writer: *std.Io.Writer, x: []const u8, count: usize) !void {
    for (0..count) |_| {
        try writer.print("{s}", .{x});
    }
}

pub fn text_latency(
    writer: *std.Io.Writer,
    title: []const u8,
    trials: []const root.TrialStats,
    opts: root.TextOpts,
) !void {
    var name_len: usize = "fn".len;
    var max_avg: f64 = 1e-9;
    for (trials) |stats| {
        name_len = @max(name_len, stats.trial.name.len);
        max_avg = @max(max_avg, stats.call_avg_ns);
    }
    const groups: u32 = @intFromFloat(@max(0, floor(log(f64, 1000.0, max_avg))));
    _, const longunits, const factor: f64 = switch (groups) {
        0 => .{ "ns", "nanosec/op", 1.0 },
        1 => .{ "us", "microsec/op", 1e-3 },
        2 => .{ "ms", "millisec/op", 1e-6 },
        else => .{ "s", "seconds/op", 1e-9 },
    };

    if (opts.with_header) {
        try writer.print(text_header, .{
            .name = title,
            .mode = @import("builtin").mode,
            .disp = "latency (lower is better)",
            .longunits = longunits,
            .clkname = time.Clock.clksrc,
            .clkfreq = time.Clock.hz,
        });
        try writer.writeByte('\n');
    }

    try draw_text_tables(writer, trials, opts, name_len, lat_conv, factor);
    try writer.flush();
}

pub fn text_thruput(
    writer: *std.Io.Writer,
    title: []const u8,
    trials: []const root.TrialStats,
    opts: root.TextOpts,
) !void {
    var name_len: usize = "fn".len;
    var max_avg: f64 = 0;
    for (trials) |stats| {
        name_len = @max(name_len, stats.trial.name.len);
        max_avg = @max(max_avg, 1e9 / stats.call_avg_ns);
    }
    const groups: u32 = @intFromFloat(@max(0, floor(log(f64, 1000.0, max_avg))));
    _, const longunits, const factor: f64 = switch (groups) {
        0 => .{ "ops", "ops/sec", 1e9 },
        1 => .{ "Kops", "Kops/sec", 1e6 },
        2 => .{ "Mops", "Mops/sec", 1e3 },
        else => .{ "Gops", "Gops/sec", 1e0 },
    };

    if (opts.with_header) {
        try writer.print(text_header, .{
            .name = title,
            .mode = @import("builtin").mode,
            .disp = "throughput (higher is better)",
            .longunits = longunits,
            .clkname = time.Clock.clksrc,
            .clkfreq = time.Clock.hz,
        });
        try writer.writeByte('\n');
    }

    try draw_text_tables(writer, trials, opts, name_len, thru_conv, factor);
    try writer.flush();
}

fn lat_conv(x: f64, y: f64) f64 {
    return x * y;
}
fn thru_conv(x: f64, y: f64) f64 {
    return y / x;
}

fn draw_text_tables(
    writer: *std.Io.Writer,
    trials: []const root.TrialStats,
    opts: root.TextOpts,
    name_len: usize,
    conv: fn (f64, f64) f64,
    factor: f64,
) !void {
    const vbar, const hbar, const plus = if (opts.ascii) .{ "|", "-", "+" } else .{ "\u{2502}", "\u{2500}", "\u{253c}" };

    try writer.print(
        "{[name]s: <[name_len]} {[vbar]s}" ++
            "{[calls]s: >11} " ++
            "{[total]s: >8} " ++
            "{[avg]s: >7} {[vbar]s}" ++
            "{[min]s: >7} " ++
            "{[p25]s: >7} " ++
            "{[p50]s: >7} " ++
            "{[p75]s: >7} " ++
            "{[max]s: >7}\n",
        .{
            .name = "fn",
            .name_len = name_len + 1,
            .calls = "calls",
            .total = "seconds",
            .avg = "mean",
            .min = "best",
            .p25 = "p75",
            .p50 = "p50",
            .p75 = "p25",
            .max = "worst",
            .vbar = vbar,
        },
    );

    try write_n(writer, hbar, name_len + 2);
    try write_n(writer, plus, 1);
    try write_n(writer, hbar, 12 + 9 + 8);
    try write_n(writer, plus, 1);
    try write_n(writer, hbar, 5 * 8 - 1);
    try writer.writeByte('\n');

    for (trials) |stats| {
        try writer.print(
            "{[name]s: <[name_len]} {[vbar]s}" ++
                "{[calls]d: >11} " ++
                "{[total]d: >8.2} " ++
                "{[avg]d: >7.2} {[vbar]s}" ++
                "{[min]d: >7.2} " ++
                "{[p25]d: >7.2} " ++
                "{[p50]d: >7.2} " ++
                "{[p75]d: >7.2} " ++
                "{[max]d: >7.2}\n",
            .{
                .name = stats.trial.name,
                .name_len = name_len + 1,
                .calls = stats.trial_calls,
                .total = stats.trial_nanos / 1e9,
                .avg = conv(stats.call_avg_ns, factor),
                .min = conv(stats.call_min_ns, factor),
                .p25 = conv(stats.percentiles[75], factor),
                .p50 = conv(stats.percentiles[50], factor),
                .p75 = conv(stats.percentiles[25], factor),
                .max = conv(stats.call_max_ns, factor),
                .vbar = vbar,
            },
        );
    }
}

pub fn text_perf_cpu(
    writer: *std.Io.Writer,
    trials: []const root.TrialStats,
    opts: root.TextOpts,
) !void {
    var max_name_len: usize = "fn".len;
    for (trials) |t| {
        max_name_len = @max(max_name_len, t.trial.name.len);
    }
    const vbar, const hbar, const plus =
        if (opts.ascii) .{ "|", "-", "+" } else .{ "\u{2502}", "\u{2500}", "\u{253c}" };

    try writer.print(
        "{[name]s: <[max_name_len]} {[vbar]s}" ++
            "{[ipc]s: >7} " ++
            "{[inst]s: >10} " ++
            "{[cyc]s: >10} " ++
            "{[imiss]s: >8} {[vbar]s}" ++
            "{[brmrt]s: >8} " ++
            "{[brmiss]s: >10} " ++
            "{[brtot]s: >10}\n",
        .{
            .name = "fn",
            .max_name_len = max_name_len + 1,
            .ipc = "ipc",
            .inst = "insts",
            .imiss = "imiss",
            .cyc = "cycles",
            .brmrt = "miss/M",
            .brmiss = "misses",
            .brtot = "branches",
            .vbar = vbar,
        },
    );

    try write_n(writer, hbar, max_name_len + 2);
    try write_n(writer, plus, 1);
    try write_n(writer, hbar, 2 * 8 + 2 * 11 + 1);
    try write_n(writer, plus, 1);
    try write_n(writer, hbar, 2 * 11 + 8);
    try writer.writeByte('\n');

    for (trials) |stats| {
        if (stats.trial.perf.cpu_calls == 0) continue;
        try writer.print(
            "{[name]s: <[max_name_len]} {[vbar]s}" ++
                "{[ipc]d: >7.3} " ++
                "{[inst]d: >10.1} " ++
                "{[cyc]d: >10.1} " ++
                "{[imiss]d: >8.3} {[vbar]s}" ++
                "{[brmsrt]d: >8.2} " ++
                "{[brmiss]d: >10.3} " ++
                "{[brtot]d: >10.1}\n",
            .{
                .name = stats.trial.name,
                .max_name_len = max_name_len + 1,
                .ipc = stats.inst_per_cycle,
                .inst = stats.inst_per_call,
                .cyc = stats.cycle_per_call,
                .imiss = stats.l1i_miss_per_call,
                .brmsrt = stats.brmiss_per_mill,
                .brmiss = stats.brmiss_per_call,
                .brtot = stats.branch_per_call,
                .vbar = vbar,
            },
        );
    }
    try writer.flush();
}

pub fn text_perf_mem(
    writer: *std.Io.Writer,
    trials: []const root.TrialStats,
    opts: root.TextOpts,
) !void {
    var max_name_len: usize = "fn".len;
    for (trials) |t| {
        max_name_len = @max(max_name_len, t.trial.name.len);
    }
    const vbar, const hbar, const plus =
        if (opts.ascii) .{ "|", "-", "+" } else .{ "\u{2502}", "\u{2500}", "\u{253c}" };

    try writer.print("{[c1]s: <[max_name_len]} {[vbar]s} " ++
        "{[c2]s: ^[sep_len]} {[vbar]s} " ++
        "{[c3]s: ^[sep_len]}\n", .{
        .max_name_len = max_name_len + 1,
        .vbar = vbar,
        .sep_len = 33,
        .c1 = "",
        .c2 = "L1 Cache",
        .c3 = "LL Cache",
    });

    try writer.print(
        "{[name]s: <[max_name_len]} {[vbar]s}" ++
            "{[l1mpm]s: >8} " ++
            "{[l1mpc]s: >7} " ++
            "{[l1rpc]s: >8} " ++
            "{[l1wpc]s: >8} {[vbar]s}" ++
            "{[llmpc]s: >7} " ++
            "{[llrpc]s: >7} " ++
            "{[llwmpc]s: >7} " ++
            "{[llwpc]s: >7}\n",
        .{
            .name = "fn",
            .max_name_len = max_name_len + 1,
            .l1mpm = "rmiss/M",
            .l1mpc = "rmiss",
            .l1rpc = "read",
            .l1wpc = "write",
            .llmpc = "rmiss",
            .llrpc = "read",
            .llwmpc = "wmiss",
            .llwpc = "write",
            .vbar = vbar,
        },
    );

    try write_n(writer, hbar, max_name_len + 2);
    try write_n(writer, plus, 1);
    try write_n(writer, hbar, 9 * 3 + 8);
    try write_n(writer, plus, 1);
    try write_n(writer, hbar, 8 * 4 - 1);
    try writer.writeByte('\n');

    for (trials) |stats| {
        if (stats.trial.perf.mem_calls == 0) continue;
        try writer.print(
            "{[name]s: <[max_name_len]} {[vbar]s}" ++
                "{[l1mpm]d: >8.3} " ++
                "{[l1mpc]d: >7.3} " ++
                "{[l1rpc]d: >8.3} " ++
                "{[l1wpc]d: >8.3} {[vbar]s}" ++
                "{[llmpc]d: >7.3} " ++
                "{[llrpc]d: >7.3} " ++
                "{[llwmpc]d: >7.3} " ++
                "{[llwpc]d: >7.3}\n",
            .{
                .name = stats.trial.name,
                .max_name_len = max_name_len + 1,
                .l1mpm = stats.l1d_miss_per_mill,
                .l1mpc = stats.l1d_read_miss_per_call,
                .l1rpc = stats.l1d_read_per_call,
                .l1wpc = stats.l1d_write_per_call,
                .llmpc = stats.ll_read_miss_per_call,
                .llrpc = stats.ll_read_per_call,
                .llwmpc = stats.ll_write_miss_per_call,
                .llwpc = stats.ll_write_per_call,
                .vbar = vbar,
            },
        );
    }
    try writer.flush();
}

pub fn csv_summary(
    writer: *std.Io.Writer,
    trials: []const root.TrialStats,
    opts: root.SummaryOpts,
) !void {
    // header
    if (opts.with_header) {
        try writer.print(
            "fn{[sep]c}calls{[sep]c}seconds{[sep]c}mean",
            .{ .sep = opts.separator },
        );
        for (opts.pctiles) |p| {
            try writer.print("{c}p{d}", .{ opts.separator, p });
        }
        if (opts.with_perf and Env.perf_cpu) {
            try writer.print(
                "{[sep]c}ipc{[sep]c}inst_per_call{[sep]c}cycle_per_call" ++
                    "{[sep]c}brmiss_per_mill{[sep]c}brmiss_per_call{[sep]c}branch_per_call{[sep]c}l1i_miss_per_call",
                .{ .sep = opts.separator },
            );
        }
        if (opts.with_perf and Env.perf_mem) {
            try writer.print(
                "{[sep]c}l1d_read_per_call{[sep]c}l1d_read_miss_per_call" ++
                    "{[sep]c}ll_read_per_call{[sep]c}ll_read_miss_per_call" ++
                    "{[sep]c}l1d_write_per_call{[sep]c}ll_write_per_call{[sep]c}ll_write_miss_per_call",
                .{ .sep = opts.separator },
            );
        }
        try writer.writeByte('\n');
    }

    // data
    for (trials) |t| {
        try writer.print(
            "{[name]s}{[sep]c}{[calls]d}{[sep]c}{[time]d:.4}{[sep]c}{[mean]d:.4}",
            .{
                .name = t.trial.name,
                .calls = t.trial_calls,
                .time = t.trial_nanos / 1e9,
                .mean = t.call_avg_ns,
                .sep = opts.separator,
            },
        );
        for (opts.pctiles) |p| {
            // percentiles[] is stored descending (index 0 = worst, index 100 = best),
            // so ascending percentile `p` lives at index (100 - p).
            try writer.print("{[sep]c}{[v]d:.4}", .{
                .v = t.percentiles[100 - p],
                .sep = opts.separator,
            });
        }
        if (opts.with_perf and Env.perf_cpu) {
            try writer.print(
                "{[sep]c}{[ipc]d:.4}{[sep]c}{[inst]d:.4}{[sep]c}{[cyc]d:.4}" ++
                    "{[sep]c}{[brmrt]d:.4}{[sep]c}{[brmiss]d:.4}{[sep]c}{[brtot]d:.4}{[sep]c}{[imiss]d:.4}",
                .{
                    .ipc = t.inst_per_cycle,
                    .inst = t.inst_per_call,
                    .cyc = t.cycle_per_call,
                    .brmrt = t.brmiss_per_mill,
                    .brmiss = t.brmiss_per_call,
                    .brtot = t.branch_per_call,
                    .imiss = t.l1i_miss_per_call,
                    .sep = opts.separator,
                },
            );
        }
        if (opts.with_perf and Env.perf_mem) {
            try writer.print(
                "{[sep]c}{[l1r]d:.4}{[sep]c}{[l1rm]d:.4}{[sep]c}{[llr]d:.4}{[sep]c}{[llrm]d:.4}" ++
                    "{[sep]c}{[l1w]d:.4}{[sep]c}{[llw]d:.4}{[sep]c}{[llwm]d:.4}",
                .{
                    .l1r = t.l1d_read_per_call,
                    .l1rm = t.l1d_read_miss_per_call,
                    .llr = t.ll_read_per_call,
                    .llrm = t.ll_read_miss_per_call,
                    .l1w = t.l1d_write_per_call,
                    .llw = t.ll_write_per_call,
                    .llwm = t.ll_write_miss_per_call,
                    .sep = opts.separator,
                },
            );
        }
        try writer.writeByte('\n');
    }
    try writer.flush();
}

pub fn csv_samples(
    writer: *std.Io.Writer,
    trials: []const root.TrialStats,
    opts: root.SamplesOpts,
) !void {
    try writer.print("fn{[sep]c}calls{[sep]c}nanos\n", .{ .sep = opts.separator });
    for (trials) |t| {
        for (t.trial.data.items) |s| {
            try writer.print("{[name]s}{[sep]c}{[calls]d}{[sep]c}{[nanos]d}\n", .{
                .name = t.trial.name,
                .calls = s.calls,
                .nanos = s.nanos,
                .sep = opts.separator,
            });
        }
    }
    try writer.flush();
}

const gnuplot_template = @embedFile("template.gp");

pub fn gnuplot(
    writer: *std.Io.Writer,
    trials: []const root.TrialStats,
    opts: root.GnuplotOpts,
) !void {
    const suite_title = opts.title orelse "zmida";
    const units = "Kops/sec";
    const pctiles = [_]u32{ 10, 25, 50, 75, 90 };

    try writer.print("$Data << EOD\n", .{});
    for (trials) |t| {
        try writer.print("{[name]s} {[mean]d:.4}", .{ .name = t.trial.name, .mean = 1e6 / t.call_avg_ns });
        for (pctiles) |p| {
            try writer.print(" {d:.4}", .{1e6 / t.percentiles[p]});
        }
        try writer.writeByte('\n');
    }
    try writer.print("EOD\n\n", .{});
    try writer.print(gnuplot_template, .{ .title = suite_title, .units = units });
    try writer.flush();
}

const gnuplot_perf_template = @embedFile("template_perf.gp");

pub fn gnuplot_perf(
    writer: *std.Io.Writer,
    trials: []const root.TrialStats,
    opts: root.GnuplotOpts,
) !void {
    try writer.print("$Data << EOD\n", .{});
    for (trials) |t| {
        try writer.print(
            "{[name]s} {[inst]d:.4} {[cyc]d:.4} {[brm]d:.4} {[brt]d:.4} {[imiss]d:.4}\n",
            .{
                .name = t.trial.name,
                .inst = t.inst_per_call,
                .cyc = t.cycle_per_call,
                .brm = t.brmiss_per_call,
                .brt = t.branch_per_call,
                .imiss = t.l1i_miss_per_call,
            },
        );
    }
    try writer.print("EOD\n\n", .{});
    try writer.print(gnuplot_perf_template, .{ .title = opts.title orelse "zmida" });
    try writer.flush();
}

test "refAllDecls" {
    _ = std.testing.refAllDecls(@This());
}
