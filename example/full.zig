const std = @import("std");
const zm = @import("zmida");
const dno = std.mem.doNotOptimizeAway;

// We want to force ILP between calls. Technically, since out input
// is multiple calls, we get ILP within the call. If we were to make
// the input be a single argument typle, then this would be necessary.
// But I'm using it to show how to do it.
pub const __zm__callmod__ = std.builtin.CallModifier.always_inline;

pub fn main(init: std.process.Init) !void {
    const funcs = .{ div, adiv, adiv0, adiv_folded, adiv_half_step };

    const N = 100 * 2 * 8;
    var xs: [N]f32 align(32) = zm.gen.uniform(f32, N, 0, 1000.0, 0);
    const args: []struct { Vec, Vec } = @ptrCast(@alignCast(&xs));

    // pin the cpu, and gather perf counters. We are looking for ILP
    zm.init(&init, .{ .pin_cpu = 1, .perf_cpu = true });
    const config: zm.Config = .byadapt(.{});

    var study = try zm.Study.run("div", config, funcs, args);

    try study.write_text(null, .{ .mode = .lat });
    try study.write_gnuplot("div", .{});
    try study.write_gnuplot_perf("div", .{});
}

const Vec = @Vector(8, f32);
const UVec = @Vector(8, u32);

fn adiv_folded(n: Vec, x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const ubits: UVec = @bitCast(x);
    const aug = magic - ubits;
    const r0: Vec = @bitCast(aug);

    const factor = @mulAdd(Vec, -x, r0, @as(Vec, @splat(2.0)));

    return (n * r0) * factor;
}

fn adiv_half_step(n: Vec, x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const ubits: UVec = @bitCast(x);
    const aug = magic - ubits;
    const r0: Vec = @bitCast(aug);

    const r1 = r0 * @mulAdd(Vec, -x, r0, @as(Vec, @splat(2.0)));
    const q0 = n * r1;

    return @mulAdd(Vec, @mulAdd(Vec, -q0, x, n), r0, q0);
}

fn adiv0(n: Vec, x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const ubits: UVec = @bitCast(x);
    const aug = magic - ubits;
    var r: Vec = @bitCast(aug);
    r *= @mulAdd(Vec, -x, r, @as(Vec, @splat(2.0)));
    return n * r;
}

fn adiv(n: Vec, x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const zero: Vec = @splat(0.0);
    const inf: Vec = @splat(std.math.inf(f32));
    const ubits: UVec = @bitCast(x);
    const aug = magic - ubits;
    var r: Vec = @bitCast(aug);
    r *= @mulAdd(Vec, -x, r, @as(Vec, @splat(2.0)));
    r = @select(f32, x == zero, inf, r);
    return n * r;
}

fn div(n: Vec, x: Vec) Vec {
    return n / x;
}
