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

/// Stateful Claude SSE stream aggregator: emits text/thinking deltas live,
/// reassembles tool_use blocks from content_block_start + input_json_delta
/// fragments (emitting one `.tool_call` per block at content_block_stop),
/// and merges usage from message_start/message_delta. Replaces the old
/// stateless parser, which dropped every tool_use block and each partial
/// JSON fragment on the floor.
pub const ClaudeStreamState = struct {
    allocator: std.mem.Allocator,
    /// Owns id/name strings and input DOMs referenced by emitted tool_call
    /// events. Delta strings point into the per-payload DOM (freed when
    /// feed returns). Callback-scoped validity either way — see the
    /// provider.StreamEvent ownership contract.
    arena: std.heap.ArenaAllocator,
    tools: std.ArrayList(ToolAcc) = .empty,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    saw_usage: bool = false,

    const ToolAcc = struct {
        index: usize,
        id: []const u8,
        name: []const u8,
        json: std.ArrayList(u8) = .empty,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tools = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.tools.items) |*acc| acc.json.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Process one SSE data payload. Returns true when the stream finished
    /// (message_stop). Events are emitted through cb as they parse.
    pub fn feed(self: *Self, data: []const u8, ctx: ?*anyopaque, cb: *const provider.StreamCallback) anyerror!bool {
        // Per-payload arena: the DOM dies with the chunk; every string that
        // outlives feed() is duped into self.arena first.
        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, line_arena.allocator(), data, .{}) catch return false;
        if (parsed != .object) return false;
        const event_type = parsed.object.get("type") orelse return false;
        if (event_type != .string) return false;
        const t = event_type.string;

        if (std.mem.eql(u8, t, "content_block_start")) {
            const index = jsonInt(parsed, "index") orelse 0;
            if (parsed.object.get("content_block")) |cb_block| {
                if (cb_block == .object) {
                    const bt = cb_block.object.get("type") orelse return false;
                    if (bt == .string and std.mem.eql(u8, bt.string, "tool_use")) {
                        const a = self.arena.allocator();
                        var acc = ToolAcc{ .index = index, .id = "", .name = "" };
                        if (cb_block.object.get("id")) |v| {
                            if (v == .string) acc.id = try a.dupe(u8, v.string);
                        }
                        if (cb_block.object.get("name")) |v| {
                            if (v == .string) acc.name = try a.dupe(u8, v.string);
                        }
                        try self.tools.append(self.allocator, acc);
                    }
                }
            }
        } else if (std.mem.eql(u8, t, "content_block_delta")) {
            const index = jsonInt(parsed, "index") orelse 0;
            const delta = parsed.object.get("delta") orelse return false;
            if (delta != .object) return false;
            const dt = delta.object.get("type") orelse return false;
            if (dt != .string) return false;
            if (std.mem.eql(u8, dt.string, "text_delta")) {
                if (delta.object.get("text")) |tv| {
                    if (tv == .string and tv.string.len > 0) try cb(ctx, .{ .content_delta = tv.string });
                }
            } else if (std.mem.eql(u8, dt.string, "thinking_delta")) {
                if (delta.object.get("thinking")) |tv| {
                    if (tv == .string and tv.string.len > 0) try cb(ctx, .{ .thinking_delta = tv.string });
                }
            } else if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                if (delta.object.get("partial_json")) |pv| {
                    if (pv == .string and pv.string.len > 0) {
                        if (self.accFor(index)) |acc| try acc.json.appendSlice(self.allocator, pv.string);
                    }
                }
            }
        } else if (std.mem.eql(u8, t, "content_block_stop")) {
            const index = jsonInt(parsed, "index") orelse 0;
            try self.flushTool(index, ctx, cb);
        } else if (std.mem.eql(u8, t, "message_start")) {
            if (parsed.object.get("message")) |m| {
                if (m == .object) {
                    if (m.object.get("usage")) |u| {
                        if (u == .object) {
                            if (u.object.get("input_tokens")) |iv| {
                                if (iv == .integer and iv.integer >= 0) {
                                    self.input_tokens = @intCast(iv.integer);
                                    self.saw_usage = true;
                                }
                            }
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, t, "message_delta")) {
            if (parsed.object.get("usage")) |u| {
                if (u == .object) {
                    if (u.object.get("output_tokens")) |ov| {
                        if (ov == .integer and ov.integer >= 0) {
                            self.output_tokens = @intCast(ov.integer);
                            self.saw_usage = true;
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, t, "message_stop")) {
            return true;
        } else if (std.mem.eql(u8, t, "error")) {
            try cb(ctx, .{ .error_occurred = provider.ProviderError.ServerError });
        }
        return false;
    }

    /// Merged usage across message_start/message_delta, or null if the
    /// stream carried no usage at all.
    pub fn usageValue(self: *const Self) ?provider.Usage {
        if (!self.saw_usage) return null;
        return .{ .input_tokens = self.input_tokens, .output_tokens = self.output_tokens };
    }

    fn accFor(self: *Self, index: usize) ?*ToolAcc {
        var i = self.tools.items.len;
        while (i > 0) {
            i -= 1;
            if (self.tools.items[i].index == index) return &self.tools.items[i];
        }
        return null;
    }

    fn flushTool(self: *Self, index: usize, ctx: ?*anyopaque, cb: *const provider.StreamCallback) anyerror!void {
        var i: usize = 0;
        while (i < self.tools.items.len) : (i += 1) {
            if (self.tools.items[i].index != index) continue;
            var acc = self.tools.orderedRemove(i);
            defer acc.json.deinit(self.allocator);
            const a = self.arena.allocator();
            const input: std.json.Value = if (acc.json.items.len > 0)
                std.json.parseFromSliceLeaky(std.json.Value, a, acc.json.items, .{}) catch
                    std.json.Value{ .object = .empty }
            else
                std.json.Value{ .object = .empty };
            const id = if (acc.id.len > 0) acc.id else try std.fmt.allocPrint(a, "toolu_{d}", .{acc.index});
            try cb(ctx, .{ .tool_call = .{ .id = id, .name = acc.name, .input = input } });
            return;
        }
    }
};

fn jsonInt(v: std.json.Value, key: []const u8) ?usize {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f == .integer and f.integer >= 0) return @intCast(f.integer);
    return null;
}

test "SSEParser basic parsing" {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const input = "event: message\ndata: hello world\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\n";
    const count = try parser.feed(input);
    try std.testing.expectEqual(@as(usize, 2), count);
}

/// Test callback that copies strings so they outlive provider arenas.
const StreamSink = struct {
    alloc: std.mem.Allocator,
    deltas: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(provider.ToolUseBlock) = .empty,
    done_usage: ?provider.Usage = null,

    fn cb(ctx_opaque: ?*anyopaque, event: provider.StreamEvent) anyerror!void {
        const self: *StreamSink = @ptrCast(@alignCast(ctx_opaque.?));
        switch (event) {
            .content_delta => |d| try self.deltas.appendSlice(self.alloc, d),
            .thinking_delta => |d| try self.thinking.appendSlice(self.alloc, d),
            .tool_call => |tu| try self.calls.append(self.alloc, .{
                .id = try self.alloc.dupe(u8, tu.id),
                .name = try self.alloc.dupe(u8, tu.name),
                .input = tu.input,
            }),
            .done => |u| {
                if (u != null) self.done_usage = u;
            },
            else => {},
        }
    }

    fn deinit(self: *StreamSink) void {
        self.deltas.deinit(self.alloc);
        self.thinking.deinit(self.alloc);
        for (self.calls.items) |*tu| {
            self.alloc.free(tu.id);
            self.alloc.free(tu.name);
        }
        self.calls.deinit(self.alloc);
    }
};

test "ClaudeStreamState reassembles tool_use and merges usage" {
    var sink: StreamSink = .{ .alloc = std.testing.allocator };
    defer sink.deinit();
    var state = ClaudeStreamState.init(std.testing.allocator);
    defer state.deinit();

    const finished = blk: {
        var stopped = false;
        const lines = [_][]const u8{
            \\{"type":"message_start","message":{"usage":{"input_tokens":25}}}
            ,
            \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
            ,
            \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me check."}}
            ,
            \\{"type":"content_block_stop","index":0}
            ,
            \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"FileRead","input":{}}}
            ,
            \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"pa"}}
            ,
            \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"th\":\"/tmp/a\"}"}}
            ,
            \\{"type":"content_block_stop","index":1}
            ,
            \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}
            ,
            \\{"type":"message_stop"}
            ,
        };
        for (lines) |line| {
            const done = try state.feed(line, @ptrCast(&sink), StreamSink.cb);
            if (done) {
                stopped = true;
                break;
            }
        }
        break :blk stopped;
    };

    try std.testing.expect(finished);
    try std.testing.expectEqualStrings("Let me check.", sink.deltas.items);
    try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    const tc = sink.calls.items[0];
    try std.testing.expectEqualStrings("toolu_01", tc.id);
    try std.testing.expectEqualStrings("FileRead", tc.name);
    try std.testing.expect(tc.input == .object);
    const path = tc.input.object.get("path") orelse return error.MissingPath;
    try std.testing.expectEqualStrings("/tmp/a", path.string);

    const usage = state.usageValue().?;
    try std.testing.expectEqual(@as(u32, 25), usage.input_tokens);
    try std.testing.expectEqual(@as(u32, 42), usage.output_tokens);
}

test "ClaudeStreamState passes thinking deltas through" {
    var sink: StreamSink = .{ .alloc = std.testing.allocator };
    defer sink.deinit();
    var state = ClaudeStreamState.init(std.testing.allocator);
    defer state.deinit();

    _ = try state.feed(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}
    , @ptrCast(&sink), StreamSink.cb);

    try std.testing.expectEqualStrings("hmm", sink.thinking.items);
}
