/// SSE (Server-Sent Events) parser for LLM streaming responses.
/// Parses chunked HTTP response into StreamEvent items.
/// Compatible with Zig 0.16.
const std = @import("std");
const provider = @import("provider.zig");

pub const SSEEvent = struct {
    event: ?[]const u8 = null,
    data: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry: ?u32 = null,
};

/// SSE parser state machine.
pub const SSEParser = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    events: std.ArrayList(SSEEvent),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .events = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free event data
        for (self.events.items) |event| {
            if (event.event) |e| self.allocator.free(e);
            if (event.data) |d| self.allocator.free(d);
            if (event.id) |id| self.allocator.free(id);
        }
        self.events.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
    }

    /// Feed raw bytes from the HTTP response into the parser.
    /// Returns the number of complete events parsed.
    pub fn feed(self: *Self, chunk: []const u8) !usize {
        try self.buffer.appendSlice(self.allocator, chunk);
        const count_before = self.events.items.len;
        try self.parseBuffer();
        return self.events.items.len - count_before;
    }

    /// Get and drain all parsed events. Ownership of the events and their
    /// strings moves to the caller: free each string, then the slice itself.
    pub fn drain(self: *Self) []SSEEvent {
        const items = self.events.items;
        if (items.len == 0) return &.{};
        const result = self.allocator.dupe(SSEEvent, items) catch return &.{};
        self.events.shrinkRetainingCapacity(0);
        return @constCast(result);
    }

    fn parseBuffer(self: *Self) !void {
        var buf = self.buffer.items;
        while (true) {
            const boundary = findDoubleNewline(buf);
            if (boundary == null) break;

            const event_bytes = buf[0..boundary.?];
            // Separator is "\n\n" or "\r\n\r\n"; skip its full width.
            const sep_len: usize = if (buf[boundary.?] == '\r') 4 else 2;
            buf = buf[boundary.? + sep_len ..];

            var event = SSEEvent{};
            var lines = std.mem.splitSequence(u8, event_bytes, "\n");
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (line[0] == ':') continue;
                if (std.mem.indexOfScalar(u8, line, ':')) |colon_idx| {
                    const field = line[0..colon_idx];
                    var value = line[colon_idx + 1 ..];
                    if (value.len > 0 and value[0] == ' ') value = value[1..];

                    if (std.mem.eql(u8, field, "event")) {
                        event.event = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, field, "data")) {
                        event.data = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, field, "id")) {
                        event.id = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, field, "retry")) {
                        event.retry = std.fmt.parseInt(u32, value, 10) catch null;
                    }
                }
            }

            if (event.data != null) {
                try self.events.append(self.allocator, event);
            } else {
                if (event.event) |e| self.allocator.free(e);
                if (event.id) |id| self.allocator.free(id);
            }
        }

        // Keep remaining unparsed bytes
        const remaining = self.buffer.items.len - (buf.ptr - self.buffer.items.ptr);
        if (remaining > 0 and remaining < self.buffer.items.len) {
            std.mem.copyForwards(u8, self.buffer.items, buf);
            self.buffer.shrinkRetainingCapacity(remaining);
        } else if (remaining == 0) {
            self.buffer.shrinkRetainingCapacity(0);
        }
    }

    fn findDoubleNewline(buf: []const u8) ?usize {
        var i: usize = 0;
        while (i + 1 < buf.len) : (i += 1) {
            if (buf[i] == '\n' and buf[i + 1] == '\n') return i;
            if (buf[i] == '\r' and i + 3 < buf.len and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') return i;
        }
        return null;
    }
};

/// Parse a Claude SSE data payload into a StreamEvent.
pub fn parseClaudeStreamEvent(allocator: std.mem.Allocator, data: []const u8) ?provider.StreamEvent {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{}) catch return null;

    const event_type = parsed.object.get("type") orelse return null;
    if (event_type != .string) return null;

    if (std.mem.eql(u8, event_type.string, "content_block_delta")) {
        const delta = parsed.object.get("delta") orelse return null;
        if (delta.object.get("type")) |dt| {
            if (dt == .string and std.mem.eql(u8, dt.string, "text_delta")) {
                const text = delta.object.get("text") orelse return null;
                if (text == .string) {
                    return .{ .content_delta = text.string };
                }
            }
        }
    } else if (std.mem.eql(u8, event_type.string, "message_stop")) {
        return .{ .done = null };
    } else if (std.mem.eql(u8, event_type.string, "message_delta")) {
        if (parsed.object.get("usage")) |usage| {
            return .{
                .done = .{
                    .input_tokens = 0,
                    .output_tokens = switch (usage.object.get("output_tokens").?) {
                        .integer => |i| @intCast(i),
                        .float => |f| @intFromFloat(f),
                        else => 0,
                    },
                },
            };
        }
        return .{ .done = null };
    }

    return null;
}

test "SSEParser basic parsing" {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const input = "event: message\ndata: hello world\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\n";
    const count = try parser.feed(input);
    try std.testing.expectEqual(@as(usize, 2), count);
}
