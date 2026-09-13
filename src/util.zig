const std = @import("std");
const root = @import("root.zig");
pub const Env = root.Env;
pub const dno = std.mem.doNotOptimizeAway;

const clock_nanosleep = std.os.linux.clock_nanosleep;
const clock_gettime = std.os.linux.clock_gettime;
const timespec = std.os.linux.timespec;

pub inline fn is_tuple(T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

pub const ClockSource = enum { monotonic, tsc };

pub const Clock = struct {
    pub var clksrc: ClockSource = .monotonic;
    pub var hz: u64 = 1e9; // ticks per second
    pub var nspt: f64 = 1; // nanoseconds per tick

    pub fn setup(clock_source: ClockSource) void {
        clksrc = clock_source;
        if (clksrc == .monotonic) {
            hz = 1e9;
        } else {
            if (!invariant_tsc()) @panic("system does not have invariant tsc");
            const freq = get_tsc_freq();
            if (freq == null) @panic("system does not expose tsc frequency");
            hz = freq.?;
        }
        nspt = 1e9 / @as(f64, @floatFromInt(hz));
    }
};

pub const Timer = struct {
    start_ticks: u64,
    stop_ticks: u64,

    pub inline fn start(this: *@This()) void {
        this.start_ticks = if (Clock.clksrc == .monotonic) now() else tsc_start();
    }

    pub inline fn stop(this: *@This()) void {
        this.stop_ticks = if (Clock.clksrc == .monotonic) now() else tsc_stop();
    }

    pub fn ticks(this: *@This()) u64 {
        return this.stop_ticks - this.start_ticks;
    }

    pub fn nanos(this: *@This()) f64 {
        return @as(f64, @floatFromInt(this.ticks())) * Clock.nspt;
    }
};

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

pub fn pause_for(sleep_nanos: u64) void {
    var sleep_ts = timespec_from_nanos(sleep_nanos);
    while (clock_nanosleep(.MONOTONIC, .{ .ABSTIME = false }, &sleep_ts, &sleep_ts) != 0) {}
}

pub fn pause_until(stop_nanos: u64) void {
    var max_wakeup: usize = 10;
    const sleep_min = 5 * 1000 * 1000; // 1 millis
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

pub fn now() u64 {
    var ts: timespec = undefined;
    const ret = clock_gettime(.MONOTONIC, &ts);
    if (ret != 0) @panic("clock_gettime failed");
    return nanos_from_timespec(ts);
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

pub inline fn cpuid(leaf: u32, subleaf: u32) CpuidRegisters {
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

pub inline fn tsc_start() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;

    asm volatile (
        \\lfence
        \\rdtsc
        \\lfence
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );

    return (@as(u64, hi) << 32) | lo;
}
pub fn tsc_stop() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;

    asm volatile (
        \\rdtscp
        \\lfence
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .rcx = true });

    return (@as(u64, hi) << 32) | lo;
}

const tt = std.testing;

test "alrefs" {
    _ = std.testing.refAllDecls(@This());
}

test get_fname {
    try tt.expectEqualStrings("util.WhoAreYou((function 'get_fname'))", WhoAreYou(get_fname).the);
    try tt.expectEqualStrings("get_fname", get_fname(get_fname));
}

test pause_for {
    const sleep_time = 10 * 1000 * 1000;
    const start = now();
    pause_for(sleep_time);
    const stop = now();
    const paused = stop - start;
    const diff = @abs(@as(i64, @intCast(paused)) - @as(i64, @intCast(sleep_time)));
    std.debug.print("diff {}\n", .{diff});
    try tt.expect(diff < 1000 * 1000); // 1ms
    try tt.expect(paused >= sleep_time);
}

test pause_until {
    const sleep_time = 10 * 1000 * 1000;
    const start = now();
    pause_until(start + sleep_time);
    const stop = now();
    const diff = @abs(@as(i66, @intCast(stop - start)) - @as(i64, @intCast(sleep_time)));
    try tt.expect(diff < 1000 * 1000);
}

test "tsc check" {
    try tt.expect(invariant_tsc());
    try tt.expect(get_tsc_freq() != null);
}

test "tsc start/stop" {
    const start = tsc_start();
    const stop = tsc_stop();
    try tt.expect(start != 0);
    try tt.expect(stop != 0);
    try tt.expect(stop > start);
}
