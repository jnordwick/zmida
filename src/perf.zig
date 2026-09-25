const std = @import("std");
const errno = @import("errno.zig");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;

const sys = std.os.linux;
const fd_t = sys.fd_t;
const pid_t = sys.pid_t;
const PERF = sys.PERF;
const perf_event_attr = sys.perf_event_attr;

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
    data: [max_events]u64 = @splat(0),

    pub fn buffer(this: *@This(), nevents: u64) []u8 {
        const ptr: [*]u8 = @ptrCast(this);
        return ptr[0 .. (nevents + 3) * @sizeOf(u64)];
    }

    pub fn events(this: *const @This()) []const u64 {
        return this.data[0..this.nr];
    }

    pub fn adj(T: type, this: *const @This(), i: usize) T {
        const en: f64 = @floatFromInt(this.enabled);
        const ru: f64 = @floatFromInt(this.running);
        const d: f64 = @floatFromInt(this.data[i]);
        return switch (@typeInfo(T)) {
            .float => d,
            .int => @intFromFloat(@round((en / ru) * d)),
            else => @compileError("bad type"),
        };
    }

    pub fn clear(this: *@This()) void {
        this.* = .{};
    }
};

pub const PerfProbe = struct {
    nevents: u64 = 0,
    fds: [max_events]fd_t = @splat(0),
    events: [max_events]Event = undefined,
    pinned: bool = false,

    pub fn init(pinned: bool, events: []const Event) @This() {
        var this: @This() = .{ .nevents = events.len, .pinned = pinned };
        std.mem.copyForwards(Event, &this.events, events);
        return this;
    }

    pub fn open(this: *@This()) !void {
        std.debug.assert(this.fds[0] == 0);
        if (this.nevents == 0) return;
        errdefer this.close();

        const format = PERF_FORMAT.GROUP |
            PERF_FORMAT.TOTAL_TIME_ENABLED |
            PERF_FORMAT.TOTAL_TIME_RUNNING;

        var leader: perf_event_attr = .{
            .type = this.events[0].typ,
            .config = this.events[0].config,
            .flags = .{
                .disabled = true,
                .exclude_kernel = true,
                .exclude_hv = true,
                .use_clockid = true,
                .inherit = false,
                .pinned = this.pinned,
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

    pub fn close(this: *@This()) void {
        this.disable() catch {};
        for (0..this.nevents) |i| {
            if (this.fds[i] != 0) {
                close_os(this.fds[i]) catch {};
                this.fds[i] = 0;
            }
        }
    }

    pub fn deinit(this: *@This()) void {
        this.close();
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

    pub fn read(this: *const @This(), buf: []u8) !void {
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

fn ioctl(fd: fd_t, request: u32, args: usize) errno.errno!usize {
    const rc = std.os.linux.ioctl(fd, request, args);
    return @intCast(try errno.chkerr(rc));
}

fn perf_event_open(
    attr: *sys.perf_event_attr,
    pid: pid_t,
    cpu: i32,
    group: fd_t,
    flags: usize,
) errno.errno!fd_t {
    const rc = sys.perf_event_open(attr, pid, cpu, group, flags);
    return @intCast(try errno.chkerr(rc));
}

fn close_os(fd: fd_t) errno.errno!void {
    const rc = std.os.linux.close(fd);
    _ = try errno.chkerr(rc);
}

pub const PerfPanel = struct {
    const This = @This();

    pinned: bool,
    probes: ArrayList(PerfProbe),

    pub fn init(alloc: Allocator, pinned: bool) @This() {
        return .{ .pinned = pinned, .probes = .init(alloc) };
    }

    pub fn deinit(this: *@This()) void {
        this.probes.deinit();
    }

    pub fn add(this: *@This(), events: []const Event) !void {
        try this.probes.append(.init(this.pinned, events));
    }

    pub fn open(this: *@This()) !void {
        for (this.probes.items) |*p| try p.open();
    }

    pub fn close(this: *@This()) !void {
        for (this.probes.items) |*p| p.close();
    }

    pub fn enable(this: *@This()) !void {
        for (this.probes.items) |*p| try p.enable();
    }

    pub fn disable(this: *@This()) !void {
        for (this.probes.items) |*p| try p.disable();
    }

    pub fn reset(this: *@This()) !void {
        for (this.probes.items) |*p| try p.reset();
    }

    pub fn nevents(this: *const @This(), i: usize) usize {
        return this.probes.items[i].nevents;
    }

    pub fn read(this: *const @This(), i: usize, buf: []u8) !void {
        try this.probes.items[i].read(buf);
    }
};

// -----------
// TEST
// -----------

const tt = std.testing;
const now = @import("time.zig").now;

fn workload(reps: u64) void {
    const dno = std.mem.doNotOptimizeAway;
    for (0..reps) |a| {
        dno(&a);
        var ret = @sin(@sqrt(@as(f64, @floatFromInt(a))));
        dno(&ret);
    }
}

test {
    const events0 = [_]Event{ .retired_instr, .cpu_cycles, .branch_miss, .branch_total, .l1i_read_miss };
    const events1 = [_]Event{ .l1d_read, .l1d_read_miss, .ll_read, .ll_read_miss };
    const events2 = [_]Event{ .l1d_write, .ll_write, .ll_write_miss };

    var ps: PerfPanel = .init(tt.allocator, false);
    try ps.add(&events0);
    try ps.add(&events1);
    try ps.add(&events2);

    try ps.open();
    try ps.enable();
    workload(1_000_000);
    try ps.disable();

    var samp: Sample = .{};
    try ps.read(0, samp.buffer(ps.nevents(0)));
    std.debug.print("{any}\n", .{samp});

    samp.clear();
    try ps.read(1, samp.buffer(ps.nevents(1)));
    std.debug.print("{any}\n", .{samp});

    samp.clear();
    try ps.read(2, samp.buffer(ps.nevents(2)));
    std.debug.print("{any}\n", .{samp});

    ps.deinit();
}
