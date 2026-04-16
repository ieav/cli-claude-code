/// Bash tool — executes shell commands via std.process.run.

const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const command = getStringField(input, "command") orelse
        return registry.ToolResult{ .output = "Error: 'command' field is required", .is_error = true };

    const result = std.process.run(alloc, io, .{
        .argv = &.{ "/bin/sh", "-c", command },
    }) catch |err| {
        const msg = std.fmt.allocPrint(alloc, "Failed to execute: {}", .{err}) catch "exec failed";
        return registry.ToolResult{ .output = msg, .is_error = true };
    };

    const output = alloc.dupe(u8, result.stdout) catch "dup failed";
    const is_error = result.term != .exited or result.term.exited != 0;
    return registry.ToolResult{ .output = output, .is_error = is_error };
}

fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = input.object.get(key) orelse return null;
    if (obj != .string) return null;
    return obj.string;
}
