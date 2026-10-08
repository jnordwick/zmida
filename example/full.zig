const std = @import("std");
const zm = @import("zmida");

// We want force the compiler unroll the timing loop to expose more ILP.
pub const __zm__callmod__ = std.builtin.CallModifier.always_inline;

pub fn main(init: std.process.Init) !void {
    const funcs =
        .{ div, adiv, adiv0, adiv_folded, adiv_half_step };

    const N = 512;
    var args: [N]struct { Vec, Vec } = undefined;
    for (0..N) |i| {
        args[i][0] = zm.gen.uniform(f32, 8, 0, 100.0, i);
        args[i][1] = zm.gen.uniform(f32, 8, 0, 100.0, i + 1);
    }

    // pin the cpu, and gather perf counters. We are looking for ILP
    zm.init(&init, .{ .pin_cpu = 1, .perf_cpu = true });
    const config: zm.Config = .byadapt(.{});

    var study = try zm.Study.run("div", config, funcs, &args);
    defer study.deinit();

    try study.write_text(null, .{ .mode = .thru });
    try study.write_gnuplot("div", .{});
    try study.write_gnuplot_perf("div", .{});
}

const Vec = @Vector(8, f32);
const UVec = @Vector(8, u32);

fn adiv_folded(n: Vec, x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const ubits: UVec = @bitCast(x);
    const aug = magic -% ubits;
    const r0: Vec = @bitCast(aug);
    const factor = @mulAdd(Vec, -x, r0, @as(Vec, @splat(2.0)));
    return (n * r0) * factor;
}

fn adiv_half_step(n: Vec, x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const ubits: UVec = @bitCast(x);
    const aug = magic -% ubits;
    const r0: Vec = @bitCast(aug);
    const r1 = r0 * @mulAdd(Vec, -x, r0, @as(Vec, @splat(2.0)));
    const q0 = n * r1;
    return @mulAdd(Vec, @mulAdd(Vec, -q0, x, n), r0, q0);
}

fn adiv0(n: Vec, x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const ubits: UVec = @bitCast(x);
    const aug = magic -% ubits;
    var r: Vec = @bitCast(aug);
    r *= @mulAdd(Vec, -x, r, @as(Vec, @splat(2.0)));
    return n * r;
}

fn adiv(n: Vec, x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const zero: Vec = @splat(0.0);
    const inf: Vec = @splat(std.math.inf(f32));
    const ubits: UVec = @bitCast(x);
    const aug = magic -% ubits;
    var r: Vec = @bitCast(aug);
    r *= @mulAdd(Vec, -x, r, @as(Vec, @splat(2.0)));
    r = @select(f32, x == zero, inf, r);
    return n * r;
}

fn div(n: Vec, x: Vec) Vec {
    return n / x;
}
