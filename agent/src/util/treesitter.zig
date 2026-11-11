//! tree-sitter 语法校验（③ 里程碑 1，2026-11-08）：FileEdit/FileWrite 落
//! 盘后对支持的语言重解析一次，发现 ERROR/MISSING 节点就把首个错误的位置
//! 附在工具结果里——模型看见即自纠，不用等下一次构建/运行才暴露。
//! 毫秒级（单文件解析），不跑构建。
//!
//! 边界（刻意）：只给语法树，不给类型/引用（那是 LSP 的领地，ziv 明确
//! 不做）；超过 1MB 的文件跳过（防机器生成大文件拖慢回合）；未知扩展名
//! 静默跳过。语言集：py/js/ts/tsx/java/zig（vendor 清单见
//! deps/tree-sitter/README.md）。

const std = @import("std");
const c = @import("treesitter"); // build.zig translate-c (api.h)

/// 各语法的入口符号（parser.c 底部定义；scanner 符号同前缀，链接无冲突）。
extern fn tree_sitter_python() *const c.TSLanguage;
extern fn tree_sitter_javascript() *const c.TSLanguage;
extern fn tree_sitter_typescript() *const c.TSLanguage;
extern fn tree_sitter_tsx() *const c.TSLanguage;
extern fn tree_sitter_java() *const c.TSLanguage;
extern fn tree_sitter_zig() *const c.TSLanguage;

pub const Lang = enum {
    python,
    javascript,
    typescript,
    tsx,
    java,
    zig,

    pub fn language(self: Lang) *const c.TSLanguage {
        return switch (self) {
            .python => tree_sitter_python(),
            .javascript => tree_sitter_javascript(),
            .typescript => tree_sitter_typescript(),
            .tsx => tree_sitter_tsx(),
            .java => tree_sitter_java(),
            .zig => tree_sitter_zig(),
        };
    }
};

/// 按扩展名映射语言（未知 → null = 不校验）。这是唯一的语言判定事实源。
pub fn langForPath(path: []const u8) ?Lang {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".py", Lang.python },
        .{ ".pyi", Lang.python },
        .{ ".js", Lang.javascript },
        .{ ".mjs", Lang.javascript },
        .{ ".cjs", Lang.javascript },
        .{ ".ts", Lang.typescript },
        .{ ".mts", Lang.typescript },
        .{ ".tsx", Lang.tsx },
        .{ ".java", Lang.java },
        .{ ".zig", Lang.zig },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, ext, pair[0])) return pair[1];
    }
    return null;
}

/// 首个语法错误（1-based 行列，人读格式）。
pub const SyntaxError = struct {
    line: u32,
    col: u32,
    /// "ERROR" 节点或缺失的 token 名（如 "missing \")\""）。
    detail: [64]u8,
    detail_len: usize,

    pub fn detailText(self: *const SyntaxError) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

/// 单文件解析上限：机器生成的大文件（lockfix、dist 产物）不值得进回合。
pub const PARSE_SIZE_CAP: usize = 1024 * 1024;

/// 解析并返回首个 ERROR/MISSING 节点；无错误/超限/解析失败 → null。
/// 线程安全：parser/tree 都是本次调用的局部对象，无共享状态。
pub fn firstError(lang: Lang, src: []const u8) ?SyntaxError {
    if (src.len == 0 or src.len > PARSE_SIZE_CAP) return null;
    const parser = c.ts_parser_new() orelse return null;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, lang.language())) return null;
    // parse 深拷贝输入？——parse_string 只在解析期间读 src，树持有副本
    //（节点文本经 API 取回），返回后释放树即可。
    const tree = c.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len)) orelse return null;
    defer c.ts_tree_delete(tree);

    const root = c.ts_tree_root_node(tree);
    if (!c.ts_node_has_error(root)) return null; // 快路径：绝大多数编辑是对的

    // 前序游标走查，取第一个错误节点（has_error 已保证存在）。
    var cursor = c.ts_tree_cursor_new(root);
    defer c.ts_tree_cursor_delete(&cursor);
    while (true) {
        const node = c.ts_tree_cursor_current_node(&cursor);
        if (c.ts_node_is_missing(node)) {
            return errFromNode(node, true);
        }
        if (c.ts_node_is_error(node)) {
            return errFromNode(node, false);
        }
        if (c.ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (!c.ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!c.ts_tree_cursor_goto_parent(&cursor)) return null; // 走完：has_error 却没找到（理论不可达）
        }
    }
}

fn errFromNode(node: c.TSNode, missing: bool) SyntaxError {
    const start = c.ts_node_start_point(node);
    var e: SyntaxError = .{
        .line = @intCast(start.row + 1),
        .col = @intCast(start.column + 1),
        .detail = undefined,
        .detail_len = 0,
    };
    const typ = c.ts_node_type(node);
    const prefix: []const u8 = if (missing) "missing " else "";
    // typ 是静态符号名（ERROR 或缺失 token 名），生命周期随进程——截断复制。
    var fb: [48]u8 = undefined;
    const t = if (typ != null) std.mem.sliceTo(typ.?, 0) else "?";
    const t_cut = if (t.len > fb.len) t[0..fb.len] else t;
    @memcpy(fb[0..t_cut.len], t_cut);
    e.detail_len = (std.fmt.bufPrint(&e.detail, "{s}{s}", .{ prefix, t_cut }) catch return e).len;
    return e;
}

