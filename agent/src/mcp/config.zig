/// mcp.json config (T4.1) — ~/.config/ziv/mcp.json:
/// {"mcpServers": {"name": {"command": "npx -y pkg", "enabled": true}}}
/// `command` is a single string; the session splits it on spaces (v1: no
/// quoting). HTTP servers ("url") are parsed and stored but v1 stdio-only.
const std = @import("std");
const session_mod = @import("session.zig");

pub const ServerEntry = struct {
    name: []const u8,
    command: []const u8,
    enabled: bool = true,
};

pub const McpConfig = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    servers: std.ArrayList(ServerEntry) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Self) void {
        for (self.servers.items) |srv| {
            self.allocator.free(srv.name);
            self.allocator.free(srv.command);
        }
        self.servers.deinit(self.allocator);
    }

    fn configPath(self: *Self) ![]u8 {
        const env_mod = @import("../util/env.zig");
        const home = env_mod.homeDir() orelse return error.NoHome;
        _ = self;
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}/.config/ziv/mcp.json", .{home});
    }

    pub fn load(self: *Self) void {
        const path = self.configPath() catch return;
        defer std.heap.page_allocator.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(256 * 1024)) catch return;
        defer self.allocator.free(text);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value.object.get("mcpServers") orelse return;
        if (root != .object) return;
        var it = root.object.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const v = e.value_ptr.*;
            if (v != .object) continue;
            const cmd = if (v.object.get("command")) |c| (if (c == .string) c.string else continue) else continue;
            const enabled = if (v.object.get("enabled")) |en| (en == .bool and en.bool) else true;
            self.servers.append(self.allocator, .{
                .name = self.allocator.dupe(u8, name) catch continue,
                .command = self.allocator.dupe(u8, cmd) catch continue,
                .enabled = enabled,
            }) catch {};
        }
    }

    pub fn save(self: *Self) void {
        const path = self.configPath() catch return;
        defer std.heap.page_allocator.free(path);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\n  \"mcpServers\": {") catch return;
        for (self.servers.items, 0..) |srv, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("\n    \"") catch return;
            jsonEscape(w, srv.name);
            w.writeAll("\": {\"command\": \"") catch return;
            jsonEscape(w, srv.command);
            if (!srv.enabled) w.writeAll("\", \"enabled\": false") catch return;
            w.writeAll("\"}") catch return;
        }
        w.writeAll("\n  }\n}\n") catch return;

        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = aw.writer.buffered() }) catch return;
    }

    pub fn find(self: *Self, name: []const u8) ?*ServerEntry {
        for (self.servers.items) |*srv| {
            if (std.mem.eql(u8, srv.name, name)) return srv;
        }
        return null;
    }

    /// Add or replace; persists immediately.
    pub fn upsert(self: *Self, name: []const u8, command: []const u8) !void {
        if (self.find(name)) |existing| {
            const new_cmd = try self.allocator.dupe(u8, command);
            self.allocator.free(existing.command);
            existing.command = new_cmd;
        } else {
            try self.servers.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name),
                .command = try self.allocator.dupe(u8, command),
            });
        }
        self.save();
    }

    pub fn remove(self: *Self, name: []const u8) bool {
        for (self.servers.items, 0..) |srv, i| {
            if (std.mem.eql(u8, srv.name, name)) {
                self.allocator.free(srv.name);
                self.allocator.free(srv.command);
                _ = self.servers.orderedRemove(i);
                self.save();
                return true;
            }
        }
        return false;
    }

    /// /mcp install registry: name -> command for well-known servers.
    pub const known_servers = [_]struct { name: []const u8, command: []const u8 }{
        .{ .name = "playwright", .command = "npx -y @playwright/mcp@latest" },
        .{ .name = "filesystem", .command = "npx -y @modelcontextprotocol/server-filesystem /tmp" },
        .{ .name = "memory", .command = "npx -y @modelcontextprotocol/server-memory" },
        .{ .name = "fetch", .command = "uvx mcp-server-fetch" },
        .{ .name = "sequential-thinking", .command = "npx -y @modelcontextprotocol/server-sequential-thinking" },
    };
};

fn jsonEscape(w: *std.Io.Writer, value: []const u8) void {
    for (value) |ch| {
        switch (ch) {
            '"' => w.writeAll("\\\"") catch return,
            '\\' => w.writeAll("\\\\") catch return,
            '\n' => w.writeAll("\\n") catch return,
            else => w.writeByte(ch) catch return,
        }
    }
}

/// Split a command string into argv (spaces; no quoting in v1).
pub fn splitCommand(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, command, ' ');
    while (it.next()) |part| try argv.append(allocator, part);
    return argv.toOwnedSlice(allocator);
}

// ── Tests ──

test "splitCommand" {
    const argv = try splitCommand(std.testing.allocator, "npx -y @playwright/mcp@latest");
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("npx", argv[0]);
    try std.testing.expectEqualStrings("@playwright/mcp@latest", argv[2]);
}

test "known registry has playwright" {
    try std.testing.expect(McpConfig.known_servers.len >= 5);
}
