/// Runtime monitor — periodically runs detection rules and reports issues.

const std = @import("std");
const event_bus = @import("../task/event_bus.zig");
const rules = @import("rules.zig");
const builtin = @import("builtin_rules.zig");

pub const RuntimeMonitor = struct {
    allocator: std.mem.Allocator,
    rules_list: []const rules.RuntimeRule,
    context: rules.RuntimeContext,
    event_bus_ref: ?*event_bus.EventBus,
    check_interval_ms: u64,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    total_checks: std.atomic.Value(usize),
    total_failures: std.atomic.Value(usize),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .rules_list = builtin.builtin_rules,
            .context = .{
                .memory_used_bytes = 0,
                .memory_limit_bytes = 100 * 1024 * 1024,
                .memory_entry_count = 0,
                .api_calls_last_minute = 0,
                .api_rate_limit = 60,
                .db_integrity_ok = true,
                .current_tokens = 0,
                .max_tokens = 128000,
                .task_failed_count = 0,
                .task_total_count = 0,
                .network_timeout_count = 0,
                .active_tasks = 0,
                .max_concurrent_tasks = 4,
            },
            .event_bus_ref = null,
            .check_interval_ms = 30_000, // 30s
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .total_checks = std.atomic.Value(usize).init(0),
            .total_failures = std.atomic.Value(usize).init(0),
        };
    }

    pub fn setEventBus(self: *Self, bus: *event_bus.EventBus) void {
        self.event_bus_ref = bus;
    }

    pub fn updateContext(self: *Self, ctx: rules.RuntimeContext) void {
        self.context = ctx;
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, monitorLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
    }

    /// Run all checks once and return failures.
    pub fn runChecks(self: *Self, failures: *std.ArrayList(rules.FailedCheck)) !void {
        for (self.rules_list) |rule| {
            const result = rule.check_fn(&self.context);
            switch (result) {
                .pass => {},
                .fail => |info| {
                    _ = self.total_failures.fetchAdd(1, .monotonic);
                    try failures.append(info);

                    // Emit event if bus is available
                    if (self.event_bus_ref) |bus| {
                        bus.emit(.error_detected, info.message);
                    }
                },
            }
        }
        _ = self.total_checks.fetchAdd(1, .monotonic);
    }

    pub fn stats(self: *const Self) MonitorStats {
        return .{
            .total_checks = self.total_checks.load(.monotonic),
            .total_failures = self.total_failures.load(.monotonic),
            .rules_count = self.rules_list.len,
        };
    }

    fn monitorLoop(self: *Self) void {
        while (self.running.load(.monotonic)) {
            var failures = std.ArrayList(rules.FailedCheck).init(self.allocator);
            defer failures.deinit();

            self.runChecks(&failures) catch continue;

            // If there are failures needing user intervention, emit event
            if (failures.items.len > 0) {
                if (self.event_bus_ref) |bus| {
                    bus.emit(.user_intervention_needed, "检测到问题需要处理");
                }
            }

            std.time.sleep(self.check_interval_ms * std.time.ns_per_ms);
        }
    }
};

pub const MonitorStats = struct {
    total_checks: usize,
    total_failures: usize,
    rules_count: usize,
};

test "RuntimeMonitor runChecks" {
    var monitor = RuntimeMonitor.init(std.testing.allocator);

    // Default context should pass all checks
    var failures = std.ArrayList(rules.FailedCheck).init(std.testing.allocator);
    defer failures.deinit();

    try monitor.runChecks(&failures);
    try std.testing.expectEqual(@as(usize, 0), failures.items.len);

    const s = monitor.stats();
    try std.testing.expectEqual(@as(usize, 1), s.total_checks);
}
