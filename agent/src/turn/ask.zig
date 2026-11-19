/// Ask/gate interactions (P1 extraction from repl.zig — pure move):
/// AskUserQuestion tool execution (cooked read with Esc-cancel) and the
/// shared permission gate (6-step pipeline, auto-mode classifier).
const std = @import("std");
const registry = @import("../tools/registry.zig");
const auth = @import("../tools/auth_mode.zig");
const classifier_mod = @import("../tools/classifier.zig");
const denial_tracker_mod = @import("../tools/denial_tracker.zig");
const config_mod = @import("../config.zig");
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

/// T9.1 plan_approve 的 REPL 上下文：借用 ask 的交互四件套 + 模式与
/// 配置的稳定引用（批准动作镜像 /mode 的切换+落盘+指纹重置链）。
pub const PlanApproveCtx = struct {
    ask: *AskUserCtx,
    current_mode: *auth.PermissionMode,
    switcher: *ModelSwitcher,
    io: std.Io,
};

/// T9.1 plan 出环门体：把模型递来的计划摘要呈给用户三选一。
///   批准   → 切出 plan（default）+ 落盘，模型本回合即可执行；
///   继续   → 决议回传（模型继续完善计划，留在 plan 模式）；
///   放弃   → 决议回传（模型停止规划收尾）。
/// 自由文本答案按「继续 + 用户反馈」处理。非 plan 模式调用返回指引
/// 而不是切模式（防误用）。选项提问复用 askUserExecute 的编号列表。
pub fn planApproveExecute(ctx_opaque: ?*anyopaque, alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const pctx: *PlanApproveCtx = @ptrCast(@alignCast(ctx_opaque orelse return error.NoCtx));
    const summary = registry.getStringField(input, "summary") orelse "";

    if (pctx.current_mode.* != .plan) {
        return registry.ToolResult{
            .output = try alloc.dupe(u8, "not in plan mode — nothing to approve. Finish planning with /plan and /mode plan first, or just proceed"),
        };
    }

    // 组装选项式提问（经 askUserExecute 渲染编号列表）。summary 是模型
    // 文本，拼进 JSON 前必须转义（引号/反斜杠/控制字符）。
    var qaw: std.Io.Writer.Allocating = .init(alloc);
    defer qaw.deinit();
    const qw = &qaw.writer;
    try qw.writeAll("{\"question\":\"批准以下计划并开始执行？\\n\\n");
    try escapeJsonTo(qw, summary);
    try qw.writeAll("\\n\\n1) 批准——切出计划模式开始执行\\n2) 继续完善计划\\n3) 放弃计划\",\"options\":[\"批准并执行\",\"继续完善计划\",\"放弃计划\"]}");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const qinput = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), qaw.writer.buffered(), .{}) catch
        return error.QuestionBuildFailed;

    // Esc 取消/Esc 反馈都经 askUserExecute 的返回值（expected_stop 标记
    // 或「user cancelled」文案）——统一按「未批准、留在 plan」处理。
    const ans = try askUserExecute(@ptrCast(pctx.ask), alloc, qinput, io);

    // 决议 → 动作。精确匹配选项原文（askUserExecute 数字选择返回选项
    // verbatim；自由文本原样）——子串匹配会把「先不要批准」误判成批准。
    // 批准：镜像 dispatch /mode 的切换链（current_mode +
    // settings.permission_mode + saveSettings + 指纹重置，防热重载回卷）。
    if (std.mem.eql(u8, ans.output, "批准并执行")) {
        pctx.current_mode.* = .default;
        pctx.switcher.settings.permission_mode = .default;
        config_mod.saveSettings(&pctx.switcher.settings, alloc, pctx.io) catch {};
        const repl_mod = @import("../repl.zig");
        repl_mod.settings_fp_baseline = config_mod.settingsFingerprint(alloc, pctx.io);
        logger.info("plan approved: mode -> default (persisted)", .{});
        return registry.ToolResult{
            .output = try alloc.dupe(u8, "PLAN_APPROVED — the user approved the plan; the session left plan mode and you may execute now"),
        };
    }
    if (std.mem.eql(u8, ans.output, "放弃计划")) {
        return registry.ToolResult{
            .output = try alloc.dupe(u8, "PLAN_REJECTED — the user dropped the plan; stop planning and summarize what was learned"),
        };
    }
    // 「继续完善」或自由文本反馈：原样回传给模型。
    return registry.ToolResult{
        .output = try alloc.print("PLAN_REFINE — the user wants the plan reworked; feedback: {s}", .{ans.output}),
    };
}

