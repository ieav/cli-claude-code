//! History-facing slash-command bodies — /context, /undo, /rewind —
//! carved out of repl.zig (P1 step 7b, pure move). Rewind drives the
//! checkpoint engines (op_log + rollback) through a CookedGuard two-read
//! flow; the context ceiling const stays owned by repl.zig.

const std = @import("std");
const llm = @import("../llm/mod.zig");
const compaction = @import("../llm/compaction.zig");
const menu = @import("../util/menu.zig");
const op_log = @import("../checkpoint/op_log.zig");
const rollback_mod = @import("../checkpoint/rollback.zig");
const turn_history = @import("../turn/history.zig");
const repl_mod = @import("../repl.zig");

/// Show current context usage.
pub fn showContext(history: *std.ArrayList(llm.Message), total_in: u64, total_out: u64, w: *std.Io.Writer) !void {
    const est = turn_history.estimateHistoryTokens(history.items);
    const pct = @as(f64, @floatFromInt(est)) / @as(f64, @floatFromInt(repl_mod.MAX_CONTEXT_TOKENS)) * 100.0;

    // Count by role
    var counts = [_]usize{ 0, 0, 0, 0 }; // system, user, assistant, tool
    for (history.items) |msg| {
        switch (msg.role) {
            .system => counts[0] += 1,
            .user => counts[1] += 1,
            .assistant => counts[2] += 1,
            .tool => counts[3] += 1,
        }
    }

    const threshold = compaction.condensationTarget(repl_mod.MAX_CONTEXT_TOKENS);
    try std.Io.Writer.print(w, "\n  Context: {d} / {d} tokens ({d:.1}%)\n", .{ est, repl_mod.MAX_CONTEXT_TOKENS, pct });
    try std.Io.Writer.print(w, "  Messages: {d} system, {d} user, {d} assistant, {d} tool\n", .{
        counts[0], counts[1], counts[2], counts[3],
    });
    try std.Io.Writer.print(w, "  Compaction threshold: {d} tokens (61.8%)\n", .{threshold});
    try std.Io.Writer.print(w, "  Session total: {d} in / {d} out tokens\n\n", .{ total_in, total_out });
}

/// Undo last exchange (remove last assistant + any tool results).
/// Returns how many messages were actually removed — callers must only
/// bumpEpoch on a non-zero result (a no-op undo used to invalidate every
/// older rollback point's dialogue rewind).
pub fn undoLastExchange(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer) !usize {
    // Need at least system prompt + one user message + one assistant message
    if (history.items.len < 3) {
        try std.Io.Writer.writeAll(w, "  Nothing to undo.\n\n");
        return 0;
    }

    var removed: usize = 0;

    // Remove trailing assistant message
    if (history.items.len > 0) {
        const last = history.items[history.items.len - 1];
        if (last.role == .assistant) {
            const msg = history.pop().?;
            turn_history.freeMessage(msg, alloc);
            removed += 1;
        }
    }

    // Remove trailing tool-result user message (from agent loop)
    if (history.items.len > 0) {
        const last = history.items[history.items.len - 1];
        if (last.role == .user) {
            // Check if it contains tool_result blocks (agent loop feedback)
            var has_tool_result = false;
            for (last.content) |block| {
                if (block == .tool_result) {
                    has_tool_result = true;
                    break;
                }
            }
            if (has_tool_result) {
                const msg = history.pop().?;
                turn_history.freeMessage(msg, alloc);
                removed += 1;
            }
        }
    }

    // Remove trailing user message (the original prompt)
    if (history.items.len > 1) {
        const last = history.items[history.items.len - 1];
        if (last.role == .user) {
            const msg = history.pop().?;
            turn_history.freeMessage(msg, alloc);
            removed += 1;
        }
    }

    // Removing the results message above can strand the assistant tool_use
    // it answered — a dangling tool_calls gets the next request 400'd.
    const len_before_repair = history.items.len;
    turn_history.repairToolPairing(history, alloc);
    removed += len_before_repair - history.items.len;

    if (removed == 0) {
        try std.Io.Writer.writeAll(w, "  Nothing to undo.\n\n");
    } else {
        try std.Io.Writer.print(w, "  Undone: removed {d} message(s). History now has {d} messages.\n\n", .{ removed, history.items.len });
    }
    return removed;
}

