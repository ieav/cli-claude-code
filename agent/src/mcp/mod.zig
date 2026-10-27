/// MCP (Model Context Protocol) client — stdio transport, JSON-RPC 2.0.
const std = @import("std");

pub const jsonrpc = @import("jsonrpc.zig");
pub const stdio = @import("stdio.zig");

pub const protocol_version = "2025-06-18";
pub const client_info = "ziv/0.5.0";

test {
    _ = jsonrpc;
    _ = stdio;
}

// T2.2 spike: full handshake against a mock MCP server over stdio.
// Skips when ZIV_MCP_MOCK is unset (normal runs need no python).

test "MCP stdio spike: initialize, tools/list, tools/call against mock" {
    const env_mod = @import("../util/env.zig");
    const mock = env_mod.get("ZIV_MCP_MOCK") orelse return error.SkipZigTest;

    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const t = try stdio.StdioTransport.spawn(std.testing.allocator, io, &.{ "python3", mock });
    defer t.close(io);

    // 1. initialize
    const init_params = "{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"ziv\",\"version\":\"0.5.0\"}}";
    const init_id = try t.sendRequest(io, "initialize", init_params);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const init_reply = (try t.readMessage(io, arena.allocator())) orelse return error.NoInitReply;
    try std.testing.expectEqual(init_id, init_reply.id);
    const server_name = init_reply.result.?.object.get("serverInfo").?.object.get("name").?.string;
    try std.testing.expectEqualStrings("mock-mcp", server_name);

    // 2. notifications/initialized
    try t.sendNotification(io, "notifications/initialized", null);

    // 3. tools/list
    const list_id = try t.sendRequest(io, "tools/list", null);
    const list_reply = (try t.readMessage(io, arena.allocator())) orelse return error.NoListReply;
    try std.testing.expectEqual(list_id, list_reply.id);
    const tools = list_reply.result.?.object.get("tools").?;
    try std.testing.expect(tools.array.items.len >= 1);
    const first = tools.array.items[0];
    try std.testing.expectEqualStrings("echo", first.object.get("name").?.string);
    try std.testing.expect(first.object.get("inputSchema") != null);

    // 4. tools/call
    const call_id = try t.sendRequest(io, "tools/call",
        "{\"name\":\"echo\",\"arguments\":{\"msg\":\"spiketest\"}}");
    const call_reply = (try t.readMessage(io, arena.allocator())) orelse return error.NoCallReply;
    try std.testing.expectEqual(call_id, call_reply.id);
    const content = call_reply.result.?.object.get("content").?;
    const text = content.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("echo: spiketest", text);
}

// Real-server handshake (T9 acceptance gate). Run with:
//   ZIV_MCP_REAL='npx -y @playwright/mcp@latest' zig build test
// Skips otherwise; needs node + network on first download.
// KNOWN ISSUE (T9 scope): shell-launched servers (python mock, node echo,
// shell-manual playwright) all hand-shake fine through StdioTransport, but
// playwright-mcp under a zig spawn wedges at initialize — narrowed to an
// fd/procgroup attribute of Zig's .pipe spawn vs its slow ESM startup.
// Candidate fixes for T9: spawn via /bin/sh -c with a pty, or resolve the
// npx cache to a direct node invocation.
test "MCP real handshake: Playwright server lists browser tools" {
    const env_mod = @import("../util/env.zig");
    const cmd = env_mod.get("ZIV_MCP_REAL") orelse return error.SkipZigTest;

    const alloc = std.testing.allocator;
    // The env value is a full shell command line; hand it to sh -c so
    // pipes/quotes work and the child sees a shell-identical environment
    // (directly spawning npx leaves npm's stdio forwarding wedged).
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "/bin/sh");
    try argv.append(alloc, "-c");
    try argv.append(alloc, cmd);

    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const t = try stdio.StdioTransport.spawn(alloc, io, argv.items);
    defer t.close(io);

    const init_params = "{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"ziv\",\"version\":\"0.5.0\"}}";
    _ = try t.sendRequest(io, "initialize", init_params);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const init_reply = (try t.readMessage(io, arena.allocator())) orelse return error.NoInitReply;
    try std.testing.expect(init_reply.err == null);
    const server_name = init_reply.result.?.object.get("serverInfo").?.object.get("name").?.string;
    try std.testing.expectEqualStrings("Playwright", server_name);

    try t.sendNotification(io, "notifications/initialized", null);

    const list_id = try t.sendRequest(io, "tools/list", null);
    const list_reply = (try t.readMessage(io, arena.allocator())) orelse return error.NoListReply;
    try std.testing.expectEqual(list_id, list_reply.id);
    const tools = list_reply.result.?.object.get("tools").?;
    var saw_navigate = false;
    for (tools.array.items) |tool| {
        const n = tool.object.get("name") orelse continue;
        if (n == .string and std.mem.eql(u8, n.string, "browser_navigate")) saw_navigate = true;
    }
    try std.testing.expect(saw_navigate);
}
