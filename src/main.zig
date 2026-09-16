const std = @import("std");
const zm = @import("zmida");

pub fn main(init: std.process.Init) !void {
    const N = 100;
    var xosh: std.Random.Xoshiro256 = .init(0);
    var rand = xosh.random();
    var xx: [N]f64 = undefined;
    for (&xx) |*x| {
        x.* = rand.float(f64) * 20;
    }
    const funcs = .{ tgamma, lgamma, tgamma, lgamma };

    zm.set_global_opts(.{ .verbose = 1, .use_tsc = true, .perf = true });
    const config: zm.Config = .bycount(.{});
    var study = try zm.Study.run(init.gpa, init.io, null, config, funcs, xx);
    try study.write_text(null, .{ .mode = .lat });
    // try study.write_summary(null, .{ .separator = '\t' });
    // try study.write_gnuplot("example", .{});
    defer study.deinit();
}

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
    const start = zm.util.now();
    zm.util.pause_until(start + x * 1000 * 1000);
}

fn printf(io: anytype, comptime fmt: anytype, args: anytype) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);

    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
