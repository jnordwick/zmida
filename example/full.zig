const std = @import("std");
const zm = @import("zmida");
const dno = std.mem.doNotOptimizeAway;

// We want to force ILP between calls. Technically, since out input
// is multiple calls, we get ILP within the call. If we were to make
// the input be a single argument typle, then this would be necessary.
// But I'm using it to show how to do it.
pub const __zm__callmod__ = std.builtin.CallModifier.always_inline;

pub fn main(init: std.process.Init) !void {
    const funcs = .{ div, adiv, adiv0 };
    // setting up the vector input takes a lot of work
    const N = 10;
    var xs: [N * 8]f32 align(32) = zm.gen.uniform(f32, N * 8, 0, 1000.0, 0);
    var xv: [N]Vec = @as(*[N]Vec, @ptrCast(@alignCast(&xs))).*;
    var ys: [N * 8]f32 align(32) = zm.gen.uniform(f32, N * 8, 0, 1000.0, 1);
    var yv: [N]Vec = @as(*[N]Vec, @ptrCast(@alignCast(&ys))).*;
    const arg: struct { []Vec, []Vec } = .{ &xv, &yv };

    // pin the cpu, and gather perf counters. We are looking for ILP
    zm.init(&init, .{ .pin_cpu = 1, .perf_cpu = true });
    const config: zm.Config = .byadapt(.{});

    var study = try zm.Study.run("div", config, funcs, arg);

    // the data here represents 10 calls rcp and rcp0 the way it was setup
    try study.write_text(null, .{ .mode = .lat });
    try study.write_gnuplot("div", .{});
    try study.write_gnuplot_perf("div", .{});
}

const Vec = @Vector(8, f32);
const UVec = @Vector(8, u32);

fn adiv0(x: []Vec, y: []Vec) void {
    for (x, y) |*xx, *yy| {
        xx.* = xx.* * rcp0(yy.*);
    }
}

fn adiv(x: []Vec, y: []Vec) void {
    for (x, y) |*xx, *yy| {
        xx.* = xx.* * rcp(yy.*);
    }
}

fn div(x: []Vec, y: []Vec) void {
    for (x, y) |*xx, *yy| {
        xx.* = xx.* / yy.*;
    }
}

// manual fast reciprocal that does not check for 0 and is willing to
// just get a very large output (only valid x > 0)
fn rcp0(x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const ubits: UVec = @bitCast(x);
    const aug = magic - ubits;
    var r: Vec = @bitCast(aug);
    r *= @mulAdd(Vec, -x, r, @as(Vec, @splat(2.0)));
    return r;
}

// manual fast reciprocal (only vaid for x >= 0)
fn rcp(x: Vec) Vec {
    const magic: UVec = @splat(0x7ef311c2);
    const zero: Vec = @splat(0.0);
    const inf: Vec = @splat(std.math.inf(f32));
    const ubits: UVec = @bitCast(x);
    const aug = magic - ubits;
    var r: Vec = @bitCast(aug);
    r *= @mulAdd(Vec, -x, r, @as(Vec, @splat(2.0)));
    r = @select(f32, x == zero, inf, r);
    return r;
}
