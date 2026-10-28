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
        var read_err: ?anyerror = null;

        while (true) {
            // Incremental read: take whatever is buffered right now (at least
            // one byte) instead of waiting for the 4 KiB buffer to fill —
            // readSliceShort buffered the whole SSE response before parsing,
            // killing real-time streaming.
            const avail = resp_reader.peekGreedy(1) catch |err| {
                // A mid-stream read failure is NOT EOF: surface it so the
                // caller sees a truncated response instead of a silent
                // "completed" one.
                read_err = err;
                break;
            };
            if (avail.len == 0) break;
            const n = @min(avail.len, chunk_buf.len);
            @memcpy(chunk_buf[0..n], avail[0..n]);
            resp_reader.toss(n);

            for (chunk_buf[0..n]) |byte| {
                if (byte == '\n') {
                    if (line_buf.items.len > 0) {
                        const res = try self.handleStreamLine(line_buf.items, ctx, cb);
                        if (res.usage) |u| total_usage = u;
                        if (res.finished) {
                            try cb(ctx, .{ .done = total_usage });
                            return;
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
            const res = try self.handleStreamLine(line_buf.items, ctx, cb);
            if (res.usage) |u| total_usage = u;
        }

        if (read_err) |e| {
            try cb(ctx, .{ .error_occurred = switch (e) {
                error.ConnectionResetByPeer, error.BrokenPipe => provider.ProviderError.NetworkTimeout,
                else => provider.ProviderError.ServerError,
            } });
            return;
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

        // Ollama wire format: assistant tool_use blocks ride on the message
        // as "tool_calls"; tool results are separate {"role":"tool"} messages
        // that name the tool via "tool_name" (Ollama has no call-id
        // round-trip), so remember id→name pairs seen earlier.
        var id_names = std.ArrayList(IdName).empty;
        defer id_names.deinit(self.allocator);

        var msg_first = true;
        for (messages) |msg| {
            // 1. Tool results first, each as its own message.
            for (msg.content) |block| {
                if (block != .tool_result) continue;
                if (!msg_first) try writer.writeAll(",");
                msg_first = false;
                try writer.writeAll("{\"role\":\"tool\",\"tool_name\":");
                try message.writeJsonString(writer, lookupToolName(id_names.items, block.tool_result.tool_use_id));
                try writer.writeAll(",\"content\":");
                try message.writeJsonString(writer, block.tool_result.content);
                try writer.writeAll("}");
            }

            // 2. Remaining blocks: text/thinking → content, tool_use → tool_calls.
            var content_buf: std.ArrayList(u8) = .empty;
            defer content_buf.deinit(self.allocator);
            var has_tool_use = false;
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| try content_buf.appendSlice(self.allocator, t),
                    .thinking => |t| {
                        if (content_buf.items.len > 0) try content_buf.append(self.allocator, '\n');
                        try content_buf.appendSlice(self.allocator, t);
                    },
                    .tool_use => |tu| {
                        has_tool_use = true;
                        try id_names.append(self.allocator, .{ .id = tu.id, .name = tu.name });
                    },
                    .tool_result => {},
                }
            }
            if (content_buf.items.len == 0 and !has_tool_use) continue;

            if (!msg_first) try writer.writeAll(",");
            msg_first = false;
            try writer.writeAll("{\"role\":");
            const role_str: []const u8 = switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => "user",
            };
            try message.writeJsonString(writer, role_str);
            try writer.writeAll(",\"content\":");
            try message.writeJsonString(writer, content_buf.items);
            if (has_tool_use) {
                try writer.writeAll(",\"tool_calls\":[");
                var tc_first = true;
                for (msg.content) |block| {
                    if (block != .tool_use) continue;
                    if (!tc_first) try writer.writeAll(",");
                    tc_first = false;
                    try writer.writeAll("{\"function\":{\"name\":");
                    try message.writeJsonString(writer, block.tool_use.name);
                    // Ollama takes arguments as a JSON object, not a string.
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(block.tool_use.input, .{}, writer);
                    try writer.writeAll("}}");
                }
                try writer.writeAll("]");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        // Tool declarations (OpenAI-style function objects, Ollama ≥ 0.3).
        if (opts.tools) |tools| {
            try writer.writeAll(",\"tools\":[");
            for (tools, 0..) |tool, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
                try message.writeJsonString(writer, tool.name);
                try writer.writeAll(",\"description\":");
                try message.writeJsonString(writer, tool.description);
                try writer.writeAll(",\"parameters\":");
                try writer.writeAll(tool.input_schema);
                try writer.writeAll("}}");
            }
            try writer.writeAll("]");
        }

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

        // 64 KiB I/O buffer instead of a 1 MiB stack array — see openai.zig.
        var body_buf: [64 * 1024]u8 = undefined;
        const reader = response.reader(&body_buf);
        return reader.allocRemaining(self.allocator, .limited(1024 * 1024));
    }

    fn parseChatResponse(self: *Self, body: []const u8) !provider.CompleteResponse {
        // Response-owned arena: free() releases the DOM (the old leaky parse
        // on the session allocator leaked the whole tree per complete()).
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch
            return provider.ProviderError.InvalidRequest;
        if (parsed != .object) return provider.ProviderError.InvalidRequest;

        var content_blocks: std.ArrayList(provider.ContentBlock) = .empty;
        errdefer content_blocks.deinit(self.allocator);
        var tool_count: usize = 0;

        if (parsed.object.get("message")) |msg| {
            if (msg == .object) {
                if (msg.object.get("content")) |content| {
                    if (content == .string and content.string.len > 0) {
                        try content_blocks.append(self.allocator, .{ .text = content.string });
                    }
                }

                if (msg.object.get("tool_calls")) |tool_calls| {
                    if (tool_calls == .array) {
                        for (tool_calls.array.items) |tc| {
                            const tu = parseToolCall(arena.allocator(), tc, tool_count) orelse continue;
                            tool_count += 1;
                            try content_blocks.append(self.allocator, .{ .tool_use = tu });
                        }
                    }
                }
            }
        }

        const stop_reason: provider.CompleteResponse.StopReason =
            if (tool_count > 0) .tool_use else .end_turn;

        const usage: provider.Usage = blk: {
            var input_tokens: u32 = 0;
            var output_tokens: u32 = 0;
            if (parsed.object.get("prompt_eval_count")) |pe| {
                if (pe == .integer) input_tokens = @intCast(@max(pe.integer, 0));
            }
            if (parsed.object.get("eval_count")) |ec| {
                if (ec == .integer) output_tokens = @intCast(@max(ec.integer, 0));
            }
            break :blk .{ .input_tokens = input_tokens, .output_tokens = output_tokens };
        };

        return .{
            .content = try content_blocks.toOwnedSlice(self.allocator),
            .usage = usage,
            .stop_reason = stop_reason,
            .dom_arena = arena,
        };
    }

    const OllamaLineResult = struct {
        finished: bool = false,
        usage: ?provider.Usage = null,
    };

    /// Process one line-delimited stream JSON object. Emits events through
    /// cb (the REPL callback consumes them synchronously); all referenced
    /// strings live in a per-line arena that dies on return.
    /// Parse one newline-delimited stream line and emit its events.
    /// Every emitted string — deltas AND tool_call id/name/input — points
    /// into the line arena below, so all payloads are callback-scoped only
    /// (unlike OpenAI/Claude, whose tool_call strings outlive the callback
    /// in a state arena; consumers must dupe synchronously either way — see
    /// the provider.StreamEvent ownership contract).
    fn handleStreamLine(self: *Self, line: []const u8, ctx: ?*anyopaque, cb: *const provider.StreamCallback) anyerror!OllamaLineResult {
        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, line_arena.allocator(), line, .{}) catch return .{};
        if (parsed != .object) return .{};

        if (parsed.object.get("done")) |done| {
            if (done == .bool and done.bool) {
                var usage: ?provider.Usage = null;
                if (parsed.object.get("prompt_eval_count")) |pe| {
                    if (parsed.object.get("eval_count")) |ec| {
                        if (pe == .integer and ec == .integer) {
                            usage = .{
                                .input_tokens = @intCast(@max(pe.integer, 0)),
                                .output_tokens = @intCast(@max(ec.integer, 0)),
                            };
                        }
                    }
                }
                return .{ .finished = true, .usage = usage };
            }
        }

        const msg = parsed.object.get("message") orelse return .{};
        if (msg != .object) return .{};
        if (msg.object.get("content")) |content| {
            if (content == .string and content.string.len > 0) {
                try cb(ctx, .{ .content_delta = content.string });
            }
        }
        if (msg.object.get("thinking")) |content| {
            if (content == .string and content.string.len > 0) {
                try cb(ctx, .{ .thinking_delta = content.string });
            }
        }
        // Ollama delivers tool_calls complete on a single line.
        if (msg.object.get("tool_calls")) |tool_calls| {
            if (tool_calls == .array) {
                for (tool_calls.array.items, 0..) |tc, seq| {
                    const tu = parseToolCall(line_arena.allocator(), tc, seq) orelse continue;
                    try cb(ctx, .{ .tool_call = tu });
                }
            }
        }
        return .{};
    }

    const IdName = struct {
        id: []const u8,
        name: []const u8,
    };

    fn lookupToolName(pairs: []const IdName, id: []const u8) []const u8 {
        for (pairs) |p| {
            if (std.mem.eql(u8, p.id, id)) return p.name;
        }
        return "";
    }

    /// Parse one OpenAI-style tool_call entry into a ToolUseBlock. `seq`
    /// disambiguates synthesized ids (Ollama carries no call ids).
    fn parseToolCall(a: std.mem.Allocator, tc: std.json.Value, seq: usize) ?provider.ToolUseBlock {
        if (tc != .object) return null;
        const func = tc.object.get("function") orelse return null;
        if (func != .object) return null;
        const name = func.object.get("name") orelse return null;
        if (name != .string or name.string.len == 0) return null;
        const input: std.json.Value = blk: {
            const args = func.object.get("arguments") orelse break :blk std.json.Value{ .object = .empty };
            switch (args) {
                .string => |s| break :blk std.json.parseFromSliceLeaky(std.json.Value, a, s, .{}) catch
                    std.json.Value{ .object = .empty },
                .object => break :blk args,
                else => break :blk std.json.Value{ .object = .empty },
            }
        };
        const id = std.fmt.allocPrint(a, "ot_{d}", .{seq}) catch return null;
        return .{ .id = id, .name = name.string, .input = input };
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

test "Ollama buildRequestBody sends tools and wire-format tool messages" {
    const config = OllamaConfig{ .model = "llama3.2" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = OllamaProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    var input_obj: std.json.ObjectMap = .empty;
    defer input_obj.deinit(std.testing.allocator);
    try input_obj.put(std.testing.allocator, "command", .{ .string = "ls" });

    const msgs = [_]provider.Message{
        .{ .role = .user, .content = &.{.{ .text = "run ls" }}, .timestamp = 0 },
        .{
            .role = .assistant,
            .content = &.{.{ .tool_use = .{ .id = "ot_0", .name = "Bash", .input = .{ .object = input_obj } } }},
            .timestamp = 0,
        },
        .{
            .role = .user,
            .content = &.{.{ .tool_result = .{ .tool_use_id = "ot_0", .content = "file_a" } }},
            .timestamp = 0,
        },
    };
    const tools = [_]provider.ToolSpec{
        .{ .name = "Bash", .description = "Run a command", .input_schema = "{\"type\":\"object\"}" },
    };
    const body = try p.buildRequestBody(&msgs, .{ .tools = &tools }, false);
    defer std.testing.allocator.free(body);

    // tools array
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"Bash\"") != null);
    // tool_use on the assistant message as an object-arguments tool_call
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\":[{\"function\":{\"name\":\"Bash\",\"arguments\":{\"command\":\"ls\"}}}]") != null);
    // tool result as its own role:"tool" message carrying tool_name
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_name\":\"Bash\",\"content\":\"file_a\"}") != null);
}

test "Ollama parseChatResponse tool_calls are arena-owned with unique ids" {
    const config = OllamaConfig{ .model = "llama3.2" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = OllamaProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const body =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"FileRead","arguments":{"path":"/tmp/a"}}},{"function":{"name":"Grep","arguments":{"pattern":"x"}}}]},"done":true,"prompt_eval_count":5,"eval_count":3}
    ;
    const resp = try p.parseChatResponse(body);
    defer resp.free(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), resp.content.len);
    try std.testing.expectEqual(provider.CompleteResponse.StopReason.tool_use, resp.stop_reason);
    try std.testing.expectEqualStrings("ot_0", resp.content[0].tool_use.id);
    try std.testing.expectEqualStrings("FileRead", resp.content[0].tool_use.name);
    try std.testing.expectEqualStrings("ot_1", resp.content[1].tool_use.id);
    try std.testing.expect(resp.dom_arena != null);
    try std.testing.expectEqual(@as(u32, 5), resp.usage.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), resp.usage.output_tokens);
}
