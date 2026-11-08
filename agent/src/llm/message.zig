/// JSON string escaping shared by the LLM backends. (The old
/// serializeMessages/serializeContentBlock helpers were removed: pre-0.16
/// ArrayList/Writer API that no longer compiled, and a wire format that
/// embedded Anthropic content-blocks into every backend — each backend now
/// serializes its own request body.)
const std = @import("std");

/// Write a JSON-escaped string.
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeAll("\"");
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
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
            i += 1;
            continue;
        }
        // 多字节序列：完整校验（长度、连续字节、无 overlong/代理——
        // utf8Decode 全查）。坏序列 → U+FFFD 并前进 1 字节：GBK 工具
        // 输出、截断的多字节曾把 0xb0 直接送进请求体，网关 Jackson
        // 拒收整个请求（400 InvalidRequest，2026-11-09 用户会话实测）
        // ——此后每条消息都驮着毒历史全灭。有损替换优于整请求报废。
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            try writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            try writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(s[i .. i + len]) catch {
            try writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        try writer.writeAll(s[i .. i + len]);
        i += len;
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

test "writeJsonString sanitizes invalid UTF-8 to U+FFFD (GBK 工具输出毒历史修复)" {
    const alloc = std.testing.allocator;
    // GBK 高频坏形态：孤立 0xb0、截断的三字节序列、合法中文混排。
    const poison = "ok\xb0中文\xe6\xb0tail\x80";
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeJsonString(&aw.writer, poison);
    const out = aw.written();
    // 输出必须是合法 UTF-8（网关 Jackson 的硬要求）。
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    // 坏字节逐个变 U+FFFD；合法「中文」原样保留。
    var fffd: usize = 0;
    var i: usize = 0;
    while (i + 3 <= out.len) : (i += 1) {
        if (std.mem.eql(u8, out[i .. i + 3], "\u{FFFD}")) fffd += 1;
    }
    try std.testing.expect(fffd >= 3); // \xb0 + 截断的 \xe6\xb0 + \x80
    try std.testing.expect(std.mem.indexOf(u8, out, "中文") != null);
}
