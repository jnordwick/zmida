const std = @import("std");
const zz = @import("root.zig");
const util = @import("util.zig");
const float_div = util.float_div;

/// a batch is the atomic level for the stats. any stats lower than
/// that are based on running a batch and dividing by the number of
/// passes or calls in it.
pub const TrialStats = struct {
    trial_nanos: u64 = 0,
    trial_calls: u64 = 0,
    call_max_ns: f64 = 0,
    call_min_ns: f64 = 0,
    call_avg_ns: f64 = 0,
    call_stdev_ns: f64 = 0,

    pub fn init(trial: *const zz.Trial) TrialStats {
        const runs_slice = trial.runs.items;
        if (runs_slice.len == 0) return .{};

        var total_calls: u64 = 0;
        var total_nanos: u64 = 0;
        var min_ns: f64 = std.math.inf(f64);
        var max_ns: f64 = -std.math.inf(f64);

        // Pass 1: Gather grand totals and establish min/max call durations
        for (runs_slice) |batch| {
            if (batch.calls == 0) continue;

            total_calls += batch.calls;
            total_nanos += batch.nanos;

            const batch_avg_ns = float_div(f64, batch.nanos, batch.calls);
            if (batch_avg_ns < min_ns) min_ns = batch_avg_ns;
            if (batch_avg_ns > max_ns) max_ns = batch_avg_ns;
        }

        const avg_ns = float_div(f64, total_nanos, total_calls);

        // Pass 2: Calculate the unrolled-call standard deviation
        var sum_squared_diffs: f64 = 0.0;
        for (runs_slice) |batch| {
            if (batch.calls == 0) continue;

            const batch_avg_ns = float_div(f64, batch.nanos, batch.calls);
            const diff = batch_avg_ns - avg_ns;

            // Multiply by the individual batch's call count to scale it to the total data set
            sum_squared_diffs += @as(f64, @floatFromInt(batch.calls)) * (diff * diff);
        }

        const denominator: f64 = @floatFromInt(total_calls);
        const stdev_ns = @sqrt(sum_squared_diffs / denominator);

        return TrialStats{
            .trial_nanos = total_nanos,
            .trial_calls = total_calls,
            .call_max_ns = max_ns,
            .call_min_ns = min_ns,
            .call_avg_ns = avg_ns,
            .call_stdev_ns = stdev_ns,
        };
    }
};

test "refalldecls" {
    std.testing.refAllDecls(@This());
}
