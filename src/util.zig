const std = @import("std");
const tt = std.testing;
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const perf = @import("perf.zig");
const time = @import("time.zig");
const sys = @import("sys.zig");

const ArgsType = @import("trial.zig").ArgsType;

pub var have_set_gopts: bool = false;
pub var gopts = root.GlobalOpts{};

pub fn verbose(comptime lev: u32, comptime fmt: []const u8, p: anytype) void {
    if (lev <= gopts.verbose) {
        std.debug.print(fmt, if (is_tuple(@TypeOf(p))) p else .{p});
    }
}

pub inline fn debug_warn() void {
    if (@import("builtin").mode == .Debug and gopts.debug_warn) {
        std.debug.print("!!! WARNING !!! Compiled in debug mode.\n", .{});
        gopts.debug_warn = false;
    }
}

pub fn set_global_opts(opts: root.GlobalOpts) void {
    if (have_set_gopts) @panic("can only set global opts once");
    have_set_gopts = true;
    gopts = opts;
    time.Clock.setup(if (gopts.use_tsc) .tsc else .monotonic) catch {
        std.debug.print("!!! WARNING !!! No capable TSC. using monotonic.\n", .{});
    };
    if (gopts.pin_cpu) |cpu| {
        const cpu_set: sys.cpu_set = .init(cpu);
        sys.sched_setaffinity(0, &cpu_set) catch |e| {
            panic("could not set cpu affinity to {}: {}\n", .{ cpu, e });
        };
        verbose(1, "set cpu affinity to {}\n", .{cpu});
    }
    if (gopts.set_prio) |prio| {
        sys.setpriority(sys.PRIO.PROCESS, 0, prio) catch |e| {
            panic("could not set priority (must be root for < 0) to {}: {}", .{ prio, e });
        };
        verbose(1, "set priority to {}\n", .{prio});
    }
    if (root.GlobalOpts.call_mod != .auto) {
        verbose(1, "overriding @call modifier {}\n", .{root.GlobalOpts.call_mod});
    }
    debug_warn();
}

fn panic(comptime format: []const u8, args: anytype) noreturn {
    var buffer: [512]u8 = undefined;
    const str = std.fmt.bufPrint(&buffer, format, args) catch {
        @panic("Could not create panic message");
    };
    @panic(str);
}

pub fn iround(x: f64) i64 {
    return @intFromFloat(@round(x));
}

pub inline fn to_slice(T: type, S: type, x: *S) []T {
    const len = @sizeOf(S) / @sizeOf(T);
    return @as([*]T, @ptrCast(x))[0..len];
}

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
        .@"struct" => |s| {
            if (@hasDecl(x, "_zmida_generator_")) return .generator;
            if (s.is_tuple) return .single_tuple;
            @compileError("wrap single struct in a tuple, similar to @call");
        },
        .void => return .niladic,
        else => @compileError("wrap single aruments in a tuple, similar to @call"),
    }
}

pub inline fn argslen(x: anytype) usize {
    return switch (argstype_of(@TypeOf(x))) {
        .single_tuple, .niladic => 1,
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

pub fn get_file(env: root.Env, fname: ?[]const u8, suffix: []const u8) !std.Io.File {
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

pub fn make_cpu_panel(alloc: Allocator) !perf.PerfPanel {
    var panel: perf.PerfPanel = .init(alloc, true);
    try panel.add(&perf.CpuCounters.events);
    return panel;
}

pub fn make_mem_panel(alloc: Allocator) !perf.PerfPanel {
    var panel: perf.PerfPanel = .init(alloc, false);
    try panel.add(&perf.MemReadCounters.events);
    try panel.add(&perf.MemWriteCounters.events);
    return panel;
}

test "alrefs" {
    _ = std.testing.refAllDecls(@This());
}

test get_fname {
    try tt.expectEqualStrings("util.WhoAreYou((function 'get_fname'))", WhoAreYou(get_fname).the);
    try tt.expectEqualStrings("get_fname", get_fname(get_fname));
}
