const std = @import("std");
const root = @import("root.zig");
pub const Env = root.Env;
pub const dno = std.mem.doNotOptimizeAway;

const clock_nanosleep = std.os.linux.clock_nanosleep;
const clock_gettime = std.os.linux.clock_gettime;
const timespec = std.os.linux.timespec;

pub inline fn ns_from_secs(x: f64) u64 {
    return @intFromFloat(1e9 * x);
}

pub inline fn is_tuple(T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

pub inline fn now() u64 {
    var ts: timespec = undefined;
    const ret = clock_gettime(.MONOTONIC, &ts);
    if (ret != 0) @panic("clock_gettime failed");
    return nanos_from_timespec(ts);
}

pub inline fn nanos_from_timespec(ts: timespec) u64 {
    const nps = 1000 * 1000 * 1000;
    return @as(u64, @bitCast(ts.sec)) * nps + @as(u64, @bitCast(ts.nsec));
}

pub inline fn timespec_from_nanos(nanos: u64) timespec {
    const nps: comptime_int = 1e9;
    const sec = nanos / nps;
    const nsec = nanos % nps;
    return .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
}

pub fn pause_until(stop_nanos: u64) void {
    var max_wakeup: usize = 10;
    const sleep_min = 1 * 1000 * 1000; // 1 millis
    var sleep_ts = timespec_from_nanos(stop_nanos - sleep_min);
    while (clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &sleep_ts, &sleep_ts) != 0) {
        // when too many wakeups, fall down to polling behavior
        if (max_wakeup == 0) break;
        max_wakeup -= 1;
    }
    while (now() < stop_nanos) {
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

pub const CpuidRegisters = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

fn invariant_tsc() bool {
    const leaf = cpuid(0x80000000, 0);
    if (leaf.eax < 0x80000007) return false;
    return (cpuid(0x80000007, 0).edx & (1 << 8)) != 0;
}

pub fn get_tsc_freq() ?u64 {
    if (!invariant_tsc()) return null;

    const max_leaf = cpuid(0, 0).eax;
    if (max_leaf >= 0x15) {
        const leaf = cpuid(0x15, 0);
        if (leaf.eax != 0 and leaf.ecx != 0) {
            return (@as(u64, leaf.ecx) * leaf.ebx) / leaf.eax;
        }
    }
    if (max_leaf >= 0x16) {
        const leaf = cpuid(0x16, 0);
        const mhz = leaf.eax & 0xffff;
        if (mhz != 0) return @as(u64, mhz) * 1_000_000;
    }
    return null;
}

pub fn cpuid(leaf: u32, subleaf: u32) CpuidRegisters {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [eax_in] "{eax}" (leaf),
          [ecx_in] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

const tt = std.testing;

test get_fname {
    try tt.expectEqualStrings("util.WhoAreYou((function 'get_fname'))", WhoAreYou(get_fname).the);
    try tt.expectEqualStrings("get_fname", get_fname(get_fname));
}

test pause_until {
    const sleep_time = 10 * 1000 * 1000;
    const start = now();
    pause_until(start + sleep_time);
    const stop = now();
    const diff = @abs(@as(i66, @intCast(stop - start)) - @as(i64, @intCast(sleep_time)));
    try tt.expect(diff < 1000 * 1000);
}

test "tsc" {
    try tt.expect(invariant_tsc());
    try tt.expect(get_tsc_freq() != null);
}
