const std = @import("std");
const zm = @import("zmida");
const dno = std.mem.doNotOptimizeAway;

pub const __zm__callmod__ = std.builtin.CallModifier.always_inline;

pub fn main(init: std.process.Init) !void {
    const funcs =
        .{ ccall, vcall, vcall_dno, dcall, dcall_dno, mcall };

    zm.init(&init, .{ .pin_cpu = 1, .perf_cpu = true });
    const config: zm.Config = .byadapt(.{});

    var vt = vtable{ .vfunc = nothing };
    var study = try zm.Study.run("virtual calls", config, funcs, .{ &vt, 0 });
    defer study.deinit();

    try study.write_text(null, .{ .mode = .lat });
    try study.write_gnuplot("vcalls", .{});
    try study.write_gnuplot_perf("vcalls", .{});
}

const vtable = struct {
    vfunc: *const fn (u64) u64,
    data: u64 = undefined,

    const cfunc = nothing;
    fn mfunc(_: *const @This(), x: u64) u64 {
        dno(&x);
        return x;
    }

    fn dfunc(this: *const @This()) u64 {
        return this.data;
    }
};

fn nothing(x: u64) u64 {
    dno(&x);
    return x;
}

fn vcall_dno(v: *const vtable, x: u64) u64 {
    dno(&v.vfunc);
    return v.vfunc(x);
}

fn vcall(v: *const vtable, x: u64) u64 {
    return v.vfunc(x);
}

fn ccall(_: *const vtable, x: u64) u64 {
    return vtable.cfunc(x);
}

fn mcall(v: *const vtable, x: u64) u64 {
    return v.mfunc(x);
}

fn dcall(v: *vtable, x: u64) u64 {
    v.data = x;
    return v.dfunc();
}

fn dcall_dno(v: *vtable, x: u64) u64 {
    dno(vtable);
    v.data = x;
    return v.dfunc();
}
