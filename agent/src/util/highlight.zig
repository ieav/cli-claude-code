//! Syntax highlighting for CODE shown in the TUI (2026-11-11) — One Dark
//! palette over the SAME tree-sitter grammars the edit checker uses
//! (py/js/ts/tsx/java/zig; zero new deps).
//!
//! Where it hooks: the code-diff preview (+/- lines keep their red/green
//! prefixes; the line CONTENT gets token colors) and FileRead's verbose
//! body. Plain-text output when NOT a TTY or NO_COLOR is set — pipes and
//! the tests see the untouched bytes (tests target renderColored directly).
//!
//! Classification is deliberately cheap (line-scoped parse, no symbol
//! tables): deepest-match painting where a node that matches a class
//! paints its WHOLE span and stops descending:
//!   comment / string / number   — by node-type substring (lowercased)
//!   keyword                     — UNNAMED nodes ≥2 chars, all alpha: in
//!                                 tree-sitter grammars multi-letter
//!                                 unnamed leaves ARE the keywords
//!                                 ("if", "return", "fn", "pub", …) —
//!                                 no per-language word lists needed
//!   function name               — the `function` field of call sites and
//!                                 the `name` field of declarations
//!   type                        — type_identifier / type_name leaves
//! Everything else keeps the terminal's default foreground (we do NOT
//! paint the base text — the user's terminal theme stays in charge).
const std = @import("std");
const ts = @import("treesitter.zig");
const c = @import("treesitter"); // build.zig translate-c
const menu = @import("menu.zig");
const env_mod = @import("env.zig");

/// One Dark token colors (truecolor).
pub const one_dark = struct {
    pub const keyword = [3]u8{ 0xc6, 0x78, 0xdd }; // purple
    pub const string = [3]u8{ 0x98, 0xc3, 0x79 }; // green
    pub const comment = [3]u8{ 0x5c, 0x63, 0x70 }; // gray
    pub const number = [3]u8{ 0xd1, 0x9a, 0x66 }; // orange
    pub const fn_name = [3]u8{ 0x61, 0xaf, 0xef }; // blue
    pub const type_name = [3]u8{ 0xe5, 0xc0, 0x7b }; // yellow
};

/// Highlighting enabled? TTY on BOTH ends and no NO_COLOR. Decided once —
/// the env/TTY answer cannot change mid-process for our stdin/stdout.
var enabled_cached: ?bool = null;
pub fn enabled() bool {
    if (enabled_cached) |e| return e;
    const e = menu.isTty() and env_mod.get("NO_COLOR") == null;
    enabled_cached = e;
    return e;
}

const Class = enum { keyword, string, comment, number, fn_name, type_name };

fn colorOf(cl: Class) [3]u8 {
    return switch (cl) {
        .keyword => one_dark.keyword,
        .string => one_dark.string,
        .comment => one_dark.comment,
        .number => one_dark.number,
        .fn_name => one_dark.fn_name,
        .type_name => one_dark.type_name,
    };
}

/// Public line API: colorize when enabled, otherwise a plain copy.
pub fn line(alloc: std.mem.Allocator, code: []const u8, lang: ?ts.Lang) ![]u8 {
    if (lang == null or !enabled()) return alloc.dupe(u8, code);
    return renderColored(alloc, code, lang.?);
}

/// Unconditional colorize (test surface; callers go through `line`).
pub fn renderColored(alloc: std.mem.Allocator, code: []const u8, lang: ts.Lang) ![]u8 {
    const parser = c.ts_parser_new() orelse return alloc.dupe(u8, code);
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, lang.language())) return alloc.dupe(u8, code);
    const tree = c.ts_parser_parse_string(parser, null, code.ptr, @intCast(code.len)) orelse return alloc.dupe(u8, code);
    defer c.ts_tree_delete(tree);
    const root = c.ts_tree_root_node(tree);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try emitNode(&aw.writer, alloc, code, root, false);
    return aw.toOwnedSlice();
}

