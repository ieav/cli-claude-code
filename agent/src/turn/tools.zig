/// Tool-phase machinery (P1 extraction from repl.zig — pure move):
/// PreparedCall/LastTools, full-body output display, finishToolCall,
/// colorized code-diff preview. Executed by the turn loop ToolJob.
const std = @import("std");
const registry = @import("../tools/registry.zig");
const op_log = @import("../checkpoint/op_log.zig");
const llm = @import("../llm/mod.zig");
const lineinput = @import("../util/lineinput.zig");
const logger = @import("../util/log.zig");
const util_time = @import("../util/time.zig");
const diff_util = @import("../util/diff.zig");
const orchestration_mod = @import("../tools/orchestration.zig");
const allocator = std.heap.smp_allocator;

const DIFF_MAX_LINES: usize = 1000;
const DIFF_MAX_COLS: usize = 110;
const DIFF_MAX_DIFFABLE_LINES: usize = 800;

pub fn isFileModifyingTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "FileWrite") or
        std.mem.eql(u8, tool_name, "FileEdit") or
        std.mem.eql(u8, tool_name, "Write") or
        std.mem.eql(u8, tool_name, "Edit");
}

/// Execute a single tool call and record result.
/// A tool_use that passed the permission gate in phase 1 and is queued for
/// execution (possibly in parallel) in phase 2.
pub const PreparedCall = struct {
    call: orchestration_mod.ToolCall,
    snap_id: ?[16]u8,
    /// File bytes captured BEFORE a write-style tool runs — the diff
    /// preview is rendered after execution, when it's too late to read.
    old_content: ?[]u8 = null,
    /// Prior content exists but can't be shown (oversized / unreadable) —
    /// skip the preview rather than mislabel the overwrite as a new file.
    old_unavailable: bool = false,
};

/// Ring of recent tool outputs backing /last (③, 2026-11-06): the
/// transcript shows a one-line preview by design; this answers "它刚才
/// 到底输出了什么" without re-running anything. 8 slots × 8 KiB.
pub const LastTools = struct {
    pub const N: usize = 8;
    pub const CAP: usize = 8 * 1024;
    var buf: [N * CAP]u8 = undefined;
    var lens: [N]usize = @splat(0);
    var names: [N][32]u8 = undefined;
    var name_lens: [N]usize = @splat(0);
    var head: usize = 0; // next write slot; newest lives at (head+N-1)%N
    var count: usize = 0;

    pub fn push(name: []const u8, output: []const u8) void {
        const i = head;
        lens[i] = @min(output.len, CAP);
        @memcpy(buf[i * CAP .. i * CAP + lens[i]], output[0..lens[i]]);
        const nl = @min(name.len, names[i].len);
        @memcpy(names[i][0..nl], name[0..nl]);
        name_lens[i] = nl;
        head = (head + 1) % N;
        count = @min(count + 1, N);
    }

    /// n=1 → newest. Null when nothing recorded / out of range.
    pub fn get(n: usize) ?struct { name: []const u8, output: []const u8 } {
        if (n == 0 or n > count) return null;
        const i = (head + N - n) % N;
        return .{ .name = names[i][0..name_lens[i]], .output = buf[i * CAP .. i * CAP + lens[i]] };
    }
};

/// Full tool output into the transcript, 2-space indented, one line per
/// print (line-atomic above the live region via RegionWriter; markdown-
/// table rows still align). Bounded: past 50 lines or LastTools.CAP
/// bytes a dim tail marker points at /last — the ring keeps its full
/// 8 KiB regardless of what the transcript showed. The byte cut backs
/// off to a UTF-8 boundary so a mid-汉字 slice can't mojibake.
/// P3c Ctrl+O 工具输出详细/简要（默认详细=今日行为；Claude Code 同键
/// 语义）。简要态只出前 3 行 + 折叠标记。只影响后续输出——已打印内容
/// 终端无法回溯折叠（CC 同此限制）。Atomic、relaxed 即可：UI 线程写、
/// 工具线程池读，只需无撕裂，无需顺序保证（2026-11-07 审查 B 项加固）。
pub var verbose_output = std.atomic.Value(bool).init(true);

