/// MCP session manager (T3.1) + tool bridge (M6).
///
/// A session owns one stdio server process, does the initialize handshake,
/// caches the tool list, and executes tools/call. The bridge part registers
/// every server tool into the RuntimeRegistry under
/// `mcp__<server>__<tool>` with a ctx trampoline back to the session.
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const stdio = @import("stdio.zig");
const http_mod = @import("http.zig");
const mod = @import("mod.zig");
const message_mod = @import("../llm/message.zig");
const version_mod = @import("../util/version.zig");
const registry = @import("../tools/registry.zig");
const runtime_registry = @import("../tools/runtime_registry.zig");

pub const ServerConfig = struct {
    name: []const u8,
    /// stdio server: full command line (argv[0] resolved via PATH).
    argv: []const []const u8 = &.{},
    /// HTTP server (Streamable HTTP): exclusive with argv.
    url: ?[]const u8 = null,
    enabled: bool = true,
    /// Handshake watchdog (stdio only). 0 keeps the default (20 s); a
    /// hung server is SIGKILLed and connect() fails instead of freezing
    /// the REPL forever.
    handshake_timeout_ms: u32 = 0,
};

const default_handshake_timeout_ms: u32 = 20_000;

pub const CallResult = struct {
    /// Concatenated text content items.
    text: []const u8,
    is_error: bool,
};

