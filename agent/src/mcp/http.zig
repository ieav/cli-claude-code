/// Streamable HTTP transport for MCP (M5): one POST per JSON-RPC request,
/// response is either a JSON body or an SSE stream (first data event).
/// Session id from the Mcp-Session-Id response header is echoed back.
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const message = @import("../llm/message.zig");

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    http_client: std.http.Client,
    session_id: ?[]const u8 = null, // owned
    next_id: i64 = 1,

    const Self = @This();

    pub fn spawn(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .url = try allocator.dupe(u8, url),
            .http_client = .{ .allocator = allocator, .io = io },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        if (self.session_id) |s| self.allocator.free(s);
        self.allocator.free(self.url);
        self.allocator.destroy(self);
    }

    pub fn nextId(self: *Self) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Send one request and read its response. Strings/Values live in
    /// `arena`. Returns null on transport-level failure.
    pub fn roundTrip(self: *Self, arena: std.mem.Allocator, method: []const u8, params_json: ?[]const u8) !?jsonrpc.Incoming {
        const id = self.nextId();
        const body = try jsonrpc.encodeRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(body);

        const uri = try std.Uri.parse(self.url);
        var extra = std.ArrayList(std.http.Header).empty;
        defer extra.deinit(self.allocator);
        try extra.append(self.allocator, .{ .name = "content-type", .value = "application/json" });
        try extra.append(self.allocator, .{ .name = "accept", .value = "application/json, text/event-stream" });
        if (self.session_id) |sid| {
            try extra.append(self.allocator, .{ .name = "mcp-session-id", .value = sid });
        }

        var req = self.http_client.request(.POST, uri, .{ .extra_headers = extra.items }) catch return null;
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(body);
        try bw.end();
        try req.connection.?.flush();

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return null;
        if (response.head.status.class() != .success) return null;

        // Capture the session id once (pre-body, same reason).
        if (self.session_id == null) {
            var hit = response.head.iterateHeaders();
            while (hit.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "mcp-session-id")) {
                    self.session_id = self.allocator.dupe(u8, h.value) catch null;
                    break;
                }
            }
        }

        // Capture content_type BEFORE reading the body, and COPY it: the
        // head bytes are reused as the body streams (a borrowed slice turns
        // into body garbage — found via ct=eference… in a debug run).
        var ct_buf: [96]u8 = undefined;
        const ct_len = blk: {
            var hit = response.head.iterateHeaders();
            while (hit.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                    break :blk @min(h.value.len, ct_buf.len);
                }
            }
            break :blk 0;
        };
        // second pass to copy (iterator borrows head; re-iterate then dupe)
        if (ct_len > 0) {
            var hit = response.head.iterateHeaders();
            while (hit.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                    @memcpy(ct_buf[0..ct_len], h.value[0..ct_len]);
                    break;
                }
            }
        }
        const content_type = ct_buf[0..ct_len];

        // Read the body (either JSON or SSE).
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const raw = readCapped(arena, reader) catch return null;

        if (std.mem.indexOf(u8, content_type, "text/event-stream") != null) {
            // First `data:` line holding a JSON-RPC object.
            var lines = std.mem.splitScalar(u8, raw, '\n');
            while (lines.next()) |line| {
                const t = std.mem.trim(u8, line, " \r");
                if (!std.mem.startsWith(u8, t, "data:")) continue;
                const payload = std.mem.trim(u8, t[5..], " ");
                if (std.mem.eql(u8, payload, "[DONE]")) continue;
                if (std.mem.startsWith(u8, payload, "{")) {
                    return jsonrpc.parseIncoming(arena, payload);
                }
            }
            return null;
        }
        return jsonrpc.parseIncoming(arena, raw);
    }

    fn readCapped(arena: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        var chunk: [8192]u8 = undefined;
        while (list.items.len < 1024 * 1024) {
            const n = reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try list.appendSlice(arena, chunk[0..n]);
        }
        return list.toOwnedSlice(arena);
    }
};
