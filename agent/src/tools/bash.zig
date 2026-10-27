/// Bash tool — executes shell commands via std.process.run.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const command = getStringField(input, "command") orelse
        return registry.ToolResult{ .output = "Error: 'command' field is required", .is_error = true };

    const result = std.process.run(alloc, io, .{
        .argv = &.{ "/bin/sh", "-c", command },
    }) catch |err| {
        const msg = alloc.print("Failed to execute: {}", .{err}) catch "exec failed";
        return registry.ToolResult{ .output = msg, .is_error = true };
    };

    // Own one combined buffer, then release the run() buffers (they were
    // leaking per call, and stderr was dropped entirely).
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    out.appendSlice(alloc, result.stdout) catch {};
    if (result.stderr.len > 0) {
        if (out.items.len > 0) out.append(alloc, '\n') catch {};
        out.appendSlice(alloc, result.stderr) catch {};
    }
    alloc.free(result.stdout);
    alloc.free(result.stderr);

    const is_error = result.term != .exited or result.term.exited != 0;
    return registry.ToolResult{ .output = try out.toOwnedSlice(alloc), .is_error = is_error };
}

fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = input.object.get(key) orelse return null;
    if (obj != .string) return null;
    return obj.string;
}
