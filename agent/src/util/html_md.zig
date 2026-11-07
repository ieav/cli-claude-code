//! Minimal HTML → Markdown converter (P5 M2, A10 选型 a：手写流式转换，
//! 零新依赖——ziv 保持无 C 绑定)。服务 WebFetch：不求完整 DOM，只保
//! agent 读得动的结构——标题/段落/列表/链接/代码块/表格行。畸形输入
//! 按字面量吐出，永不 panic、永不死循环（每个分支都推进游标）。

const std = @import("std");

/// Convert an HTML page to readable Markdown. Caller frees the result.
pub fn convert(alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var pending_href: ?[]u8 = null; // open <a> 的 href（等待 </a> 收拢）
    defer if (pending_href) |h| alloc.free(h);
    var anchor_buf: std.ArrayList(u8) = .empty; // <a>inner</a> 的缓冲文本
    defer anchor_buf.deinit(alloc);
    var in_pre = false;

    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse {
                // 无 '>'：残缺标签按字面量吐出（流可能被截断）。
                try out.appendSlice(alloc, html[i..]);
                break;
            };
            const tag = html[i + 1 .. close];
            i = close + 1;
            const closing = tag.len > 0 and tag[0] == '/';
            const name = tagName(tag);

            if (eqAny(name, "script", "style")) {
                if (!closing) { // 跳到配对闭合（大小写不敏感）
                    if (findCloseTag(html, i, name)) |after| i = after;
                }
                continue;
            }
            if (eqAny(name, "pre", "code") and !closing and !in_pre and std.mem.eql(u8, name, "pre")) {
                in_pre = true;
                try out.appendSlice(alloc, "\n```\n");
                continue;
            }
            if (in_pre) {
                if (closing and std.mem.eql(u8, name, "pre")) {
                    in_pre = false;
                    try out.appendSlice(alloc, "\n```\n");
                }
                continue; // pre 内的任何其它标签按字面忽略
            }

            if (closing) {
                if (std.mem.eql(u8, name, "a")) {
                    if (pending_href) |h| {
                        if (anchor_buf.items.len > 0) {
                            try out.print(alloc, "[{s}]({s})", .{ anchor_buf.items, h });
                        }
                        alloc.free(h);
                        pending_href = null;
                    } else if (anchor_buf.items.len > 0) {
                        try out.appendSlice(alloc, anchor_buf.items);
                    }
                    anchor_buf.clearRetainingCapacity();
                } else if (std.mem.eql(u8, name, "p") or std.mem.eql(u8, name, "div") or
                    isHeading(name) or
                    std.mem.eql(u8, name, "ul") or std.mem.eql(u8, name, "ol") or
                    std.mem.eql(u8, name, "table") or std.mem.eql(u8, name, "blockquote"))
                {
                    try out.appendSlice(alloc, "\n\n"); // 块间空行
                } else if (std.mem.eql(u8, name, "tr") or std.mem.eql(u8, name, "li")) {
                    try out.append(alloc, '\n'); // 行级紧凑
                } else if (std.mem.eql(u8, name, "td") or std.mem.eql(u8, name, "th")) {
                    try out.appendSlice(alloc, " | ");
                }
                continue;
            }

            // 开标签
            if (std.mem.eql(u8, name, "a")) {
                if (findAttr(tag, "href")) |href| pending_href = try alloc.dupe(u8, href);
                anchor_buf.clearRetainingCapacity();
            } else if (std.mem.eql(u8, name, "br")) {
                try out.append(alloc, '\n');
            } else if (std.mem.eql(u8, name, "li")) {
                try out.appendSlice(alloc, "\n- ");
            } else if (isHeading(name)) {
                const level = name[1] - '0';
                try out.appendSlice(alloc, "\n\n");
                for (0..level) |_| try out.append(alloc, '#');
                try out.append(alloc, ' ');
            } else if (std.mem.eql(u8, name, "td") or std.mem.eql(u8, name, "th")) {
                // 单元格文本直接流式输出，闭合时补 " | "
            } else if (std.mem.eql(u8, name, "img")) {
                const alt = findAttr(tag, "alt") orelse "image";
                try out.print(alloc, "[图: {s}]", .{alt});
            } else if (std.mem.eql(u8, name, "blockquote")) {
                try out.appendSlice(alloc, "\n> ");
            }
            continue;
        }
        if (c == '&') {
            if (decodeEntity(html[i..])) |pair| {
                const dst = if (pending_href != null) &anchor_buf else &out;
                try dst.appendSlice(alloc, pair.decoded);
                i += pair.consumed;
                continue;
            }
        }
        // 普通字符：在 <a> 内收进锚缓冲，其余直出（pre 内也走这里）。
        const dst = if (pending_href != null) &anchor_buf else &out;
        try dst.append(alloc, c);
        i += 1;
    }
    // 未闭合的锚：别吞文本。
    if (pending_href) |h| {
        try out.appendSlice(alloc, anchor_buf.items);
        alloc.free(h);
        pending_href = null;
    }
    if (in_pre) try out.appendSlice(alloc, "\n```\n");

    // 压掉 3+ 连续换行为 2；去首尾空白。
    try collapseNewlines(alloc, &out);
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    const result = try alloc.dupe(u8, trimmed);
    out.deinit(alloc);
    return result;
}