pub fn printToolBody(w: *std.Io.Writer, raw: []const u8) void {
    const max_lines: usize = 50;
    if (!verbose_output.load(.monotonic)) {
        // Brief mode: first 3 lines + fold marker (long single lines fold
        // by bytes instead).
        var it = std.mem.splitScalar(u8, raw[0..@min(raw.len, LastTools.CAP)], '\n');
        var n: usize = 0;
        std.Io.Writer.writeAll(w, "\x1b[2m") catch {};
        while (it.next()) |ln| {
            if (n >= 3) break;
            var tb: [4096]u8 = undefined;
            const line = std.fmt.bufPrint(&tb, "  {s}\n", .{std.mem.trimEnd(u8, ln, " \t\r")}) catch "  …(单行超 4KiB)\n";
            std.Io.Writer.writeAll(w, line) catch {};
            n += 1;
        }
        const total = std.mem.count(u8, raw, "\n") + @intFromBool(raw.len > 0 and raw[raw.len - 1] != '\n');
        if (total > 3) {
            std.Io.Writer.print(w, "  \x1b[2m… +{d} 行（Ctrl+O 展开 · /last 查全文）\x1b[0m\n", .{total - 3}) catch {};
        }
        std.Io.Writer.writeAll(w, "\x1b[0m") catch {};
        return;
    }
    var cut = @min(raw.len, LastTools.CAP);
    while (cut > 0 and cut < raw.len and (raw[cut] & 0xC0) == 0x80) cut -= 1;
    var rest: []const u8 = raw[0..cut];
    var shown: usize = 0;
    // P3c 配色：工具体是参照物不是主信息——暗灰呈现，视线自然落在
    // 白色助手文本与青色工具调用头上。
    std.Io.Writer.writeAll(w, "\x1b[2m") catch {};
    while (rest.len > 0 and shown < max_lines) : (shown += 1) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        std.Io.Writer.print(w, "  {s}\n", .{std.mem.trimEnd(u8, rest[0..nl], " \t\r")}) catch {};
        rest = if (nl < rest.len) rest[nl + 1 ..] else "";
    }
    std.Io.Writer.writeAll(w, "\x1b[0m") catch {};
    const total_lines = std.mem.count(u8, raw, "\n") + @intFromBool(raw.len > 0 and raw[raw.len - 1] != '\n');
    // Byte-cap truncation (one huge line) shows no line-count difference —
    // `cut < raw.len` catches it (review ② 2026-11-06: an 8 KiB slice of a
    // 10 KiB single line printed unmarked).
    if (shown < total_lines or cut < raw.len) {
        std.Io.Writer.print(w, "  \x1b[2m…已截断（显示 {d}/{d} 行）· /last 查全文\x1b[0m\n", .{ shown, total_lines }) catch {};
    }
}

test "printToolBody: verbatim body, cap marker, empty" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    printToolBody(&aw.writer, "one\ntwo\n");
    try std.testing.expectEqualStrings("\x1b[2m  one\n  two\n\x1b[0m", aw.written());
    // 55 lines: 50 shown + cap marker naming the true total.
    var buf: [300]u8 = undefined;
    var f = std.Io.Writer.fixed(&buf);
    var i: usize = 0;
    while (i < 55) : (i += 1) std.Io.Writer.print(&f, "l{d}\n", .{i}) catch unreachable;
    aw.clearRetainingCapacity();
    printToolBody(&aw.writer, f.buffered());
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "  l49\n") != null); // 50th line shown
    try std.testing.expect(std.mem.indexOf(u8, out, "  l50\n") == null); // 51st not
    try std.testing.expect(std.mem.indexOf(u8, out, "显示 50/55 行") != null);
    // Empty output: no body, no marker.
    aw.clearRetainingCapacity();
    printToolBody(&aw.writer, "");
    // Empty: just the style wrap pair, no rows.
    try std.testing.expectEqualStrings("\x1b[2m\x1b[0m", aw.written());
}

