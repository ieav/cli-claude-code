//! WebFetch tool — fetch a URL and return readable Markdown (P5 M2).
//! 链路：SSRF 地址闸（T6.1b）→ 逐跳重定向卡点（T6.2，2026-11-19：
//! `.unhandled` 模式手动跟跳，每跳重过 SSRF 闸 + 跨 host 仅许 www 增删，
//! 其余跨源返回新 URL 让模型显式重新 fetch——权限链再审一次）→ GET
//! （512 KiB 下载帽）→ util/html_md 流式转换 → 30K 字符预算截断（尾部
//! 标注未读量）。权限与 WebSearch 同级（is_read_only——ziv 的既有口
//! 径；要收紧可加 WebFetch deny/ask 规则，规则模式可匹配 URL）。

const std = @import("std");
const registry = @import("registry.zig");
const html_md = @import("../util/html_md.zig");
const llm_watchdog = @import("../util/llm_watchdog.zig");
const ssrf = @import("../util/ssrf.zig");

/// 输出预算：超长页面截断并标注未读量（A7/T2.1 验收）。
pub const OUTPUT_BUDGET: usize = 30_000;
/// 下载帽：超过即停止读取（防超大响应吃内存）。
pub const DOWNLOAD_CAP: usize = 512 * 1024;
/// 重定向上限（与 std 默认 3 跳一致；超限报错而非静默截断语义）。
pub const MAX_REDIRECTS: u8 = 3;

/// Uri.host 文本（剥 v6 方括号；host 组件实际不会被百分号编码）。
pub fn uriHostText(uri: std.Uri) []const u8 {
    const h = uri.host orelse return "";
    const b = switch (h) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
    if (b.len >= 2 and b[0] == '[' and b[b.len - 1] == ']') return b[1 .. b.len - 1];
    return b;
}

/// 跨 host 跳转策略（T6.2，CC 同款）：同 host（大小写不敏感）放行；
/// 仅 www. 增删视为同源；其余跨源拒绝（返回提示而非跟随）。
pub fn hostHopAllowed(prev: []const u8, next: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(prev, next)) return true;
    const p = if (std.ascii.startsWithIgnoreCase(prev, "www.")) prev[4..] else prev;
    const n = if (std.ascii.startsWithIgnoreCase(next, "www.")) next[4..] else next;
    return std.ascii.eqlIgnoreCase(p, n);
}

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const url = registry.getStringField(input, "url") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: url") catch "", .is_error = true };
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return registry.ToolResult{ .output = alloc.dupe(u8, "Only http(s) URLs are supported") catch "", .is_error = true };
    }

    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    var current_uri = std.Uri.parse(url) catch {
        return registry.ToolResult{ .output = alloc.dupe(u8, "Invalid URL") catch "", .is_error = true };
    };

    // 首跳 SSRF 闸（fail closed：解析失败即拒）。
    var prev_host = uriHostText(current_uri);
    if (!ssrf.hostAllowed(io, prev_host)) {
        return registry.ToolResult{
            .output = try alloc.print("blocked: {s} resolves to a private/loopback/link-local address (SSRF guard)", .{prev_host}),
            .is_error = true,
        };
    }

    // Location 解析缓冲（resolveInPlace 的产物引用它，须活过整个循环）。
    // 复审修正：aux_slice 跨跳【前推不重置】——上一跳 resolveInPlace 的
    // 产物（current_uri 的组件）正指向 aux 已用区，每跳重置回 &aux 会让
    // memcpy 覆写 base 自身（std http Client 同款前推语义）。耗尽时
    // resolveInPlace 报 NoSpaceLeft → 按 oversize 报错。
    var aux: [4096]u8 = undefined;
    var aux_slice: []u8 = &aux;
    var hops: u8 = 0;
    while (true) {
        var req = client.request(.GET, current_uri, .{ .redirect_behavior = .unhandled }) catch |err| {
            return registry.ToolResult{ .output = try alloc.print("fetch failed: {s}", .{@errorName(err)}), .is_error = true };
        };
        defer req.deinit();
        // 阻塞审计修复（2026-11-15）：Web 路径原先零超时——服务器连上后
        // 挂起不发字节时，下载帽永远打不中。看门狗：20s 首字节 / 30s 块
        // 间空闲，击杀以明确错误浮出。T6.2 起重定向由本循环手动逐跳处
        // 理，每跳独立武装（旧注释「redirect 换连接短暂脱管」随之作废）。
        var kill_reason = std.atomic.Value(u8).init(@backingInt(llm_watchdog.KillReason.none));
        const wd = llm_watchdog.armWeb(&req, &kill_reason);
        defer wd.finish();
        try req.sendBodiless();
        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            if (wd.ttftKilled())
                return registry.ToolResult{ .output = try alloc.print("fetch timed out: no response within {d}s (ziv watchdog) — {s}", .{ llm_watchdog.WEB_TTFT_MS / 1000, url }), .is_error = true };
            return registry.ToolResult{ .output = try alloc.print("fetch failed (no response): {s}", .{@errorName(err)}), .is_error = true };
        };
        wd.firstByte(); // 头已到：解除 TTFT 子线，空闲线从现在起算

        if (response.head.status.class() == .redirect) {
            hops += 1;
            if (hops > MAX_REDIRECTS) {
                return registry.ToolResult{
                    .output = try alloc.print("too many redirects (> {d}) fetching {s}", .{ MAX_REDIRECTS, url }),
                    .is_error = true,
                };
            }
            const loc = response.head.location orelse
                return registry.ToolResult{ .output = alloc.dupe(u8, "redirect without Location header") catch "", .is_error = true };
            if (loc.len == 0 or loc.len > aux_slice.len) {
                return registry.ToolResult{ .output = alloc.dupe(u8, "redirect Location missing or oversize") catch "", .is_error = true };
            }
            @memcpy(aux_slice[0..loc.len], loc);
            const next_uri = std.Uri.resolveInPlace(current_uri, loc.len, &aux_slice) catch {
                return registry.ToolResult{ .output = alloc.dupe(u8, "redirect Location is not a valid URI") catch "", .is_error = true };
            };
            // 每跳三闸：scheme 仍限 http(s)、SSRF 地址闸、跨 host 仅 www。
            if (!isHttpScheme(next_uri.scheme)) {
                return registry.ToolResult{ .output = try alloc.print("redirect to non-http scheme blocked: {s}", .{next_uri.scheme}), .is_error = true };
            }
            const next_host = uriHostText(next_uri);
            if (!ssrf.hostAllowed(io, next_host)) {
                return registry.ToolResult{
                    .output = try alloc.print("redirect blocked: {s} resolves to a private/loopback/link-local address (SSRF guard)", .{next_host}),
                    .is_error = true,
                };
            }
            if (!hostHopAllowed(prev_host, next_host)) {
                // CC 同语义：跨源不自动跟随，返回新 URL 让模型显式重新
                // fetch——用户/权限链有机会再审一次这个目标。
                return registry.ToolResult{
                    .output = try alloc.print("redirected cross-origin ({s} → {s}) — not followed automatically; fetch the new URL explicitly if intended", .{ prev_host, next_host }),
                };
            }
            prev_host = next_host;
            current_uri = next_uri;
            continue;
        }

        // 终跳：本作用域内走完取体管线（req/watchdog 存活期共用）。
        return try renderBody(alloc, &response, current_uri, url, wd);
    }
}