/// 最小 JSON 字符串转义（5 字符类，与 config.appendEscaped 语义一致；
/// 模型 summary 含引号/换行时保 qjson 可解析）。
fn escapeJsonTo(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            // 控制字符必须 \u00XX——裸字节会把 JSON 写成非法（复审 🟡6）
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

/// Real AskUserQuestion body — prompt the user and return their answer.
/// With `options` (2-8 short choices) the prompt renders a numbered list
/// and a digit selects — the A-or-B decision no longer costs the user a
/// typed sentence. Anything else typed stays a free-text answer (the
/// question may legitimately need nuance), Enter skips, Esc cancels.
pub fn askUserExecute(ctx_opaque: ?*anyopaque, alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    _ = io;
    const ctx: *AskUserCtx = @ptrCast(@alignCast(ctx_opaque orelse return error.NoAskContext));
    const question = registry.getStringField(input, "question") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: question") catch "", .is_error = true };
    // Collect up to 8 options (schema documents 2-8; enforcement here is
    // defensive — the model controls the array).
    var opts_buf: [8][]const u8 = undefined;
    var n_opts: usize = 0;
    if (input == .object) {
        if (input.object.get("options")) |oarr| {
            if (oarr == .array) {
                for (oarr.array.items) |it| {
                    if (n_opts >= opts_buf.len) break;
                    if (it == .string) {
                        opts_buf[n_opts] = it.string;
                        n_opts += 1;
                    }
                }
            }
        }
    }

    // Interactive prompt/read happens with the turn-scoped region DOWN:
    // the question + typed answer need the bottom rows and cooked-input
    // echo, and a direct print with the region up would smear the
    // persistent input row. The region is re-begun before returning (the
    // tool phase still owns the screen bottom).
    lineinput.regionEnd(ctx.w);
    try std.Io.Writer.print(ctx.ow, "\n  [model asks] {s}\n", .{question});
    if (n_opts >= 2) {
        for (opts_buf[0..n_opts], 0..) |o, i| {
            try std.Io.Writer.print(ctx.ow, "    {d}. {s}\n", .{ i + 1, o });
        }
        try std.Io.Writer.print(ctx.ow, "  选择 1-{d}（Enter=跳过，Esc=取消，其他输入=自由回答）: ", .{n_opts});
    } else {
        try std.Io.Writer.print(ctx.ow, "  Your answer (Enter=skip, Esc=cancel): ", .{});
    }
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
        return registry.ToolResult{ .output = alloc.dupe(u8, "user input unavailable") catch "", .is_error = true };
    };
    ctx.r.toss(1);
    const ans = std.mem.trim(u8, ans_aw.written(), " \t\r\n");
    // Esc / Ctrl-C in the cooked read arrive as control bytes (ISIG is
    // off) — a leading one means CANCEL, not an answer; feeding the
    // model the raw byte used to turn "user pressed Esc" into junk text.
    if (ans.len > 0 and (ans[0] == 0x1b or ans[0] == 0x03)) {
        lineinput.regionBegin(ctx.w, "⚙ 执行工具 · Esc 中断");
        return registry.ToolResult{ .output = alloc.dupe(u8, "user cancelled the question (Esc)") catch "", .expected_stop = true };
    }
    // Numbered pick: a bare digit/number within range selects the option
    // VERBATIM — the model gets the exact choice text back, not "2".
    if (n_opts >= 2 and ans.len > 0 and ans.len <= 2) {
        if (std.fmt.parseInt(u8, ans, 10)) |pick| {
            if (pick >= 1 and pick <= n_opts) {
                lineinput.regionBegin(ctx.w, "⚙ 执行工具 · Esc 中断");
                return registry.ToolResult{ .output = try alloc.dupe(u8, opts_buf[pick - 1]) };
            }
        } else |_| {}
    }
    lineinput.regionBegin(ctx.w, "⚙ 执行工具 · Esc 中断");
    return registry.ToolResult{
        .output = try alloc.dupe(u8, if (ans.len > 0) ans else "(no answer given)"),
    };
}

