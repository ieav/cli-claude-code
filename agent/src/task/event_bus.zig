/// Event bus — publishes events to subscribers. Uses π ring buffer for event history.
const std = @import("std");
const time_mod = @import("../util/time.zig");
const math = @import("../math/mod.zig");

pub const EventType = enum {
    task_completed,
    task_failed,
    memory_updated,
    knowledge_updated,
    reflection_produced,
    error_detected,
    resource_warning,
    user_query_start,
    user_query_end,
    user_intervention_needed,
    user_concern_raised,
    diagnosis_completed,
    research_started,
    research_completed,
    solution_selected,
};

/// P3: typed payloads (numbers only — no borrowed strings, so the π ring
/// history is lifetime-safe by construction and the reflection sampler
/// can read old events without dangling).
pub const EventData = union(EventType) {
    task_completed: struct { jobs: u8 },
    task_failed: struct { ok: u8, failed: u8 },
    memory_updated: struct { stored: u8 },
    knowledge_updated: void,
    reflection_produced: struct { quality: f32, background: bool },
    error_detected: struct { errors: u32 },
    resource_warning: struct { failed_checks: u8 },
    user_query_start: void,
    user_query_end: struct { tools: u32, errors: u32 },
    user_intervention_needed: void,
    user_concern_raised: void,
    diagnosis_completed: void,
    research_started: void,
    research_completed: void,
    solution_selected: void,
};

pub const Event = struct {
    event_type: EventType,
    timestamp: i64,
    data: EventData,
};

pub const EventHandler = *const fn (Event) anyerror!void;

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.HashMap(EventType, std.ArrayList(EventHandler), std.hash_map.AutoContext(EventType), std.hash_map.default_max_load_percentage),
    event_log: math.PiRingBuffer(Event, 1024),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .handlers = std.HashMap(EventType, std.ArrayList(EventHandler), std.hash_map.AutoContext(EventType), std.hash_map.default_max_load_percentage).init(allocator),
            .event_log = math.PiRingBuffer(Event, 1024).init(),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.handlers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.handlers.deinit();
    }

    pub fn subscribe(self: *Self, event_type: EventType, handler: EventHandler) !void {
        const result = try self.handlers.getOrPut(event_type);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(EventHandler).empty;
        }
        try result.value_ptr.append(self.allocator, handler);
    }

    /// Emit on the MAIN thread only (handlers run synchronously here and
    /// SQLite writes must stay main-thread — see cron wiring).
    pub fn emit(self: *Self, data: EventData) void {
        const event = Event{
            .event_type = std.meta.activeTag(data),
            .timestamp = time_mod.nowMillis(),
            .data = data,
        };

        // Log to π ring buffer
        self.event_log.push(event);

        // Notify subscribers
        if (self.handlers.get(event.event_type)) |handlers| {
            for (handlers.items) |handler| {
                handler(event) catch {};
            }
        }
    }

    /// Get recent events from π ring buffer (uniform coverage).
    /// Caller owns the returned slice — free it with freeEvents().
    pub fn getRecentEvents(self: *Self, count: usize) []const Event {
        const n = @min(count, self.event_log.count);
        if (n == 0) return &.{};
        // Return the last n items from the ring buffer
        var result: std.ArrayList(Event) = .empty;
        defer result.deinit(self.allocator);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.event_log.get(n - 1 - i)) |evt| {
                result.append(self.allocator, evt) catch break;
            }
        }
        return result.toOwnedSlice(self.allocator) catch &.{};
    }

    /// Free a slice returned by getRecentEvents.
    pub fn freeEvents(self: *Self, events: []const Event) void {
        if (events.len > 0) self.allocator.free(@constCast(events));
    }

    pub fn eventCount(self: *const Self) usize {
        return self.event_log.count;
    }

    /// One-line human description (static labels + numbers — used by the
    /// π-sampled reflection context).
    pub fn describe(ev: Event, buf: []u8) []const u8 {
        return switch (ev.data) {
            .task_completed => |d| std.fmt.bufPrint(buf, "subagent fan-out completed ({d} jobs)", .{d.jobs}) catch "task_completed",
            .task_failed => |d| std.fmt.bufPrint(buf, "subagent fan-out partial ({d} ok / {d} failed)", .{ d.ok, d.failed }) catch "task_failed",
            .memory_updated => |d| std.fmt.bufPrint(buf, "memories stored ({d})", .{d.stored}) catch "memory_updated",
            .knowledge_updated => "knowledge graph updated",
            .reflection_produced => |d| std.fmt.bufPrint(buf, "reflection ({s}, quality {d:.2})", .{ if (d.background) "background llm" else "heuristic", d.quality }) catch "reflection",
            .error_detected => |d| std.fmt.bufPrint(buf, "tool errors ({d})", .{d.errors}) catch "error_detected",
            .resource_warning => |d| std.fmt.bufPrint(buf, "runtime warnings ({d})", .{d.failed_checks}) catch "resource_warning",
            .user_query_start => "user query started",
            .user_query_end => |d| std.fmt.bufPrint(buf, "user query ended ({d} tools, {d} errors)", .{ d.tools, d.errors }) catch "user_query_end",
            .user_intervention_needed => "user intervention needed",
            .user_concern_raised => "user concern raised",
            .diagnosis_completed => "diagnosis completed",
            .research_started => "research started",
            .research_completed => "research completed",
            .solution_selected => "solution selected",
        };
    }
};

test "EventBus emit and subscribe" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    bus.emit(.{ .task_completed = .{ .jobs = 2 } });
    try std.testing.expectEqual(@as(usize, 1), bus.eventCount());

    bus.emit(.{ .task_failed = .{ .ok = 1, .failed = 1 } });
    try std.testing.expectEqual(@as(usize, 2), bus.eventCount());

    var buf: [128]u8 = undefined;
    const ev = Event{ .event_type = .task_completed, .timestamp = 0, .data = .{ .task_completed = .{ .jobs = 2 } } };
    try std.testing.expect(std.mem.indexOf(u8, EventBus.describe(ev, &buf), "completed") != null);
}