test "LastTools: ring order and wrap" {
    LastTools.head = 0;
    LastTools.count = 0;
    LastTools.push("bash", "out-1");
    LastTools.push("read", "out-2");
    try std.testing.expectEqualStrings("out-2", LastTools.get(1).?.output);
    try std.testing.expectEqualStrings("out-1", LastTools.get(2).?.output);
    try std.testing.expect(LastTools.get(3) == null);
    for (0..10) |_| LastTools.push("t", "x");
    try std.testing.expectEqual(@as(usize, LastTools.N), LastTools.count);
    try std.testing.expectEqualStrings("x", LastTools.get(1).?.output);
    try std.testing.expect(LastTools.get(LastTools.N + 1) == null);
}

/// Phase 2 tail: print the outcome, truncate oversized output, record in the
/// operation log, append the tool_result block. Returns true on tool error.
pub fn finishToolCall(
    p: PreparedCall,
    result: registry.ToolResult,
    alloc: std.mem.Allocator,
    log: *op_log.OperationLog,
    result_blocks: *std.ArrayList(llm.ContentBlock),
    w: *std.Io.Writer,
    ow: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    history_len: usize,
    elapsed_ms: i64,
) !bool {
    // Wall time from batch dispatch — for a parallel batch this includes
    // queue wait and overlaps siblings; per-tool exclusive time would
    // need per-future t0 plumbing the pool doesn't expose.
    logger.info("Tool execute: {s} ({d}ms)", .{ p.call.tool_name, elapsed_ms });

    // Tool phase: the region is already up (turn-scoped) — just swap the
    // STATUS text; the input row never flickers between phases anymore.
    lineinput.regionStatus(w, "⚙ 执行工具 · Esc 中断");

    // Colorized code-change preview (TUI-only, shown only on success).
    // Tool output itself stays compact — it feeds LLM history; the diff
    // never does. Render failures must not break tool flow. `ow` keeps
    // every diff line above the live region.
    if (!result.is_error and isFileModifyingTool(p.call.tool_name) and !p.old_unavailable) {
        var diff_arena = std.heap.ArenaAllocator.init(allocator);
        defer diff_arena.deinit();
        renderCodeDiff(ow, diff_arena.allocator(), p.call.input, p.old_content) catch {};
    }

    // Truncate large outputs for history — must dupe before freeing
    const max_result = 4096;
    const raw = result.output;
    const truncated = raw.len > max_result;

    // Full-body display (2026-11-06, user call — supersedes the ③ 80-col
    // one-liner): the preview made every interesting output a /last
    // round-trip. Bounded at 50 lines / 8 KiB so a runaway grep still
    // can't flood the screen; past the cap a dim marker points at /last.
    // Wall time carried live; tool name colored by outcome.
    LastTools.push(p.call.tool_name, raw);
    const name_col = if (result.is_error) "\x1b[31m" else "\x1b[36m";
    std.Io.Writer.print(ow, "  [{s}{s}\x1b[0m · {d}.{d}s]\n", .{
        name_col,
        p.call.tool_name,
        @divTrunc(elapsed_ms, 1000),
        @divTrunc(@mod(elapsed_ms, 1000), 100),
    }) catch {};
    printToolBody(ow, raw);

    // History copy: truncate at 4096 bytes — but BACK OFF to a UTF-8
    // char boundary. A mid-char cut used to poison every later request:
    // the gateway's JSON parser rejected the whole session with
    // "Invalid UTF-8 middle byte" (tool outputs full of CJK comments hit
    // the 4096th byte mid-汉字 all the time).
    var hist_cut: usize = max_result;
    while (hist_cut > 0 and hist_cut < raw.len and (raw[hist_cut] & 0xC0) == 0x80) hist_cut -= 1;
    const content_for_history: []const u8 = if (truncated)
        try alloc.dupe(u8, raw[0..hist_cut])
    else
        raw; // ownership transfers, no dupe needed

    try result_blocks.append(alloc, .{
        .tool_result = .{
            // Duped: p.call.tool_use_id borrows the assistant message's id —
            // history must own its own copy or clearHistory double-frees.
            .tool_use_id = try alloc.dupe(u8, p.call.tool_use_id),
            .content = content_for_history,
            .is_error = result.is_error,
        },
    });
    _ = log.record(p.call.tool_name, "executed", result.output, p.snap_id, p.snap_id != null, history_len) catch {};
    if (truncated) {
        // History owns the dupe; the original (error or not) is spent.
        alloc.free(result.output);
    }
    // If not truncated, content_for_history == result.output; ownership moved into history
    try std.Io.File.Writer.flush(file_writer);
    return result.is_error;
}

