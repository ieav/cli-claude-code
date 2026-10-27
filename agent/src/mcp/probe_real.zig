// One-off real-server handshake probe (not part of the test suite).
// Usage: zig run src/mcp/probe_real.zig -- <argv...>
const std = @import("std");
const stdio = @import("stdio.zig");
const mod = @import("mod.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    const raw = std.mem.span(std.c.getenv("ZIV_PROBE_CMD") orelse "npx -y @playwright/mcp@latest");
    var it = std.mem.tokenizeScalar(u8, raw, ' ');
    while (it.next()) |a| try argv.append(alloc, a);

    std.debug.print("spawning: {s}\n", .{raw});
    const t = try stdio.StdioTransport.spawn(alloc, io, argv.items);
    defer t.close(io);

    _ = try t.sendRequest(io, "initialize",
        "{\"protocolVersion\":\"" ++ mod.protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"ziv-probe\",\"version\":\"0.1\"}}");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const init_reply = (try t.readMessage(io, arena.allocator())) orelse return error.NoInitReply;
    if (init_reply.err) |e| {
        std.debug.print("initialize error: {d} {s}\n", .{ e.code, e.message });
        return error.InitFailed;
    }
    const si = init_reply.result.?.object.get("serverInfo").?;
    std.debug.print("serverInfo: {s} {s}\n", .{
        si.object.get("name").?.string,
        si.object.get("version").?.string,
    });

    try t.sendNotification(io, "notifications/initialized", null);
    _ = try t.sendRequest(io, "tools/list", null);
    const list_reply = (try t.readMessage(io, arena.allocator())) orelse return error.NoListReply;
    if (list_reply.err) |e| {
        std.debug.print("tools/list error: {d} {s}\n", .{ e.code, e.message });
        return error.ListFailed;
    }
    const tools = list_reply.result.?.object.get("tools").?.array.items;
    std.debug.print("tool count: {d}\n", .{tools.len});
    for (tools[0..@min(tools.len, 5)]) |tool| {
        std.debug.print("  - {s}: {s}\n", .{
            tool.object.get("name").?.string,
            tool.object.get("description").?.string[0..@min(50, tool.object.get("description").?.string.len)],
        });
    }
    var saw = false;
    for (tools) |tool| {
        const n = tool.object.get("name") orelse continue;
        if (n == .string and std.mem.eql(u8, n.string, "browser_navigate")) saw = true;
    }
    std.debug.print("browser_navigate present: {}\n", .{saw});
    if (!saw) return error.NavigateMissing;
}