/// T2.1/T2.2「总是允许」学习（2026-11-19；同日审查修正落点）：ask 门
/// 答 a 时把合成的最窄 allow 规则同时落两处——运行时 settings（本回合
/// 起免询问）+ user 层 settings.json 合并追加（跨会话；local 层是整字
/// 段覆盖语义，写它会顶掉 user 手写规则，禁用）。字符串与数组全部上
/// smp_allocator 进程级持有（permissionGate 的 alloc 可能是回合作用
/// 域，借它会悬垂）；上限 config.LEARNED_RULES_CAP 条封顶。任何失败
/// 只降级为一次性放行。
fn learnAlwaysRule(switcher: *ModelSwitcher, tool_name: []const u8, pattern: ?[]const u8, ow: *std.Io.Writer, file_writer: *std.Io.File.Writer) void {
    const gpa = std.heap.smp_allocator;
    if (switcher.settings.allow_rules.len >= config_mod.LEARNED_RULES_CAP) {
        std.Io.Writer.print(ow, "  [learned-rule cap ({d}) reached — allowed once only]\n", .{config_mod.LEARNED_RULES_CAP}) catch {};
        return;
    }
    const old = switcher.settings.allow_rules;
    // 幂等（复审 🟢6）：同 (tool, pattern) 已在运行时规则里 → 只补文件
    // 侧（appendUserAllowRule 自身幂等），运行时不重复追加——重复条目
    // 对匹配无增益，却会被下次 autoSave 扁平化写回 user 层持续膨胀。
    var already_present = false;
    for (old) |r| {
        if (std.mem.eql(u8, r.tool_name, tool_name)) {
            const ep = r.content_pattern orelse "";
            const np = pattern orelse "";
            if (std.mem.eql(u8, ep, np)) {
                already_present = true;
                break;
            }
        }
    }
    if (!already_present) {
        // 复审修正（2026-11-19）：任何分配失败整条丢弃（一次性放行）——
        // 原 dupe(pattern) 失败静默落成「无 pattern 裸规则」= fail-open
        // 放行该工具全部调用，与「失败只降级为一次性放行」的声明相反。
        const owned_pattern: ?[]const u8 = if (pattern) |ptn| gpa.dupe(u8, ptn) catch null else null;
        if (pattern != null and owned_pattern == null) {
            std.Io.Writer.writeAll(ow, "  [rule allocation failed — allowed once only]\n") catch {};
            return;
        }
        const n = gpa.alloc(auth.PermissionRule, old.len + 1) catch {
            if (owned_pattern) |op| gpa.free(op);
            std.Io.Writer.writeAll(ow, "  [rule allocation failed — allowed once only]\n") catch {};
            return;
        };
        @memcpy(n[0..old.len], old);
        n[old.len] = .{
            .source = .local_settings,
            .behavior = .allow,
            .tool_name = gpa.dupe(u8, tool_name) catch {
                if (owned_pattern) |op| gpa.free(op);
                gpa.free(n);
                std.Io.Writer.writeAll(ow, "  [rule allocation failed — allowed once only]\n") catch {};
                return;
            },
            .content_pattern = owned_pattern,
        };
        // 旧切片来自三层加载（会话生命周期），不 free——每次学习一条的
        // 一次性小泄漏，200 条封顶（与 settings 其余字段的既定取舍一致）。
        switcher.settings.allow_rules = n;
    }

    config_mod.appendUserAllowRule(gpa, switcher.io, tool_name, pattern) catch |err| {
        std.Io.Writer.print(ow, "  [rule active this session only — could not write user settings.json: {}]\n", .{err}) catch {};
        std.Io.File.Writer.flush(file_writer) catch {};
        return;
    };
    // 刷新指纹基线：运行时状态已含规则，省掉下一提示符的整配置重载
    // （重载无害但会打 [settings reloaded] 噪音）。
    const repl_mod = @import("../repl.zig");
    repl_mod.settings_fp_baseline = config_mod.settingsFingerprint(gpa, switcher.io);
    if (pattern) |ptn| {
        std.Io.Writer.print(ow, "  [always allowed: {s}({s}) — merged into user settings.json]\n", .{ tool_name, ptn }) catch {};
    } else {
        std.Io.Writer.print(ow, "  [always allowed: {s} — merged into user settings.json]\n", .{tool_name}) catch {};
    }
    std.Io.File.Writer.flush(file_writer) catch {};
    logger.info("always-allow learned: {s}({s})", .{ tool_name, if (pattern) |ptn| ptn else "(no pattern)" });
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
            try std.Io.Writer.print(ow, "  Tool {s}: {s}. Allow? [y/N/a] (a=always): ", .{ tool_def.name, a.message });
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
            if (std.mem.eql(u8, ans, "a") or std.mem.eql(u8, ans, "A")) {
                // T2.1「a = 总是允许」：合成最窄规则（command 前两 token +
                // `*` / path 精确），运行时生效 + Local 层落盘；合成不出
                // 可复用 pattern 时退化为一次性放行。
                if (auth.synthesizeAllowRule(alloc, tool_def.name, input)) |rule| {
                    learnAlwaysRule(switcher, rule.tool_name, rule.content_pattern, ow, file_writer);
                } else {
                    try std.Io.Writer.writeAll(ow, "  [no reusable pattern in this input — allowed once only]\n");
                    try std.Io.File.Writer.flush(file_writer);
                }
            } else if (!std.mem.eql(u8, ans, "y") and !std.mem.eql(u8, ans, "Y")) {
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
