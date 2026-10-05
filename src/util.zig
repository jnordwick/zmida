const std = @import("std");
const tt = std.testing;
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const perf = @import("perf.zig");

const ArgsType = @import("trial.zig").ArgsType;
const Env = root.Env;

pub fn verbose(lev: i32, comptime fmt: []const u8, args: anytype) void {
    const of = if (lev < 0) std.Io.File.stdout() else std.Io.File.stderr();
    if (lev <= Env.verbose) {
        var buffer: [512]u8 = undefined;
        var writer = of.writer(Env.io, &buffer);
        writer.interface.print(fmt, if (is_tuple(@TypeOf(args))) args else .{args}) catch |e| {
            errexit("print failed: {}", e);
        };
        writer.interface.flush() catch |e| {
            errexit("flush failed: {}", e);
        };
    }
}

pub fn debug_warn() void {
    // Test the ORIGINAL io, not Env.io.
    if (@import("builtin").mode == .Debug and Env.debug_warn) {
        verbose(0, "--- warning --- Compiled in debug mode.\n", .{});
        Env.debug_warn = false;
    }
}

pub fn str_in(x: []const u8, pats: anytype) bool {
    inline for (pats) |p| {
        if (std.mem.eql(u8, x, p)) return true;
    }
    return false;
}

pub fn parse_bool(x: []const u8) bool {
    if (str_in(x, .{ "true", "on" })) {
        return true;
    } else if (str_in(x, .{ "false", "off" })) {
        return false;
    } else {
        errexit("unknown option value: {s}", x);
    }
}

pub fn split(str: [:0]const u8, sep: u8) struct { []const u8, []const u8 } {
    const slice = str[0..str.len];
    const pos = std.mem.indexOfScalar(u8, slice, sep) orelse
        return .{ slice, "" };
    return .{ slice[0..pos], slice[pos + 1 ..] };
}

fn print_usage(lev: i32) noreturn {
    const msg =
        \\ usage:
        \\   -c=<n> | --cpu=<n>     pin to cpu: any core number
        \\   -h     | --help        this message
        \\   -n=<n> | --nice=<n>    set process niceness: -20 to 19 (<0 requies root)
        \\   -p=<s> | --perf=<s>    perf_event counters: cpu (default), mem, both
        \\   -t[=b] | --tsc[=b]     attempt RDTSC timer: yes/true (default), no/false
        \\   -v[=n] | --verbose[=n] verbose level: 0 (silent) to 2 (default)
        \\
    ;
    verbose(lev, msg, .{});
    std.process.exit(if (lev < 0) 0 else 1);
}

pub fn parse_opts(pinit: *const std.process.Init, env_opts: root.EnvOpts) root.EnvOpts {
    var opts = env_opts;
    var iter = pinit.minimal.args.iterate();
    _ = iter.skip();

    while (iter.next()) |str| {
        if (str[0] != '-') continue;
        const name, const val = split(str, '=');
        if (str_in(name, .{ "-v", "--verbose" })) {
            var v: i32 = 0;
            if (val.len > 0) {
                v = std.fmt.parseInt(i32, val, 10) catch
                    errexit("verbose level 0-2: {s}", val);
            } else {
                v = 2;
            }
            verbose(2, "found verbose option {}\n", v);
            opts.verbose = v;
            // directly set for verbose to get trace output from option parsing
            Env.verbose = v;
        } else if (str_in(name, .{ "-t", "--tsc" })) {
            opts.use_tsc = val.len == 0 or parse_bool(val);
        } else if (str_in(name, .{ "-c", "--cpu" })) {
            const v = std.fmt.parseInt(u32, val, 10) catch
                errexit("pin cpu wants cpu number: {s}", val);
            opts.pin_cpu = v;
        } else if (str_in(name, .{ "-n", "--nice" })) {
            const v: i32 = std.fmt.parseInt(i32, val, 10) catch
                errexit("nice value -20 to 19: {s}", val);
            opts.set_prio = v;
        } else if (str_in(name, .{ "-p", "--perf" })) {
            if (std.mem.eql(u8, val, "cpu")) {
                opts.perf_cpu = true;
                opts.perf_mem = false;
            } else if (std.mem.eql(u8, val, "mem")) {
                opts.perf_cpu = false;
                opts.perf_mem = true;
            } else if (std.mem.eql(u8, val, "both")) {
                opts.perf_cpu = true;
                opts.perf_mem = true;
            } else {
                errexit("unknown perf arguent (cpu, mem, both): {s}", val);
            }
        } else if (str_in(name, .{ "-h", "--help" })) {
            print_usage(-1);
        } else {
            verbose(0, "unknown option name: {s}", name);
            print_usage(0);
        }
    }
    return opts;
}

