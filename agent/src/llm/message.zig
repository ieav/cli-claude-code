/// Message serialization/deserialization for LLM API calls.

const std = @import("std");
const provider = @import("provider.zig");

/// Serialize messages to JSON for an API request body.
/// Returns caller-owned slice.
pub fn serializeMessages(
    allocator: std.mem.Allocator,
    messages: []const provider.Message,
    system_prompt: ?[]const u8,
    tools_json: ?[]const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"messages\":[");

    // System prompt as first message
    var msg_idx: usize = 0;
    if (system_prompt) |sp| {
        try writer.writeAll("{\"role\":\"system\",\"content\":");
        try writeJsonString(writer, sp);
        try writer.writeAll("}");
        msg_idx = 1;
    }

    for (messages) |msg| {
        if (msg_idx > 0) try writer.writeAll(",");
        try writer.writeAll("{\"role\":");
        try writeJsonString(writer, @tagName(msg.role));
        try writer.writeAll(",\"content\":");

        if (msg.content.len == 1 and msg.content[0] == .text) {
            // Simple text content
            try writeJsonString(writer, msg.content[0].text);
        } else {
            // Content blocks array
            try writer.writeAll("[");
            for (msg.content, 0..) |block, i| {
                if (i > 0) try writer.writeAll(",");
                try serializeContentBlock(writer, &block);
            }
            try writer.writeAll("]");
        }
        try writer.writeAll("}");
        msg_idx += 1;
    }

    try writer.writeAll("]");

    // Add tools if provided
    if (tools_json) |tj| {
        try writer.writeAll(",\"tools\":");
        try writer.writeAll(tj);
    }

    try writer.writeAll("}");
    return buf.toOwnedSlice();
}

fn serializeContentBlock(writer: anytype, block: *const provider.ContentBlock) !void {
    switch (block.*) {
        .text => |t| {
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try writeJsonString(writer, t);
            try writer.writeAll("}");
        },
        .tool_use => |tu| {
            try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
            try writeJsonString(writer, tu.id);
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, tu.name);
            try writer.writeAll(",\"input\":");
            // input is already a std.json.Value, stringify it
            var buf = std.ArrayList(u8).init(writer.context.allocator orelse return error.NoAllocator);
            try std.json.stringify(tu.input, .{}, buf.writer());
            try writer.writeAll(buf.items);
        },
        .tool_result => |tr| {
            try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try writeJsonString(writer, tr.tool_use_id);
            try writer.writeAll(",\"content\":");
            try writeJsonString(writer, tr.content);
            if (tr.is_error) {
                try writer.writeAll(",\"is_error\":true");
            }
            try writer.writeAll("}");
        },
        .thinking => |t| {
            try writer.writeAll("{\"type\":\"thinking\",\"thinking\":");
            try writeJsonString(writer, t);
            try writer.writeAll("}");
        },
    }
}

/// Write a JSON-escaped string.
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{:0>4x}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeAll("\"");
}

/// Estimate token count for text (rough: ~4 chars per token for English).
pub fn estimateTokens(text: []const u8) u32 {
    return @intCast(text.len / 4);
}

test "writeJsonString escapes correctly" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try writeJsonString(buf.writer(), "hello \"world\"\nnew line");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nnew line\"", buf.items);
}