/// Rewind: show rollback points and restore files to a previous checkpoint.
/// Claude-style: the conversation is rewound too — every message newer than
/// the checkpoint's timestamp is dropped, so files AND dialogue return to
/// that moment (the system prompt always survives).
pub fn rewindOperation(
    engine: *rollback_mod.RollbackEngine,
    history: *std.ArrayList(llm.Message),
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    const rollback_points = engine.listRollbackPoints() catch {
        try std.Io.Writer.writeAll(w, "  Error listing rollback points.\n\n");
        return;
    };
    defer alloc.free(rollback_points);

    if (rollback_points.len == 0) {
        try std.Io.Writer.writeAll(w, "  No rollback points available.\n");
        try std.Io.Writer.writeAll(w, "  Rollback requires file-modifying tools (FileWrite, FileEdit) to have been executed.\n\n");
        return;
    }

    try std.Io.Writer.print(w, "  Rollback points ({d}):\n", .{rollback_points.len});
    try std.Io.Writer.writeAll(w, "    [0] Session start (undo all file changes)\n");
    for (rollback_points, 0..) |rp, i| {
        var lb: [64]u8 = undefined;
        const excerpt = labelExcerpt(&lb, rp.turn_label);
        if (excerpt.len > 0) {
            try std.Io.Writer.print(w, "    [{d}] {s} (files: {d}) — \x1b[2m{s}\x1b[0m\n", .{ i + 1, rp.tool_name, rp.files_affected, excerpt });
        } else {
            try std.Io.Writer.print(w, "    [{d}] {s} (files: {d})\n", .{ i + 1, rp.tool_name, rp.files_affected });
        }
    }
    try std.Io.Writer.writeAll(w, "\n  Select rollback point (or Enter to cancel): ");
    try std.Io.File.Writer.flush(file_writer);

    // Cooked-with-echo (session raw otherwise — same as the confirm below).
    var cooked_sel = menu.CookedGuard{};
    cooked_sel.enter();
    defer cooked_sel.restore();
    var ans_buf: [64]u8 = undefined;
    var ans_writer = std.Io.Writer.fixed(&ans_buf);
    const n = std.Io.Reader.streamDelimiter(r, &ans_writer, '\n') catch {
        try std.Io.Writer.writeAll(w, "\n");
        return;
    };
    r.toss(1);
    const ans = std.mem.trim(u8, ans_buf[0..n], " \t\r\n");
    if (ans.len == 0) {
        try std.Io.Writer.writeAll(w, "  Cancelled.\n\n");
        return;
    }

    const idx = std.fmt.parseInt(usize, ans, 10) catch {
        try std.Io.Writer.writeAll(w, "  Invalid selection.\n\n");
        return;
    };
    if (idx > rollback_points.len) {
        try std.Io.Writer.writeAll(w, "  Invalid selection.\n\n");
        return;
    }

    // [0] rolls everything back to the session start state.
    const target_op_id = if (idx == 0)
        rollback_mod.session_start_op_id
    else
        rollback_points[idx - 1].op_id;
    // Rewind boundary for the conversation: the message count at the moment
    // the op was recorded (index-precise — ms timestamps cannot split
    // messages inside one fast tool turn). Session start keeps only the
    // system prompt. A stale epoch (history rewritten by compact/clear/undo
    // since the point) invalidates the index — files rewind, dialogue does
    // not, instead of deleting innocent post-rewrite messages.
    const point_epoch: u64 = if (idx == 0) engine.op_log.epoch else rollback_points[idx - 1].epoch;
    const epoch_valid = point_epoch == engine.op_log.epoch;
    const truncate_to: usize = if (idx == 0) 1 else rollback_points[idx - 1].history_len;

    // Preview first
    const preview = engine.previewRollback(target_op_id) catch {
        try std.Io.Writer.writeAll(w, "  Error previewing rollback.\n\n");
        return;
    };

    const messages_to_drop: usize = if (epoch_valid and history.items.len > truncate_to) history.items.len - truncate_to else 0;

    try std.Io.Writer.print(w, "\n  Rollback preview:\n", .{});
    try std.Io.Writer.print(w, "    Files to restore: {d}\n", .{preview.files_to_restore});
    try std.Io.Writer.print(w, "    Files to delete:  {d}\n", .{preview.files_to_delete});
    try std.Io.Writer.print(w, "    Operations to undo: {d}\n", .{preview.operations_to_undo});
    if (epoch_valid) {
        try std.Io.Writer.print(w, "    Messages to drop: {d} (conversation rewinds with the files)\n", .{messages_to_drop});
    } else {
        try std.Io.Writer.writeAll(w, "    Messages to drop: 0 (history was compacted/cleared since this point — files rewind only)\n");
    }
    try std.Io.Writer.writeAll(w, "  Proceed? [y/N]: ");
    try std.Io.File.Writer.flush(file_writer);

    // Cooked-with-echo for the confirm read (session raw otherwise).
    var cooked = menu.CookedGuard{};
    cooked.enter();
    defer cooked.restore();
    var confirm_buf: [16]u8 = undefined;
    var confirm_writer = std.Io.Writer.fixed(&confirm_buf);
    _ = std.Io.Reader.streamDelimiter(r, &confirm_writer, '\n') catch {
        try std.Io.Writer.writeAll(w, "\n");
        return;
    };
    r.toss(1);
    const confirm = std.mem.trim(u8, confirm_buf[0..confirm_writer.end], " \t\r\n");
    if (!std.mem.eql(u8, confirm, "y") and !std.mem.eql(u8, confirm, "Y")) {
        try std.Io.Writer.writeAll(w, "  Cancelled.\n\n");
        return;
    }

    // Execute rollback
    const result = engine.rollbackTo(target_op_id, io) catch |err| {
        try std.Io.Writer.print(w, "  Rollback failed: {}\n\n", .{err});
        return;
    };

    try std.Io.Writer.print(w, "  Rollback complete:\n", .{});
    for (result.restored_files) |fp| {
        try std.Io.Writer.print(w, "    Restored: {s}\n", .{fp});
    }
    for (result.deleted_files) |fp| {
        try std.Io.Writer.print(w, "    Deleted:  {s}\n", .{fp});
    }
    for (result.errors) |e| {
        try std.Io.Writer.print(w, "    Error: {s}: {s}\n", .{ e.file_path, e.message });
    }
    // Conversation rewind: pop messages down to the checkpoint length
    // (system prompt at index 0 always survives). Skipped on stale epoch.
    var dropped: usize = 0;
    while (epoch_valid and history.items.len > @max(truncate_to, 1)) {
        const msg = history.orderedRemove(history.items.len - 1);
        turn_history.freeMessage(msg, alloc);
        dropped += 1;
    }
    // The recorded history_len can fall between a tool_use and its results —
    // trim the stranded pair end so the next request stays wire-valid.
    const len_before_repair = history.items.len;
    turn_history.repairToolPairing(history, alloc);
    dropped += len_before_repair - history.items.len;

    try std.Io.Writer.print(w, "  ({d} restored, {d} deleted, {d} errors, {d} messages rewound)\n\n", .{
        result.restored_files.len,
        result.deleted_files.len,
        result.errors.len,
        dropped,
    });

    engine.freeResult(result);
}