pub fn errexit(comptime format: []const u8, args: anytype) noreturn {
    verbose(0, "!!! ERROR !!! " ++ format ++ "\n", args);
    std.process.exit(1);
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

pub fn abs_diff(T: type, x: T, y: T) T {
    return if (x > y) x - y else y - x;
}

pub fn rel_diff(actual: anytype, expected: anytype) f64 {
    const a = to_float(f64, actual);
    const e = to_float(f64, expected);
    return (a - e) / e;
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
            if (@hasDecl(x, "__zm__generator__")) return .generator;
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

pub fn get_file(fname: ?[]const u8, suffix: []const u8) !std.Io.File {
    if (fname == null) {
        return std.Io.File.stdout();
    }
    const len = fname.?.len + suffix.len;
    if (len >= 1024) errexit("filename to long, max 1024 was {}", len);
    var name: [1024]u8 = undefined;
    std.mem.copyForwards(u8, name[0..], fname.?);
    std.mem.copyForwards(u8, name[fname.?.len..], suffix);
    return std.Io.Dir.cwd().createFile(Env.io, name[0..len], .{});
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

fn read_cpu_file(x: u32, name: []const u8, dest: []u8) ?[]const u8 {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "/sys/devices/system/cpu/cpu{d}/cpufreq/{s}",
        .{ x, name },
    ) catch return null;
    const file = std.Io.Dir.openFileAbsolute(Env.io, path, .{}) catch return null;
    defer file.close(Env.io);
    const n = file.readPositionalAll(Env.io, dest, 0) catch return null;
    return std.mem.trim(u8, dest[0..n], " \t\r\n");
}

pub fn check_cpu_files(x: u32) void {
    var drv_buf: [32]u8 = undefined;
    var gov_buf: [32]u8 = undefined;
    var epp_buf: [32]u8 = undefined;
    const driver = read_cpu_file(x, "scaling_driver", &drv_buf);
    const gov = read_cpu_file(x, "scaling_governor", &gov_buf);
    const epp = read_cpu_file(x, "energy_performance_preference", &epp_buf);

    const cannot_read = "<cannot read>";
    verbose(2, "scaling_driver: {s}\n", driver orelse cannot_read);
    verbose(2, "scaling_governor: {s}\n", gov orelse cannot_read);
    verbose(2, "energy_performance_preference: {s}\n", epp orelse cannot_read);

    // with these drivers the EPP hint decides frequency; the governor name is misleading
    const epp_driven = if (driver) |d|
        std.mem.eql(u8, d, "intel_pstate") or std.mem.eql(u8, d, "amd-pstate-epp")
    else
        false;

    if (gov) |g| {
        if (!epp_driven and !std.mem.eql(u8, g, "performance")) {
            verbose(0, "--- warning --- cpu {d}: scaling governor is {s}, results might be affected\n", .{ x, g });
        }
    }
    if (epp) |e| {
        // power / balance_power are bad; balance_performance and default are fine
        if (std.mem.indexOf(u8, e, "power") != null) {
            verbose(0, "--- warning --- cpu {d}: energy performance pref is {s}, results might be affected\n", .{ x, e });
        }
    }
}

test "alrefs" {
    _ = std.testing.refAllDecls(@This());
}

test get_fname {
    try tt.expectEqualStrings("util.WhoAreYou((function 'get_fname'))", WhoAreYou(get_fname).the);
    try tt.expectEqualStrings("get_fname", get_fname(get_fname));
}

test split {
    const testing = std.testing;

    var r = split("foo=bar", '=');
    try testing.expectEqualStrings("foo", r[0]);
    try testing.expectEqualStrings("bar", r[1]);

    r = split("foo", '=');
    try testing.expectEqualStrings("foo", r[0]);
    try testing.expectEqualStrings("", r[1]);

    r = split("=bar", '=');
    try testing.expectEqualStrings("", r[0]);
    try testing.expectEqualStrings("bar", r[1]);

    r = split("foo=", '=');
    try testing.expectEqualStrings("foo", r[0]);
    try testing.expectEqualStrings("", r[1]);

    r = split("foo=bar=baz", '=');
    try testing.expectEqualStrings("foo", r[0]);
    try testing.expectEqualStrings("bar=baz", r[1]);

    r = split("", '=');
    try testing.expectEqualStrings("", r[0]);
    try testing.expectEqualStrings("", r[1]);
}

test check_cpu_files {
    if (true) return error.SkipZigTest;
    Env.io = std.testing.io;
    check_cpu_files(0);
}
