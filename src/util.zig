const std = @import("std");
const tt = std.testing;

const root = @import("root.zig");
const ArgsType = @import("trial.zig").ArgsType;
pub const Env = root.Env;

pub inline fn is_tuple(T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

pub fn to_float(T: type, x: anytype) T {
    const ti = @typeInfo(@TypeOf(x));
    return switch (ti) {
        .float, .comptime_float => x,
        .int, .comptime_int => @floatFromInt(x),
        else => @compileError("not a number"),
    };
}

pub fn float_div(T: type, num: anytype, denom: anytype) T {
    return to_float(T, num) / to_float(T, denom);
}

pub fn idiv_up(T: type, n: anytype, d: anytype) T {
    return (@as(T, @intCast(d)) - 1 + @as(T, @intCast(n))) / @as(T, @intCast(d));
}

pub inline fn argstype_of(x: type) ArgsType {
    switch (@typeInfo(x)) {
        .array => @compileError("bad argstype: use ptr to array instead"),
        .pointer => |p| {
            switch (p.size) {
                .slice => return if (is_tuple(p.child)) .slice_tuple else .slice_naked,
                .one => {
                    switch (@typeInfo(p.child)) {
                        .array => |pa| return if (is_tuple(pa.child)) .ptrarray_tuple else .ptrarray_naked,
                        else => @compileError("bad argstype: ptr to bad type"),
                    }
                },
                else => @compileError("multi element and c pointers cannot be argstype"),
            }
        },
        .@"struct" => @compileError("nyi tuple/generator argstype"),
        .void => return .niladic,
        else => @compileError("nyi single argstype"),
    }
}

pub inline fn argslen(x: anytype) usize {
    return switch (argstype_of(@TypeOf(x))) {
        .single_naked, .single_tuple, .niladic => 1,
        else => x.len,
    };
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
        // ths format of the string "util.WhoAreYou((function 'get_fname'))"
        pub const the = @typeName(@This());
        pub const who = blk: {
            const start = std.mem.indexOfScalar(u8, the, '\'') orelse @compileError("unexpected @typeName format");
            const end = std.mem.lastIndexOfScalar(u8, the, '\'') orelse @compileError("unexpected @typeName format");
            break :blk the[start + 1 .. end];
        };
    };
}

pub fn get_fname(comptime func: anytype) []const u8 {
    return WhoAreYou(func).who;
}

pub fn get_file(env: Env, fname: ?[]const u8, suffix: []const u8) !std.Io.File {
    if (fname == null) {
        return std.Io.File.stdout();
    }
    const len = fname.?.len + suffix.len;
    if (len >= 1024) @panic("filename to long");
    var name: [1024]u8 = undefined;
    std.mem.copyForwards(u8, name[0..], fname.?);
    std.mem.copyForwards(u8, name[fname.?.len..], suffix);
    return std.Io.Dir.cwd().createFile(env.io, name[0..len], .{});
}

test "alrefs" {
    _ = std.testing.refAllDecls(@This());
}

test get_fname {
    try tt.expectEqualStrings("util.WhoAreYou((function 'get_fname'))", WhoAreYou(get_fname).the);
    try tt.expectEqualStrings("get_fname", get_fname(get_fname));
}