/// One-line display excerpt of a rollback point's turn label: FIRST line
/// only, inner whitespace runs collapsed, capped at 48 bytes on a UTF-8
/// boundary with a trailing "…". Empty/blank → "" (the caller then omits
/// the suffix entirely — old op-log records and non-turn ops carry no
/// label).
fn labelExcerpt(buf: []u8, label: []const u8) []const u8 {
    const fl = std.mem.indexOfScalar(u8, label, '\n') orelse label.len;
    const line = std.mem.trim(u8, label[0..fl], " \t\r");
    if (line.len == 0) return "";

    var f = std.Io.Writer.fixed(buf);
    const cap = 48;
    var i: usize = 0;
    var pending_space = false;
    var written: usize = 0;
    var truncated = false;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t') {
            pending_space = written > 0;
            i += 1;
            continue;
        }
        if (pending_space) {
            std.Io.Writer.writeAll(&f, " ") catch break;
            written += 1;
            pending_space = false;
        }
        var l: usize = 1;
        if (c >= 0xF0) {
            l = 4;
        } else if (c >= 0xE0) {
            l = 3;
        } else if (c >= 0xC0) {
            l = 2;
        }
        l = @min(l, line.len - i); // malformed tail: never read past the line
        if (written + l > cap) {
            truncated = true;
            break;
        }
        std.Io.Writer.writeAll(&f, line[i .. i + l]) catch break;
        written += l;
        i += l;
    }
    if (truncated) std.Io.Writer.writeAll(&f, "…") catch {};
    return f.buffered();
}

