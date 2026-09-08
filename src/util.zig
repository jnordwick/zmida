const std = @import("std");
pub const dno = std.mem.doNotOptimizeAway;

pub inline fn ns_from_secs(x: f64) u64 {
    return @intFromFloat(1e9 * x);
}

pub inline fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    const ret = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    if (ret != 0) @panic("clock_gettime failed");
    return nanos_from_timespec(ts);
}

pub inline fn nanos_from_timespec(ts: std.os.linux.timespec) u64 {
    const nanos_per_second: u64 = 1000 * 1000 * 1000;
    return @as(u64, @bitCast(ts.sec)) * nanos_per_second + @as(u64, @bitCast(ts.nsec));
}

// TODO: add sleep if stop if far enough in future
pub fn pause_until(stop: u64) void {
    while (now() < stop) {
        std.atomic.spinLoopHint();
    }
}

pub fn set_bool(flag: *std.atomic.Value(bool), start: *std.atomic.Value(u64), nanos: u64) void {
    while (start.load(.acquire) == 0) {
        std.atomic.spinLoopHint();
    }
    const cend: u64 = start.load(.acquire) + nanos;
    pause_until(cend);
    flag.store(true, .release);
}

pub fn float_div(T: type, num: anytype, denom: anytype) T {
    return @as(T, @floatFromInt(num)) / @as(T, @floatFromInt(denom));
}

pub inline fn from_slice_like(Elem: type, x: anytype) []const Elem {
    const ti = @typeInfo(@TypeOf(x));
    switch (ti) {
        .array => |a| return x[0..a.len],
        .pointer => |p| {
            if (p.size == .slice) return x;
            if (p.size == .one) {
                switch (@typeInfo(p.child)) {
                    .array => |a| return x[0..a.len],
                    else => {},
                }
            }
        },
        else => {},
    }
    @compileError("expected slice-like type");
}

fn WhoAreYou(x: anytype) type {
    return struct {
        const t = x;
        pub const the = @typeName(@This());
        pub const who = the[0 .. the.len - 3][26..];
    };
}

const tt = std.testing;

pub fn get_fname(comptime func: anytype) []const u8 {
    return WhoAreYou(func).who;
}

test get_fname {
    try tt.expectEqualStrings("get_fname", get_fname(get_fname));
}
