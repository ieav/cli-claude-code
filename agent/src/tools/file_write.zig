/// FileWrite tool — writes content to a file.
const std = @import("std");
const registry = @import("registry.zig");
const treesitter = @import("../util/treesitter.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = getStringField(input, "path") orelse
        return registry.ToolResult{ .output = "Error: 'path' field is required", .is_error = true };

    const content = getStringField(input, "content") orelse
        return registry.ToolResult{ .output = "Error: 'content' field is required", .is_error = true };

    // Write file (parent directory must exist)
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = content,
    }) catch |err| {
        const msg = alloc.print("Failed to write '{s}': {}", .{ path, err }) catch "write failed";
        return registry.ToolResult{ .output = msg, .is_error = true };
    };

    const base = alloc.print("Wrote {} bytes to {s}", .{ content.len, path }) catch "wrote file";
    // ③ 里程碑 1：整文件重写与定点编辑同一套落盘后语法校验。
    if (treesitter.appendValidationWarning(alloc, path, content)) |warn| {
        defer alloc.free(warn);
        const joined = std.mem.concat(alloc, u8, &.{ base, warn }) catch base;
        return registry.ToolResult{ .output = joined };
    }
    return registry.ToolResult{ .output = base };
}

fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = input.object.get(key) orelse return null;
    if (obj != .string) return null;
    return obj.string;
}