fn eqAny(name: []const u8, comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, name, a) or std.mem.eql(u8, name, b);
}

fn isHeading(name: []const u8) bool {
    if (name.len != 2 or name[0] != 'h') return false;
    return name[1] >= '1' and name[1] <= '6';
}

/// 标签名（小写、去 '/' 与属性），缓冲区由调用方提供。
var tag_name_buf: [16]u8 = undefined;
fn tagName(tag: []const u8) []const u8 {
    var t = tag;
    if (t.len > 0 and (t[0] == '/' or t[0] == '!')) t = t[1..];
    var n: usize = 0;
    while (n < t.len and n < tag_name_buf.len and (std.ascii.isAlphanumeric(t[n]) or t[n] == '-')) : (n += 1) {}
    const out = tag_name_buf[0..n];
    for (out, 0..) |*ch, k| ch.* = std.ascii.toLower(t[k]);
    return out;
}

/// 找 `</name`（大小写不敏感）之后的位置——script/style 整段跳过。
fn findCloseTag(html: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (i < html.len) {
        const lt = std.mem.indexOfScalarPos(u8, html, i, '<') orelse return null;
        if (lt + 1 < html.len and html[lt + 1] == '/') {
            const after = html[lt + 2 ..];
            if (after.len >= name.len and std.ascii.eqlIgnoreCase(after[0..name.len], name)) {
                const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse return html.len;
                return gt + 1;
            }
        }
        i = lt + 1;
    }
    return null;
}

/// 从标签体提取属性值（href=/alt=，单双引号或裸值）。
fn findAttr(tag: []const u8, attr: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        const eq = std.mem.indexOfScalarPos(u8, tag, i, '=') orelse return null;
        // 属性名 = eq 前的最后一个词
        var s = eq;
        while (s > 0 and !std.ascii.isWhitespace(tag[s - 1])) s -= 1;
        const an = tag[s..eq];
        if (std.ascii.eqlIgnoreCase(an, attr) and eq + 1 < tag.len) {
            var v = tag[eq + 1 ..];
            if (v.len > 0 and (v[0] == '"' or v[0] == '\'')) {
                const q = v[0];
                v = v[1..];
                const end = std.mem.indexOfScalar(u8, v, q) orelse return null;
                return v[0..end];
            }
            const end = std.mem.indexOfAny(u8, v, " \t\r\n>") orelse v.len;
            return v[0..end];
        }
        i = eq + 1;
    }
    return null;
}

const Entity = struct { decoded: []const u8, consumed: usize };

