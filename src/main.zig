const std = @import("std");
const Io = std.Io;

const zz = @import("zmida");

fn lgamma(x: f64) f64 {
    return std.math.lgamma(f64, x);
}

fn tgamma(x: f64) f64 {
    return std.math.gamma(f64, x);
}

fn log(x: f64) f64 {
    return @log(x);
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
    var xosh: std.Random.Xoshiro256 = .init(0);
    var rand = xosh.random();
    const N = 100;
    var xx: [N]f64 = undefined;
    for (&xx) |*x| {
        x.* = rand.float(f64) * std.math.pi * 8;
    }

    const config = zz.TimedConfig{};
    const funcs = .{ tgamma, lgamma, std.math.sinh, log };
    var study = try zz.Study.run(init.gpa, config, funcs, xx);
    defer study.deinit();
    try study.gen_stats(init.gpa);

    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    try zz.out.text_out_latency(&stdout.interface, study.stats.items);
    try zz.out.text_out_thruput(&stdout.interface, study.stats.items);
    //try zz.out.gnuplot_out(&stdout.interface, &ts);
}
