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

    fn stream(ptr: *anyopaque, messages: []const provider.Message, opts: provider.CompleteOptions, ctx: ?*anyopaque, cb: *const provider.StreamCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const body = try self.buildRequestBody(messages, opts, true);
        defer self.allocator.free(body);

        var sse_parser = streaming_mod.SSEParser.init(self.allocator);
        defer sse_parser.deinit();

        const uri_str = try self.allocator.print("{s}/chat/completions", .{self.config.base_url});
        defer self.allocator.free(uri_str);
        const uri = try std.Uri.parse(uri_str);

        const auth_header = try self.allocator.print("Bearer {s}", .{self.config.api_key});
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
        var agg = OpenAIStreamState.init(self.allocator);
        defer agg.deinit();

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
                        try agg.finalize(ctx, cb);
                        try cb(ctx, .{ .done = agg.usage });
                        return;
                    }
                    try agg.feed(data, ctx, cb);
                }
            }
        }
        try agg.finalize(ctx, cb);
        if (read_err) |e| {
            try cb(ctx, .{ .error_occurred = mapStreamError(e) });
            return;
        }
        try cb(ctx, .{ .done = agg.usage });
    }

    fn mapStreamError(err: anyerror) provider.ProviderError {
        return switch (err) {
            error.ConnectionResetByPeer, error.BrokenPipe => provider.ProviderError.NetworkTimeout,
            else => provider.ProviderError.ServerError,
        };
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

        // Wire format: tool_result blocks become standalone {"role":"tool"}
        // messages; tool_use blocks become a "tool_calls" array on the
        // assistant message — OpenAI never accepts either as a content item.
        var msg_first = true;
        for (messages) |msg| {
            // 1. Tool results first, each as its own message.
            for (msg.content) |block| {
                if (block != .tool_result) continue;
                if (!msg_first) try writer.writeAll(",");
                msg_first = false;
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try message.writeJsonString(writer, block.tool_result.tool_use_id);
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
                    .tool_use => has_tool_use = true,
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
            if (content_buf.items.len > 0) {
                try writer.writeAll(",\"content\":");
                try message.writeJsonString(writer, content_buf.items);
            } else {
                try writer.writeAll(",\"content\":null");
            }
            if (has_tool_use) {
                try writer.writeAll(",\"tool_calls\":[");
                var tc_first = true;
                for (msg.content) |block| {
                    if (block != .tool_use) continue;
                    if (!tc_first) try writer.writeAll(",");
                    tc_first = false;
                    try writer.writeAll("{\"id\":");
                    try message.writeJsonString(writer, block.tool_use.id);
                    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try message.writeJsonString(writer, block.tool_use.name);
                    // arguments is a JSON *string* on the wire.
                    var args_buf: std.ArrayList(u8) = .empty;
                    defer args_buf.deinit(self.allocator);
                    var args_aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &args_buf);
                    try std.json.Stringify.value(block.tool_use.input, .{}, &args_aw.writer);
                    args_buf = args_aw.toArrayList();
                    try writer.writeAll(",\"arguments\":");
                    try message.writeJsonString(writer, args_buf.items);
                    try writer.writeAll("}}");
                }
                try writer.writeAll("]");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        // Tool declarations: the model cannot call tools it never sees.
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

        try writer.print(",\"max_tokens\":{d}", .{opts.max_tokens});
        try writer.print(",\"temperature\":{d:.2}", .{opts.temperature});

        if (do_stream) {
            // include_usage makes the final chunk carry real token counts.
            try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}");
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
        const url = try self.allocator.print("{s}{s}", .{ self.config.base_url, path });
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        const auth_header = try self.allocator.print("Bearer {s}", .{self.config.api_key});
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

        // 64 KiB I/O buffer instead of a 1 MiB stack array — complete() is
        // also called from thread-pool workers (classifier) with tighter
        // stacks; allocRemaining grows past the buffer as needed.
        var body_buf: [64 * 1024]u8 = undefined;
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
        if (choice != .object) return provider.ProviderError.InvalidRequest;
        const message_obj = choice.object.get("message") orelse return provider.ProviderError.InvalidRequest;
        const finish_reason = choice.object.get("finish_reason");

        var content_blocks: std.ArrayList(provider.ContentBlock) = .empty;
        // Tool-only responses carry content: null or omit it entirely.
        if (message_obj.object.get("content")) |content| {
            if (content == .string and content.string.len > 0) {
                try content_blocks.append(self.allocator, .{ .text = content.string });
            }
        }

        if (message_obj.object.get("tool_calls")) |tool_calls| {
            if (tool_calls == .array) {
                for (tool_calls.array.items, 0..) |tc, tc_i| {
                    if (tc != .object) continue;
                    const func = tc.object.get("function") orelse continue;
                    if (func != .object) continue;
                    const name = func.object.get("name") orelse continue;
                    if (name != .string or name.string.len == 0) continue;
                    // Some gateways omit the id — synthesize a stable one so
                    // the tool result round-trip stays keyed.
                    const id: []const u8 = blk: {
                        const idv = tc.object.get("id") orelse
                            break :blk try std.fmt.allocPrint(arena.allocator(), "call_{d}", .{tc_i});
                        if (idv != .string or idv.string.len == 0)
                            break :blk try std.fmt.allocPrint(arena.allocator(), "call_{d}", .{tc_i});
                        break :blk idv.string;
                    };
                    const input: std.json.Value = blk: {
                        const args = func.object.get("arguments") orelse
                            break :blk std.json.Value{ .object = .empty };
                        switch (args) {
                            .string => |s| break :blk std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), s, .{}) catch
                                std.json.Value{ .object = .empty },
                            .object => break :blk args,
                            else => break :blk std.json.Value{ .object = .empty },
                        }
                    };

                    try content_blocks.append(self.allocator, .{
                        .tool_use = .{
                            .id = id,
                            .name = name.string,
                            .input = input,
                        },
                    });
                }
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

    /// Accumulates streamed tool_calls fragments (the name arrives in the
    /// first chunk; the arguments JSON string arrives split across many
    /// chunks keyed by the "index" field) and emits one `.tool_call` event
    /// per completed call, in index order, at finish_reason/"[DONE]".
    const OpenAIStreamState = struct {
        allocator: std.mem.Allocator,
        /// Owns id/name strings and input DOMs referenced by emitted
        /// tool_call events. Delta strings point into the per-chunk DOM
        /// (freed when feed returns). Callback-scoped validity either way —
        /// see the provider.StreamEvent ownership contract.
        arena: std.heap.ArenaAllocator,
        calls: std.ArrayList(?*ToolCallAcc) = .empty,
        usage: ?provider.Usage = null,
        finalized: bool = false,

        const ToolCallAcc = struct {
            id: std.ArrayList(u8) = .empty,
            name: std.ArrayList(u8) = .empty,
            arguments: std.ArrayList(u8) = .empty,
        };

        fn init(allocator: std.mem.Allocator) OpenAIStreamState {
            return .{
                .allocator = allocator,
                .arena = std.heap.ArenaAllocator.init(allocator),
                .calls = .empty,
            };
        }

        fn deinit(self: *OpenAIStreamState) void {
            for (self.calls.items) |maybe| {
                if (maybe) |acc| {
                    acc.id.deinit(self.allocator);
                    acc.name.deinit(self.allocator);
                    acc.arguments.deinit(self.allocator);
                    self.allocator.destroy(acc);
                }
            }
            self.calls.deinit(self.allocator);
            self.arena.deinit();
        }

        fn accFor(self: *OpenAIStreamState, idx: usize) !*ToolCallAcc {
            while (self.calls.items.len <= idx) try self.calls.append(self.allocator, null);
            if (self.calls.items[idx]) |acc| return acc;
            const acc = try self.allocator.create(ToolCallAcc);
            acc.* = .{};
            self.calls.items[idx] = acc;
            return acc;
        }

        /// Process one SSE data payload (a chat.completion.chunk object).
        /// Emits content/thinking deltas live; buffers tool_call fragments.
        fn feed(self: *OpenAIStreamState, data: []const u8, ctx: ?*anyopaque, cb: *const provider.StreamCallback) anyerror!void {
            // Per-payload arena replaces the old smp_allocator leaky parse:
            // the DOM dies with the chunk; emitted strings are arena-duped.
            var line_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer line_arena.deinit();
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, line_arena.allocator(), data, .{}) catch return;
            if (parsed != .object) return;

            // The final chunk (stream_options.include_usage) carries
            // top-level usage with empty/absent choices — capture it.
            if (parsed.object.get("usage")) |u| {
                if (u == .object) {
                    const pt = u.object.get("prompt_tokens");
                    const ct = u.object.get("completion_tokens");
                    if (pt != null and pt.? == .integer and ct != null and ct.? == .integer) {
                        self.usage = .{
                            .input_tokens = @intCast(pt.?.integer),
                            .output_tokens = @intCast(ct.?.integer),
                        };
                    }
                }
            }

            const choices = parsed.object.get("choices") orelse return;
            if (choices != .array or choices.array.items.len == 0) return;
            const choice = choices.array.items[0];
            if (choice != .object) return;

            if (choice.object.get("delta")) |delta| {
                if (delta == .object) {
                    if (delta.object.get("content")) |c| {
                        if (c == .string and c.string.len > 0) {
                            try cb(ctx, .{ .content_delta = c.string });
                        }
                    }
                    // GLM-style reasoning models stream reasoning separately.
                    if (delta.object.get("reasoning_content")) |c| {
                        if (c == .string and c.string.len > 0) {
                            try cb(ctx, .{ .thinking_delta = c.string });
                        }
                    }
                    if (delta.object.get("tool_calls")) |tcs| {
                        if (tcs == .array) {
                            for (tcs.array.items) |tc| {
                                try self.feedToolCall(tc);
                            }
                        }
                    }
                }
            }

            if (choice.object.get("finish_reason")) |fr| {
                if (fr == .string and std.mem.eql(u8, fr.string, "tool_calls")) {
                    try self.finalize(ctx, cb);
                }
            }
        }

        fn feedToolCall(self: *OpenAIStreamState, tc: std.json.Value) !void {
            if (tc != .object) return;
            const idx: usize = blk: {
                const iv = tc.object.get("index") orelse break :blk 0;
                if (iv == .integer and iv.integer >= 0) break :blk @intCast(iv.integer);
                break :blk 0;
            };
            const acc = try self.accFor(idx);
            // The id only arrives on the first fragment per index; overwrite
            // rather than concatenate.
            if (tc.object.get("id")) |idv| {
                if (idv == .string and idv.string.len > 0) {
                    acc.id.clearRetainingCapacity();
                    try acc.id.appendSlice(self.allocator, idv.string);
                }
            }
            if (tc.object.get("function")) |f| {
                if (f == .object) {
                    if (f.object.get("name")) |nv| {
                        if (nv == .string and nv.string.len > 0) try acc.name.appendSlice(self.allocator, nv.string);
                    }
                    if (f.object.get("arguments")) |av| {
                        if (av == .string and av.string.len > 0) try acc.arguments.appendSlice(self.allocator, av.string);
                    }
                }
            }
        }

        /// Emit one .tool_call event per accumulated call (index order).
        /// Idempotent: finish_reason and "[DONE]" can both fire it.
        fn finalize(self: *OpenAIStreamState, ctx: ?*anyopaque, cb: *const provider.StreamCallback) anyerror!void {
            if (self.finalized) return;
            self.finalized = true;
            const a = self.arena.allocator();
            for (self.calls.items, 0..) |maybe, i| {
                const acc = maybe orelse continue;
                if (acc.name.items.len == 0) continue;
                const id = if (acc.id.items.len > 0)
                    try a.dupe(u8, acc.id.items)
                else
                    try std.fmt.allocPrint(a, "call_{d}", .{i});
                const input: std.json.Value = blk: {
                    const args = acc.arguments.items;
                    if (args.len == 0) break :blk std.json.Value{ .object = .empty };
                    break :blk std.json.parseFromSliceLeaky(std.json.Value, a, args, .{}) catch
                        std.json.Value{ .object = .empty };
                };
                try cb(ctx, .{ .tool_call = .{
                    .id = id,
                    .name = try a.dupe(u8, acc.name.items),
                    .input = input,
                } });
            }
        }
    };
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

test "OpenAI buildRequestBody sends tool declarations" {
    const config = OpenAIConfig{ .api_key = "test-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = OpenAIProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    const msgs = [_]provider.Message{
        .{ .role = .user, .content = &.{.{ .text = "Hello" }}, .timestamp = 0 },
    };
    const tools = [_]provider.ToolSpec{
        .{ .name = "FileRead", .description = "Read a file", .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
    };
    const body = try p.buildRequestBody(&msgs, .{ .tools = &tools }, false);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"FileRead\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"") != null);
}

test "OpenAI buildRequestBody flattens tool_use and tool_result to wire format" {
    const config = OpenAIConfig{ .api_key = "test-key" };
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var p = OpenAIProvider.init(std.testing.allocator, io_state.io(), config);
    defer p.deinit();

    var input_obj: std.json.ObjectMap = .empty;
    defer input_obj.deinit(std.testing.allocator);
    try input_obj.put(std.testing.allocator, "command", .{ .string = "ls" });

    const msgs = [_]provider.Message{
        .{ .role = .user, .content = &.{.{ .text = "run ls" }}, .timestamp = 0 },
        .{
            .role = .assistant,
            .content = &.{
                .{ .text = "I will run that." },
                .{ .tool_use = .{ .id = "call_1", .name = "Bash", .input = .{ .object = input_obj } } },
            },
            .timestamp = 0,
        },
        .{
            .role = .user,
            .content = &.{.{ .tool_result = .{ .tool_use_id = "call_1", .content = "file_a\nfile_b" } }},
            .timestamp = 0,
        },
    };
    const body = try p.buildRequestBody(&msgs, .{}, false);
    defer std.testing.allocator.free(body);

    // tool_use must appear as assistant tool_calls, not content items
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"Bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}") != null);
    // tool_result must be its own {"role":"tool"} message
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"file_a\\nfile_b\"}") != null);
}