/// 工具结果附加行（FileEdit/FileWrite 共用）。null 错误 → 空串。
/// caller 持有返回值（alloc 分配）。
/// 措辞刻意容错：语法器有已知盲区（如 Zig 0.14 的多重声明解构），
/// 「确信正确就继续」防止模型在误报上空转烧回合。
pub fn formatWarning(alloc: std.mem.Allocator, path: []const u8, e: *const SyntaxError) ?[]u8 {
    const short = std.fs.path.basename(path);
    return std.fmt.allocPrint(alloc, "\n[语法检查] ⚠ {s}:{d}:{d} {s}（tree-sitter）。若该行确为合法语法（新语言特性可能是语法器盲区）可忽略，否则请修复", .{
        short, e.line, e.col, e.detailText(),
    }) catch null;
}

/// 落盘后的校验入口：未知扩展名/超限/无错误 → null（零成本跳过）；
/// 有错 → 附加行。FileEdit/FileWrite 在写成功后调用（喂内存里的新内容，
/// 不再回读磁盘）。
pub fn appendValidationWarning(alloc: std.mem.Allocator, path: []const u8, new_contents: []const u8) ?[]u8 {
    const lang = langForPath(path) orelse return null;
    var e = firstError(lang, new_contents) orelse return null;
    return formatWarning(alloc, path, &e);
}

// ──── tests ────

test "langForPath maps extensions, unknown → null" {
    try std.testing.expectEqual(Lang.python, langForPath("a/b/c.py"));
    try std.testing.expectEqual(Lang.typescript, langForPath("x.ts"));
    try std.testing.expectEqual(Lang.tsx, langForPath("x.tsx"));
    try std.testing.expectEqual(Lang.javascript, langForPath("x.mjs"));
    try std.testing.expectEqual(Lang.zig, langForPath("src/main.zig"));
    try std.testing.expectEqual(Lang.java, langForPath("A.java"));
    try std.testing.expect(langForPath("a.txt") == null);
    try std.testing.expect(langForPath("noext") == null);
}

test "firstError: valid sources pass, broken ones report 1-based position" {
    // Python：未闭合括号 → ERROR。
    if (firstError(.python, "def f(:\n  return 1\n")) |e| {
        try std.testing.expect(e.line >= 1 and e.col >= 1);
    } else {
        // 坏样本没被标出 = 校验器坏了。
        return error.BrokenPythonNotFlagged;
    }
    // 正常 Python 不报。
    try std.testing.expect(firstError(.python, "def f():\n    return 1\n") == null);

    // Zig：缺分号。
    if (firstError(.zig, "const x = 1\nconst y = 2;\n")) |e| {
        _ = e;
    } else return error.BrokenZigNotFlagged;
    try std.testing.expect(firstError(.zig, "const x: u8 = 1;\n") == null);

    // JS/TS/TSX/Java 各自过一遍正反例（报错位置不深究，只验正负判定）。
    try std.testing.expect(firstError(.javascript, "const a = 1;\n") == null);
    if (firstError(.javascript, "const a = ;\n")) |_| {} else return error.BrokenJsNotFlagged;
    try std.testing.expect(firstError(.typescript, "const a: number = 1;\n") == null);
    if (firstError(.typescript, "const a: = 1;\n")) |_| {} else return error.BrokenTsNotFlagged;
    try std.testing.expect(firstError(.tsx, "const a = <div>hi</div>;\n") == null);
    try std.testing.expect(firstError(.java, "class A { int x = 1; }\n") == null);
    if (firstError(.java, "class A { int x = ; }\n")) |_| {} else return error.BrokenJavaNotFlagged;

    // 尺寸帽：超 1MB 直接跳过（不解析不报错）。
    var big: [PARSE_SIZE_CAP + 1]u8 = @splat('x');
    try std.testing.expect(firstError(.python, big[0..]) == null);
}

test "formatWarning includes path line col" {
    const alloc = std.testing.allocator;
    var e: SyntaxError = .{ .line = 3, .col = 7, .detail = undefined, .detail_len = 0 };
    e.detail_len = (std.fmt.bufPrint(&e.detail, "ERROR", .{}) catch return error.Test).len;
    const w = formatWarning(alloc, "src/a.py", &e) orelse return error.Test;
    defer alloc.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "a.py:3:7") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "语法检查") != null);
}


// 回归门：真实代码语料零误报基线。当前已知豁免 1 处——config_menu.zig
// 的 Zig 多重声明解构（maxxnino 语法器不认 0.14 新语法）。语法器升级
// 支持后把上限收回 0。
test "false-positive scan over this repo's real code" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();
    var flagged: usize = 0;
    var total: usize = 0;
    var total_ms: i64 = 0;
    const dirs = [_][]const u8{ "src", "src/util", "src/tools", "src/turn", "src/session", "src/commands", "src/agent", "src/llm", "src/memory", "src/knowledge", "src/hooks", "src/mcp", "src/skills", "src/runtime", "src/storage", "src/task", "src/checkpoint", "src/math", "src/research", "scripts", "deps/sqlite3", "examples" };
    for (dirs) |dir_name| {
        var d = std.Io.Dir.cwd().openDir(io, dir_name, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            if (ent.kind != .file) continue;
            const lang = langForPath(ent.name) orelse continue;
            var pb: [512]u8 = undefined;
            const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir_name, ent.name }) catch continue;
            const src = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, p, alloc, std.Io.Limit.limited(4 * 1024 * 1024)) catch continue;
            defer alloc.free(src);
            total += 1;
            const t0 = @import("time.zig").nowMillis();
            const e = firstError(lang, src);
            total_ms += @import("time.zig").nowMillis() - t0;
            if (e) |err| {
                flagged += 1;
                std.debug.print("FP? {s}:{d}:{d} {s}\n", .{ p, err.line, err.col, err.detailText() });
            }
        }
    }
    std.debug.print("SCAN: {d}/{d} flagged, {d}ms total parse\n", .{ flagged, total, total_ms });
    try std.testing.expect(flagged <= 1); // 已知豁免：Zig 解构语法（见上）
}
