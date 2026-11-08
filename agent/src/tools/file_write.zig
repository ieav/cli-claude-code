/// FileWrite tool — writes content to a file.
const std = @import("std");
const registry = @import("registry.zig");
const treesitter = @import("../util/treesitter.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = getStringField(input, "path") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Error: 'path' field is required") catch "", .is_error = true };

    const content = getStringField(input, "content") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Error: 'content' field is required") catch "", .is_error = true };

    // Write file (parent directory must exist)
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = content,
    }) catch |err| {
        const msg = alloc.print("Failed to write '{s}': {}", .{ path, err }) catch return error.OutOfMemory;
        return registry.ToolResult{ .output = msg, .is_error = true };
    };

    // 所有权纪律：output alloc-owned（history freeContentBlocks 无差别
    // free，静态串会炸）。print OOM 直接走 error 路径，不再用字面量兜底。
    const base = try alloc.print("Wrote {} bytes to {s}", .{ content.len, path });
    // ③ 里程碑 1：整文件重写与定点编辑同一套落盘后语法校验。
    if (treesitter.appendValidationWarning(alloc, path, content)) |warn| {
        defer alloc.free(warn);
        defer alloc.free(base);
        return registry.ToolResult{ .output = try std.mem.concat(alloc, u8, &.{ base, warn }) };
    }
    return registry.ToolResult{ .output = base };
}

fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = input.object.get(key) orelse return null;
    if (obj != .string) return null;
    return obj.string;
}
