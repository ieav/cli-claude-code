/// Anthropic Claude backend — implements ProviderVTable for Claude models.
/// Uses the Messages API (https://api.anthropic.com/v1/messages).
/// Compatible with Zig 0.16 HTTP Client API.
const std = @import("std");
const provider = @import("provider.zig");
const message = @import("message.zig");
const streaming_mod = @import("streaming.zig");
const logger = @import("../util/log.zig");

pub const ClaudeConfig = struct {
    api_key: []const u8,
    model: []const u8 = "claude-sonnet-4-6",
    base_url: []const u8 = "https://api.anthropic.com",
    api_version: []const u8 = "2023-06-01",
};

pub const ClaudeProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: ClaudeConfig,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ClaudeConfig) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    pub fn toProvider(self: *Self) provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .complete_fn = complete,
                .stream_fn = stream,
                .count_tokens_fn = countTokens,
                .supports_tool_use_fn = supportsToolUse,
                .supports_streaming_fn = supportsStreaming,
                .deinit_fn = deinitVTable,
            },
        };
    }

    // ── VTable implementations ──

    fn complete(ptr: *anyopaque, messages: []const provider.Message, opts: provider.CompleteOptions) anyerror!provider.CompleteResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const body = try self.buildRequestBody(messages, opts, false);
        defer self.allocator.free(body);

        const response_body = try self.sendRequest("/v1/messages", body);
        defer self.allocator.free(response_body);

        return self.parseResponse(response_body);
    }

    fn stream(ptr: *anyopaque, messages: []const provider.Message, opts: provider.CompleteOptions, cb: *provider.StreamCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const body = try self.buildRequestBody(messages, opts, true);
        defer self.allocator.free(body);

        var sse_parser = streaming_mod.SSEParser.init(self.allocator);
        defer sse_parser.deinit();

        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{self.config.base_url});
        defer self.allocator.free(uri_str);
        const uri = try std.Uri.parse(uri_str);

        const extra_headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.config.api_key },
            .{ .name = "anthropic-version", .value = self.config.api_version },
        };

        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(body));

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status.class() != .success) {
            logger.err("Claude stream error: status={d}", .{@backingInt(response.head.status)});
            switch (@backingInt(response.head.status)) {
                401 => return provider.ProviderError.AuthFailed,
                429 => return provider.ProviderError.RateLimit,
                400 => return provider.ProviderError.InvalidRequest,
                else => return provider.ProviderError.ServerError,
            }
        }

        // Stream: read chunks and parse SSE events incrementally
        var resp_read_buf: [8192]u8 = undefined;
        const resp_reader = response.reader(&resp_read_buf);
        var chunk_buf: [4096]u8 = undefined;
        var total_usage: ?provider.Usage = null;

        while (true) {
            const n = resp_reader.readSliceShort(&chunk_buf) catch return provider.ProviderError.ServerError;
            if (n == 0) break;

            _ = sse_parser.feed(chunk_buf[0..n]) catch {};
            const events = sse_parser.drain();
            defer {
                for (events) |evt| {
                    if (evt.event) |s| self.allocator.free(s);
                    if (evt.data) |s| self.allocator.free(s);
                    if (evt.id) |s| self.allocator.free(s);
                }
                self.allocator.free(events);
            }

            for (events) |evt| {
                if (evt.data) |data| {
                    if (streaming_mod.parseClaudeStreamEvent(self.allocator, data)) |stream_event| {
                        switch (stream_event) {
                            .done => |u| {
                                if (u) |new_usage| total_usage = new_usage;
                                try cb(.{ .done = total_usage });
                                return;
                            },
                            else => try cb(stream_event),
                        }
                    }
                }
            }
        }
        try cb(.{ .done = total_usage });
    }

    fn countTokens(ptr: *anyopaque, text: []const u8) anyerror!u32 {
        _ = ptr;
        // Rough estimate: ~3.5 chars per token for Claude
        return @intCast(@divTrunc(text.len * 10, 35));
    }

    fn supportsToolUse(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    fn supportsStreaming(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    // ── Internal helpers ──

    fn buildRequestBody(
        self: *Self,
        messages: []const provider.Message,
        opts: provider.CompleteOptions,
        do_stream: bool,
    ) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &buf);
        const writer = &aw.writer;

        try writer.writeAll("{\"model\":");
        try message.writeJsonString(writer, self.config.model);

        try writer.print(",\"max_tokens\":{d}", .{opts.max_tokens});
        try writer.print(",\"temperature\":{d:.2}", .{opts.temperature});

        // Separate system prompt from messages
        var system_parts: std.ArrayList(u8) = .empty;
        defer system_parts.deinit(self.allocator);
        var non_system_count: usize = 0;

        // Count non-system messages first
        for (messages) |msg| {
            if (msg.role == .system) {
                for (msg.content) |block| {
                    if (block == .text) {
                        if (system_parts.items.len > 0) try system_parts.append(self.allocator, '\n');
                        try system_parts.appendSlice(self.allocator, block.text);
                    }
                }
            } else {
                non_system_count += 1;
            }
        }

        // System prompt as top-level field (Claude format)
        if (system_parts.items.len > 0) {
            try writer.writeAll(",\"system\":");
            try message.writeJsonString(writer, system_parts.items);
        }

        // Messages array (exclude system messages)
        try writer.writeAll(",\"messages\":[");
        var msg_idx: usize = 0;
        for (messages) |msg| {
            if (msg.role == .system) continue;
            if (msg_idx > 0) try writer.writeAll(",");
            try writer.writeAll("{\"role\":");
            const role_str: []const u8 = switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                .tool => "user", // Claude uses "user" role for tool results
                .system => unreachable,
            };
            try message.writeJsonString(writer, role_str);
            try writer.writeAll(",\"content\":");

            if (msg.content.len == 1 and msg.content[0] == .text) {
                try message.writeJsonString(writer, msg.content[0].text);
            } else if (msg.content.len > 0) {
                try writer.writeAll("[");
                for (msg.content, 0..) |block, j| {
                    if (j > 0) try writer.writeAll(",");
                    switch (block) {
                        .text => |t| {
                            try writer.writeAll("{\"type\":\"text\",\"text\":");
                            try message.writeJsonString(writer, t);
                            try writer.writeAll("}");
                        },
                        .tool_use => |tu| {
                            try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                            try message.writeJsonString(writer, tu.id);
                            try writer.writeAll(",\"name\":");
                            try message.writeJsonString(writer, tu.name);
                            try writer.writeAll(",\"input\":");
                            try std.json.Stringify.value(tu.input, .{}, writer);
                            try writer.writeAll("}");
                        },
                        .tool_result => |tr| {
                            try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
                            try message.writeJsonString(writer, tr.tool_use_id);
                            try writer.writeAll(",\"content\":");
                            try message.writeJsonString(writer, tr.content);
                            if (tr.is_error) {
                                try writer.writeAll(",\"is_error\":true");
                            }
                            try writer.writeAll("}");
                        },
                        .thinking => |t| {
                            // Claude supports thinking blocks natively
                            try writer.writeAll("{\"type\":\"thinking\",\"thinking\":");
                            try message.writeJsonString(writer, t);
                            try writer.writeAll("}");
                        },
                    }
                }
                try writer.writeAll("]");
            } else {
                try writer.writeAll("\"\"");
            }
            try writer.writeAll("}");
            msg_idx += 1;
        }
        try writer.writeAll("]");

        if (do_stream) {
            try writer.writeAll(",\"stream\":true");
        }

        if (opts.stop_sequences) |seqs| {
            try writer.writeAll(",\"stop_sequences\":[");
            for (seqs, 0..) |s, i| {
                if (i > 0) try writer.writeAll(",");
                try message.writeJsonString(writer, s);
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("}");

        buf = aw.toArrayList();
        return buf.toOwnedSlice(self.allocator);
    }

    fn sendRequest(self: *Self, path: []const u8, body: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.config.base_url, path });
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);

        const extra_headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.config.api_key },
            .{ .name = "anthropic-version", .value = self.config.api_version },
        };

        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(body));

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status.class() != .success) {
            logger.err("Claude API error: status={d} path={s}", .{ @backingInt(response.head.status), path });
            switch (@backingInt(response.head.status)) {
                401 => return provider.ProviderError.AuthFailed,
                429 => return provider.ProviderError.RateLimit,
                400 => return provider.ProviderError.InvalidRequest,
                else => return provider.ProviderError.ServerError,
            }
        }

        var body_buf: [1024 * 1024]u8 = undefined;
        const reader = response.reader(&body_buf);
        return reader.allocRemaining(self.allocator, .limited(1024 * 1024));
    }

    fn parseResponse(self: *Self, body: []const u8) !provider.CompleteResponse {
        // Parse into a response-owned arena so free() can release the DOM.
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch
            return provider.ProviderError.InvalidRequest;

        // Check for Anthropic error format
        if (parsed.object.get("error")) |err_val| {
            if (err_val.object.get("type")) |err_type| {
                if (std.mem.eql(u8, err_type.string, "authentication_error"))
                    return provider.ProviderError.AuthFailed;
                if (std.mem.eql(u8, err_type.string, "rate_limit_error"))
                    return provider.ProviderError.RateLimit;
            }
            return provider.ProviderError.InvalidRequest;
        }

        const content_arr = parsed.object.get("content") orelse return provider.ProviderError.InvalidRequest;

        var content_blocks: std.ArrayList(provider.ContentBlock) = .empty;
        for (content_arr.array.items) |block| {
            const block_type = block.object.get("type") orelse continue;
            if (std.mem.eql(u8, block_type.string, "text")) {
                const text = block.object.get("text") orelse continue;
                if (text.string.len > 0) {
                    try content_blocks.append(self.allocator, .{ .text = text.string });
                }
            } else if (std.mem.eql(u8, block_type.string, "tool_use")) {
                const id = block.object.get("id") orelse continue;
                const name = block.object.get("name") orelse continue;
                const input = block.object.get("input") orelse continue;

                try content_blocks.append(self.allocator, .{
                    .tool_use = .{
                        .id = id.string,
                        .name = name.string,
                        .input = input,
                    },
                });
            } else if (std.mem.eql(u8, block_type.string, "thinking")) {
                const thinking = block.object.get("thinking") orelse continue;
                if (thinking.string.len > 0) {
                    try content_blocks.append(self.allocator, .{ .thinking = thinking.string });
                }
            }
        }

        const stop_reason: provider.CompleteResponse.StopReason = blk: {
            if (parsed.object.get("stop_reason")) |sr| {
                if (sr == .string) {
                    if (std.mem.eql(u8, sr.string, "end_turn")) break :blk .end_turn;
                    if (std.mem.eql(u8, sr.string, "max_tokens")) break :blk .max_tokens;
                    if (std.mem.eql(u8, sr.string, "stop_sequence")) break :blk .stop_sequence;
                    if (std.mem.eql(u8, sr.string, "tool_use")) break :blk .tool_use;
                }
            }
            break :blk .end_turn;
        };

        const usage_obj = parsed.object.get("usage");
        const usage: provider.Usage = if (usage_obj) |u| .{
            .input_tokens = @intCast(u.object.get("input_tokens").?.integer),
            .output_tokens = @intCast(u.object.get("output_tokens").?.integer),
        } else .{ .input_tokens = 0, .output_tokens = 0 };

        return .{
            .content = try content_blocks.toOwnedSlice(self.allocator),
            .usage = usage,
            .stop_reason = stop_reason,
            .dom_arena = arena,
        };
    }
};

