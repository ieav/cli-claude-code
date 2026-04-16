/// Ollama backend — implements ProviderVTable for local Ollama models.
/// Uses Ollama's /api/chat endpoint (https://github.com/ollama/ollama).

const std = @import("std");
const provider = @import("provider.zig");
const message = @import("message.zig");

pub const OllamaConfig = struct {
    model: []const u8 = "llama3.2",
    base_url: []const u8 = "http://localhost:11434",
    keep_alive: []const u8 = "5m",
};

pub const OllamaProvider = struct {
    allocator: std.mem.Allocator,
    config: OllamaConfig,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: OllamaConfig) Self {
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
                .count_tokens_fn = null,
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

        const response_body = try self.sendRequest("/api/chat", body);
        defer self.allocator.free(response_body);

        return self.parseChatResponse(response_body);
    }

    fn stream(ptr: *anyopaque, messages: []const provider.Message, opts: provider.CompleteOptions, cb: *provider.StreamCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const body = try self.buildRequestBody(messages, opts, true);
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/chat", .{self.config.base_url});
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("content-type", "application/json");

        var req = try self.http_client.open(.POST, uri, .{
            .headers = headers,
        });
        defer req.deinit();
        req.transfer_type = .chunked;

        try req.send();
        try req.writer().writeAll(body);
        try req.finish();

        // Ollama streaming: each line is a JSON object
        var line_buf = std.ArrayList(u8).init(self.allocator);
        defer line_buf.deinit();
        var total_usage: ?provider.Usage = null;
        var recv_buf: [4096]u8 = undefined;

        while (true) {
            const n = try req.reader().read(&recv_buf);
            if (n == 0) break;

            for (recv_buf[0..n]) |byte| {
                if (byte == '\n') {
                    if (line_buf.items.len > 0) {
                        if (parseOllamaStreamLine(line_buf.items)) |event| {
                            switch (event) {
                                .done => |u| {
                                    if (u) |new_usage| total_usage = new_usage;
                                },
                                else => try cb(event),
                            }
                        }
                        line_buf.clearRetainingCapacity();
                    }
                } else {
                    try line_buf.append(byte);
                }
            }
        }

        // Process any remaining data
        if (line_buf.items.len > 0) {
            if (parseOllamaStreamLine(line_buf.items)) |event| {
                switch (event) {
                    .done => |u| {
                        if (u) |new_usage| total_usage = new_usage;
                    },
                    else => try cb(event),
                }
            }
        }

        try cb(.{ .done = total_usage });
    }

    fn supportsToolUse(ptr: *anyopaque) bool {
        _ = ptr;
        return true; // Ollama supports function calling for compatible models
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

            // Flatten content blocks to plain text for Ollama
            if (msg.content.len == 1 and msg.content[0] == .text) {
                try message.writeJsonString(writer, msg.content[0].text);
            } else {
                // Concatenate all text blocks
                try writer.writeAll("\"");
                for (msg.content) |block| {
                    switch (block) {
                        .text => |t| {
                            for (t) |c| {
                                switch (c) {
                                    '"' => try writer.writeAll("\\\""),
                                    '\\' => try writer.writeAll("\\\\"),
                                    '\n' => try writer.writeAll("\\n"),
                                    else => try writer.writeByte(c),
                                }
                            }
                        },
                        else => {},
                    }
                }
                try writer.writeAll("\"");
            }
            try writer.writeAll("}");
        }

        try writer.writeAll("]");

        // Ollama options format
        try writer.writeAll(",\"options\":{\"num_predict\":");
        try writer.print("{d}", .{opts.max_tokens});
        try writer.writeAll(",\"temperature\":");
        try writer.print("{d:.2}", .{opts.temperature});
        try writer.writeAll("}");

        if (do_stream) {
            try writer.writeAll(",\"stream\":true");
        }

        try writer.writeAll("}");
        return buf.toOwnedSlice();
    }

    fn sendRequest(self: *Self, path: []const u8, body: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.config.base_url, path });
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("content-type", "application/json");

        var req = try self.http_client.open(.POST, uri, .{
            .headers = headers,
        });
        defer req.deinit();
        req.transfer_type = .chunked;

        try req.send();
        try req.writer().writeAll(body);
        try req.finish();

        try req.wait();

        // Check for connection refused (Ollama not running)
        const status = req.response.status;
        if (status.code == 0) return provider.ProviderError.ServerError;
        if (status.class() != .success) {
            switch (status.code) {
                400 => return provider.ProviderError.InvalidRequest,
                404 => return provider.ProviderError.InvalidRequest,
                else => return provider.ProviderError.ServerError,
            }
        }

        return try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
    }

    fn parseChatResponse(self: *Self, body: []const u8) !provider.CompleteResponse {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, body) catch
            return provider.ProviderError.InvalidRequest;

        var content_blocks = std.ArrayList(provider.ContentBlock).init(self.allocator);
        errdefer content_blocks.deinit();

        // Ollama response format: {"message":{"role":"assistant","content":"..."},"done":true}
        if (parsed.object.get("message")) |msg| {
            if (msg.object.get("content")) |content| {
                if (content == .string and content.string.len > 0) {
                    try content_blocks.append(.{ .text = content.string });
                }
            }

            // Check for tool calls
            if (msg.object.get("tool_calls")) |tool_calls| {
                for (tool_calls.array.items) |tc| {
                    const func = tc.object.get("function") orelse continue;
                    const name = func.object.get("name") orelse continue;
                    const arguments = func.object.get("arguments") orelse continue;

                    const args_json = if (arguments == .string)
                        std.json.parseFromSliceLeaky(std.json.Value, arguments.string) catch
                            std.json.Value{ .null = {} }
                    else
                        arguments;

                    try content_blocks.append(.{
                        .tool_use = .{
                            .id = "ollama_tool",
                            .name = name.string,
                            .input = args_json,
                        },
                    });
                }
            }
        }

        const done = parsed.object.get("done");
        const stop_reason: provider.CompleteResponse.StopReason = if (done) |d|
            if (d == .bool and d.bool) .end_turn else .end_turn
        else
            .end_turn;

        // Ollama includes eval_count / prompt_eval_count for usage
        const usage: provider.Usage = blk: {
            var input_tokens: u32 = 0;
            var output_tokens: u32 = 0;
            if (parsed.object.get("prompt_eval_count")) |pe| {
                input_tokens = @intCast(pe.integer);
            }
            if (parsed.object.get("eval_count")) |ec| {
                output_tokens = @intCast(ec.integer);
            }
            break :blk .{ .input_tokens = input_tokens, .output_tokens = output_tokens };
        };

        return .{
            .content = try content_blocks.toOwnedSlice(),
            .usage = usage,
            .stop_reason = stop_reason,
        };
    }

    /// Parse a single Ollama streaming line into a StreamEvent.
    fn parseOllamaStreamLine(line: []const u8) ?provider.StreamEvent {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, line) catch return null;

        // Check if done
        if (parsed.object.get("done")) |done| {
            if (done == .bool and done.bool) {
                var usage: ?provider.Usage = null;
                if (parsed.object.get("prompt_eval_count")) |pe| {
                    if (parsed.object.get("eval_count")) |ec| {
                        usage = .{
                            .input_tokens = @intCast(pe.integer),
                            .output_tokens = @intCast(ec.integer),
                        };
                    }
                }
                return .{ .done = usage };
            }
        }

        // Content delta
        if (parsed.object.get("message")) |msg| {
            if (msg.object.get("content")) |content| {
                if (content == .string and content.string.len > 0) {
                    return .{ .content_delta = content.string };
                }
            }
        }

        return null;
    }

    /// Check if Ollama is running by hitting /api/tags.
    pub fn isRunning(self: *Self) bool {
        const url = std.fmt.allocPrint(self.allocator, "{s}/api/tags", .{self.config.base_url}) catch return false;
        defer self.allocator.free(url);
        const uri = std.Uri.parse(url) catch return false;

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();

        var req = self.http_client.open(.GET, uri, .{
            .headers = headers,
        }) catch return false;
        defer req.deinit();

        req.send() catch return false;
        req.finish() catch return false;
        req.wait() catch return false;

        return req.response.status.class() == .success;
    }

    /// List available models.
    pub fn listModels(self: *Self) ![]const []const u8 {
        const body = try self.sendRequest("/api/tags", "");
        defer self.allocator.free(body);

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, body);
        const models_array = parsed.object.get("models") orelse return error.InvalidRequest;

        var names = std.ArrayList([]const u8).init(self.allocator);
        for (models_array.array.items) |m| {
            if (m.object.get("name")) |name| {
                if (name == .string) {
                    try names.append(name.string);
                }
            }
        }
        return names.toOwnedSlice();
    }
};

