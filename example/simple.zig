const std = @import("std");
const zm = @import("zmida");

pub fn main(init: std.process.Init) !void {
    const funcs = .{ logtgamma, lgamma };
    const args = zm.gen.uniform(f64, 100, 0, 10, 0);

    try zm.bench(&init, funcs, &args);
    try zm.bench_ex("simple", &init, .{ .verbose = 0 }, .bycount(.{}), funcs, &args);
}

fn lgamma(x: f64) f64 {
    return std.math.lgamma(f64, x);
}

fn logtgamma(x: f64) f64 {
    return std.math.log(f64, std.math.e, std.math.gamma(f64, x));
}
