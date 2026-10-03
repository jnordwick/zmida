const std = @import("std");
const zm = @import("zmida");

pub fn main(init: std.process.Init) !void {
    const bb = zm.gen.uniform(f32, 100, 2, 10, 0);
    const xx = zm.gen.uniform(f32, 100, 10, 100, 0);
    const args = zm.gen.tie(.{ bb, xx });

    try zm.bench(&init, .{ std_log, builtin_log }, &args);

    const ls = zm.gen.LinSpace(f32).init(1, 10, 100);
    try zm.bench(&init, just_log, ls);
}

fn std_log(base: f32, x: f32) f32 {
    return std.math.log(f32, base, x);
}

fn builtin_log(base: f32, x: f32) f32 {
    return @log(x) / @log(base);
}

fn just_log(x: f32) f32 {
    return @log(x);
}