test "Ollama provider creation" {
    const config = OllamaConfig{
        .model = "llama3.2",
    };
    var p = OllamaProvider.init(std.testing.allocator, config);
    defer p.deinit();

    const prov = p.toProvider();
    try std.testing.expect(prov.supportsStreaming());
    try std.testing.expect(prov.supportsToolUse());
}

test "Ollama build request body" {
    const config = OllamaConfig{};
    var p = OllamaProvider.init(std.testing.allocator, config);
    defer p.deinit();

    const msgs = [_]provider.Message{
        .{
            .role = .user,
            .content = &.{.{ .text = "Hello from Ollama" }},
            .timestamp = 0,
        },
    };
    const body = try p.buildRequestBody(&msgs, .{ .max_tokens = 256, .temperature = 0.8 }, false);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"llama3.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") == null); // no stream param for non-streaming
}

test "Ollama parse stream line" {
    const line = "{\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}";
    const event = OllamaProvider.parseOllamaStreamLine(line);
    try std.testing.expect(event != null);
    switch (event.?) {
        .content_delta => |text| {
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => try std.testing.expect(false),
    }

    const done_line = "{\"done\":true,\"eval_count\":10,\"prompt_eval_count\":5}";
    const done_event = OllamaProvider.parseOllamaStreamLine(done_line);
    try std.testing.expect(done_event != null);
    switch (done_event.?) {
        .done => |usage| {
            try std.testing.expect(usage != null);
            try std.testing.expectEqual(@as(u32, 5), usage.?.input_tokens);
            try std.testing.expectEqual(@as(u32, 10), usage.?.output_tokens);
        },
        else => try std.testing.expect(false),
    }
}
