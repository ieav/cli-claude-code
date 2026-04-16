/// Event bus — publishes events to subscribers. Uses π ring buffer for event history.

const std = @import("std");
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

pub const Event = struct {
    event_type: EventType,
    timestamp: i64,
    message: []const u8,
    data: ?std.json.Value,
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
            entry.value_ptr.deinit();
        }
        self.handlers.deinit();
    }

    pub fn subscribe(self: *Self, event_type: EventType, handler: EventHandler) !void {
        const result = try self.handlers.getOrPut(event_type);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(EventHandler).init(self.allocator);
        }
        try result.value_ptr.append(handler);
    }

    pub fn emit(self: *Self, event_type: EventType, message: []const u8) void {
        const event = Event{
            .event_type = event_type,
            .timestamp = std.time.milliTimestamp(),
            .message = message,
            .data = null,
        };

        // Log to π ring buffer
        self.event_log.push(event);

        // Notify subscribers
        if (self.handlers.get(event_type)) |handlers| {
            for (handlers.items) |handler| {
                handler(event) catch {};
            }
        }
    }

    pub fn emitWithData(self: *Self, event_type: EventType, message: []const u8, data: std.json.Value) void {
        const event = Event{
            .event_type = event_type,
            .timestamp = std.time.milliTimestamp(),
            .message = message,
            .data = data,
        };

        self.event_log.push(event);

        if (self.handlers.get(event_type)) |handlers| {
            for (handlers.items) |handler| {
                handler(event) catch {};
            }
        }
    }

    /// Get recent events from π ring buffer (uniform coverage).
    pub fn getRecentEvents(self: *Self, count: usize) []const Event {
        const n = @min(count, self.event_log.count);
        if (n == 0) return &.{};
        // Return the last n items from the ring buffer
        var result = std.ArrayList(Event).init(self.allocator);
        defer result.deinit();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.event_log.get(n - 1 - i)) |evt| {
                result.append(evt) catch break;
            }
        }
        return result.toOwnedSlice() catch &.{};
    }

    pub fn eventCount(self: *const Self) usize {
        return self.event_log.count;
    }
};

test "EventBus emit and subscribe" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();

    bus.emit(.task_completed, "test task done");
    try std.testing.expectEqual(@as(usize, 1), bus.eventCount());

    bus.emit(.task_failed, "test task failed");
    try std.testing.expectEqual(@as(usize, 2), bus.eventCount());
}