/// Test callback that dupes everything so strings outlive provider arenas.
const TestSink = struct {
    alloc: std.mem.Allocator,
    deltas: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(provider.ToolUseBlock) = .empty,
    done_usage: ?provider.Usage = null,

    fn cb(ctx_opaque: ?*anyopaque, event: provider.StreamEvent) anyerror!void {
        const self: *TestSink = @ptrCast(@alignCast(ctx_opaque.?));
        switch (event) {
            .content_delta => |d| try self.deltas.appendSlice(self.alloc, d),
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

    fn deinit(self: *TestSink) void {
        self.deltas.deinit(self.alloc);
        for (self.calls.items) |*tu| {
            self.alloc.free(tu.id);
            self.alloc.free(tu.name);
        }
        self.calls.deinit(self.alloc);
    }
};

test "OpenAI stream state accumulates chunked tool arguments" {
    var sink: TestSink = .{ .alloc = std.testing.allocator };
    defer sink.deinit();
    var state = OpenAIProvider.OpenAIStreamState.init(std.testing.allocator);
    defer state.deinit();

    try state.feed(
        \\{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"FileRead","arguments":""}}]},"finish_reason":null}]}
    , @ptrCast(&sink), TestSink.cb);
    try state.feed(
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"pa"}}]},"finish_reason":null}]}
    , @ptrCast(&sink), TestSink.cb);
    try state.feed(
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"/tmp/a\"}"}}]},"finish_reason":null}]}
    , @ptrCast(&sink), TestSink.cb);
    try state.feed(
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
    , @ptrCast(&sink), TestSink.cb);

    try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    const tc = sink.calls.items[0];
    try std.testing.expectEqualStrings("call_abc", tc.id);
    try std.testing.expectEqualStrings("FileRead", tc.name);
    const path = registry_like_path(tc.input);
    try std.testing.expectEqualStrings("/tmp/a", path);
}