pub const McpSession = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    allocator_io: ?std.Io = null,
    transport: ?Transport = null,
    server_name: []const u8 = "",
    server_version: []const u8 = "",
    tool_names: std.ArrayList([]const u8) = .empty,
    tool_defs: std.ArrayList(ToolMeta) = .empty,
    /// Per-tool trampoline contexts (bridge allocates; freed in deinit).
    trampolines: std.ArrayList(*TrampolineCtx) = .empty,
    connected: bool = false,
    /// Serializes callTool invocations: readOnly MCP tools may execute in
    /// parallel batches, but one session's pipe/HTTP conversation is a
    /// strictly sequential protocol — the lock keeps JSON-RPC frames from
    /// interleaving while different servers still run truly in parallel.
    call_mutex: std.Io.Mutex = .init,

    const Self = @This();

    pub const Transport = union(enum) {
        stdio: *stdio.StdioTransport,
        http: *http_mod.HttpTransport,
    };

    pub const ToolMeta = struct {
        description: []const u8,
        schema: []const u8,
        /// Server-declared `annotations.readOnlyHint`. Unverified claim —
        /// the permission gate still asks — but it makes the tool eligible
        /// for parallel execution (serialized per-session by call_mutex).
        read_only: bool = false,
    };

    pub const TrampolineCtx = struct {
        session: *McpSession,
        tool_name: []const u8, // server-side name, session-owned
    };

    /// Spawn + handshake + tools/list. All retained strings are session-
    /// owned (freed in deinit).
    pub fn connect(self: *Self, io: std.Io, cfg: ServerConfig) !void {
        if (self.connected) return;
        if (cfg.url != null) return self.connectHttp(io, cfg);
        const t = try stdio.StdioTransport.spawn(self.allocator, io, cfg.argv);

        // Handshake watchdog: 100 ms polls; on timeout SIGKILL the child so
        // the blocked pipe read below unblocks (EOF) and connect fails.
        const timeout_ms = if (cfg.handshake_timeout_ms > 0) cfg.handshake_timeout_ms else default_handshake_timeout_ms;
        var handshake_done = std.atomic.Value(bool).init(false);
        const wd_thread = std.Thread.spawn(.{}, handshakeWatchdog, .{ t, &handshake_done, timeout_ms }) catch null;
        defer if (wd_thread) |th| th.join(); // polls are short — join is fast
        // Registration order matters: defers run in reverse order, so `done`
        // is registered AFTER the errdefer close — it stores before close
        // can free the transport. A watchdog firing in between would call
        // killPid() on freed memory otherwise.
        errdefer t.close(io);
        defer handshake_done.store(true, .release);

        const init_params = try std.fmt.allocPrint(self.allocator, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"ziv\",\"version\":\"{s}\"}}}}", .{ mod.protocol_version, version_mod.version });
        defer self.allocator.free(init_params);
        const init_id = try t.sendRequest(io, "initialize", init_params);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const init_reply = (try t.readReply(io, arena.allocator(), init_id)) orelse return error.HandshakeFailed;
        if (init_reply.err != null) return error.HandshakeFailed;
        const a = self.allocator;
        if (init_reply.result) |res| {
            if (res == .object) {
                if (res.object.get("serverInfo")) |si| {
                    if (si == .object) {
                        if (si.object.get("name")) |n| {
                            if (n == .string) self.server_name = try a.dupe(u8, n.string);
                        }
                        if (si.object.get("version")) |v| {
                            if (v == .string) self.server_version = try a.dupe(u8, v.string);
                        }
                    }
                }
            }
        }

        try t.sendNotification(io, "notifications/initialized", null);
        try self.listToolsStdio(t, io, arena.allocator());

        self.transport = .{ .stdio = t };
        self.connected = true;
    }

    /// Streamable HTTP connect: initialize + tools/list over POSTs.
    fn connectHttp(self: *Self, io: std.Io, cfg: ServerConfig) !void {
        _ = io;
        const t = try http_mod.HttpTransport.spawn(self.allocator, self.allocator_io orelse return error.NoIo, cfg.url.?);
        // Every early return below must release the transport and its
        // pooled connections — spawn only cleans up its own allocation
        // failures, so a dead URL leaked one HttpTransport per retry.
        errdefer t.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const init_params = try std.fmt.allocPrint(arena.allocator(), "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"ziv\",\"version\":\"{s}\"}}}}", .{ mod.protocol_version, version_mod.version });
        const init_reply = (try t.roundTrip(arena.allocator(), "initialize", init_params)) orelse return error.HandshakeFailed;
        if (init_reply.err != null) return error.HandshakeFailed;
        const a = self.allocator;
        if (init_reply.result) |res| {
            if (res == .object) {
                if (res.object.get("serverInfo")) |si| {
                    if (si == .object) {
                        if (si.object.get("name")) |n| {
                            if (n == .string) self.server_name = try a.dupe(u8, n.string);
                        }
                        if (si.object.get("version")) |v| {
                            if (v == .string) self.server_version = try a.dupe(u8, v.string);
                        }
                    }
                }
            }
        }
        // The spec requires the initialized notification before any
        // request; playwright rejects tools/list without it.
        _ = try t.roundTrip(arena.allocator(), "notifications/initialized", null);

        try self.listToolsHttp(t, arena.allocator());
        self.transport = .{ .http = t };
        self.connected = true;
    }

    /// tools/list over stdio, following cursor pagination (a server MAY
    /// split the tool list; ignoring nextCursor silently hides every tool
    /// beyond the first page).
    fn listToolsStdio(self: *Self, t: *stdio.StdioTransport, io: std.Io, arena: std.mem.Allocator) !void {
        var cursor: ?[]const u8 = null;
        var pages: usize = 0;
        while (pages < 16) : (pages += 1) {
            const params: ?[]const u8 = if (cursor) |c| try encodeCursorParam(arena, c) else null;
            const list_id = try t.sendRequest(io, "tools/list", params);
            const list_reply = (try t.readReply(io, arena, list_id)) orelse return error.ToolsListFailed;
            cursor = try self.captureToolsPage(list_reply);
            if (cursor == null) return;
        }
        return error.ToolsListFailed; // unbounded pagination — refuse, don't loop
    }

    /// tools/list over Streamable HTTP, same pagination contract.
    fn listToolsHttp(self: *Self, t: *http_mod.HttpTransport, arena: std.mem.Allocator) !void {
        var cursor: ?[]const u8 = null;
        var pages: usize = 0;
        while (pages < 16) : (pages += 1) {
            const params: ?[]const u8 = if (cursor) |c| try encodeCursorParam(arena, c) else null;
            const list_reply = (try t.roundTrip(arena, "tools/list", params)) orelse return error.ToolsListFailed;
            cursor = try self.captureToolsPage(list_reply);
            if (cursor == null) return;
        }
        return error.ToolsListFailed; // unbounded pagination — refuse, don't loop
    }

    /// Validate one tools/list reply, capture its tools, return the next
    /// page cursor (null = last page). Malformed replies are errors, never
    /// tagged-union panics — the server controls this JSON.
    fn captureToolsPage(self: *Self, reply: jsonrpc.Incoming) !?[]const u8 {
        if (reply.err != null) return error.ToolsListFailed;
        const result_v = reply.result orelse return error.ToolsListFailed;
        if (result_v != .object) return error.ToolsListFailed;
        const tools = result_v.object.get("tools") orelse return error.ToolsListFailed;
        if (tools != .array) return error.ToolsListFailed;
        try self.captureTools(self.allocator, tools);
        return nextCursor(result_v);
    }

    /// Shared tools/list metadata capture (dupe out of the arena).
    fn captureTools(self: *Self, a: std.mem.Allocator, tools: std.json.Value) !void {
        for (tools.array.items) |tool| {
            if (tool != .object) continue;
            const name_v = tool.object.get("name") orelse continue;
            if (name_v != .string) continue;
            try self.tool_names.append(a, try a.dupe(u8, name_v.string));
            const desc = if (tool.object.get("description")) |d|
                (if (d == .string) try a.dupe(u8, d.string) else try a.dupe(u8, ""))
            else
                try a.dupe(u8, "");
            const schema = blk: {
                const sc = tool.object.get("inputSchema") orelse break :blk try a.dupe(u8, "{\"type\":\"object\"}");
                var buf: std.ArrayList(u8) = .empty;
                var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
                try std.json.Stringify.value(sc, .{}, &aw.writer);
                buf = aw.toArrayList();
                break :blk try buf.toOwnedSlice(a);
            };
            try self.tool_defs.append(a, .{
                .description = desc,
                .schema = schema,
                .read_only = toolIsReadOnly(tool),
            });
        }
    }

    /// MCP annotations: `annotations.readOnlyHint == true` marks a tool as
    /// side-effect-free per the server's claim.
    fn toolIsReadOnly(tool: std.json.Value) bool {
        const ann = tool.object.get("annotations") orelse return false;
        if (ann != .object) return false;
        const hint = ann.object.get("readOnlyHint") orelse return false;
        return hint == .bool and hint.bool;
    }

    /// Execute one tool call. Returned text is arena-owned. Serialized per
    /// session (call_mutex): safe to invoke from parallel tool batches.
    pub fn callTool(self: *Self, io: std.Io, arena: std.mem.Allocator, tool: []const u8, args_json: ?[]const u8) !CallResult {
        self.call_mutex.lockUncancelable(io);
        defer self.call_mutex.unlock(io);
        const params = if (args_json) |args|
            try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ tool, args })
        else
            try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\"}}", .{tool});
        const reply = switch (self.transport orelse return error.NotConnected) {
            .http => |t| (try t.roundTrip(arena, "tools/call", params)) orelse return error.CallFailed,
            .stdio => |t| blk: {
                const call_id = t.sendRequest(io, "tools/call", params) catch |err| {
                    // Pipe gone — server died. Flip connected so /mcp
                    // connect's stale-session reaper respawns instead of
                    // answering "already connected" to a dead process.
                    self.connected = false;
                    return err;
                };
                const maybe_reply = t.readReply(io, arena, call_id) catch |err| {
                    self.connected = false;
                    return err;
                };
                break :blk maybe_reply orelse {
                    self.connected = false; // EOF mid-call: server died
                    return error.CallFailed;
                };
            },
        };
        if (reply.err) |e| {
            return .{ .text = try std.fmt.allocPrint(arena, "MCP error {d}: {s}", .{ e.code, e.message }), .is_error = true };
        }
        const res = reply.result orelse return error.CallFailed;
        if (res != .object) return error.CallFailed;
        const is_err = if (res.object.get("isError")) |v| (v == .bool and v.bool) else false;
        var text: std.ArrayList(u8) = .empty;
        if (res.object.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |item| {
                    if (item != .object) continue;
                    const ty = item.object.get("type") orelse continue;
                    if (ty != .string or !std.mem.eql(u8, ty.string, "text")) continue;
                    const txt = item.object.get("text") orelse continue;
                    if (txt == .string) try text.appendSlice(arena, txt.string);
                }
            }
        }
        return .{ .text = try text.toOwnedSlice(arena), .is_error = is_err };
    }

    pub fn disconnect(self: *Self, io: std.Io) void {
        switch (self.transport orelse {
            self.connected = false;
            return;
        }) {
            .stdio => |t| t.close(io),
            .http => |t| t.deinit(),
        }
        self.transport = null;
        self.connected = false;
    }

    pub fn deinit(self: *Self) void {
        for (self.tool_names.items) |n| self.allocator.free(n);
        self.tool_names.deinit(self.allocator);
        for (self.tool_defs.items) |d| {
            self.allocator.free(d.description);
            self.allocator.free(d.schema);
        }
        self.tool_defs.deinit(self.allocator);
        for (self.trampolines.items) |tc| {
            self.allocator.free(tc.tool_name);
            self.allocator.destroy(tc);
        }
        self.trampolines.deinit(self.allocator);
        if (self.server_name.len > 0) self.allocator.free(self.server_name);
        if (self.server_version.len > 0) self.allocator.free(self.server_version);
    }
};