fn decodeEntity(src: []const u8) ?Entity {
    const semi = std.mem.indexOfScalarPos(u8, src, 0, ';') orelse return null;
    if (semi == 0 or semi > 10) return null;
    const name = src[1..semi];
    if (name.len > 0 and name[0] == '#') {
        const cp: u21 = blk: {
            if (name.len > 1 and (name[1] == 'x' or name[1] == 'X')) {
                break :blk std.fmt.parseInt(u21, name[2..], 16) catch return null;
            }
            break :blk std.fmt.parseInt(u21, name[1..], 10) catch return null;
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return null;
        entity_buf = buf; // 单线程工具路径；立刻被拷贝
        return .{ .decoded = entity_buf[0..n], .consumed = semi + 1 };
    }
    const table = [_]struct { n: []const u8, r: []const u8 }{
        .{ .n = "amp", .r = "&" },   .{ .n = "lt", .r = "<" },
        .{ .n = "gt", .r = ">" },    .{ .n = "quot", .r = "\"" },
        .{ .n = "apos", .r = "'" },  .{ .n = "nbsp", .r = " " },
        .{ .n = "hellip", .r = "…" }, .{ .n = "mdash", .r = "—" },
        .{ .n = "ndash", .r = "–" }, .{ .n = "rsquo", .r = "'" },
        .{ .n = "lsquo", .r = "'" }, .{ .n = "ldquo", .r = "\"" },
        .{ .n = "rdquo", .r = "\"" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e.n)) return .{ .decoded = e.r, .consumed = semi + 1 };
    }
    return null;
}

var entity_buf: [4]u8 = undefined;

fn collapseNewlines(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    var n: usize = 0;
    var run: usize = 0;
    for (out.items) |c| {
        if (c == '\n') {
            run += 1;
            if (run <= 2) {
                out.items[n] = c;
                n += 1;
            }
        } else {
            run = 0;
            out.items[n] = c;
            n += 1;
        }
    }
    out.shrinkRetainingCapacity(n);
    _ = alloc;
}

// ──── Tests（P5 T2.2 验收：结构保留/剥离/实体/表格） ────

test "convert: script/style stripped, structure kept" {
    const a = std.testing.allocator;
    const md = try convert(a, "<html><head><script>var x=1;</script><style>p{}</style></head>" ++
        "<body><h1>Title</h1><p>para one</p><p>para &amp; two</p></body></html>");
    defer a.free(md);
    try std.testing.expectEqualStrings("# Title\n\npara one\n\npara & two", md);
    try std.testing.expect(std.mem.indexOf(u8, md, "var x") == null);
    try std.testing.expect(std.mem.indexOf(u8, md, "p{}") == null);
}

test "convert: links, lists, code fence, entities numeric" {
    const a = std.testing.allocator;
    const md = try convert(a, "<a href=\"https://x.y/z\">docs</a>" ++
        "<ul><li>one</li><li>two</li></ul>" ++
        "<pre>if (a &lt; b) { x(); }</pre>" ++
        "<p>&#65;&#66;C</p>");
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "[docs](https://x.y/z)") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n- one") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "```\nif (a < b) { x(); }\n```") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "ABC") != null);
}

test "convert: table rows as pipe lines; img alt; malformed literal" {
    const a = std.testing.allocator;
    const md = try convert(a, "<table><tr><th>k</th><th>v</th></tr><tr><td>a</td><td>b</td></tr></table>" ++
        "<img src=\"s.png\" alt=\"diagram\">" ++
        "<p>unclosed <b>bold");
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "k | v") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "a | b") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "[图: diagram]") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "unclosed bold") != null);
}

test "convert: empty and tag-only input" {
    const a = std.testing.allocator;
    const md = try convert(a, "");
    defer a.free(md);
    try std.testing.expectEqualStrings("", md);
    const md2 = try convert(a, "<br><br>");
    defer a.free(md2);
    try std.testing.expectEqualStrings("", md2);
}
