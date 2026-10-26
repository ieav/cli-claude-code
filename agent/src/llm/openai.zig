/// OpenAI backend — implements ProviderVTable for GPT-4 / GPT-4o / GPT-3.5 models.
/// Uses the Chat Completions API (https://api.openai.com/v1/chat/completions).
/// Compatible with Zig 0.16 HTTP Client API.
const std = @import("std");
const provider = @import("provider.zig");
const message = @import("message.zig");
const streaming_mod = @import("streaming.zig");
const logger = @import("../util/log.zig");

pub const OpenAIConfig = struct {
    api_key: []const u8,
    model: []const u8 = "gpt-4o",
    base_url: []const u8 = "https://api.openai.com/v1",
    organization: ?[]const u8 = null,
};

pub const OpenAIProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: OpenAIConfig,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: OpenAIConfig) Self {
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

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key});
        defer self.allocator.free(auth_header);

        const extra_headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
        };

        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(body));

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status.class() != .success) {
            logger.err("OpenAI stream error: status={d}", .{@backingInt(response.head.status)});
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
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &buf);
        const writer = &aw.writer;

        try writer.writeAll("{\"model\":");
        try message.writeJsonString(writer, self.config.model);
        try writer.writeAll(",\"messages\":[");

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
                            try std.json.Stringify.value(tu.input, .{}, writer);
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

        buf = aw.toArrayList();
        return buf.toOwnedSlice(self.allocator);
    }

    fn sendRequest(self: *Self, path: []const u8, body: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.config.base_url, path });
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key});
        defer self.allocator.free(auth_header);

        const extra_headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
        };

        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(body));

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status.class() != .success) {
            logger.err("OpenAI API error: status={d} path={s}", .{ @backingInt(response.head.status), path });
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

        const choices = parsed.object.get("choices") orelse return provider.ProviderError.InvalidRequest;
        if (choices.array.items.len == 0) return provider.ProviderError.InvalidRequest;

        const choice = choices.array.items[0];
        const message_obj = choice.object.get("message") orelse return provider.ProviderError.InvalidRequest;
        const content = message_obj.object.get("content") orelse return provider.ProviderError.InvalidRequest;
        const finish_reason = choice.object.get("finish_reason");

        var content_blocks: std.ArrayList(provider.ContentBlock) = .empty;
        if (content == .string and content.string.len > 0) {
            try content_blocks.append(self.allocator, .{ .text = content.string });
        }

        if (message_obj.object.get("tool_calls")) |tool_calls| {
            for (tool_calls.array.items) |tc| {
                const func = tc.object.get("function") orelse continue;
                const name = func.object.get("name") orelse continue;
                const arguments = func.object.get("arguments") orelse continue;
                const id = tc.object.get("id") orelse continue;

                const args_json = std.json.parseFromSliceLeaky(std.json.Value, self.allocator, arguments.string, .{}) catch
                    std.json.Value{ .null = {} };

                try content_blocks.append(self.allocator, .{
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
            .content = try content_blocks.toOwnedSlice(self.allocator),
            .usage = usage,
            .stop_reason = stop_reason,
            .dom_arena = arena,
        };
    }

    fn parseOpenAIStreamChunk(data: []const u8) ?provider.StreamEvent {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.smp_allocator, data, .{}) catch return null;

        const choices = parsed.object.get("choices") orelse return null;
        if (choices.array.items.len == 0) return null;

        const choice = choices.array.items[0];
        const delta = choice.object.get("delta") orelse return null;

        if (delta.object.get("content")) |content| {
            if (content == .string and content.string.len > 0) {
                return .{ .content_delta = content.string };
            }
        }

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
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = OpenAIProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const prov = p.toProvider();
    try std.testing.expect(prov.supportsStreaming());
    try std.testing.expect(prov.supportsToolUse());
}

test "OpenAI parseStreamChunk extracts content delta" {
    const chunk_data =
        \\{"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
    ;
    const event = OpenAIProvider.parseOpenAIStreamChunk(chunk_data);
    try std.testing.expect(event != null);
    switch (event.?) {
        .content_delta => |text| {
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => try std.testing.expect(false),
    }
}

test "OpenAI parseStreamChunk detects finish" {
    const chunk_data =
        \\{"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
    ;
    const event = OpenAIProvider.parseOpenAIStreamChunk(chunk_data);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .done);
}

test "OpenAI parseStreamChunk returns null for empty delta" {
    const chunk_data =
        \\{"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":null}]}
    ;
    const event = OpenAIProvider.parseOpenAIStreamChunk(chunk_data);
    try std.testing.expect(event == null);
}

test "OpenAI parseStreamChunk handles tool call delta" {
    const chunk_data =
        \\{"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"Bash","arguments":""}}]},"finish_reason":null}]}
    ;
    const event = OpenAIProvider.parseOpenAIStreamChunk(chunk_data);
    try std.testing.expect(event != null);
    switch (event.?) {
        .tool_call => |tc| {
            try std.testing.expectEqualStrings("Bash", tc.name);
            try std.testing.expectEqualStrings("call_abc", tc.id);
        },
        else => try std.testing.expect(false),
    }
}

test "OpenAI parseResponse extracts content and usage" {
    const config = OpenAIConfig{ .api_key = "test-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = OpenAIProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const body =
        \\{"id":"chatcmpl-123","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hi there!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":3,"total_tokens":11}}
    ;
    const resp = try p.parseResponse(body);
    defer resp.free(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), resp.content.len);
    try std.testing.expectEqualStrings("Hi there!", resp.content[0].text);
    try std.testing.expectEqual(provider.CompleteResponse.StopReason.end_turn, resp.stop_reason);
    try std.testing.expectEqual(@as(u32, 8), resp.usage.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), resp.usage.output_tokens);
}

test "OpenAI buildRequestBody includes stop sequences" {
    const config = OpenAIConfig{ .api_key = "test-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = OpenAIProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const msgs = [_]provider.Message{
        .{
            .role = .user,
            .content = &.{.{ .text = "Hello" }},
            .timestamp = 0,
        },
    };
    const stops = [_][]const u8{ "stop1", "stop2" };
    const body = try p.buildRequestBody(&msgs, .{ .max_tokens = 100, .temperature = 0.5, .stop_sequences = &stops }, false);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"stop\":[\"stop1\",\"stop2\"]") != null);
}
