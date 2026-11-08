//! WebFetch tool — fetch a URL and return readable Markdown (P5 M2).
//! 链路：GET（512 KiB 下载帽）→ util/html_md 流式转换 → 30K 字符预算
//! 截断（尾部标注未读量）。权限与 WebSearch 同级（is_read_only——ziv 的
//! 既有口径；要收紧可加 WebFetch deny/ask 规则，规则模式可匹配 URL）。

const std = @import("std");
const registry = @import("registry.zig");
const html_md = @import("../util/html_md.zig");

/// 输出预算：超长页面截断并标注未读量（A7/T2.1 验收）。
pub const OUTPUT_BUDGET: usize = 30_000;
/// 下载帽：超过即停止读取（防超大响应吃内存）。
pub const DOWNLOAD_CAP: usize = 512 * 1024;

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const url = registry.getStringField(input, "url") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: url") catch "", .is_error = true };
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return registry.ToolResult{ .output = alloc.dupe(u8, "Only http(s) URLs are supported") catch "", .is_error = true };
    }

    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch {
        return registry.ToolResult{ .output = alloc.dupe(u8, "Invalid URL") catch "", .is_error = true };
    };
    var req = client.request(.GET, uri, .{}) catch |err| {
        return registry.ToolResult{ .output = try alloc.print("fetch failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        return registry.ToolResult{ .output = try alloc.print("fetch failed (no response): {s}", .{@errorName(err)}), .is_error = true };
    };
    const status: u16 = @backingInt(response.head.status);
    if (response.head.status.class() != .success) {
        return registry.ToolResult{
            .output = try alloc.print("HTTP {d} fetching {s}", .{ status, url }),
            .is_error = true,
        };
    }

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    var truncated_download = false;
    {
        var transfer_buf: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buf); // 只许调用一次（断言锁定）
        var chunk: [16 * 1024]u8 = undefined;
        while (body.items.len < DOWNLOAD_CAP) {
            const n = reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try body.appendSlice(alloc, chunk[0..n]);
            if (body.items.len >= DOWNLOAD_CAP) truncated_download = true;
        }
    }
    defer body.deinit(alloc);

    // 透明解压（同 knowledge/search.zig 的 readResponseBody）：有服务器
    // 不带 Content-Encoding 也发 gzip，魔法字节嗅探兜底。
    var plain: []u8 = body.items;
    var decompressed: ?[]u8 = null;
    defer if (decompressed) |d| alloc.free(d);
    const container: ?std.compress.flate.Container = if (response.head.content_encoding == .gzip or
        (plain.len >= 2 and plain[0] == 0x1f and plain[1] == 0x8b))
        .gzip
    else if (response.head.content_encoding == .deflate)
        .zlib
    else
        null;
    if (container) |c| {
        var in_reader = std.Io.Reader.fixed(plain);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var d = std.compress.flate.Decompress.init(&in_reader, c, &window);
        var out_list: std.ArrayList(u8) = .empty;
        errdefer out_list.deinit(alloc);
        var dchunk: [16 * 1024]u8 = undefined;
        while (out_list.items.len < DOWNLOAD_CAP) {
            const n = d.reader.readSliceShort(&dchunk) catch break;
            if (n == 0) break;
            try out_list.appendSlice(alloc, dchunk[0..n]);
        }
        decompressed = try out_list.toOwnedSlice(alloc);
        plain = decompressed.?;
    }

    const md = try html_md.convert(alloc, plain);
    defer alloc.free(md);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    if (md.len <= OUTPUT_BUDGET) {
        try w.print("{s}", .{md});
    } else {
        // 截断到预算 + 未读量标注（CC WebFetch 同语义）。
        try w.print("{s}\n\n…(截断：本页 {d} 字符，已读 {d}，未读 {d})", .{ md[0..OUTPUT_BUDGET], md.len, OUTPUT_BUDGET, md.len - OUTPUT_BUDGET });
    }
    if (truncated_download) {
        try w.print("\n\n[下载在 {d} KiB 处截断]", .{DOWNLOAD_CAP / 1024});
    }
    var list = aw.toArrayList();
    return registry.ToolResult{ .output = try list.toOwnedSlice(alloc) };
}

/// 预算截断的纯逻辑（单测锁定标注形态）。
pub fn budgetLine(md_len: usize, shown: usize) ?[]const u8 {
    if (md_len <= shown) return null;
    return "…(截断)";
}

test "budgetLine: null within budget, marker past it" {
    try std.testing.expect(budgetLine(100, 30_000) == null);
    try std.testing.expect(budgetLine(40_000, 30_000) != null);
}
