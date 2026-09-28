const std = @import("std");

const linux = std.os.linux;
pub const fd_t = linux.fd_t;
pub const pid_t = linux.pid_t;
pub const PERF = linux.PERF;
pub const perf_event_attr = linux.perf_event_attr;
pub const cpu_set_t = linux.cpu_set_t;
pub const id_t = i32;

const errno = @import("errno.zig");

pub const PERF_IOC_FLAG_GROUP: usize = 1;

pub const PERF_FORMAT = struct {
    pub const TOTAL_TIME_ENABLED: u64 = 1 << 0;
    pub const TOTAL_TIME_RUNNING: u64 = 1 << 1;
    pub const ID: u64 = 1 << 2;
    pub const GROUP: u64 = 1 << 3;
    pub const LOST: u64 = 1 << 4;
};

pub fn close(fd: fd_t) errno.errno!void {
    const rc = std.os.linux.close(fd);
    _ = try errno.chkerr(rc);
}

pub fn ioctl(fd: fd_t, request: u32, args: usize) errno.errno!usize {
    const rc = std.os.linux.ioctl(fd, request, args);
    return @intCast(try errno.chkerr(rc));
}

pub fn perf_event_open(
    attr: *perf_event_attr,
    pid: pid_t,
    cpu: i32,
    group: fd_t,
    flags: usize,
) errno.errno!fd_t {
    const rc = std.os.linux.perf_event_open(attr, pid, cpu, group, flags);
    return @intCast(try errno.chkerr(rc));
}

pub const PRIO = enum(i32) {
    PROCESS = 0,
    PGRP = 1,
    USER = 2,
    DARWIN_THREAD = 3,
};

pub fn getpriority(which: PRIO, who: id_t) !i32 {
    const rc = std.os.linux.syscall2(
        .getpriority,
        @bitCast(@as(isize, @intCast(@intFromEnum(which)))),
        @bitCast(@as(isize, @intCast(who))),
    );
    const prio = try errno.chkerr(rc);
    return 20 - @as(i32, @intCast(@as(u32, @truncate(prio))));
}

pub fn setpriority(which: PRIO, who: id_t, prio: i32) !void {
    const rc = std.os.linux.syscall3(
        .setpriority,
        @bitCast(@as(isize, @intCast(@intFromEnum(which)))),
        @bitCast(@as(isize, @intCast(who))),
        @bitCast(@as(isize, prio)),
    );
    _ = try errno.chkerr(rc);
}

pub const cpu_set = struct {
    mask: cpu_set_t = @splat(0),

    pub fn zero(this: *@This()) void {
        this.mask = @splat(0);
    }

    pub fn init(x: u32) @This() {
        var this: @This() = .{};
        this.set(x);
        return this;
    }

    pub fn is_set(this: *const @This(), cpu: u32) bool {
        const word_idx = cpu / 64;
        const bit_idx = @as(u6, @intCast(cpu % 64));
        return (this.mask[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }

    pub fn set(this: *@This(), cpu: u32) void {
        const word_idx = cpu / 64;
        const bit_idx = @as(u6, @intCast(cpu % 64));
        this.mask[word_idx] |= (@as(u64, 1) << bit_idx);
    }

    pub fn clear(this: *@This(), cpu: u32) void {
        const word_idx = cpu / 64;
        const bit_idx = @as(u6, @intCast(cpu % 64));
        this.mask[word_idx] &= ~(@as(u64, 1) << bit_idx);
    }

    pub fn set_all(this: *@This()) void {
        this.mask = @splat(@as(u64, @bitCast(@as(i64, -1))));
    }
};

pub fn sched_setaffinity(pid: pid_t, set: *const cpu_set) !void {
    const size = @sizeOf(@TypeOf(set.mask));
    const rc = std.os.linux.syscall3(
        .sched_setaffinity,
        @as(u32, @bitCast(pid)),
        size,
        @intFromPtr(&set.mask),
    );
    _ = try errno.chkerr(rc);
}

pub fn sched_getaffinity(pid: i32, mask: *cpu_set) !void {
    const rc = std.os.linux.syscall3(
        .sched_getaffinity,
        @bitCast(@as(isize, pid)),
        @sizeOf(cpu_set_t),
        @intFromPtr(&mask.mask),
    );

    // Decodes using your fast custom error-handling layer
    _ = try errno.chkerr(rc);
}

// -----------
// | Testing |
// -----------

test "get/set-priority" {
    const V: i32 = 15;
    try setpriority(PRIO.PROCESS, 0, V);
    const r = try getpriority(PRIO.PROCESS, 0);
    try std.testing.expectEqual(V, r);
}

test "get/set-affinity" {
    var curmask: cpu_set = .{};
    try sched_getaffinity(0, &curmask);
    const counts1 = @popCount(curmask.mask[0]) + @popCount(curmask.mask[1]);

    var mask: cpu_set = .{};
    mask.set(0);
    try sched_setaffinity(0, &mask);

    try sched_getaffinity(0, &curmask);
    const counts2 = @popCount(curmask.mask[0]) + @popCount(curmask.mask[1]);
    try std.testing.expectEqual(@as(usize, 1), counts2);

    mask.set_all();
    try sched_setaffinity(0, &mask);
    try sched_getaffinity(0, &curmask);
    const counts3 = @popCount(curmask.mask[0]) + @popCount(curmask.mask[1]);
    try std.testing.expectEqual(@as(usize, counts1), counts3);
}
