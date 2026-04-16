/// Thread pool — manages a pool of worker threads that execute tasks from a queue.
/// Concurrency is bounded by e-based logistic function: max = sigmoid(pressure) × hw_threads.

const std = @import("std");
const math = @import("../math/mod.zig");
const mpsc = @import("mpsc_queue.zig");

pub const TaskPriority = enum(u8) {
    critical = 0,
    high = 1,
    normal = 2,
    low = 3,
    background = 4,
};

pub const TaskStatus = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

pub const TaskFn = *const fn (*std.mem.Allocator, ?*anyopaque) anyerror!void;

pub const Task = struct {
    id: u64,
    name: []const u8,
    priority: TaskPriority,
    status: std.atomic.Value(TaskStatus),
    progress: std.atomic.Value(f64),
    execute_fn: TaskFn,
    ctx: ?*anyopaque,
    cancel_token: std.atomic.Value(bool),
    error_message: ?[]const u8,
    retry_count: u32,
    max_retries: u32,
};

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: mpsc.BoundedMPSC(*Task, 256),
    active_count: std.atomic.Value(usize),
    total_submitted: std.atomic.Value(usize),
    total_completed: std.atomic.Value(usize),
    total_failed: std.atomic.Value(usize),
    shutdown: std.atomic.Value(bool),
    notify: std.Thread.Condition,
    mutex: std.Thread.Mutex,
    max_concurrent: usize,
    next_task_id: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const hw_threads = std.Thread.getCpuCount() catch 4;
        // e-controlled max: logisticCap bounds concurrency
        const max_concurrent = math.effectiveConcurrency(0, hw_threads);

        return .{
            .allocator = allocator,
            .threads = &.{},
            .queue = mpsc.BoundedMPSC(*Task, 256).init(),
            .active_count = std.atomic.Value(usize).init(0),
            .total_submitted = std.atomic.Value(usize).init(0),
            .total_completed = std.atomic.Value(usize).init(0),
            .total_failed = std.atomic.Value(usize).init(0),
            .shutdown = std.atomic.Value(bool).init(false),
            .notify = .{},
            .mutex = .{},
            .max_concurrent = max_concurrent,
            .next_task_id = std.atomic.Value(u64).init(0),
        };
    }

    pub fn start(self: *Self) !void {
        const thread_count = self.max_concurrent;
        self.threads = try self.allocator.alloc(std.Thread, thread_count);

        for (self.threads, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{ self, i });
        }
    }

    pub fn deinit(self: *Self) void {
        self.shutdown.store(true, .release);
        self.mutex.lock();
        self.notify.broadcast();
        self.mutex.unlock();

        for (self.threads) |t| {
            t.join();
        }
        self.allocator.free(self.threads);
    }

    pub fn submit(self: *Self, task: *Task) !void {
        task.id = self.next_task_id.fetchAdd(1, .monotonic);
        task.status.store(.pending, .release);
        _ = self.total_submitted.fetchAdd(1, .monotonic);

        if (!self.queue.push(task)) {
            return error.QueueFull;
        }

        self.mutex.lock();
        self.notify.signal();
        self.mutex.unlock();
    }

    pub fn cancel(self: *Self, task_id: u64) bool {
        _ = self;
        _ = task_id;
        return false;
    }

    pub fn activeCount(self: *const Self) usize {
        return self.active_count.load(.monotonic);
    }

    pub fn stats(self: *const Self) PoolStats {
        return .{
            .active = self.active_count.load(.monotonic),
            .submitted = self.total_submitted.load(.monotonic),
            .completed = self.total_completed.load(.monotonic),
            .failed = self.total_failed.load(.monotonic),
            .max_concurrent = self.max_concurrent,
        };
    }

    fn workerLoop(self: *Self, worker_id: usize) void {
        _ = worker_id;
        while (!self.shutdown.load(.monotonic)) {
            if (self.queue.pop()) |task| {
                _ = self.active_count.fetchAdd(1, .monotonic);
                defer _ = self.active_count.fetchSub(1, .monotonic);

                if (task.cancel_token.load(.monotonic)) {
                    task.status.store(.cancelled, .release);
                    continue;
                }

                task.status.store(.running, .release);
                task.execute_fn(self.allocator, task.ctx) catch {
                    task.status.store(.failed, .release);
                    _ = self.total_failed.fetchAdd(1, .monotonic);
                    continue;
                };

                task.status.store(.completed, .release);
                _ = self.total_completed.fetchAdd(1, .monotonic);
            } else {
                // Wait for notification
                self.mutex.lock();
                self.notify.wait(&self.mutex, 1 * std.time.ns_per_ms);
                self.mutex.unlock();
            }
        }
    }
};

pub const PoolStats = struct {
    active: usize,
    submitted: usize,
    completed: usize,
    failed: usize,
    max_concurrent: usize,
};

test "ThreadPool init and deinit" {
    var pool = try ThreadPool.init(std.testing.allocator);
    // Don't start threads in test to avoid complexity
    try std.testing.expect(!pool.shutdown.load(.monotonic));
}