fn emitNode(w: *std.Io.Writer, alloc: std.mem.Allocator, src: []const u8, node: c.TSNode, fnc_hint: bool) !void {
    const start = c.ts_node_start_byte(node);
    const end = c.ts_node_end_byte(node);
    if (end <= start) return; // zero-width (ERROR inserts)
    const n_children = c.ts_node_child_count(node);
    const typ = std.mem.span(c.ts_node_type(node));
    const named = c.ts_node_is_named(node);

    // Whole-span classes first — paint and stop descending.
    if (classOfType(typ, named, src[start..end])) |cl| {
        return emitSpan(w, src[start..end], cl);
    }
    // Function-name painting: an identifier reached via the `function`
    // field of a call or the `name` field of a declaration paints blue.
    if (named and fnc_hint and std.mem.eql(u8, typ, "identifier")) {
        return emitSpan(w, src[start..end], .fn_name);
    }
    if (n_children == 0) {
        try w.writeAll(src[start..end]); // plain leaf (identifier, punct…)
        return;
    }
    // Descend, painting inter-node gaps verbatim.
    var cursor = start;
    var i: u32 = 0;
    while (i < n_children) : (i += 1) {
        const child = c.ts_node_child(node, i);
        const cs = c.ts_node_start_byte(child);
        const ce = c.ts_node_end_byte(child);
        if (cs > cursor) try w.writeAll(src[cursor..@min(cs, src.len)]);
        // Does this child sit at a function-name field position?
        const hint = fieldHint(node, child);
        try emitNode(w, alloc, src, child, hint);
        cursor = @max(cursor, ce);
    }
    if (cursor < end) try w.writeAll(src[cursor..@min(end, src.len)]);
}

/// True when `child` is the node a parent exposes as its `function` field
/// (call sites) or its `name` field (function/method declarations).
fn fieldHint(parent: c.TSNode, child: c.TSNode) bool {
    const ptyp = std.mem.span(c.ts_node_type(parent));
    const is_call = std.mem.indexOf(u8, ptyp, "call") != null;
    const is_decl = std.mem.indexOf(u8, ptyp, "function_decl") != null or
        std.mem.indexOf(u8, ptyp, "function_def") != null or
        std.mem.indexOf(u8, ptyp, "method_decl") != null;
    if (!is_call and !is_decl) return false;
    const fname: []const u8 = if (is_call) "function" else "name";
    const fnode = c.ts_node_child_by_field_name(parent, fname.ptr, @intCast(fname.len));
    // NULL node compares as start==end==0; a real child with both bytes 0
    // is zero-width (renders nothing), so the false hit is harmless.
    return c.ts_node_start_byte(fnode) == c.ts_node_start_byte(child) and
        c.ts_node_end_byte(fnode) == c.ts_node_end_byte(child) and
        c.ts_node_end_byte(child) > 0;
}

const lower_buf_max = 48;

fn classOfType(typ: []const u8, named: bool, text: []const u8) ?Class {
    // Keywords: multi-letter all-alpha UNNAMED leaves. Punctuation (≤1
    // char) and operators (non-alpha) fall through uncolored.
    if (!named) {
        if (typ.len >= 2 and allAlpha(typ)) return .keyword;
        return null;
    }
    var lb: [lower_buf_max]u8 = undefined;
    if (typ.len > lower_buf_max) return null;
    const lt = std.ascii.lowerString(&lb, typ);
    if (std.mem.indexOf(u8, lt, "comment") != null) return .comment;
    if (std.mem.indexOf(u8, lt, "string") != null) return .string;
    if (std.mem.indexOf(u8, lt, "number") != null or
        std.mem.indexOf(u8, lt, "integer") != null or
        std.mem.indexOf(u8, lt, "float") != null) return .number;
    if (std.mem.eql(u8, lt, "type_identifier") or std.mem.eql(u8, lt, "type_name") or
        std.mem.eql(u8, lt, "primitive_type")) return .type_name;
    _ = text;
    return null;
}

fn allAlpha(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isAlphabetic(ch)) return false;
    }
    return true;
}

fn emitSpan(w: *std.Io.Writer, text: []const u8, cl: Class) !void {
    const col = colorOf(cl);
    try w.print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{ col[0], col[1], col[2], text });
}

test "renderColored paints keyword/string/comment/number (py)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try renderColored(a, "return 42  # answer", .python);
    // keyword `return` purple, number orange, trailing comment gray.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;198;120;221mreturn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;209;154;102m42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;92;99;112m# answer") != null);
    // Plain space between tokens survives verbatim (gap painting).
    try std.testing.expect(std.mem.indexOf(u8, out, "mreturn\x1b[0m \x1b[") != null);
}

test "renderColored: js call name blue, string green, zig keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const js = try renderColored(a, "const s = readLine(\"hi\");", .javascript);
    try std.testing.expect(std.mem.indexOf(u8, js, "\x1b[38;2;198;120;221mconst") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\x1b[38;2;152;195;121m\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\x1b[38;2;97;175;239mreadLine") != null);
    const z = try renderColored(a, "pub fn main() void { }", .zig);
    try std.testing.expect(std.mem.indexOf(u8, z, "\x1b[38;2;198;120;221mpub") != null);
    try std.testing.expect(std.mem.indexOf(u8, z, "\x1b[38;2;198;120;221mfn") != null);
}

test "line() degrades to plain copy when disabled (tests are non-TTY)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try line(a, "return 1;", .python);
    try std.testing.expectEqualStrings("return 1;", out);
}
