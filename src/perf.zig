const std = @import("std");

const PERF = std.os.linux.PERF;
const perf_event_open = std.posix.perf_event_open;
const system = std.posix.system;
const perf_event_attr = system.perf_event_attr;

pub const max_events = 8;

const PERF_IOC_FLAG_GROUP: usize = 1;

pub const Event = struct {
    const HW = PERF.COUNT.HW;
    const CACHE = PERF.COUNT.HW.CACHE;

    typ: PERF.TYPE,
    config: u64,

    pub fn make_hw(s: HW) Event {
        return .{ .typ = .HARDWARE, .config = @intFromEnum(s) };
    }

    pub fn make_cache(lev: CACHE, op: CACHE.OP, res: CACHE.RESULT) Event {
        const config = @intFromEnum(lev) | (@intFromEnum(op) << 8) | (@intFromEnum(res) << 16);
        return .{ .typ = .HW_CACHE, .config = config };
    }

    pub const cpu_cycles = Event.make_hw(.CPU_CYCLES);
    pub const retired_instr = Event.make_hw(.INSTRUCTIONS);
    pub const branch_total = Event.make_hw(.BRANCH_INSTRUCTIONS);
    pub const branch_miss = Event.make_hw(.BRANCH_MISSES);
    pub const l1i_read_miss = Event.make_cache(.L1I, .READ, .MISS);

    pub const l1d_read = Event.make_cache(.L1D, .READ, .ACCESS);
    pub const l1d_read_miss = Event.make_cache(.L1D, .READ, .MISS);
    pub const l1d_write = Event.make_cache(.L1D, .WRITE, .ACCESS);

    pub const ll_read = Event.make_cache(.LL, .READ, .ACCESS);
    pub const ll_read_miss = Event.make_cache(.LL, .READ, .MISS);
    pub const ll_write = Event.make_cache(.LL, .WRITE, .ACCESS);
    pub const ll_write_miss = Event.make_cache(.LL, .WRITE, .MISS);
};

pub const Sample = extern struct {
    nr: u64 = 0,
    enabled: u64 = 0,
    running: u64 = 0,
    records: [max_events]u64 = @splat(0),

    pub fn buffer(this: *@This(), nevents: u64) []u8 {
        const ptr: [*]u8 = @ptrCast(this);
        return ptr[0 .. (nevents + 3) * @sizeOf(u64)];
    }

    pub fn events(this: *const @This()) []const u64 {
        return this.records[0..this.nr];
    }

    pub fn clear(this: *@This()) void {
        this.* = .{};
    }
};

pub const PerfEvent = struct {
    nevents: u64 = 0,
    fds: [max_events]system.fd_t = @splat(0),
    events: [max_events]Event = undefined,

    pub fn add_many(this: *@This(), events: []const Event) !void {
        for (events) |e| {
            try this.add(e);
        }
    }

    pub fn add(this: *@This(), evt: Event) !void {
        if (this.nevents == max_events) return error.TooManyEvents;
        this.events[this.nevents] = evt;
        this.nevents += 1;
    }

    pub fn install(this: *@This()) !void {
        std.debug.assert(this.fds[0] == 0);
        if (this.nevents == 0) return;

        errdefer this.uninstall();

        const format = PERF_FORMAT.GROUP |
            PERF_FORMAT.TOTAL_TIME_ENABLED |
            PERF_FORMAT.TOTAL_TIME_RUNNING;

        var leader: perf_event_attr = .{
            .type = this.events[0].typ,
            .config = this.events[0].config,
            .flags = .{
                .disabled = true,
                .pinned = true,
                .exclude_kernel = true,
                .exclude_hv = true,
                .use_clockid = true,
                .inherit = false,
            },
            .clockid = .MONOTONIC_RAW,
            .read_format = format,
        };
        this.fds[0] = try perf_event_open(&leader, 0, -1, -1, 0);

        for (1..this.nevents) |i| {
            var rest: perf_event_attr = .{
                .type = this.events[i].typ,
                .config = this.events[i].config,
                .flags = .{
                    .exclude_kernel = true,
                    .exclude_hv = true,
                    .use_clockid = true,
                    .inherit = false,
                },
                .clockid = .MONOTONIC_RAW,
            };
            this.fds[i] = try perf_event_open(&rest, 0, -1, this.fds[0], 0);
        }
        try this.reset();
    }

    pub fn uninstall(this: *@This()) void {
        this.disable() catch {};
        for (0..this.nevents) |i| {
            if (this.fds[i] != 0) {
                close(this.fds[i]) catch {};
                this.fds[i] = 0;
            }
        }
    }

    pub fn reinstall(this: *@This()) !void {
        this.uninstall();
        try this.install();
    }

    pub fn deinit(this: *@This()) void {
        this.uninstall();
    }

    pub fn enable(this: *const @This()) !void {
        if (this.fds[0] == 0) return;
        _ = try ioctl(this.fds[0], PERF.EVENT_IOC.ENABLE, PERF_IOC_FLAG_GROUP);
    }

    pub fn disable(this: *const @This()) !void {
        if (this.fds[0] == 0) return;
        _ = try ioctl(this.fds[0], PERF.EVENT_IOC.DISABLE, PERF_IOC_FLAG_GROUP);
    }

    pub fn reset(this: *const @This()) !void {
        if (this.fds[0] == 0) return;
        _ = try ioctl(this.fds[0], PERF.EVENT_IOC.RESET, PERF_IOC_FLAG_GROUP);
    }

    pub fn read(this: *const @This(), sample: *Sample) !void {
        const buf = sample.buffer(this.nevents);
        const r = try std.posix.read(this.fds[0], buf);
        std.debug.assert(r == buf.len);
    }
};

const PERF_FORMAT = struct {
    pub const TOTAL_TIME_ENABLED: u64 = 1 << 0;
    pub const TOTAL_TIME_RUNNING: u64 = 1 << 1;
    pub const ID: u64 = 1 << 2;
    pub const GROUP: u64 = 1 << 3;
    pub const LOST: u64 = 1 << 4;
};

fn ioctl(fd: system.fd_t, request: u32, args: usize) !usize {
    const rc = std.os.linux.ioctl(fd, request, args);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

fn close(fd: system.fd_t) !void {
    const rc = std.os.linux.close(fd);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

fn workload(reps: u64) void {
    const dno = std.mem.doNotOptimizeAway;
    for (0..reps) |a| {
        dno(&a);
        var ret = @sin(@sqrt(@as(f64, @floatFromInt(a))));
        dno(&ret);
    }
}

const tt = std.testing;
const now = @import("time.zig").now;

test {
    const events = [_]Event{ .retired_instr, .cpu_cycles, .branch_miss, .branch_total, .l1i_read_miss };
    var stats: PerfEvent = .{};
    try stats.add_many(&events);
    try stats.install();
    try stats.enable();
    workload(1_000_000);
    try stats.disable();

    {
        var samp: Sample = .{};
        try stats.read(&samp);
        const e = samp.events();
        std.debug.print("{any}\n{any}\n", .{ samp, e });
    }

    try stats.reset();
    {
        var samp: Sample = .{};
        try stats.read(&samp);
        const e = samp.events();
        std.debug.print("{any}\n{any}\n", .{ samp, e });
    }

    try stats.enable();
    workload(1_000_000);
    try stats.disable();

    {
        var samp: Sample = .{};
        try stats.read(&samp);
        const e = samp.events();
        std.debug.print("{any}\n{any}\n", .{ samp, e });
    }
}
