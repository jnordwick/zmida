const std = @import("std");
const zz = @import("root.zig");
const util = @import("util.zig");
const float_div = util.float_div;

/// a batch is the atomic level for the stats. any stats lower than
/// that are based on running a batch and dividing by the number of
pub const TrialStats = struct {
    trial: *const zz.Trial,
    trial_nanos: u64 = 0,
    trial_calls: u64 = 0,
    call_max_ns: f64 = 0,
    call_min_ns: f64 = 0,
    call_avg_ns: f64 = 0,

    pub fn init(trial: *const zz.Trial) TrialStats {
        const runs_slice = trial.data.items;
        if (runs_slice.len == 0) return .{ .trial = trial };

        var total_calls: u64 = 0;
        var total_nanos: u64 = 0;
        var min_ns: f64 = std.math.inf(f64);
        var max_ns: f64 = -std.math.inf(f64);

        for (runs_slice) |batch| {
            if (batch.calls == 0) @panic("batch had zero calls");

            total_calls += batch.calls;
            total_nanos += batch.nanos;

            const batch_avg_ns = float_div(f64, batch.nanos, batch.calls);
            if (batch_avg_ns < min_ns) min_ns = batch_avg_ns;
            if (batch_avg_ns > max_ns) max_ns = batch_avg_ns;
        }

        return TrialStats{
            .trial = trial,
            .trial_nanos = total_nanos,
            .trial_calls = total_calls,
            .call_max_ns = max_ns,
            .call_min_ns = min_ns,
            .call_avg_ns = float_div(f64, total_calls, total_nanos),
        };
    }
};

test "refalldecls" {
    std.testing.refAllDecls(@This());
}
