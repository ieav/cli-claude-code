/// OpenAI backend — implements ProviderVTable for GPT-4 / GPT-4o / GPT-3.5 models.
/// Uses the Chat Completions API (https://api.openai.com/v1/chat/completions).

const std = @import("std");
const provider = @import("provider.zig");
const message = @import("message.zig");
const streaming_mod = @import("streaming.zig");

pub const OpenAIConfig = struct {
    api_key: []const u8,
    model: []const u8 = "gpt-4o",
    base_url: []const u8 = "https://api.openai.com/v1",
    organization: ?[]const u8 = null,
};

pub const OpenAIProvider = struct {
    allocator: std.mem.Allocator,
    config: OpenAIConfig,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: OpenAIConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .http_client = .{ .allocator = allocator },
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

        const response_body = try self.sendRequest("/chat/completions", body);
        defer self.allocator.free(response_body);

        return self.parseResponse(response_body);
    }

    fn stream(ptr: *anyopaque, messages: []const provider.Message, opts: provider.CompleteOptions, cb: *provider.StreamCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const body = try self.buildRequestBody(messages, opts, true);
        defer self.allocator.free(body);

        var sse_parser = streaming_mod.SSEParser.init(self.allocator);
        defer sse_parser.deinit();

        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.config.base_url});
        defer self.allocator.free(uri_str);
        const uri = try std.Uri.parse(uri_str);

        // Build auth header
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key});
        defer self.allocator.free(auth_header);

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("content-type", "application/json");
        try headers.append("authorization", auth_header);

        var req = try self.http_client.open(.POST, uri, .{
            .headers = headers,
        });
        defer req.deinit();
        req.transfer_type = .chunked;

        try req.send();
        try req.writer().writeAll(body);
        try req.finish();

        // Read streaming response
        var recv_buf: [4096]u8 = undefined;
        var total_usage: ?provider.Usage = null;

        while (true) {
            const n = try req.reader().read(&recv_buf);
            if (n == 0) break;

            _ = try sse_parser.feed(recv_buf[0..n]);
            const events = sse_parser.drain();
            defer self.allocator.free(events);

            for (events) |evt| {
                if (evt.data) |data| {
                    if (std.mem.eql(u8, data, "[DONE]")) {
                        try cb(.{ .done = total_usage });
                        return;
                    }
                    if (parseOpenAIStreamChunk(data)) |stream_event| {
                        switch (stream_event) {
                            .done => |u| {
                                if (u) |new_usage| total_usage = new_usage;
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
        // Rough estimate: ~4 chars per token for English
        return @intCast(text.len / 4);
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
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{\"model\":");
        try message.writeJsonString(writer, self.config.model);
        try writer.writeAll(",\"messages\":");

        // Serialize messages using the shared serializer
        // Convert to OpenAI format: system/user/assistant/tool roles map directly
        try writer.writeAll("[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"role\":");
            const role_str: []const u8 = switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
            };
            try message.writeJsonString(writer, role_str);
            try writer.writeAll(",\"content\":");

            if (msg.content.len == 1 and msg.content[0] == .text) {
                try message.writeJsonString(writer, msg.content[0].text);
            } else if (msg.content.len > 0) {
                // OpenAI content blocks format
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
                            try writer.writeAll("{\"type\":\"function\",\"id\":");
                            try message.writeJsonString(writer, tu.id);
                            try writer.writeAll(",\"function\":{\"name\":");
                            try message.writeJsonString(writer, tu.name);
                            try writer.writeAll(",\"arguments\":");
                            var arg_buf = std.ArrayList(u8).init(self.allocator);
                            try std.json.stringify(tu.input, .{}, arg_buf.writer());
                            try writer.writeAll(arg_buf.items);
                            arg_buf.deinit();
                            try writer.writeAll("}}");
                        },
                        .tool_result => |tr| {
                            try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                            try message.writeJsonString(writer, tr.tool_use_id);
                            try writer.writeAll(",\"content\":");
                            try message.writeJsonString(writer, tr.content);
                            try writer.writeAll("}");
                        },
                        .thinking => |t| {
                            // OpenAI doesn't have thinking blocks; store as text
                            try writer.writeAll("{\"type\":\"text\",\"text\":");
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
        }
        try writer.writeAll("]");

        // Options
        try writer.print(",\"max_tokens\":{d}", .{opts.max_tokens});
        try writer.print(",\"temperature\":{d:.2}", .{opts.temperature});

        if (do_stream) {
            try writer.writeAll(",\"stream\":true");
        }

        if (opts.stop_sequences) |seqs| {
            try writer.writeAll(",\"stop\":[");
            for (seqs, 0..) |s, i| {
                if (i > 0) try writer.writeAll(",");
                try message.writeJsonString(writer, s);
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("}");
        return buf.toOwnedSlice();
    }

    fn sendRequest(self: *Self, path: []const u8, body: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.config.base_url, path });
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key});
        defer self.allocator.free(auth_header);

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("content-type", "application/json");
        try headers.append("authorization", auth_header);

        var req = try self.http_client.open(.POST, uri, .{
            .headers = headers,
        });
        defer req.deinit();
        req.transfer_type = .chunked;

        try req.send();
        try req.writer().writeAll(body);
        try req.finish();

        try req.wait();
        const status = req.response.status;
        if (status.class() != .success) {
            switch (status.code) {
                401 => return provider.ProviderError.AuthFailed,
                429 => return provider.ProviderError.RateLimit,
                400 => return provider.ProviderError.InvalidRequest,
                else => return provider.ProviderError.ServerError,
            }
        }

        const body_reader = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return body_reader;
    }

    fn parseResponse(self: *Self, body: []const u8) !provider.CompleteResponse {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, body) catch
            return provider.ProviderError.InvalidRequest;

        const choices = parsed.object.get("choices") orelse return provider.ProviderError.InvalidRequest;
        if (choices.array.items.len == 0) return provider.ProviderError.InvalidRequest;

        const choice = choices.array.items[0];
        const message_obj = choice.object.get("message") orelse return provider.ProviderError.InvalidRequest;
        const content = message_obj.object.get("content") orelse return provider.ProviderError.InvalidRequest;
        const finish_reason = choice.object.get("finish_reason");

        var content_blocks = std.ArrayList(provider.ContentBlock).init(self.allocator);
        if (content == .string and content.string.len > 0) {
            try content_blocks.append(.{ .text = content.string });
        }

        // Check for tool calls
        if (message_obj.object.get("tool_calls")) |tool_calls| {
            for (tool_calls.array.items) |tc| {
                const func = tc.object.get("function") orelse continue;
                const name = func.object.get("name") orelse continue;
                const arguments = func.object.get("arguments") orelse continue;
                const id = tc.object.get("id") orelse continue;

                const args_json = std.json.parseFromSliceLeaky(std.json.Value, arguments.string) catch
                    std.json.Value{ .null = {} };

                try content_blocks.append(.{
                    .tool_use = .{
                        .id = id.string,
                        .name = name.string,
                        .input = args_json,
                    },
                });
            }
        }

        const stop_reason: provider.CompleteResponse.StopReason = blk: {
            if (finish_reason) |fr| {
                if (fr == .string) {
                    if (std.mem.eql(u8, fr.string, "stop")) break :blk .end_turn;
                    if (std.mem.eql(u8, fr.string, "length")) break :blk .max_tokens;
                    if (std.mem.eql(u8, fr.string, "tool_calls")) break :blk .tool_use;
                }
            }
            break :blk .end_turn;
        };

        const usage_obj = parsed.object.get("usage");
        const usage: provider.Usage = if (usage_obj) |u| .{
            .input_tokens = @intCast(u.object.get("prompt_tokens").?.integer),
            .output_tokens = @intCast(u.object.get("completion_tokens").?.integer),
        } else .{ .input_tokens = 0, .output_tokens = 0 };

        return .{
            .content = try content_blocks.toOwnedSlice(),
            .usage = usage,
            .stop_reason = stop_reason,
        };
    }

    /// Parse an OpenAI streaming chunk (data: {...}) into a StreamEvent.
    fn parseOpenAIStreamChunk(data: []const u8) ?provider.StreamEvent {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, data) catch return null;

        const choices = parsed.object.get("choices") orelse return null;
        if (choices.array.items.len == 0) return null;

        const choice = choices.array.items[0];
        const delta = choice.object.get("delta") orelse return null;

        // Content delta
        if (delta.object.get("content")) |content| {
            if (content == .string and content.string.len > 0) {
                return .{ .content_delta = content.string };
            }
        }

        // Tool call delta
        if (delta.object.get("tool_calls")) |tool_calls| {
            if (tool_calls.array.items.len > 0) {
                const tc = tool_calls.array.items[0];
                if (tc.object.get("function")) |func| {
                    if (func.object.get("name")) |name| {
                        return .{
                            .tool_call = .{
                                .id = tc.object.get("id").?.string,
                                .name = name.string,
                                .input = std.json.Value{ .object = .{} },
                            },
                        };
                    }
                }
            }
        }

        // Finish reason
        if (choice.object.get("finish_reason")) |fr| {
            if (fr == .string and fr.string.len > 0) {
                return .{ .done = null };
            }
        }

        return null;
    }
};

test "OpenAI provider creation" {
    const config = OpenAIConfig{
        .api_key = "test-key",
        .model = "gpt-4o",
    };
    var p = OpenAIProvider.init(std.testing.allocator, config);
    defer p.deinit();

    const prov = p.toProvider();
    try std.testing.expect(prov.supportsStreaming());
    try std.testing.expect(prov.supportsToolUse());
}

test "OpenAI build request body" {
    const config = OpenAIConfig{
        .api_key = "test-key",
    };
    var p = OpenAIProvider.init(std.testing.allocator, config);
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

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.50") != null);
}
