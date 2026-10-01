const std = @import("std");
const tt = std.testing;

const root = @import("root.zig");
const util = @import("util.zig");
const float_div = util.float_div;
const Env = root.Env;

pub const TrialStats = struct {
    trial: *const root.Trial,
    trial_calls: u64 = 0,
    trial_nanos: f64 = 0,
    call_max_ns: f64 = -std.math.inf(f64),
    call_min_ns: f64 = std.math.inf(f64),
    call_avg_ns: f64 = 0,

    // cpu instruction
    inst_per_cycle: f64 = 0,
    inst_per_call: f64 = 0,
    cycle_per_call: f64 = 0,
    brmiss_per_mill: f64 = 0,
    brmiss_per_call: f64 = 0,
    branch_per_call: f64 = 0,
    l1i_miss_per_call: f64 = 0,

    // cache
    l1d_miss_per_mill: f64 = 0,
    l1d_read_per_call: f64 = 0,
    l1d_read_miss_per_call: f64 = 0,

    ll_read_per_call: f64 = 0,
    ll_read_miss_per_call: f64 = 0,

    l1d_write_per_call: f64 = 0,
    ll_write_miss_per_call: f64 = 0,
    ll_write_per_call: f64 = 0,

    percentiles: [101]f64 = @splat(0),

    pub fn init(trial: *const root.Trial) TrialStats {
        const runs_slice = trial.data.items;
        if (runs_slice.len == 0) return .{ .trial = trial };

        var total_calls: u64 = 0;
        var total_nanos: f64 = 0;

        for (runs_slice) |batch| {
            if (batch.calls == 0) util.errexit("batch had zero calls: 0", .{});
            total_calls += batch.calls;
            total_nanos += batch.nanos;
        }

        const lat = latencies(trial.data.items);
        defer Env.alloc.free(lat);
        const min_ns, const max_ns = minmax(lat);

        const cpu_calls: f64 = @floatFromInt(trial.perf.cpu_calls);
        const mem_calls: f64 = @floatFromInt(trial.perf.mem_calls);
        const cpu = trial.perf.cpu;
        const memr = trial.perf.memr;
        const memw = trial.perf.memw;

        const ts = TrialStats{
            .trial = trial,
            .trial_nanos = total_nanos,
            .trial_calls = total_calls,
            .call_max_ns = max_ns,
            .call_min_ns = min_ns,
            .call_avg_ns = total_nanos / @as(f64, @floatFromInt(total_calls)),
            .percentiles = percentiles(lat),

            .inst_per_cycle = float_div(f64, cpu.instructions, cpu.cpu_cycles),
            .inst_per_call = adj(cpu, cpu.instructions) / cpu_calls,
            .cycle_per_call = adj(cpu, cpu.cpu_cycles) / cpu_calls,
            .brmiss_per_mill = float_div(f64, 1_000_000 * cpu.branch_miss, cpu.branch_total),
            .brmiss_per_call = adj(cpu, cpu.branch_miss) / cpu_calls,
            .branch_per_call = adj(cpu, cpu.branch_total) / cpu_calls,
            .l1i_miss_per_call = adj(cpu, cpu.l1i_read_miss) / cpu_calls,

            .l1d_miss_per_mill = float_div(f64, 1_000_000 * memr.l1d_read_miss, memr.l1d_read),
            .l1d_read_per_call = adj(memr, memr.l1d_read) / mem_calls,
            .l1d_read_miss_per_call = adj(memr, memr.l1d_read_miss) / mem_calls,

            .ll_read_per_call = adj(memr, memr.ll_read) / mem_calls,
            .ll_read_miss_per_call = adj(memr, memr.ll_read_miss) / mem_calls,

            .l1d_write_per_call = adj(memw, memw.l1d_write) / mem_calls,
            .ll_write_per_call = adj(memw, memw.ll_write) / mem_calls,
            .ll_write_miss_per_call = adj(memw, memw.ll_write_miss) / mem_calls,
        };
        return ts;
    }
};

fn adj(counter: anytype, c: u64) f64 {
    const ru: f64 = @floatFromInt(counter.time_running);
    const en: f64 = @floatFromInt(counter.time_enabled);
    const cf: f64 = @floatFromInt(c);
    return (en / ru) * cf;
}

fn latencies(samples: []root.Sample) []f64 {
    var s = Env.alloc.alloc(f64, samples.len) catch |e| {
        util.errexit("alloc failed {}", e);
    };
    for (samples, 0..samples.len) |x, i| {
        s[i] = float_div(f64, x.nanos, x.calls);
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
