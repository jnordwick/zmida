const std = @import("std");

/// generate n random numbers in interval [from, to], using supplied random seed.
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

/// join two arrays into array of 2-tuples. Useful for functions that take two arguments.
pub fn tie2(comptime T: type, comptime n: u64, x: [n]T, y: [n]T) [n]struct { T, T } {
    const arr_t = struct { T, T };
    var arr: [n]arr_t = undefined;
    for (0..n) |i| {
        arr[i] = .{ x[i], y[i] };
    }
    return arr;
}

/// like tie2, but prepends each tuple with type, like .{u32, 1, 2}
pub fn tie2t(comptime T: type, comptime n: u64, x: [n]T, y: [n]T) [n]struct { comptime type = T, T, T } {
    const arr_t = struct { comptime type = T, T, T };
    var arr: [n]arr_t = undefined;
    for (0..n) |i| {
        arr[i] = .{ T, x[i], y[i] };
    }
    return arr;
}

/// integer inclusive range generator in [begin, end] by step
pub fn Range(T: type) type {
    return struct {
        /// so the runner knows the this is a generator and not an argument.
        pub const __zm__generator__ = true;
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

/// floating point linear space generator.
/// generates n points in [begin, end]
pub fn LinSpace(T: type) type {
    return struct {
        pub const __zm__generator__ = true;
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

fn TieType(comptime tuple: type) type {
    const si = @typeInfo(tuple).@"struct";
    const N = si.fields.len;
    var ftypes: [N]type = undefined;

    var arr_len = 0;
    inline for (0..N) |i| {
        switch (@typeInfo(si.fields[i].type)) {
            .array => |t| {
                if (arr_len != 0 and arr_len != t.len)
                    @compileError("Array lengths must match");
                arr_len = t.len;
            },
            else => {},
        }
    }

    inline for (0..N) |i| {
        ftypes[i] = switch (@typeInfo(si.fields[i].type)) {
            .array => |t| t.child,
            else => si.fields[i].type,
        };
    }
    const TupType = @Tuple(&ftypes);
    return [arr_len]TupType;
}

/// ties arrays and auto-broadcasts any scalars
/// x: a tuple of arrays and anything else is considered a scalar. all array must be same length.
pub fn tie(x: anytype) TieType(@TypeOf(x)) {
    const RetType = TieType(@TypeOf(x));
    const fields = @typeInfo(@TypeOf(x)).@"struct".fields;

    var ret: RetType = undefined;
    inline for (0..ret.len) |i| {
        inline for (0..fields.len) |f| {
            ret[i][f] = switch (@typeInfo(fields[f].type)) {
                .array => x[f][i],
                else => x[f],
            };
        }
    }
    return ret;
}

test tie {
    const p1 = [_]f32{ 2.718, 7.389, 20.055 };
    const tuple = .{ @as(f32, 2.718), p1 };
    const t = tie(tuple);

    for (0..p1.len) |i| {
        const r = @call(.auto, log, t[i]);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(i + 1)), r, 0.1);
    }
}

fn log(b: f32, x: f32) f32 {
    return std.math.log(f32, b, x);
}
