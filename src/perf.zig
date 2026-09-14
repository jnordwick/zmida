const std = @import("std");

const PERF = std.os.linux.PERF;
const perf_event_open = std.posix.perf_event_open;
const system = std.posix.system;
const perf_event_attr = system.perf_event_attr;
const dno = std.mem.doNotOptimizeAway;

pub const max_events = 16;

const PerfEvent = struct {
    typ: PERF.TYPE,
    config: u64,

    pub fn make(t: PERF.TYPE, s: anytype) PerfEvent {
        return .{ .typ = t, .config = @intFromEnum(s) };
    }

    const cpu_cycles = PerfEvent.make(.HARDWARE, PERF.COUNT.HW.CPU_CYCLES);
    const retired_instr = PerfEvent.make(.HARDWARE, PERF.COUNT.HW.INSTRUCTIONS);
    const branch_total = PerfEvent.make(.HARDWARE, PERF.COUNT.HW.BRANCH_INSTRUCTIONS);
    const branch_miss = PerfEvent.make(.HARDWARE, PERF.COUNT.HW.BRANCH_MISSES);
};

const PerfSample = extern struct {
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

const PerfStats = struct {
    nevents: u64 = 0,
    fds: [max_events]system.fd_t = @splat(0),
    events: [max_events]PerfEvent = undefined,

    pub fn default() PerfStats {
        var this: PerfStats = .{};
        this.add(.retired_instr) catch {};
        this.add(.cpu_cycles) catch {};
        this.add(.branch_miss) catch {};
        this.add(.branch_total) catch {};
        return this;
    }

    pub fn add(this: *@This(), evt: PerfEvent) !void {
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
                },
                .clockid = .MONOTONIC_RAW,
            };
            this.fds[i] = try perf_event_open(&rest, 0, -1, this.fds[0], 0);
        }
        try this.reset();
    }

    pub fn uninstall(this: *@This()) void {
        for (0..this.nevents) |i| {
            if (this.fds[i] != 0) {
                close(this.fds[i]) catch {};
                this.fds[0] = 0;
            }
        }
    }

    pub fn deinit(this: *@This()) void {
        this.uninstall();
    }

    pub fn enable(this: *const @This()) !void {
        if (this.fds[0] == 0) return;
        _ = try ioctl(this.fds[0], PERF.EVENT_IOC.ENABLE, 0);
    }

    pub fn disable(this: *const @This()) !void {
        if (this.fds[0] == 0) return;
        _ = try ioctl(this.fds[0], PERF.EVENT_IOC.DISABLE, 0);
    }

    pub fn reset(this: *const @This()) !void {
        if (this.fds[0] == 0) return;
        _ = try ioctl(this.fds[0], PERF.EVENT_IOC.RESET, 0);
    }

    pub fn read(this: *const @This(), sample: *PerfSample) !void {
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
    for (0..reps) |a| {
        dno(&a);
        var ret = @sin(@sqrt(@as(f64, @floatFromInt(a))));
        dno(&ret);
    }
}

test {
    const names = [_][]const u8{ "retired", "cycles", "branch miss", "branch total" };
    var stats: PerfStats = .default();
    try stats.install();
    try stats.enable();
    workload(100_000_000);
    try stats.disable();
    var samp: PerfSample = .{};
    try stats.read(&samp);
    const e = samp.events();
    std.debug.print("nr {}\ntime {} / {}\n", .{ e.len, samp.running, samp.enabled });
    for (e, 0..) |s, i| {
        std.debug.print("{s} {}\n", .{ names[i], s });
    }
}