// ──── Code-change diff preview ────

/// Render a colorized preview of what a file-modifying tool actually
/// changed: removed lines in red, added in green, dim overflow note —
/// visually distinct from every other TUI line so edits scan fast.
/// edit-style tools (old_string/new_string) diff those strings directly;
/// write-style tools (content) diff the captured pre-write bytes.
/// `alloc` is a per-call scratch arena — nothing here outlives the print.
/// `w` is the region-aware transcript writer: every line lands above the
/// live region during a turn (see lineinput.RegionWriter).
pub fn renderCodeDiff(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    input: std.json.Value,
    old_content: ?[]const u8,
) !void {
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const dim = "\x1b[2m";
    const reset = "\x1b[0m";

    var old_text: ?[]const u8 = null; // null → brand-new content
    var new_text: []const u8 = "";
    var replace_all = false;
    if (registry.getStringField(input, "old_string")) |old_s| {
        old_text = old_s;
        new_text = registry.getStringField(input, "new_string") orelse "";
        replace_all = registry.getBool(input, "replaceAll") orelse false;
    } else if (registry.getStringField(input, "content")) |content| {
        new_text = content;
        if (old_content) |oc| old_text = oc;
    } else return; // nothing diffable on this input

    var lines: std.ArrayList(diff_util.DiffLine) = .empty;
    if (old_text) |ot| {
        // computeDiff hides lines common to both sides — an old_string
        // that carries surrounding context would otherwise echo it twice.
        const old_rows = std.mem.count(u8, ot, "\n") + 1;
        const new_rows = std.mem.count(u8, new_text, "\n") + 1;
        if (old_rows > DIFF_MAX_DIFFABLE_LINES or new_rows > DIFF_MAX_DIFFABLE_LINES) {
            try std.Io.Writer.print(w, "  " ++ dim ++ "（{d} 行 → {d} 行，改动过大不展开 diff）" ++ reset ++ "\n", .{ old_rows, new_rows });
            return;
        }
        const d = try diff_util.computeDiff(alloc, ot, new_text);
        for (d) |dl| {
            if (dl.kind != .equal) try lines.append(alloc, dl);
        }
    } else {
        for (try diffSplitLines(alloc, new_text)) |l| {
            try lines.append(alloc, .{ .kind = .added, .content = l });
        }
    }

    var i: usize = 0;
    while (i < lines.items.len and i < DIFF_MAX_LINES) : (i += 1) {
        const trunc = try diffTruncLine(alloc, lines.items[i].content, DIFF_MAX_COLS);
        switch (lines.items[i].kind) {
            .removed => try std.Io.Writer.print(w, "  " ++ red ++ "- {s}" ++ reset ++ "\n", .{trunc}),
            .added => try std.Io.Writer.print(w, "  " ++ green ++ "+ {s}" ++ reset ++ "\n", .{trunc}),
            .equal => {},
        }
    }
    if (i < lines.items.len) {
        try std.Io.Writer.print(w, "  " ++ dim ++ "…（还有 {d} 行未显示）" ++ reset ++ "\n", .{lines.items.len - i});
    } else if (old_text == null and lines.items.len > 0) {
        try std.Io.Writer.print(w, "  " ++ dim ++ "（新文件 · {d} 行）" ++ reset ++ "\n", .{lines.items.len});
    }
    if (replace_all) {
        try std.Io.Writer.print(w, "  " ++ dim ++ "（replaceAll：所有匹配处同样替换）" ++ reset ++ "\n", .{});
    }
}

/// Split text into lines for diff display. splitSequence yields one
/// artifact empty element for a trailing "\n" — drop it (it would render
/// a dangling "+ "/"- " row after every normal file edit).
pub fn diffSplitLines(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, text, "\n");
    while (it.next()) |line| try lines.append(alloc, line);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines.toOwnedSlice(alloc);
}

