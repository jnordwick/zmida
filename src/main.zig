const std = @import("std");
const Io = std.Io;

const zz = @import("zmida");

fn lgamma(x: f64) f64 {
    return std.math.lgamma(f64, x);
}

fn tgamma(x: f64) f64 {
    return std.math.gamma(f64, x);
}

fn wait(x: u32) void {
    const start = zz.util.now();
    zz.util.pause_until(start + x * 1000 * 1000);
}

fn printf(io: anytype, comptime fmt: anytype, args: anytype) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);

    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    // var xosh: std.Random.Xoshiro256 = .init(0);
    // var rand = xosh.random();

    // const N = 1000;
    // var xx: [N]f64 = undefined;
    // for (&xx) |*x| {
    //     x.* = rand.float(f64) * 1000;
    // }

    const ss = [5]u32{ 10, 10, 10, 10, 10 };

    try printf(init.io, "running\n", .{});
    const config = zz.CountConfig{ .warmup_passes = 1, .trial_batches = 10, .batch_passes = 1 };
    const t1 = try zz.bench(init.gpa, config, wait, ss);
    const t2 = try zz.bench(
    const stats: zz.TrialStats = .init(&t1);
    defer t1.deinit();

    const ts: [1]zz.TrialStats = .{stats};
    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    try zz.out.text_out(&stdout.interface, &ts);
}