fn handshakeWatchdog(t: *stdio.StdioTransport, done: *std.atomic.Value(bool), timeout_ms: u32) void {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 100) {
        var req: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&req, null);
        if (done.load(.acquire)) return;
    }
    // Timeout: kill the server; the parked read gets EOF and connect()
    // returns an error instead of freezing the caller forever.
    t.killPid();
}

/// `{"cursor":"<escaped>"}` params for a paginated tools/list request.
fn encodeCursorParam(arena: std.mem.Allocator, cursor: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    try aw.writer.writeAll("{\"cursor\":");
    try message_mod.writeJsonString(&aw.writer, cursor);
    try aw.writer.writeAll("}");
    buf = aw.toArrayList();
    return buf.toOwnedSlice(arena);
}

/// nextCursor of a tools/list result — null when absent/empty/非字符串.
fn nextCursor(result_v: std.json.Value) ?[]const u8 {
    const nc = result_v.object.get("nextCursor") orelse return null;
    if (nc != .string or nc.string.len == 0) return null;
    return nc.string;
}

/// Bridge (M6): register every session tool into the runtime registry as
/// `mcp__<server>__<tool>`. The trampoline gets the session as ctx.
pub fn bridgeSessionTools(
    session: *McpSession,
    reg: *runtime_registry.RuntimeRegistry,
) !void {
    const prefix = try std.fmt.allocPrint(reg.allocator, "mcp__{s}__", .{session.name});
    defer reg.allocator.free(prefix);
    for (session.tool_names.items, session.tool_defs.items) |tool_name, meta| {
        const full = try std.fmt.allocPrint(reg.allocator, "{s}{s}", .{ prefix, tool_name });
        defer reg.allocator.free(full);

        const tc = try session.allocator.create(McpSession.TrampolineCtx);
        errdefer session.allocator.destroy(tc);
        tc.* = .{ .session = session, .tool_name = try session.allocator.dupe(u8, tool_name) };
        try session.trampolines.append(session.allocator, tc);

        try reg.registerDynamic(full, meta.description, meta.schema, trampoline, tc, meta.read_only);
    }
}

