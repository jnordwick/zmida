const std = @import("std");

pub fn uniform(comptime T: type, comptime n: u64, from: T, to: T, seed: u64) [n]T {
    var arr: [n]T = undefined;
    var rand: std.Random.Xoshiro256 = .init(seed);
    var rr = rand.random();
    for (&arr) |*a| {
        a.* = switch (@typeInfo(T)) {
            .float => from + (to - from) * rr.float(T),
            .int => rr.intRangeAtMost(T, from, to),
            else => @compileError("make_array: unsupported type " ++ @typeName(T)),
        };
    }
    return arr;
}

pub fn tie2(comptime T: type, comptime n: u64, x: [n]T, y: [n]T) [n]struct { T, T } {
    const arr_t = struct { T, T };
    var arr: [n]arr_t = undefined;
    for (0..n) |i| {
        arr[i] = .{ x[i], y[i] };
    }
    return arr;
}

pub fn tie2t(comptime T: type, comptime n: u64, x: [n]T, y: [n]T) [n]struct { comptime type = T, T, T } {
    const arr_t = struct { comptime type = T, T, T };
    var arr: [n]arr_t = undefined;
    for (0..n) |i| {
        arr[i] = .{ T, x[i], y[i] };
    }
    return arr;
}

pub fn Range(T: type) type {
    return struct {
        pub const _zmida_generator_ = true;
        len: u64,
        cur: T,
        begin: T,
        end: T,
        step: T,

        pub fn init(begin: T, end: T, step: T) @This() {
            const len = (end - begin) / step + 1;
            return .{
                .cur = begin,
                .begin = begin,
                .end = end,
                .step = step,
                .len = len,
            };
        }

        pub fn next(this: *@This()) ?struct { T } {
            if (this.cur > this.end) return null;
            const tmp = this.cur;
            this.cur += this.step;
            return .{tmp};
        }
    };
}

pub fn LinSpace(T: type) type {
    return struct {
        pub const _zmida_generator_ = true;
        len: u64,
        cur: T,
        begin: T,
        end: T,
        step: T,

        pub fn init(begin: T, end: T, npoints: u64) @This() {
            const step = (end - begin) / @as(T, @floatFromInt(npoints - 1));

            return .{
                .len = npoints,
                .cur = begin,
                .begin = begin,
                .end = end + step * 0.5,
                .step = step,
            };
        }

        pub fn next(this: *@This()) ?struct { T } {
            if (this.cur > this.end) return null;
            const tmp = this.cur;
            this.cur += this.step;
            return .{tmp};
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "Range: divisible" {
    var r = Range(u64).init(0, 10, 2);
    const expected = [_]u64{ 0, 2, 4, 6, 8, 10 };

    try std.testing.expectEqual(@as(u64, 6), r.len);
    for (expected) |x| {
        const v = r.next();
        try std.testing.expect(v != null);
        try std.testing.expectEqual(x, v.?[0]);
    }
    try std.testing.expect(r.next() == null);
}

test "Range: not divisible" {
    var r = Range(u64).init(0, 10, 3);
    const expected = [_]u64{ 0, 3, 6, 9 };

    try std.testing.expectEqual(@as(u64, 4), r.len);
    for (expected) |x| {
        const v = r.next();
        try std.testing.expect(v != null);
        try std.testing.expectEqual(x, v.?[0]);
    }
    try std.testing.expect(r.next() == null);
}

test "LinSpace" {
    var r = LinSpace(f64).init(0.0, 10.0, 6);
    const expected = [_]f64{ 0.0, 2.0, 4.0, 6.0, 8.0, 10.0 };

    try std.testing.expectEqual(@as(u64, 6), r.len);
    for (expected) |x| {
        const v = r.next();
        try std.testing.expect(v != null);
        try std.testing.expectApproxEqAbs(x, v.?[0], 1e-12);
    }
    try std.testing.expect(r.next() == null);
}

test "uniform" {
    const xs = uniform(u64, 1000, 10, 20, 12345);

    try std.testing.expectEqual(@as(usize, 1000), xs.len);
    for (xs) |x| {
        try std.testing.expect(x >= 10);
        try std.testing.expect(x <= 20);
    }
}

test "tie2" {
    const x = [_]u64{ 1, 2, 3, 4 };
    const y = [_]u64{ 10, 20, 30, 40 };
    const result = tie2(u64, 4, x, y);

    try std.testing.expectEqual(@as(u64, 1), result[0][0]);
    try std.testing.expectEqual(@as(u64, 10), result[0][1]);
    try std.testing.expectEqual(@as(u64, 4), result[3][0]);
    try std.testing.expectEqual(@as(u64, 40), result[3][1]);
}

test "tie2t" {
    const x = [_]u64{ 1, 2, 3, 4 };
    const y = [_]u64{ 10, 20, 30, 40 };
    const result = tie2t(u64, 4, x, y);

    try std.testing.expectEqual(u64, result[0][0]);
    try std.testing.expectEqual(@as(u64, 1), result[0][1]);
    try std.testing.expectEqual(@as(u64, 10), result[0][2]);
}