fn isHttpScheme(s: []const u8) bool {
    return std.mem.eql(u8, s, "http") or std.mem.eql(u8, s, "https");
}

/// 终跳取体：状态码检查 → 下载帽读取 → 透明解压 → Markdown 化 →
/// 预算截断（原 execute 尾段，T6.2 抽出复用）。
fn renderBody(
    alloc: std.mem.Allocator,
    response: *std.http.Client.Response,
    uri: std.Uri,
    orig_url: []const u8,
    wd: anytype,
) anyerror!registry.ToolResult {
    _ = uri;
    const status: u16 = @backingInt(response.head.status);
    if (response.head.status.class() != .success) {
        return registry.ToolResult{
            .output = try alloc.print("HTTP {d} fetching {s}", .{ status, orig_url }),
            .is_error = true,
        };
    }

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    var truncated_download = false;
    var stalled = false;
    {
        var transfer_buf: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buf); // 只许调用一次（断言锁定）
        var chunk: [16 * 1024]u8 = undefined;
        while (body.items.len < DOWNLOAD_CAP) {
            const n = reader.readSliceShort(&chunk) catch {
                // 看门狗击杀（块间空闲超 30s）→ 明确报错；其他传输错误维
                // 持原行为（跳出循环，按已有内容继续——错误页面常带部分体）。
                if (wd.idleKilled() or wd.ttftKilled()) stalled = true;
                break;
            };
            if (n == 0) break;
            wd.firstByte(); // 每个数据块推进空闲线：健康慢流不死
            try body.appendSlice(alloc, chunk[0..n]);
            if (body.items.len >= DOWNLOAD_CAP) truncated_download = true;
        }
    }
    defer body.deinit(alloc);
    if (stalled) {
        return registry.ToolResult{ .output = try alloc.print("fetch stalled: no data for {d}s mid-body (ziv watchdog, {d} bytes received) — {s}", .{ llm_watchdog.WEB_IDLE_MS / 1000, body.items.len, orig_url }), .is_error = true };
    }

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

test "T6.2 uriHostText: plain, v6 bracket stripped, empty" {
    const ua = std.Uri.parse("https://example.com/a") catch unreachable;
    try std.testing.expectEqualStrings("example.com", uriHostText(ua));
    const ub = std.Uri.parse("http://[::1]:8080/x") catch unreachable;
    try std.testing.expectEqualStrings("::1", uriHostText(ub));
}

test "T6.2 hostHopAllowed: same host, www add/drop ok, cross-origin rejected" {
    try std.testing.expect(hostHopAllowed("example.com", "example.com"));
    try std.testing.expect(hostHopAllowed("example.com", "www.example.com"));
    try std.testing.expect(hostHopAllowed("www.example.com", "example.com"));
    try std.testing.expect(hostHopAllowed("WWW.EXAMPLE.COM", "example.com"));
    try std.testing.expect(!hostHopAllowed("example.com", "evil.com"));
    try std.testing.expect(!hostHopAllowed("example.com", "sub.example.com"));
    try std.testing.expect(!hostHopAllowed("notwww.example.com", "example.com"));
}
