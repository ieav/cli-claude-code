//! M7 `-p` 非交互一发模式（docs/harness-efficiency-plan.md §5 迭代二）
//! ——CI/脚本的门票：`ziv -p "提示"` 跑完一个 agent 回合，最终文本打
//! 到 stdout，退出。无 TUI、无 raw mode、无输入行。
//!
//! 实现选择：复用 subagent 的无头 agent 循环（单一实现，不另起炉灶），
//! 差异只经 SubagentConfig 注入：
//!   · 系统提示 = ziv 正式 system prompt（与 REPL 同源）
//!   · 权限    = 用户 settings 的规则与模式；ask 在无交互下降级为拒绝
//!   · 回合上限 = settings.agent_loop_limit（同 REPL 口径）
//!   · 工具    = 内建全量减交互类（AskUser/Task*/agent——deny 清单恒定）
//!
//! v1 明确不做（保持小而清楚）：MCP 连接、记忆注入、会话持久化、自动
//! 压缩——超窗会以错误退出（oneshot 场景任务应短小；需要时再迭代）。
//! 存储锚定照常（zivroot.init），工具里凡是写 .ziv 路径的仍落项目根。

const std = @import("std");
const config_mod = @import("../config.zig");
const model_switcher = @import("../session/model_switcher.zig");
const registry = @import("../tools/registry.zig");
const runtime_registry = @import("../tools/runtime_registry.zig");
const hooks_mod = @import("../hooks/hooks.zig");
const subagent = @import("subagent.zig");
const system_prompt_mod = @import("../system_prompt.zig");
const zivroot = @import("../util/zivroot.zig");
const logger = @import("../util/log.zig");

/// Run one prompt to completion. `out` receives the final assistant text
/// (what a script consumes); diagnostics go to `err_w`. Returns the process
/// exit code: 0 = got an answer, 1 = run failed (provider dead, etc.).
pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err_w: *std.Io.Writer,
    prompt: []const u8,
) !u8 {
    if (prompt.len == 0) {
        try std.Io.Writer.writeAll(err_w, "ziv -p: empty prompt\n");
        return 1;
    }
    zivroot.init(io);
    logger.initFromEnv();

    const settings = config_mod.loadSettings(alloc, io) catch config_mod.Settings{};
    var switcher = model_switcher.ModelSwitcher.init(settings, io);
    defer switcher.deinit();
    // M6 Hooks：oneshot 与交互会话同一套钩子（subagent 执行口读全局配置）。
    hooks_mod.setConfig(.{
        .pre = switcher.settings.hooks_pre,
        .post = switcher.settings.hooks_post,
    });

    const provider = switcher.getProvider() catch |e| {
        try std.Io.Writer.print(err_w, "ziv -p: no usable provider ({s}) — check /config 的 api_keys 与 base_url\n", .{@errorName(e)});
        return 1;
    };

    var reg = runtime_registry.RuntimeRegistry.init(alloc);
    defer reg.deinit();

    // 正式 system prompt（与 REPL 同源；oneshot 不做记忆注入——快速
    // 启动优先，注入是交互会话的增益）。项目规则（ziv.md）尾拼进同一
    // 字符串——规则对无头任务同样生效；generate=false：不在用户项目
    // 里自动写文件（生成是交互会话的行为）。
    var sys_prompt = system_prompt_mod.buildSystemPrompt(alloc, switcher.settings.system_prompt, switcher.settings.output_style) catch null;
    defer if (sys_prompt) |sp| alloc.free(sp);
    {
        const rules_mod = @import("../rules/ziv_md.zig");
        var rstate = rules_mod.loadStartup(alloc, io, false);
        defer rules_mod.freeRulesState(alloc, &rstate);
        if (rules_mod.buildBlockText(alloc, &rstate)) |rextra| {
            defer alloc.free(rextra);
            if (sys_prompt) |sp| {
                if (std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ sp, rextra })) |joined| {
                    sys_prompt = joined;
                    alloc.free(sp);
                } else |_| {}
            }
        }
    }

    // 用户规则 + 模式；ask → 拒绝由 subagent 引擎的降级语义兜住
    // （无人在场，不允许悬停等待审批）。
    const perm_ctx = registry.PermissionContext{
        .mode = switcher.settings.permission_mode,
        .allow_rules = switcher.settings.allow_rules,
        .deny_rules = switcher.settings.deny_rules,
        .ask_rules = switcher.settings.ask_rules,
        .provider = provider,
        .allocator = alloc,
        .model_name = switcher.modelName(),
    };

    const res = subagent.run(.{
        .task = prompt,
        .alloc = alloc,
        .io = io,
        .provider = provider,
        .tools = &reg,
        .max_turns = @max(1, switcher.settings.agent_loop_limit),
        .system_prompt = sys_prompt,
        .perm_ctx = &perm_ctx,
        // 输出预算与交互会话同源（settings.max_tokens）——思考型模型的
        // 思考 token 计入输出预算，小值会"想完就没字"（config.zig 同因）。
        .response_budget = switcher.settings.max_tokens,
    });
    defer res.deinit(alloc);

    if (res.err) {
        try std.Io.Writer.print(err_w, "ziv -p: {s}\n", .{res.summary});
        return 1;
    }
    try std.Io.Writer.print(out, "{s}\n", .{res.summary});
    return 0;
}

test "oneshot: empty prompt is a usage error, not a crash" {
    // 纯参数层检查：空提示在触达 provider 之前就被挡下（loadSettings
    // 需要 io，不再往下走）。
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var sw = std.Io.Writer.fixed(&out_buf);
    var ew = std.Io.Writer.fixed(&err_buf);
    const code = try run(std.testing.allocator, undefined, &sw, &ew, "");
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_buf[0..ew.end], "empty prompt") != null);
}
