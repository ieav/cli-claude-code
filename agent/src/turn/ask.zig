/// Ask/gate interactions (P1 extraction from repl.zig — pure move):
/// AskUserQuestion tool execution (cooked read with Esc-cancel) and the
/// shared permission gate (6-step pipeline, auto-mode classifier).
const std = @import("std");
const registry = @import("../tools/registry.zig");
const auth = @import("../tools/auth_mode.zig");
const classifier_mod = @import("../tools/classifier.zig");
const denial_tracker_mod = @import("../tools/denial_tracker.zig");
const lineinput = @import("../util/lineinput.zig");
const menu = @import("../util/menu.zig");
const llm = @import("../llm/mod.zig");
const logger = @import("../util/log.zig");
const ModelSwitcher = @import("../repl.zig").ModelSwitcher;

/// AskUserQuestion execution context: the live REPL reader/writer.
/// `w` is the REAL writer (region lifecycle); `ow` is the region-aware
/// transcript writer for the printed lines.
pub const AskUserCtx = struct {
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    ow: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
};

/// Real AskUserQuestion body — prompt the user and return their answer.
pub fn askUserExecute(ctx_opaque: ?*anyopaque, alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    _ = io;
    const ctx: *AskUserCtx = @ptrCast(@alignCast(ctx_opaque orelse return error.NoAskContext));
    const question = registry.getStringField(input, "question") orelse
        return registry.ToolResult{ .output = "Missing required field: question", .is_error = true };
    // Interactive prompt/read happens with the turn-scoped region DOWN:
    // the question + typed answer need the bottom rows and cooked-input
    // echo, and a direct print with the region up would smear the
    // persistent input row. The region is re-begun before returning (the
    // tool phase still owns the screen bottom).
    lineinput.regionEnd(ctx.w);
    try std.Io.Writer.print(ctx.ow, "\n  [model asks] {s}\n  Your answer (Enter=skip, Esc=cancel): ", .{question});
    try std.Io.File.Writer.flush(ctx.file_writer);
    // Cooked-with-echo for the answer read (2026-11-06 session-raw
    // follow-up): raw mode would leave the user typing blind with Enter
    // delivered as \r — streamDelimiter waits for \n and blocks forever.
    // Same guard as the y/N permission gate and the /rewind confirm.
    var cooked = menu.CookedGuard{};
    cooked.enter();
    defer cooked.restore();
    var ans_aw: std.Io.Writer.Allocating = .init(alloc);
    defer ans_aw.deinit();
    _ = std.Io.Reader.streamDelimiter(ctx.r, &ans_aw.writer, '\n') catch {
        lineinput.regionBegin(ctx.w, "⚙ 执行工具 · Esc 中断");
        return registry.ToolResult{ .output = "user input unavailable", .is_error = true };
    };
    ctx.r.toss(1);
    const ans = std.mem.trim(u8, ans_aw.written(), " \t\r\n");
    // Esc / Ctrl-C in the cooked read arrive as control bytes (ISIG is
    // off) — a leading one means CANCEL, not an answer; feeding the
    // model the raw byte used to turn "user pressed Esc" into junk text.
    if (ans.len > 0 and (ans[0] == 0x1b or ans[0] == 0x03)) {
        lineinput.regionBegin(ctx.w, "⚙ 执行工具 · Esc 中断");
        return registry.ToolResult{ .output = "user cancelled the question (Esc)", .expected_stop = true };
    }
    lineinput.regionBegin(ctx.w, "⚙ 执行工具 · Esc 中断");
    return registry.ToolResult{
        .output = try alloc.dupe(u8, if (ans.len > 0) ans else "(no answer given)"),
    };
}

