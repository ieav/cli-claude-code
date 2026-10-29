/// JSON string escaping shared by the LLM backends. (The old
/// serializeMessages/serializeContentBlock helpers were removed: pre-0.16
/// ArrayList/Writer API that no longer compiled, and a wire format that
/// embedded Anthropic content-blocks into every backend — each backend now
/// serializes its own request body.)
const std = @import("std");

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
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeAll("\"");
}

test "writeJsonString escapes correctly" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeJsonString(&aw.writer, "hello \"world\"\nnew line");
    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nnew line\"", list.items);
}
