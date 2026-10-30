/// Cron scheduler — periodic tasks with π/φ/e-based intervals.
/// Runs background maintenance, reflection, and knowledge updates.
///
/// P3 threading contract: the scheduler thread NEVER runs task code —
/// it only pushes due-task indices into `due_inbox`. The MAIN thread
/// drains and executes (SQLite is THREADSAFE=0; all DB writes stay
/// main-thread). Tasks that miss a drain (inbox full) simply retry on
/// the next tick.
const std = @import("std");
const time_mod = @import("../util/time.zig");
const math = @import("../math/mod.zig");
const mpsc = @import("mpsc_queue.zig");

pub const CronTask = struct {
    name: []const u8,
    interval_ms: u64,
    last_run: std.atomic.Value(i64),
    enabled: std.atomic.Value(bool),
    /// Executed on the MAIN thread by drainDue(). ctx is opaque
    /// scheduler-registered state (e.g. a REPL-owned sweep context).
    task_fn: *const fn (?*anyopaque) anyerror!void,
    ctx: ?*anyopaque = null,
};

pub const CronScheduler = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(CronTask),
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    due_inbox: mpsc.BoundedMPSC(usize, 16),

    const Self = @This();

    // π/φ/e-based intervals (in ms)
    pub const REFLECTION_INTERVAL: u64 = @intFromFloat(math.constants.PI * 24.0 * 60.0 * 60.0 * 1000.0); // π×24h ≈ 3.14 d
    pub const KNOWLEDGE_UPDATE_INTERVAL: u64 = @intFromFloat(math.constants.PHI * 60.0 * 60.0 * 1000.0); // ~37.1 min
    pub const MEMORY_DECAY_INTERVAL: u64 = @intFromFloat(math.constants.E * 30.0 * 60.0 * 1000.0); // ~81.5 min
    pub const HEALTH_CHECK_INTERVAL: u64 = 60 * 1000; // 60s
    pub const RESOURCE_MONITOR_INTERVAL: u64 = 30 * 1000; // 30s

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tasks = .empty,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .due_inbox = .init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.tasks.deinit(self.allocator);
    }

    pub fn addTask(self: *Self, task: CronTask) !void {
        try self.tasks.append(self.allocator, task);
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, schedulerLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// Scheduler loop: pure timing — detect due tasks, hand their indices
    /// to the main thread. markRun happens HERE (so a full inbox retries
    /// next tick) but the task body never runs on this thread.
    fn schedulerLoop(self: *Self) void {
        while (self.running.load(.monotonic)) {
            const now = time_mod.nowMillis();

            for (self.tasks.items, 0..) |*task, i| {
                if (!task.enabled.load(.monotonic)) continue;
                const last = task.last_run.load(.monotonic);
                if (last == 0 or (now - last) >= @as(i64, @intCast(task.interval_ms))) {
                    if (self.due_inbox.push(i)) {
                        task.last_run.store(now, .release);
                    }
                }
            }

            var ts: std.c.timespec = .{ .sec = 1, .nsec = 0 };
            _ = std.c.nanosleep(&ts, null);
        }
    }

    /// Main-thread drain: run every task that came due. Called at the REPL
    /// loop top (same cadence as the reflection inbox).
    pub fn drainDue(self: *Self) void {
        while (self.due_inbox.pop()) |i| {
            if (i >= self.tasks.items.len) continue;
            const t = &self.tasks.items[i];
            t.task_fn(t.ctx) catch |e| {
                // Cron failures must never take the session down; the
                // scheduler will retry on the next interval anyway.
                std.debug.print("[cron] {s} failed: {}\n", .{ t.name, e });
            };
        }
    }
};

test "CronScheduler intervals" {
    // Verify π/φ/e-based intervals are reasonable
    try std.testing.expect(CronScheduler.REFLECTION_INTERVAL > 3 * 24 * 60 * 60 * 1000); // > 3 days
    try std.testing.expect(CronScheduler.REFLECTION_INTERVAL < 4 * 24 * 60 * 60 * 1000); // < 4 days
    try std.testing.expect(CronScheduler.KNOWLEDGE_UPDATE_INTERVAL > 35 * 60 * 1000);
    try std.testing.expect(CronScheduler.MEMORY_DECAY_INTERVAL > 80 * 60 * 1000);
}

test "due tasks drain on the calling thread" {
    // A 1ms-interval task fires (nearly) immediately; drainDue must run
    // its body HERE, on this thread — the SQLite threading contract.
    const T = struct {
        var ran_on: ?std.Thread.Id = null;
        fn run(_: ?*anyopaque) anyerror!void {
            ran_on = std.Thread.getCurrentId();
        }
    };
    var sched = CronScheduler.init(std.testing.allocator);
    defer sched.deinit();
    try sched.addTask(.{
        .name = "probe",
        .interval_ms = 1,
        .last_run = std.atomic.Value(i64).init(0),
        .enabled = std.atomic.Value(bool).init(true),
        .task_fn = T.run,
    });
    try sched.start();
    // wait until the scheduler thread queued it
    var spins: usize = 0;
    while (sched.due_inbox.isEmpty() and spins < 100) : (spins += 1) {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    sched.drainDue();
    try std.testing.expect(T.ran_on != null);
    try std.testing.expectEqual(std.Thread.getCurrentId(), T.ran_on.?);
}