test "Claude provider creation" {
    const config = ClaudeConfig{
        .api_key = "test-key",
        .model = "claude-sonnet-4-6",
    };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = ClaudeProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const prov = p.toProvider();
    try std.testing.expect(prov.supportsStreaming());
    try std.testing.expect(prov.supportsToolUse());
}

test "Claude build request body" {
    const config = ClaudeConfig{
        .api_key = "test-key",
    };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = ClaudeProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const msgs = [_]provider.Message{
        .{
            .role = .user,
            .content = &.{.{ .text = "Hello" }},
            .timestamp = 0,
        },
    };
    const body = try p.buildRequestBody(&msgs, .{ .max_tokens = 100, .temperature = 0.5 }, false);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-sonnet-4-6\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.50") != null);
}

test "Claude system prompt extraction" {
    const config = ClaudeConfig{ .api_key = "test-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = ClaudeProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const msgs = [_]provider.Message{
        .{
            .role = .system,
            .content = &.{.{ .text = "You are helpful." }},
            .timestamp = 0,
        },
        .{
            .role = .user,
            .content = &.{.{ .text = "Hi" }},
            .timestamp = 0,
        },
    };
    const body = try p.buildRequestBody(&msgs, .{ .max_tokens = 50, .temperature = 0.7 }, false);
    defer std.testing.allocator.free(body);

    // System prompt should be top-level, not in messages array
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"You are helpful.\"") != null);
}

