/// FileEdit tool — find and replace strings in a file.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = registry.getStringField(input, "path") orelse
        return registry.ToolResult{ .output = "Missing required field: path", .is_error = true };
    const old_string = registry.getStringField(input, "old_string") orelse
        return registry.ToolResult{ .output = "Missing required field: old_string", .is_error = true };
    const new_string = registry.getStringField(input, "new_string") orelse
        return registry.ToolResult{ .output = "Missing required field: new_string", .is_error = true };
    const replace_all_flag = if (registry.getBool(input, "replaceAll")) |v| v else false;

    if (old_string.len == 0) {
        return registry.ToolResult{ .output = "old_string cannot be empty", .is_error = true };
    }

    // Read file
    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
        return registry.ToolResult{
            .output = try alloc.print("Cannot read file: {}", .{err}),
            .is_error = true,
        };
    };
    defer alloc.free(contents);

    // Find old_string
    const first_pos = std.mem.indexOf(u8, contents, old_string) orelse
        return registry.ToolResult{
            .output = try alloc.print("old_string not found in {s}", .{path}),
            .is_error = true,
        };

    // Verify uniqueness unless replaceAll
    if (!replace_all_flag) {
        const second_pos = std.mem.indexOfPos(u8, contents, first_pos + old_string.len, old_string);
        if (second_pos != null) {
            return registry.ToolResult{
                .output = "old_string is not unique in file. Use replaceAll=true or provide more context.",
                .is_error = true,
            };
        }
    }

    // Build new content
    var new_contents = std.ArrayList(u8).empty;
    defer new_contents.deinit(alloc);

    if (replace_all_flag) {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, contents, start, old_string)) |pos| {
            try new_contents.appendSlice(alloc, contents[start..pos]);
            try new_contents.appendSlice(alloc, new_string);
            start = pos + old_string.len;
        }
        try new_contents.appendSlice(alloc, contents[start..]);
    } else {
        try new_contents.appendSlice(alloc, contents[0..first_pos]);
        try new_contents.appendSlice(alloc, new_string);
        try new_contents.appendSlice(alloc, contents[first_pos + old_string.len ..]);
    }

    // Write back
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = new_contents.items,
    }) catch |err| {
        return registry.ToolResult{
            .output = try alloc.print("Cannot write file: {}", .{err}),
            .is_error = true,
        };
    };

    const count = if (replace_all_flag)
        std.mem.count(u8, contents, old_string)
    else
        @as(usize, 1);

    return registry.ToolResult{
        .output = try alloc.print("Replaced {d} occurrence(s) in {s}", .{ count, path }),
    };
}

fn fileEditIsConcurrencySafe(_: std.json.Value) bool {
    return false;
}

fn fileEditValidateInput(input: std.json.Value) registry.ValidationResult {
    const path = registry.getStringField(input, "path") orelse
        return .{ .invalid = .{ .message = "path is required" } };
    if (path.len == 0) return .{ .invalid = .{ .message = "path cannot be empty" } };

    const old_string = registry.getStringField(input, "old_string") orelse
        return .{ .invalid = .{ .message = "old_string is required" } };
    if (old_string.len == 0) return .{ .invalid = .{ .message = "old_string cannot be empty" } };

    _ = registry.getStringField(input, "new_string") orelse
        return .{ .invalid = .{ .message = "new_string is required" } };

    return .valid;
}