/// Truncate one diff line to `max_cols` DISPLAY columns (CJK counts 2),
/// never cutting mid-UTF-8; tabs expand to 4 spaces so code indent stays
/// readable; other control bytes are stripped. Append "…" when cut.
pub fn diffTruncLine(alloc: std.mem.Allocator, s: []const u8, max_cols: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    var i: usize = 0;
    var cut = false;
    while (i < s.len) {
        const c = s[i];
        var piece: []const u8 = undefined;
        var cw: usize = undefined;
        if (c == '\t') {
            piece = "    ";
            cw = 4;
            i += 1;
        } else if (c < 0x20) {
            i += 1;
            continue;
        } else {
            var j = i + 1;
            while (j < s.len and (s[j] & 0xC0) == 0x80) j += 1;
            piece = s[i..j];
            cw = if (c >= 0xE0) 2 else 1;
            i = j;
        }
        if (col + cw > max_cols - 1) { // keep one column for the ellipsis
            cut = true;
            break;
        }
        try out.appendSlice(alloc, piece);
        col += cw;
    }
    if (cut) try out.appendSlice(alloc, "…");
    return out.toOwnedSlice(alloc);
}

// ──── Conversation management helpers ────

test "diffSplitLines drops only the artifact trailing empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const two = try diffSplitLines(a, "a\nb\n");
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("b", two[1]);

    const no_nl = try diffSplitLines(a, "x");
    try std.testing.expectEqual(@as(usize, 1), no_nl.len);

    // "a\n\n" has a REAL blank line — only the split artifact goes.
    const blank = try diffSplitLines(a, "a\n\n");
    try std.testing.expectEqual(@as(usize, 2), blank.len);
    try std.testing.expectEqualStrings("", blank[1]);

    const empty = try diffSplitLines(a, "");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "diffTruncLine caps display width CJK-aware, expands tabs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const short = try diffTruncLine(a, "const x = 1;", DIFF_MAX_COLS);
    try std.testing.expectEqualStrings("const x = 1;", short);

    // CJK chars are 2 columns: cap 6 → 2 chars + ellipsis.
    const cjk = try diffTruncLine(a, "中文注释内容", 6);
    try std.testing.expectEqualStrings("中文…", cjk);

    // Never cuts mid-UTF-8: "中" needs 2 cols but only 1 is left.
    const boundary = try diffTruncLine(a, "ab中", 3);
    try std.testing.expectEqualStrings("ab…", boundary);

    const tab = try diffTruncLine(a, "\tfoo", DIFF_MAX_COLS);
    try std.testing.expectEqualStrings("    foo", tab);
}

test "renderCodeDiff colors edits and hides unchanged context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    // old_string carries surrounding context ("a"/"c") that appears on
    // both sides — it must not be echoed as a -/+ pair.
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"f.zig\",\"old_string\":\"a\\nb\\nc\",\"new_string\":\"a\\nX\\nc\"}", .{});
    try renderCodeDiff(&aw.writer, a, input, null);

    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[31m- b\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[32m+ X\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- a") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- c") == null);

    // Write-style with no prior content → all green + new-file footer.
    aw.writer.end = 0;
    const wr = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"new.zig\",\"content\":\"line1\\nline2\"}", .{});
    try renderCodeDiff(&aw.writer, a, wr, null);
    const out2 = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out2, "\x1b[32m+ line1\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "新文件 · 2 行") != null);

    // Oversized input: summary line only, no per-line diff.
    aw.writer.end = 0;
    var big_old: std.ArrayList(u8) = .empty;
    var big_new: std.ArrayList(u8) = .empty;
    for (0..DIFF_MAX_DIFFABLE_LINES + 1) |_| {
        try big_old.appendSlice(a, "old line\n");
        try big_new.appendSlice(a, "new line\n");
    }
    var big_obj: std.json.ObjectMap = .empty;
    try big_obj.put(a, "old_string", .{ .string = big_old.items });
    try big_obj.put(a, "new_string", .{ .string = big_new.items });
    try renderCodeDiff(&aw.writer, a, .{ .object = big_obj }, null);
    const out3 = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out3, "改动过大不展开 diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, out3, "\x1b[31m- old line") == null);
}
