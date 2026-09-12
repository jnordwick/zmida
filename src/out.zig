const std = @import("std");
const root = @import("root.zig");

const float_div = @import("util.zig").float_div;

const text_header =
    \\{[name]s}
    \\units: {[longunits]s}
    \\mode: {[mode]s}
    \\
;

fn write_n(writer: *std.Io.Writer, x: []const u8, count: usize) !void {
    for (0..count) |_| {
        try writer.print("{s}", .{x});
    }
}

pub fn text_out_thruput(writer: *std.Io.Writer, trials: []const root.TrialStats, opts: root.TextOpts) !void {
    var name_len: usize = "fn".len;
    var max_avg: f64 = 0;
    for (trials) |stats| {
        name_len = @max(name_len, stats.trial.name.len);
        max_avg = @max(max_avg, 1e9 / stats.call_avg_ns);
    }
    const groups: u32 = @intFromFloat(std.math.floor(std.math.log(f64, 1000.0, max_avg)));
    _, const longunits, const factor: f64 = switch (groups) {
        0 => .{ "ops", "ops/sec", 1e9 },
        1 => .{ "Kops", "Kops/sec", 1e6 },
        2 => .{ "Mops", "Mops/sec", 1e3 },
        else => .{ "Gops", "Gops/sec", 1e0 },
    };

    const vbar, const hbar, const plus = if (opts.ascii) .{ "|", "-", "+" } else .{ "\u{2502}", "\u{2500}", "\u{253c}" };

    if (opts.header) {
        try writer.print(text_header, .{
            .name = "default suite name",
            .mode = "throughput (higher is better)",
            .longunits = longunits,
        });
    }

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

    var separator_len = name_len + 2;
    try write_n(writer, hbar, separator_len);
    try write_n(writer, plus, 1);
    separator_len = 12 + 9 + 8;
    try write_n(writer, hbar, separator_len);
    try write_n(writer, plus, 1);
    separator_len = 5 * 8 - 1;
    try write_n(writer, hbar, separator_len);
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
                .total = @as(f64, @floatFromInt(stats.trial_nanos)) / 1e9,
                .avg = factor / stats.call_avg_ns,
                .min = factor / stats.call_min_ns,
                .p25 = factor / stats.percentiles[75],
                .p50 = factor / stats.percentiles[50],
                .p75 = factor / stats.percentiles[25],
                .max = factor / stats.call_max_ns,
                .vbar = vbar,
            },
        );
    }
    try writer.flush();
}

pub fn text_out_latency(writer: *std.Io.Writer, trials: []const root.TrialStats, opts: root.TextOpts) !void {
    var name_len: usize = "fn".len;
    var max_avg: f64 = 1e-9;
    for (trials) |stats| {
        name_len = @max(name_len, stats.trial.name.len);
        max_avg = @max(max_avg, stats.call_avg_ns);
    }
    const groups: u32 = @intFromFloat(std.math.floor(std.math.log(f64, 1000.0, max_avg)));
    _, const longunits, const factor: f64 = switch (groups) {
        0 => .{ "ns", "nanosec/op", 1.0 },
        1 => .{ "us", "microsec/op", 1e-3 },
        2 => .{ "ms", "millisec/op", 1e-6 },
        else => .{ "s", "seconds/op", 1e-9 },
    };

    const vbar, const hbar, const plus = if (opts.ascii) .{ "|", "-", "+" } else .{ "\u{2502}", "\u{2500}", "\u{253c}" };

    if (opts.header) {
        try writer.print(text_header, .{
            .name = "default suite name",
            .mode = "latency (lower is better)",
            .longunits = longunits,
        });
    }

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

    var separator_len = name_len + 2;
    try write_n(writer, hbar, separator_len);
    try write_n(writer, plus, 1);
    separator_len = 12 + 9 + 8;
    try write_n(writer, hbar, separator_len);
    try write_n(writer, plus, 1);
    separator_len = 5 * 8 - 1;
    try write_n(writer, hbar, separator_len);
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
                .total = @as(f64, @floatFromInt(stats.trial_nanos)) / 1e9,
                .avg = stats.call_avg_ns * factor,
                .min = stats.call_min_ns * factor,
                .p25 = stats.percentiles[75] * factor,
                .p50 = stats.percentiles[50] * factor,
                .p75 = stats.percentiles[25] * factor,
                .max = stats.call_max_ns * factor,
                .vbar = vbar,
            },
        );
    }
    try writer.flush();
}

pub fn csv_out_summary(writer: *std.Io.Writer, trials: []const root.TrialStats) !void {
    const cols = [_]u32{ 100, 75, 50, 25, 0 };
    try writer.print("fn,calls,seconds,mean", .{});
    for (&cols) |c| {
        try writer.print(",p{d}", .{c});
    }
    try writer.writeByte('\n');

    for (trials) |t| {
        try writer.print(
            "{[name]s},{[calls]d},{[time]d:.4},{[mean]d:.4}",
            .{
                .name = t.trial.name,
                .calls = t.trial_calls,
                .time = @as(f64, @floatFromInt(t.trial_nanos)) / 1e9,
                .mean = t.call_avg_ns,
            },
        );
        for (&cols) |c| {
            try writer.print(",{d:.4}", .{t.percentiles[c]});
        }
        try writer.writeByte('\n');
    }
    try writer.flush();
}

pub fn csv_out_samples(writer: *std.Io.Writer, trials: []const root.TrialStats) !void {
    try writer.print("fn,calls,time\n", .{});
    for (trials) |t| {
        for (t.trial.data.items) |s| {
            try writer.print("{s},{d},{d}\n", .{ t.trial.name, s.calls, s.nanos });
        }
    }
}

const gnuplot_template =
    \\set title "{[title]s}"
    \\set ylabel "ops/sec"
    \\set grid y
    \\set style fill solid 0.5 border
    \\set boxwidth 0.1
    \\set autoscale xfix
    \\set offsets 0.5, 0.5, 0, 0
    \\set xtics rotate by -45
    \\plot $Data using 0:($4-$5):2:3:($4+$5):xticlabels(1) \
    \\     with candlesticks linecolor rgb "#333333" fill solid 0.4 \
    \\     title "min/max & stdev", \
    \\     $Data using 0:4 with points pointtype 7 pointsize 1.2 linecolor rgb "#d62728" \
    \\     title "mean"
;

pub fn gnuplot_out(writer: *std.Io.Writer, trials: []const root.TrialStats) !void {
    const suite_title = "Suite Name";
    try writer.print("$Data << EOD\n", .{});
    for (trials) |t| {
        try writer.print("{[name]s: <20} {[min]d: <12.4} {[max]d: <12.4} {[avg]d: <12.4}\n", .{
            .name = t.trial.name,
            .min = 1e9 / t.call_max_ns,
            .max = 1e9 / t.call_min_ns,
            .avg = 1e9 / t.call_avg_ns,
        });
    }
    try writer.print("EOD\n\n", .{});
    try writer.print(gnuplot_template, .{ .title = suite_title });
}

test "refAllDecls" {
    _ = std.testing.refAllDecls(@This());
}
