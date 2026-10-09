const std = @import("std");
const zm = @import("zmida");

// I want to be able to pick out the assembly and make sure the entire
// function is compiled without specializing on input. Since I'm looping
// over a large array, a single extra function call overhead
// will be amortized over many calls.
pub const __zm__callmod__ = std.builtin.CallModifier.never_inline;

// too big for the stack
const N = 16 * 16 * 100;
var data: [N]u16 = undefined;

pub fn main(init: std.process.Init) !void {
    data = zm.gen.uniform(u16, N, 0, 4095, 0);

    // we lay out the data as a single argument to one call of the function
    const args: struct { [*c]u16, usize } = .{ @ptrCast(&data), N };
    const funcs = .{ basic, accum_4, accum_8, reduce, partial };

    // pin, set priority, and get cpu counters
    zm.init(&init, .{ .pin_cpu = 2, .set_prio = -10, .perf_cpu = true, .perf_mem = true });

    // we want output in units of number of elements
    const config: zm.Config = .byadapt(.{ .work_units = N / 16 });
    var study = try zm.Study.run("widesum", config, funcs, args);
    defer study.deinit();

    // latency mode doesn't make sense since we are specifically measuring over bulk workloads.

    try study.write_text(null, .{ .mode = .thru });
    try study.write_text("", .{ .mode = .thru });
    try study.write_gnuplot("", .{ .typ = .bars });
    try study.write_gnuplot_perf("", .{});
}

// I'm flagging all the functions as export so I can grab the assembly:
// objdump -Sl --disassemble=<funcname> --disassembler-color=on <filename>
const lanes = 16;

export fn basic(xin: [*c]u16, yin: usize) u64 {
    const x = xin[0..yin];
    var accum: u64 = 0;
    for (x) |xx| accum += xx;
    return accum;
}

export fn accum_4(xin: [*c]u16, yin: usize) u64 {
    const x = xin[0..yin];
    var accum0: u64 = 0;
    var accum1: u64 = 0;
    var accum2: u64 = 0;
    var accum3: u64 = 0;

    const stop = x.len & ~@as(usize, 3);
    var i: usize = 0;
    while (i < stop) : (i += 4) {
        accum0 += x[i];
        accum1 += x[i + 1];
        accum2 += x[i + 2];
        accum3 += x[i + 3];
    }
    accum0 += accum1;
    accum2 += accum3;
    accum0 += accum2;
    while (i < x.len) : (i += 1)
        accum0 += x[i];

    return accum0;
}

export fn accum_8(xin: [*c]u16, yin: usize) u64 {
    const x = xin[0..yin];
    var accum0: u64 = 0;
    var accum1: u64 = 0;
    var accum2: u64 = 0;
    var accum3: u64 = 0;
    var accum4: u64 = 0;
    var accum5: u64 = 0;
    var accum6: u64 = 0;
    var accum7: u64 = 0;

    const stop = x.len & ~@as(usize, 7);
    var i: usize = 0;
    while (i < stop) : (i += 8) {
        accum0 += x[i];
        accum1 += x[i + 1];
        accum2 += x[i + 2];
        accum3 += x[i + 3];
        accum4 += x[i + 4];
        accum5 += x[i + 5];
        accum6 += x[i + 6];
        accum7 += x[i + 7];
    }
    accum0 += accum1;
    accum2 += accum3;
    accum4 += accum5;
    accum6 += accum7;
    accum0 += accum2;
    accum4 += accum6;
    accum0 += accum4;

    while (i < x.len) : (i += 1)
        accum0 += x[i];

    return accum0;
}

export fn reduce(xin: [*c]u16, yin: usize) u64 {
    const x = xin[0..yin];
    const stop = x.len & ~@as(usize, lanes - 1);
    var accum: u64 = 0;
    var i: usize = 0;
    while (i < stop) : (i += lanes) {
        const v: @Vector(lanes, u16) = x[i..][0..lanes].*;
        accum += @reduce(.Add, v);
    }
    while (i < x.len) : (i += 1)
        accum += x[i];
    return accum;
}

export fn partial(xin: [*c]u16, yin: usize) u64 {
    const x = xin[0..yin];
    const block_lanes = 16; // must be power of 2
    var stop = x.len & ~@as(usize, block_lanes * lanes - 1);
    var accum: @Vector(lanes / 2, u32) = @splat(0);
    var i: usize = 0;
    while (i < stop) : (i += block_lanes * lanes) {
        var parts: @Vector(lanes, u16) = @splat(0);
        for (0..block_lanes) |j| {
            const row: @Vector(lanes, u16) = x[i + j * lanes ..][0..lanes].*;
            parts += row;
        }
        const wide: @Vector(lanes, u32) = parts;
        const lo: @Vector(lanes / 2, u32) = @intCast(std.simd.extract(wide, 0, lanes / 2));
        const hi: @Vector(lanes / 2, u32) = @intCast(std.simd.extract(wide, lanes / 2, lanes / 2));
        accum += lo + hi;
    }

    stop = x.len & ~@as(usize, lanes - 1);
    var tail: @Vector(lanes, u16) = @splat(0);
    while (i < stop) : (i += lanes) {
        const v: @Vector(lanes, u16) = x[i..][0..lanes].*;
        tail += v;
    }
    const wide: @Vector(lanes, u32) = tail;
    const lo: @Vector(lanes / 2, u32) = @intCast(std.simd.extract(wide, 0, lanes / 2));
    const hi: @Vector(lanes / 2, u32) = @intCast(std.simd.extract(wide, lanes / 2, lanes / 2));
    accum += lo + hi;

    const wide2: @Vector(lanes / 2, u64) = accum;
    const lo2: @Vector(lanes / 4, u64) = @intCast(std.simd.extract(wide2, 0, lanes / 4));
    const hi2: @Vector(lanes / 4, u64) = @intCast(std.simd.extract(wide2, lanes / 4, lanes / 4));
    const both2 = lo2 + hi2;
    var fin: u64 = @reduce(.Add, both2);
    while (i < x.len) : (i += 1) {
        fin += x[i];
    }
    return fin;
}
