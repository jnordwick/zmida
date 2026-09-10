const std = @import("std");
const zz = @import("root.zig");

pub fn text_out(writer: *std.Io.Writer, trials: []const zz.TrialStats) !void {
    // Find the longest function name so the numeric columns line up.
    var name_len: usize = "Function".len;
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
        "{[name]s: <[name_len]} {[calls]s: >12} {[total]s: >12}{[units]s} {[min]s: >10}{[units]s} {[avg]s: >10}{[units]s} {[max]s: >10}{[units]s} {[sdev]s: >10}{[units]s}\n",
        .{
            .name = "Function",
            .name_len = name_len,
            .units = units,
            .calls = "Calls",
            .total = "Total",
            .min = "Min",
            .avg = "Avg",
            .max = "Max",
            .sdev = "Stdev",
        },
    );

    const separator_len = name_len + 1 + 12 + 1 + 12 + 4 + 10 + 4 + 10 + 4 + 10 + 4 + 10 + 3;

    for (0..separator_len) |_| {
        try writer.writeByte('-');
    }
    try writer.writeByte('\n');

    for (trials) |stats| {
        try writer.print(
            "{[name]s: <[name_len]} {[calls]d: >12} {[total]e: >15.4} {[min]d: >13.4} {[avg]d: >13.4} {[max]d: >13.4} {[sdev]d: >13.4}\n",
            .{
                .name = stats.trial.name,
                .name_len = name_len,
                .calls = stats.trial_calls,
                .total = @as(f64, @floatFromInt(stats.trial_nanos)) * factor,
                .min = stats.call_min_ns * factor,
                .avg = stats.call_avg_ns * factor,
                .max = stats.call_max_ns * factor,
                .sdev = stats.call_stdev_ns * factor,
            },
        );
    }
}
