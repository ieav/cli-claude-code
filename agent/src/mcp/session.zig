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

    const Self = @This();

    pub const Transport = union(enum) {
        stdio: *stdio.StdioTransport,
        http: *http_mod.HttpTransport,
    };

    pub const ToolMeta = struct {
        description: []const u8,
        schema: []const u8,
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
        defer handshake_done.store(true, .release);
        errdefer t.close(io);

        const init_params = try std.fmt.allocPrint(self.allocator,
            "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"ziv\",\"version\":\"0.5.0\"}}}}",
            .{mod.protocol_version});
        defer self.allocator.free(init_params);
        _ = try t.sendRequest(io, "initialize", init_params);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const init_reply = (try t.readMessage(io, arena.allocator())) orelse return error.HandshakeFailed;
        if (init_reply.err != null) return error.HandshakeFailed;
        const a = self.allocator;
        if (init_reply.result) |res| {
            if (res.object.get("serverInfo")) |si| {
                if (si.object.get("name")) |n| {
                    if (n == .string) self.server_name = try a.dupe(u8, n.string);
                }
                if (si.object.get("version")) |v| {
                    if (v == .string) self.server_version = try a.dupe(u8, v.string);
                }
            }
        }

        try t.sendNotification(io, "notifications/initialized", null);
        _ = try t.sendRequest(io, "tools/list", null);
        const list_reply = (try t.readMessage(io, arena.allocator())) orelse return error.ToolsListFailed;
        if (list_reply.err != null) return error.ToolsListFailed;
        const tools = list_reply.result.?.object.get("tools") orelse return error.ToolsListFailed;

        // Cache tool metadata (arena dies — dupe into the session).
        for (tools.array.items) |tool| {
            const name_v = tool.object.get("name") orelse continue;
            if (name_v != .string) continue;
            try self.tool_names.append(a, try a.dupe(u8, name_v.string));
            const desc = if (tool.object.get("description")) |d|
                (if (d == .string) try a.dupe(u8, d.string) else try a.dupe(u8, ""))
            else
                try a.dupe(u8, "");
            const schema = blk: {
                const s = tool.object.get("inputSchema") orelse break :blk try a.dupe(u8, "{\"type\":\"object\"}");
                var buf: std.ArrayList(u8) = .empty;
                var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
                try std.json.Stringify.value(s, .{}, &aw.writer);
                buf = aw.toArrayList();
                break :blk try buf.toOwnedSlice(a);
            };
            try self.tool_defs.append(a, .{ .description = desc, .schema = schema });
        }

        self.transport = .{ .stdio = t };
        self.connected = true;
    }

    /// Streamable HTTP connect: initialize + tools/list over POSTs.
    fn connectHttp(self: *Self, io: std.Io, cfg: ServerConfig) !void {
        _ = io;
        const t = try http_mod.HttpTransport.spawn(self.allocator, self.allocator_io orelse return error.NoIo, cfg.url.?);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const init_params = try std.fmt.allocPrint(arena.allocator(),
            "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"ziv\",\"version\":\"0.5.0\"}}}}",
            .{mod.protocol_version});
        const init_reply = (try t.roundTrip(arena.allocator(), "initialize", init_params)) orelse return error.HandshakeFailed;
        if (init_reply.err != null) return error.HandshakeFailed;
        const a = self.allocator;
        if (init_reply.result) |res| {
            if (res.object.get("serverInfo")) |si| {
                if (si.object.get("name")) |n| {
                    if (n == .string) self.server_name = try a.dupe(u8, n.string);
                }
                if (si.object.get("version")) |v| {
                    if (v == .string) self.server_version = try a.dupe(u8, v.string);
                }
            }
        }
        const list_reply = (try t.roundTrip(arena.allocator(), "tools/list", null)) orelse return error.ToolsListFailed;
        if (list_reply.err != null) return error.ToolsListFailed;
        const tools = list_reply.result.?.object.get("tools") orelse return error.ToolsListFailed;
        try self.captureTools(a, arena.allocator(), tools);
        self.transport = .{ .http = t };
        self.connected = true;
    }

    /// Shared tools/list metadata capture (dupe out of the arena).
    fn captureTools(self: *Self, a: std.mem.Allocator, arena: std.mem.Allocator, tools: std.json.Value) !void {
        _ = arena;
        for (tools.array.items) |tool| {
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
            try self.tool_defs.append(a, .{ .description = desc, .schema = schema });
        }
    }

    /// Execute one tool call. Returned text is arena-owned.
    pub fn callTool(self: *Self, io: std.Io, arena: std.mem.Allocator, tool: []const u8, args_json: ?[]const u8) !CallResult {
        const params = if (args_json) |args|
            try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ tool, args })
        else
            try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\"}}", .{tool});
        const reply = switch (self.transport orelse return error.NotConnected) {
            .http => |t| (try t.roundTrip(arena, "tools/call", params)) orelse return error.CallFailed,
            .stdio => |t| blk: {
                _ = try t.sendRequest(io, "tools/call", params);
                break :blk (try t.readMessage(io, arena)) orelse return error.CallFailed;
            },
        };
        if (reply.err) |e| {
            return .{ .text = try std.fmt.allocPrint(arena, "MCP error {d}: {s}", .{ e.code, e.message }), .is_error = true };
        }
        const res = reply.result orelse return error.CallFailed;
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

        try reg.registerDynamic(full, meta.description, meta.schema, trampoline, tc);
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