pub fn unbridgeSessionTools(session: *McpSession, reg: *runtime_registry.RuntimeRegistry) void {
    const prefix = std.fmt.allocPrint(reg.allocator, "mcp__{s}__", .{session.name}) catch return;
    defer reg.allocator.free(prefix);
    _ = reg.removeByPrefix(prefix);
}

fn trampoline(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: std.json.Value,
    io: std.Io,
) anyerror!registry.ToolResult {
    const tc: *McpSession.TrampolineCtx = @ptrCast(@alignCast(ctx orelse return error.NoSession));

    // Serialize the input back to raw JSON for tools/call arguments.
    var buf: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    try std.json.Stringify.value(input, .{}, &aw.writer);
    buf = aw.toArrayList();
    const args = try buf.toOwnedSlice(allocator);
    defer allocator.free(args);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const res = tc.session.callTool(io, arena.allocator(), tc.tool_name, args) catch |err| {
        return registry.ToolResult{
            .output = try std.fmt.allocPrint(allocator, "MCP call failed: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    };
    // The result text is arena-owned; the registry contract expects
    // allocator-owned output.
    return registry.ToolResult{
        .output = try allocator.dupe(u8, res.text),
        .is_error = res.is_error,
    };
}

test "captureTools parses annotations.readOnlyHint" {
    const alloc = std.testing.allocator;
    var sess = McpSession{
        .allocator = alloc,
        .name = "t",
    };
    defer sess.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tools = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\[{"name":"ro_tool","description":"d","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}},
        \\ {"name":"rw_tool","description":"d","annotations":{"readOnlyHint":false}},
        \\ {"name":"plain_tool","description":"d"}]
    , .{});

    try sess.captureTools(alloc, tools);

    try std.testing.expectEqual(@as(usize, 3), sess.tool_defs.items.len);
    try std.testing.expect(sess.tool_defs.items[0].read_only);
    try std.testing.expect(!sess.tool_defs.items[1].read_only);
    try std.testing.expect(!sess.tool_defs.items[2].read_only);
    try std.testing.expectEqualStrings("ro_tool", sess.tool_names.items[0]);
}

test "captureToolsPage validates reply shape and follows cursor" {
    const alloc = std.testing.allocator;
    var sess = McpSession{ .allocator = alloc, .name = "t" };
    defer sess.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // Well-formed page with a nextCursor.
    const page1 = jsonrpc.parseIncoming(arena.allocator(),
        \\{"jsonrpc":"2.0","id":9,"result":{"tools":[{"name":"a","description":"d"}],"nextCursor":"p2"}}
    ) orelse return error.TestUnexpectedResult;
    const cur = try sess.captureToolsPage(page1);
    try std.testing.expectEqualStrings("p2", cur.?);
    try std.testing.expectEqual(@as(usize, 1), sess.tool_names.items.len);

    // Final page: no cursor.
    const page2 = jsonrpc.parseIncoming(arena.allocator(),
        \\{"jsonrpc":"2.0","id":10,"result":{"tools":[{"name":"b","description":"d"}]}}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect((try sess.captureToolsPage(page2)) == null);
    try std.testing.expectEqual(@as(usize, 2), sess.tool_names.items.len);

    // result:null used to unwrap into a tagged-union panic.
    const null_result = jsonrpc.parseIncoming(arena.allocator(),
        \\{"jsonrpc":"2.0","id":11,"result":null}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.ToolsListFailed, sess.captureToolsPage(null_result));

    // result present but tools not an array.
    const bad_tools = jsonrpc.parseIncoming(arena.allocator(),
        \\{"jsonrpc":"2.0","id":12,"result":{"tools":"nope"}}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.ToolsListFailed, sess.captureToolsPage(bad_tools));
}

test "encodeCursorParam JSON-escapes the cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try encodeCursorParam(arena.allocator(), "a\"b");
    try std.testing.expectEqualStrings("{\"cursor\":\"a\\\"b\"}", p);
}