test "OpenAI stream state synthesizes missing id and captures usage" {
    var sink: TestSink = .{ .alloc = std.testing.allocator };
    defer sink.deinit();
    var state = OpenAIProvider.OpenAIStreamState.init(std.testing.allocator);
    defer state.deinit();

    // Gateway fragments with no id at all.
    try state.feed(
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"name":"Grep","arguments":"{\"pattern\":\"x\"}"}}]},"finish_reason":null}]}
    , @ptrCast(&sink), TestSink.cb);
    // Final usage chunk (stream_options.include_usage) has empty choices.
    try state.feed(
        \\{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}
    , @ptrCast(&sink), TestSink.cb);
    try state.finalize(@ptrCast(&sink), TestSink.cb);

    try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    const tc = sink.calls.items[0];
    try std.testing.expectEqualStrings("call_1", tc.id);
    try std.testing.expectEqualStrings("Grep", tc.name);
    try std.testing.expect(state.usage != null);
    try std.testing.expectEqual(@as(u32, 11), state.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 7), state.usage.?.output_tokens);
}

test "OpenAI stream state emits content deltas live" {
    var sink: TestSink = .{ .alloc = std.testing.allocator };
    defer sink.deinit();
    var state = OpenAIProvider.OpenAIStreamState.init(std.testing.allocator);
    defer state.deinit();

    try state.feed(
        \\{"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}
    , @ptrCast(&sink), TestSink.cb);
    try state.feed(
        \\{"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}
    , @ptrCast(&sink), TestSink.cb);
    try state.feed(
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
    , @ptrCast(&sink), TestSink.cb);

    try std.testing.expectEqualStrings("Hello", sink.deltas.items);
    try std.testing.expectEqual(@as(usize, 0), sink.calls.items.len);
}

/// Minimal accessor for tests: input.path as a string (arena-backed, valid
/// until the owning state is deinited).
fn registry_like_path(input: std.json.Value) []const u8 {
    if (input != .object) return "";
    const p = input.object.get("path") orelse return "";
    return if (p == .string) p.string else "";
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