/// Shared permission gate for the agent loop and /run.
/// deny → prints and returns false; allow → true; ask → interactive y/N,
/// except in auto mode where a reachable LLM classifier decides (with the
/// rule-based fallback of "allow" on classifier failure).
pub fn permissionGate(
    tool_def: *const registry.ToolDefinition,
    input: std.json.Value,
    mode: auth.PermissionMode,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    /// Region-aware transcript writer: business prints go through it so
    /// they land above the live region when one is up (verbatim when not).
    ow: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    denials: *denial_tracker_mod.DenialTracker,
) !bool {
    const perm_ctx = registry.PermissionContext{
        .mode = mode,
        .allow_rules = switcher.settings.allow_rules,
        .deny_rules = switcher.settings.deny_rules,
        .ask_rules = switcher.settings.ask_rules,
        .provider = switcher.getProvider() catch null,
        .allocator = alloc,
        .model_name = switcher.modelName(),
    };
    var decision = auth.checkToolPermission(tool_def, input, &perm_ctx);

    // Auto mode: delegate ambiguous (ask) calls to the LLM classifier.
    if (mode == .auto and decision == .ask) {
        if (switcher.getProvider() catch null) |p| {
            var lc = classifier_mod.LLMClassifier.init(alloc, p, switcher.modelName());
            // Fail CLOSED: on classifier error fall back to asking the user
            // (fail-open silently allowed writes when the LLM was down).
            const cr = lc.classify(tool_def, input) catch classifier_mod.ClassifierResult{ .block = .{ .reason = "classifier unavailable — confirm manually" } };
            decision = switch (cr) {
                .allow => .{ .allow = {} },
                .block => |b| .{ .deny = .{ .message = b.reason } },
            };
            logger.info("classifier(auto): {s} -> {s}", .{ tool_def.name, switch (cr) {
                .allow => "allow",
                .block => "block",
            } });
        }
    }

    switch (decision) {
        .deny => |d| {
            if (denials.recordDenial()) {
                std.Io.Writer.print(ow, "  [{d} consecutive denials — the agent is being starved; try /mode, an allow rule, or /config]\n", .{denials.consecutive_denials}) catch {};
            }
            std.Io.Writer.print(ow, "  [Permission denied: {s}]\n", .{d.message}) catch {};
            try std.Io.File.Writer.flush(file_writer);
            return false;
        },
        .allow => {
            denials.recordApproval();
            return true;
        },
        .ask => |a| {
            // Interactive y/N happens with the turn region DOWN (the prompt
            // + cooked-input echo own the bottom rows; a direct print with
            // the region up smears the persistent input row). Re-begun on
            // EVERY exit — the tool phase still owns the screen bottom.
            lineinput.regionEnd(w);
            try std.Io.Writer.print(ow, "  Tool {s}: {s}. Allow? [y/N]: ", .{ tool_def.name, a.message });
            try std.Io.File.Writer.flush(file_writer);

            // Cooked-with-echo for the answer read (session is raw now —
            // without this the user types blind and Enter never terminates
            // the delimiter read). No-op on non-TTY stdin.
            var cooked = menu.CookedGuard{};
            cooked.enter();
            defer cooked.restore();
            // Allocating answer buffer: the old fixed 64-byte reader turned
            // a long pasted answer into "Cancelled" and left the tail of the
            // line polluting the next read.
            var ans_aw: std.Io.Writer.Allocating = .init(alloc);
            defer ans_aw.deinit();
            _ = std.Io.Reader.streamDelimiter(r, &ans_aw.writer, '\n') catch {
                try std.Io.Writer.writeAll(ow, "\n  [Cancelled]\n");
                try std.Io.File.Writer.flush(file_writer);
                lineinput.regionBegin(w, "⚙ 执行工具 · Esc 中断");
                return false;
            };
            r.toss(1);
            const ans = std.mem.trim(u8, ans_aw.written(), " \t\r\n");
            if (!std.mem.eql(u8, ans, "y") and !std.mem.eql(u8, ans, "Y")) {
                _ = denials.recordDenial();
                try std.Io.Writer.writeAll(ow, "  [Denied by user]\n");
                try std.Io.File.Writer.flush(file_writer);
                lineinput.regionBegin(w, "⚙ 执行工具 · Esc 中断");
                return false;
            }
            denials.recordApproval();
            lineinput.regionBegin(w, "⚙ 执行工具 · Esc 中断");
            return true;
        },
    }
}
