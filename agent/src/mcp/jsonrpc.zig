/// JSON-RPC 2.0 codec for MCP (line-delimited over stdio).
/// Wire framing is one JSON object per newline; this module encodes
/// requests/notifications and decodes responses + server notifications.
const std = @import("std");
const message = @import("../llm/message.zig");

pub const ErrorCodes = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal: i64 = -32603;
};

pub const RpcError = struct {
    code: i64,
    message: []const u8,
};

/// A decoded incoming message: a response to one of our requests (id set,
/// result or err), or a server notification (method set, id null).
pub const Incoming = struct {
    id: ?i64 = null,
    method: ?[]const u8 = null,
    result: ?std.json.Value = null,
    err: ?RpcError = null,

    pub fn isResponse(self: Incoming) bool {
        return self.id != null;
    }
};

/// Encode a request: {"jsonrpc":"2.0","id":N,"method":M,"params":P}.
/// `params_json` is RAW JSON text (or null to omit the field).
pub fn encodeRequest(allocator: std.mem.Allocator, id: i64, method: []const u8, params_json: ?[]const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    const w = &aw.writer;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try w.print("{d}", .{id});
    try w.writeAll(",\"method\":");
    try message.writeJsonString(w, method);
    if (params_json) |p| {
        try w.writeAll(",\"params\":");
        try w.writeAll(p);
    }
    try w.writeAll("}");

    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

/// Encode a notification (no id — server must not reply).
pub fn encodeNotification(allocator: std.mem.Allocator, method: []const u8, params_json: ?[]const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    const w = &aw.writer;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try message.writeJsonString(w, method);
    if (params_json) |p| {
        try w.writeAll(",\"params\":");
        try w.writeAll(p);
    }
    try w.writeAll("}");

    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

/// Decode one incoming JSON-RPC message. All strings/Values live in
/// `arena` (caller-scoped arena expected).
pub fn parseIncoming(arena: std.mem.Allocator, line: []const u8) ?Incoming {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    if (parsed != .object) return null;

    var out = Incoming{};

    if (parsed.object.get("id")) |v| {
        if (v == .integer) out.id = v.integer;
    }
    if (parsed.object.get("method")) |v| {
        if (v == .string) out.method = v.string;
    }
    if (parsed.object.get("result")) |v| {
        out.result = v;
    }
    if (parsed.object.get("error")) |v| {
        if (v == .object) {
            var e = RpcError{ .code = 0, .message = "" };
            if (v.object.get("code")) |c| {
                if (c == .integer) e.code = c.integer;
            }
            if (v.object.get("message")) |m| {
                if (m == .string) e.message = m.string;
            }
            out.err = e;
        }
    }
    return out;
}

// ── Tests ──

test "encodeRequest produces valid JSON-RPC" {
    const line = try encodeRequest(std.testing.allocator, 7, "tools/list", "{\"a\":1}");
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{\"a\":1}}",
        line,
    );
}

test "encodeRequest omits null params and escapes method" {
    const line = try encodeRequest(std.testing.allocator, 1, "a\"b", null);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\\\"b\"}",
        line,
    );
}

test "encodeNotification has no id" {
    const line = try encodeNotification(std.testing.allocator, "notifications/initialized", null);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "notifications/initialized") != null);
}

test "parseIncoming decodes result response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const msg = parseIncoming(arena.allocator(),
        \\{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"echo"}]}}
    ) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(?i64, 3), msg.id);
    try std.testing.expect(msg.method == null);
    try std.testing.expect(msg.result != null);
    const tools = msg.result.?.object.get("tools").?;
    try std.testing.expectEqualStrings("echo", tools.array.items[0].object.get("name").?.string);
}

test "parseIncoming decodes error response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const msg = parseIncoming(arena.allocator(),
        \\{"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"no such method"}}
    ) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(i64, -32601), msg.err.?.code);
    try std.testing.expectEqualStrings("no such method", msg.err.?.message);
}

test "parseIncoming decodes server notification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const msg = parseIncoming(arena.allocator(),
        \\{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
    ) orelse return error.ParseFailed;
    try std.testing.expect(msg.id == null);
    try std.testing.expect(!msg.isResponse());
    try std.testing.expectEqualStrings("notifications/tools/list_changed", msg.method.?);
}

test "parseIncoming rejects garbage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(parseIncoming(arena.allocator(), "not json") == null);
    try std.testing.expect(parseIncoming(arena.allocator(), "[1,2]") == null);
}