test "Claude parseResponse extracts text content" {
    const config = ClaudeConfig{ .api_key = "test-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = ClaudeProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const response_json =
        \\{"id":"msg_123","type":"message","role":"assistant","content":[{"type":"text","text":"Hello from Claude!"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}
    ;
    const resp = try p.parseResponse(response_json);
    defer resp.free(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expectEqualStrings("Hello from Claude!", resp.content[0].text);
    try std.testing.expectEqual(provider.CompleteResponse.StopReason.end_turn, resp.stop_reason);
    try std.testing.expectEqual(@as(u32, 10), resp.usage.input_tokens);
    try std.testing.expectEqual(@as(u32, 5), resp.usage.output_tokens);
}

test "Claude parseResponse handles tool_use" {
    const config = ClaudeConfig{ .api_key = "test-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = ClaudeProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const response_json =
        \\{"id":"msg_456","type":"message","role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}],"model":"claude-sonnet-4-6","stop_reason":"tool_use","usage":{"input_tokens":20,"output_tokens":15}}
    ;
    const resp = try p.parseResponse(response_json);
    defer resp.free(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expect(resp.content[0] == .tool_use);
    try std.testing.expectEqualStrings("Bash", resp.content[0].tool_use.name);
    try std.testing.expectEqual(provider.CompleteResponse.StopReason.tool_use, resp.stop_reason);
}

test "Claude parseResponse detects auth error" {
    const config = ClaudeConfig{ .api_key = "bad-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = ClaudeProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const error_json =
        \\{"error":{"type":"authentication_error","message":"invalid x-api-key"}}
    ;
    const result = p.parseResponse(error_json);
    try std.testing.expectError(provider.ProviderError.AuthFailed, result);
}

test "Claude buildRequestBody streaming flag" {
    const config = ClaudeConfig{ .api_key = "test-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = ClaudeProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const msgs = [_]provider.Message{
        .{
            .role = .user,
            .content = &.{.{ .text = "Hi" }},
            .timestamp = 0,
        },
    };
    const body_stream = try p.buildRequestBody(&msgs, .{ .max_tokens = 50, .temperature = 0.7 }, true);
    defer std.testing.allocator.free(body_stream);
    try std.testing.expect(std.mem.indexOf(u8, body_stream, "\"stream\":true") != null);

    const body_nostream = try p.buildRequestBody(&msgs, .{ .max_tokens = 50, .temperature = 0.7 }, false);
    defer std.testing.allocator.free(body_nostream);
    try std.testing.expect(std.mem.indexOf(u8, body_nostream, "\"stream\"") == null);
}
