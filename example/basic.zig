const std = @import("std");
const zm = @import("zmida");

pub fn main(init: std.process.Init) !void {
    const funcs = .{ logtgamma, lgamma };
    const xx = zm.gen.uniform(f64, 100, 0, 10, 0);

    zm.set_global_opts(.{
        .use_tsc = true,
        .perf_level = .{ .cpu = true },
    });
    const config: zm.Config = .bytime(.{});
    var study = try zm.Study.run(
        init.gpa,
        init.io,
        "gamma",
        config,
        funcs,
        &xx,
    );
    defer study.deinit();
    try study.write_text(null, .{ .mode = .lat });
}

fn lgamma(x: f64) f64 {
    return std.math.lgamma(f64, x);
}

fn logtgamma(x: f64) f64 {
    return std.math.log(f64, std.math.e, std.math.gamma(f64, x));
}
