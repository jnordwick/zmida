const std = @import("std");
const zz = @import("root.zig");

pub fn text_out_thruput(writer: *std.Io.Writer, trials: []const zz.TrialStats) !void {
    var name_len: usize = "fn".len;
    var max_avg: f64 = 1;
    for (trials) |stats| {
        name_len = @max(name_len, stats.trial.name.len);
        max_avg = @max(max_avg, 1e9 / stats.call_avg_ns);
    }
    const groups: u32 = @intFromFloat(std.math.floor(std.math.log(f64, 1000.0, max_avg)));
    const units = switch (groups) {
        0 => " /s",
        1 => " K/s",
        2 => " M/s",
        else => " G/s",
    };
    const factor: f64 = switch (groups) {
        0 => 1e9,
        1 => 1e6,
        2 => 1e3,
        else => 1.0,
    };

    try writer.print(
        "{[name]s: <[name_len]} " ++
            "{[calls]s: >12} " ++
            "{[total]s: >12} " ++
            "{[min]s: >10}{[units]s} " ++
            "{[avg]s: >10}{[units]s} " ++
            "{[max]s: >10}{[units]s}\n",
        .{
            .name = "fn",
            .name_len = name_len,
            .units = units,
            .calls = "calls",
            .total = "total sec",
            .min = "min",
            .avg = "avg",
            .max = "max",
        },
    );

    const separator_len = name_len + 1 + 12 + 1 + 12 + 1 + 10 + 5 + 10 + 5 + 10 + 5 + 10 + 4;

    for (0..separator_len) |_| {
        try writer.writeByte('-');
    }
    try writer.writeByte('\n');

    for (trials) |stats| {
        try writer.print(
            "{[name]s: <[name_len]} " ++
                "{[calls]d: >12} " ++
                "{[total]e: >12.4} " ++
                "{[min]d: >14.4} " ++
                "{[avg]d: >14.4} " ++
                "{[max]d: >14.4}\n",
            .{
                .name = stats.trial.name,
                .name_len = name_len,
                .calls = stats.trial_calls,
                .total = @as(f64, @floatFromInt(stats.trial_nanos)) / 1e9,
                .min = factor / stats.call_min_ns,
                .avg = factor / stats.call_avg_ns,
                .max = factor / stats.call_max_ns,
            },
        );
    }
}

pub fn text_out_latency(writer: *std.Io.Writer, trials: []const zz.TrialStats) !void {
    var name_len: usize = "fn".len;
    var max_avg: f64 = 1e-9;
    for (trials) |stats| {
        name_len = @max(name_len, stats.trial.name.len);
        max_avg = @max(max_avg, stats.call_avg_ns);
    }
    const groups: u32 = @intFromFloat(std.math.floor(std.math.log(f64, 1000.0, max_avg)));
    const units = switch (groups) {
        0 => " ns",
        1 => " us",
        2 => " ms",
        else => " s ",
    };
    const factor: f64 = switch (groups) {
        0 => 1.0,
        1 => 1e-3,
        2 => 1e-6,
        else => 1e-9,
    };

    try writer.print(
        "{[name]s: <[name_len]} " ++
            "{[calls]s: >12} " ++
            "{[total]s: >12}{[units]s} " ++
            "{[min]s: >10}{[units]s} " ++
            "{[avg]s: >10}{[units]s} " ++
            "{[max]s: >10}{[units]s}\n",
        .{
            .name = "fn",
            .name_len = name_len,
            .units = units,
            .calls = "calls",
            .total = "total",
            .min = "min",
            .avg = "avg",
            .max = "max",
        },
    );

    const separator_len = name_len + 1 + 12 + 1 + 12 + 4 + 10 + 4 + 10 + 4 + 10 + 4 + 10 + 3;

    for (0..separator_len) |_| {
        try writer.writeByte('-');
    }
    try writer.writeByte('\n');

    for (trials) |stats| {
        try writer.print(
            "{[name]s: <[name_len]} " ++
                "{[calls]d: >12} " ++
                "{[total]e: >15.4} " ++
                "{[min]d: >13.4} " ++
                "{[avg]d: >13.4} " ++
                "{[max]d: >13.4}\n",
            .{
                .name = stats.trial.name,
                .name_len = name_len,
                .calls = stats.trial_calls,
                .total = @as(f64, @floatFromInt(stats.trial_nanos)) * factor,
                .min = stats.call_min_ns * factor,
                .avg = stats.call_avg_ns * factor,
                .max = stats.call_max_ns * factor,
            },
        );
    }
}

pub fn csv_out_summary(writer: *std.Io.Writer, trials: []const zz.TrialStats) !void {
    try writer.print("fn,calls,time,min,avg,max\n", .{});
    for (trials) |t| {
        try writer.print(
            "{[name]s},{[calls]d},{[total]d},{[min]d:.4},{[avg]d:.4},{[max]d:.4}\n",
            .{
                .name = t.trial.name,
                .calls = t.trial_calls,
                .total = t.trial_nanos,
                .min = t.call_min_ns,
                .avg = t.call_avg_ns,
                .max = t.call_max_ns,
            },
        );
    }
}

pub fn csv_out_samples(writer: *std.Io.Writer, trials: []const zz.TrialStats) !void {
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

pub fn gnuplot_out(writer: *std.Io.Writer, trials: []const zz.TrialStats) !void {
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