test "labelExcerpt: first line, collapse, UTF-8-safe cap" {
    var buf: [64]u8 = undefined;
    // Multi-line keeps only the first line.
    try std.testing.expectEqualStrings("修复登录", labelExcerpt(&buf, "修复登录\n第二步\n第三步"));
    // Whitespace runs collapse; edges trimmed.
    try std.testing.expectEqualStrings("a b c", labelExcerpt(&buf, "  a \t b   c  "));
    // Blank → empty (caller omits the suffix).
    try std.testing.expectEqualStrings("", labelExcerpt(&buf, "  \nsecond"));
    try std.testing.expectEqualStrings("", labelExcerpt(&buf, ""));
    // Byte cap cuts on a rune boundary — 30 CJK chars = 90 bytes > 48:
    // the cut must land after a whole char and end with the ellipsis.
    const long = "修修修修修修修修修修修修修修修修修修修修修修修修修修修修修修";
    const got = labelExcerpt(&buf, long);
    try std.testing.expect(got.len <= 48 + 3); // cap + "…"
    try std.testing.expect(got[got.len - 3] == 0xE2); // "…" UTF-8 head
    var count: usize = 0;
    var i: usize = 0;
    while (i < got.len - 3) : (i += 3) count += 1;
    try std.testing.expectEqual(@as(usize, 16), count); // 48/3 whole chars
}


test "undoLastExchange strips a stranded assistant tool_use" {
    // [sys, user, assistant(tool_use), user(tool_results), assistant(final)]
    // — undo drops the last two, which used to strand the tool_use: the next
    // request carried tool_calls with no tool responses (a 400 on strict
    // gateways).
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    sys_blocks[0] = .{ .text = try alloc.dupe(u8, "sys") };
    try history.append(alloc, .{ .role = .system, .content = sys_blocks, .timestamp = 0 });

    const q = try alloc.alloc(llm.ContentBlock, 1);
    q[0] = .{ .text = try alloc.dupe(u8, "run ls") };
    try history.append(alloc, .{ .role = .user, .content = q, .timestamp = 0 });

    const tu = try alloc.alloc(llm.ContentBlock, 1);
    tu[0] = .{ .tool_use = .{ .id = try alloc.dupe(u8, "call_1"), .name = try alloc.dupe(u8, "Bash"), .input = .null } };
    try history.append(alloc, .{ .role = .assistant, .content = tu, .timestamp = 0 });

    const tr = try alloc.alloc(llm.ContentBlock, 1);
    tr[0] = .{ .tool_result = .{
        .tool_use_id = try alloc.dupe(u8, "call_1"),
        .content = try alloc.dupe(u8, "file_a"),
    } };
    try history.append(alloc, .{ .role = .user, .content = tr, .timestamp = 0 });

    const fin = try alloc.alloc(llm.ContentBlock, 1);
    fin[0] = .{ .text = try alloc.dupe(u8, "done") };
    try history.append(alloc, .{ .role = .assistant, .content = fin, .timestamp = 0 });

    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    _ = try undoLastExchange(&history, alloc, &w);

    // The tool_use message must be gone too — history ends at the prompt.
    try std.testing.expectEqual(@as(usize, 2), history.items.len);
    try std.testing.expect(history.items[1].role == .user);

    turn_history.clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
}

