const std = @import("std");
const root = @import("root.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const CpuCounters = root.CpuCounters;
const MemReadCounters = root.MemReadCounters;
const MemWriteCounters = root.MemWriteCounters;

pub const TrialStats = struct {
    trial: *const root.Trial,
    trial_calls: u64 = 0,
    trial_nanos: f64 = 0,
    call_max_ns: f64 = -std.math.inf(f64),
    call_min_ns: f64 = std.math.inf(f64),
    call_avg_ns: f64 = 0,

    perf: CpuCounters = .{},
    memr: MemReadCounters = .{},
    memw: MemWriteCounters = .{},

    percentiles: [101]f64 = @splat(0),

    pub fn init(alloc: Allocator, trial: *const root.Trial) TrialStats {
        const runs_slice = trial.data.items;
        if (runs_slice.len == 0) return .{ .trial = trial };

        var total_calls: u64 = 0;
        var total_nanos: f64 = 0;

        for (runs_slice) |batch| {
            if (batch.calls == 0) @panic("batch had zero calls");
            total_calls += batch.calls;
            total_nanos += batch.nanos;
        }

        const lat = latencies(alloc, trial.data.items);
        defer alloc.free(lat);
        const min_ns, const max_ns = minmax(lat);

        return TrialStats{
            .trial = trial,
            .trial_nanos = total_nanos,
            .trial_calls = total_calls,
            .call_max_ns = max_ns,
            .call_min_ns = min_ns,
            .call_avg_ns = total_nanos / @as(f64, @floatFromInt(total_calls)),
            .percentiles = percentiles(lat),
        };
    }
};

fn latencies(alloc: Allocator, samples: []root.Sample) []f64 {
    var s = alloc.alloc(f64, samples.len) catch @panic("oom");
    for (samples, 0..samples.len) |x, i| {
        s[i] = util.float_div(f64, x.nanos, x.calls);
    }
    return s;
}

fn minmax(ss: []const f64) struct { f64, f64 } {
    var mn: f64 = std.math.inf(f64);
    var mx: f64 = -std.math.inf(f64);
    for (ss) |s| {
        mn = @min(mn, s);
        mx = @max(mx, s);
    }
    return .{ mn, mx };
}

fn percentiles(ss: []f64) [101]f64 {
    var pt: [101]f64 = undefined;
    std.sort.pdq(f64, ss, {}, std.sort.desc(f64));
    for (0..101) |i| {
        const p = ((ss.len - 1) * i) / 100;
        pt[i] = ss[p];
    }
    return pt;
}

test "refalldecls" {
    std.testing.refAllDecls(@This());
}

const tt = std.testing;

test percentiles {
    var arr: [1234]f64 = undefined;
    for (&arr, 0..) |*a, i| {
        a.* = 1234.0 - @as(f64, @floatFromInt(i));
    }
    const pt = percentiles(&arr);
    try tt.expectEqual(@as(f64, 1234.0), pt[0]);
    try tt.expectEqual(@as(f64, 926.0), pt[25]);
    try tt.expectEqual(@as(f64, 618.0), pt[50]);
    try tt.expectEqual(@as(f64, 310.0), pt[75]);
}
