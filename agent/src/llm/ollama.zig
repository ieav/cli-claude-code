/// Ollama backend -- implements ProviderVTable for local Ollama models.
/// Uses Ollama's /api/chat endpoint (https://github.com/ollama/ollama).
/// Compatible with Zig 0.16 HTTP Client API.
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
    io: std.Io,
    config: OllamaConfig,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: OllamaConfig) Self {
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
                .count_tokens_fn = null,
                .supports_tool_use_fn = supportsToolUse,
                .supports_streaming_fn = supportsStreaming,
                .deinit_fn = deinitVTable,
            },
        };
    }

    // -- VTable implementations --

    fn complete(ptr: *anyopaque, messages: []const provider.Message, opts: provider.CompleteOptions) anyerror!provider.CompleteResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const body = try self.buildRequestBody(messages, opts, false);
        defer self.allocator.free(body);

        const response_body = try self.sendRequest("/api/chat", body);
        defer self.allocator.free(response_body);

        return self.parseChatResponse(response_body);
    }

    fn stream(ptr: *anyopaque, messages: []const provider.Message, opts: provider.CompleteOptions, ctx: ?*anyopaque, cb: *const provider.StreamCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const body = try self.buildRequestBody(messages, opts, true);
        defer self.allocator.free(body);

        const uri_str = try self.allocator.print("{s}/api/chat", .{self.config.base_url});
        defer self.allocator.free(uri_str);
        const uri = try std.Uri.parse(uri_str);

        // Ollama is local -- no auth headers needed
        const extra_headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(body));

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status.class() != .success) {
            switch (@backingInt(response.head.status)) {
                400 => return provider.ProviderError.InvalidRequest,
                404 => return provider.ProviderError.InvalidRequest,
                else => return provider.ProviderError.ServerError,
            }
        }

        // Ollama streaming: each line is a JSON object (line-delimited, not SSE)
        // Read chunks and parse line by line incrementally
        var resp_read_buf: [8192]u8 = undefined;
        const resp_reader = response.reader(&resp_read_buf);
        var chunk_buf: [4096]u8 = undefined;

        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);
        var total_usage: ?provider.Usage = null;

        while (true) {
            // Incremental read: take whatever is buffered right now (at least
            // one byte) instead of waiting for the 4 KiB buffer to fill —
            // readSliceShort buffered the whole SSE response before parsing,
            // killing real-time streaming.
            const avail = resp_reader.peekGreedy(1) catch break;
            if (avail.len == 0) break;
            const n = @min(avail.len, chunk_buf.len);
            @memcpy(chunk_buf[0..n], avail[0..n]);
            resp_reader.toss(n);

            for (chunk_buf[0..n]) |byte| {
                if (byte == '\n') {
                    if (line_buf.items.len > 0) {
                        if (parseOllamaStreamLine(line_buf.items)) |event| {
                            switch (event) {
                                .done => |u| {
                                    if (u) |new_usage| total_usage = new_usage;
                                },
                                else => try cb(ctx, event),
                            }
                        }
                        line_buf.shrinkRetainingCapacity(0);
                    }
                } else {
                    line_buf.append(self.allocator, byte) catch {};
                }
            }
        }

        // Handle remaining partial line
        if (line_buf.items.len > 0) {
            if (parseOllamaStreamLine(line_buf.items)) |event| {
                switch (event) {
                    .done => |u| {
                        if (u) |new_usage| total_usage = new_usage;
                    },
                    else => try cb(ctx, event),
                }
            }
        }

        try cb(ctx, .{ .done = total_usage });
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

    // -- Internal helpers --

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

            // Flatten content blocks to plain text for Ollama
            if (msg.content.len == 1 and msg.content[0] == .text) {
                try message.writeJsonString(writer, msg.content[0].text);
            } else {
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

        try writer.writeAll(",\"options\":{\"num_predict\":");
        try writer.print("{d}", .{opts.max_tokens});
        try writer.writeAll(",\"temperature\":");
        try writer.print("{d:.2}", .{opts.temperature});
        try writer.writeAll("}");

        if (do_stream) {
            try writer.writeAll(",\"stream\":true");
        }

        try writer.writeAll("}");

        buf = aw.toArrayList();
        return buf.toOwnedSlice(self.allocator);
    }

    fn sendRequest(self: *Self, path: []const u8, body: []const u8) ![]u8 {
        const url = try self.allocator.print("{s}{s}", .{ self.config.base_url, path });
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);

        // Ollama is local -- no auth headers needed
        const extra_headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(body));

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status.class() != .success) {
            switch (@backingInt(response.head.status)) {
                400 => return provider.ProviderError.InvalidRequest,
                404 => return provider.ProviderError.InvalidRequest,
                else => return provider.ProviderError.ServerError,
            }
        }

        var body_buf: [1024 * 1024]u8 = undefined;
        const reader = response.reader(&body_buf);
        return reader.allocRemaining(self.allocator, .limited(1024 * 1024));
    }

    fn parseChatResponse(self: *Self, body: []const u8) !provider.CompleteResponse {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.allocator, body, .{}) catch
            return provider.ProviderError.InvalidRequest;

        var content_blocks: std.ArrayList(provider.ContentBlock) = .empty;
        errdefer content_blocks.deinit(self.allocator);

        if (parsed.object.get("message")) |msg| {
            if (msg.object.get("content")) |content| {
                if (content == .string and content.string.len > 0) {
                    try content_blocks.append(self.allocator, .{ .text = content.string });
                }
            }

            if (msg.object.get("tool_calls")) |tool_calls| {
                for (tool_calls.array.items) |tc| {
                    const func = tc.object.get("function") orelse continue;
                    const name = func.object.get("name") orelse continue;
                    const arguments = func.object.get("arguments") orelse continue;

                    const args_json = if (arguments == .string)
                        std.json.parseFromSliceLeaky(std.json.Value, self.allocator, arguments.string, .{}) catch
                            std.json.Value{ .null = {} }
                    else
                        arguments;

                    try content_blocks.append(self.allocator, .{
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
            .content = try content_blocks.toOwnedSlice(self.allocator),
            .usage = usage,
            .stop_reason = stop_reason,
        };
    }

    fn parseOllamaStreamLine(line: []const u8) ?provider.StreamEvent {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.smp_allocator, line, .{}) catch return null;

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

        if (parsed.object.get("message")) |msg| {
            if (msg.object.get("content")) |content| {
                if (content == .string and content.string.len > 0) {
                    return .{ .content_delta = content.string };
                }
            }
        }

        return null;
    }

    pub fn isRunning(self: *Self) bool {
        const url = self.allocator.print("{s}/api/tags", .{self.config.base_url}) catch return false;
        defer self.allocator.free(url);
        const uri = std.Uri.parse(url) catch return false;

        const extra_headers = [_]std.http.Header{};

        var req = self.http_client.request(.GET, uri, .{
            .extra_headers = &extra_headers,
        }) catch return false;
        defer req.deinit();

        req.sendBodyComplete(@constCast("")) catch return false;

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return false;

        return response.head.status.class() == .success;
    }

    pub fn listModels(self: *Self) ![]const []const u8 {
        const body = try self.sendRequest("/api/tags", "");
        defer self.allocator.free(body);

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.allocator, body, .{}) catch return error.InvalidRequest;
        const models_array = parsed.object.get("models") orelse return error.InvalidRequest;

        var names: std.ArrayList([]const u8) = .empty;
        for (models_array.array.items) |m| {
            if (m.object.get("name")) |name| {
                if (name == .string) {
                    try names.append(self.allocator, name.string);
                }
            }
        }
        return names.toOwnedSlice(self.allocator);
    }
};

test "Ollama provider creation" {
    const config = OllamaConfig{
        .model = "llama3.2",
    };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = OllamaProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const prov = p.toProvider();
    try std.testing.expect(prov.supportsStreaming());
    try std.testing.expect(prov.supportsToolUse());
}
