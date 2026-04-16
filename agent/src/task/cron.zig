/// Cron scheduler — periodic tasks with π/φ/e-based intervals.
/// Runs background maintenance, reflection, and knowledge updates.

const std = @import("std");
const math = @import("../math/mod.zig");

pub const CronTask = struct {
    name: []const u8,
    interval_ms: u64,
    last_run: std.atomic.Value(i64),
    enabled: std.atomic.Value(bool),
    task_fn: *const fn () anyerror!void,
};

pub const CronScheduler = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(CronTask),
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    const Self = @This();

    // π/φ/e-based intervals (in ms)
    pub const REFLECTION_INTERVAL: u64 = @intFromFloat(math.constants.PI * 10.0 * 60.0 * 1000.0); // ~31.4 min
    pub const KNOWLEDGE_UPDATE_INTERVAL: u64 = @intFromFloat(math.constants.PHI * 60.0 * 60.0 * 1000.0); // ~37.1 min
    pub const MEMORY_DECAY_INTERVAL: u64 = @intFromFloat(math.constants.E * 30.0 * 60.0 * 1000.0); // ~81.5 min
    pub const HEALTH_CHECK_INTERVAL: u64 = 60 * 1000; // 60s
    pub const RESOURCE_MONITOR_INTERVAL: u64 = 30 * 1000; // 30s

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(CronTask).init(allocator),
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.tasks.deinit();
    }

    pub fn addTask(self: *Self, task: CronTask) !void {
        try self.tasks.append(task);
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, schedulerLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    fn schedulerLoop(self: *Self) void {
        while (self.running.load(.monotonic)) {
            const now = std.time.milliTimestamp();

            for (self.tasks.items) |*task| {
                if (!task.enabled.load(.monotonic)) continue;
                const last = task.last_run.load(.monotonic);
                if (last == 0 or (now - last) >= @as(i64, @intCast(task.interval_ms))) {
                    task.task_fn() catch {};
                    task.last_run.store(now, .release);
                }
            }

            std.time.sleep(1 * std.time.ns_per_s);
        }
    }
};

test "CronScheduler intervals" {
    // Verify π/φ/e-based intervals are reasonable
    try std.testing.expect(CronScheduler.REFLECTION_INTERVAL > 30 * 60 * 1000); // > 30 min
    try std.testing.expect(CronScheduler.REFLECTION_INTERVAL < 35 * 60 * 1000); // < 35 min
    try std.testing.expect(CronScheduler.KNOWLEDGE_UPDATE_INTERVAL > 35 * 60 * 1000);
    try std.testing.expect(CronScheduler.MEMORY_DECAY_INTERVAL > 80 * 60 * 1000);
}
