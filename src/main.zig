const std = @import("std");
const zm = @import("zmida");

pub const zm__call_mod = std.builtin.CallModifier.always_inline;

pub fn main(init: std.process.Init) !void {
    const funcs = .{ logtgamma, lgamma, logtgamma, lgamma };
    const xx = zm.gen.uniform(f64, 100, 0, 10, 0);

    zm.init(init, .{
        .verbose = 2,
        .pin_cpu = 1,
        .perf_cpu = true,
    });
    const config: zm.Config = .byadapt(.{});
    var study = try zm.Study.run(
        "gamma",
        config,
        funcs,
        &xx,
    );
    defer study.deinit();
    try study.write_text(null, .{ .mode = .thru });
    //try study.write_gnuplot("ex", .{});
    //try study.write_gnuplot_perf("gamma", .{});
}

fn lgamma(x: f64) f64 {
    return std.math.lgamma(f64, x);
}

fn logtgamma(x: f64) f64 {
    return std.math.log(f64, std.math.e, std.math.gamma(f64, x));
}
