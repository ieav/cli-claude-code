/// Built-in runtime detection rules — 8 rules with φ/e thresholds.
const std = @import("std");
const math = @import("../math/mod.zig");
const rules = @import("rules.zig");

// ──── Rule 1: Memory usage ────
pub fn checkMemory(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (ctx.memory_limit_bytes == 0) return .pass;
    const ratio = @as(f64, @floatFromInt(ctx.memory_used_bytes)) / @as(f64, @floatFromInt(ctx.memory_limit_bytes));
    // Direct ratio compare: the old sigmoid(2*(ratio-0.7)) > 0.8 only fired
    // at ratio ≈ 1.39 — the process would be OOM-dead long before this rule
    // ever "detected" high memory. The 0.8 threshold below is now literal.
    if (ratio > 0.8) {
        return .{
            .fail = .{
                .rule_id = "mem_usage_high",
                .message = "内存使用率超过阈值",
                .metric_current = ratio,
                .metric_threshold = 0.8,
                .suggested_fixes = &.{
                    .{ .description = "φ 浓缩记忆", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "清理过期记忆", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "用户选择保留/删除", .action_type = .user_input_needed, .auto_fixable = false },
                },
            },
        };
    }
    return .pass;
}

// ──── Rule 2: API rate limit ────
/// Evidence-based (2026-11-06): fires ONLY on real 429 responses seen in
/// the window. The old heuristic divided a per-"minute" call count by a
/// fictional 60/min ceiling — but the health check only drains at the
/// REPL loop top, so a long turn's ENTIRE call volume landed in one
/// window: any 48+-call debugging marathon read as "approaching rate
/// limit" right after the turn ended (50 calls / 29 min tripped it).
/// Real 429s are counted at the agent-loop error site and swapped per
/// check — a truthful signal with no window semantics to break.
pub fn checkApiRate(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (ctx.api_rate_limited_count == 0) return .pass;
    return .{
        .fail = .{
            .rule_id = "api_rate_limit",
            .message = "API 速率受限（窗口内收到 429）",
            .metric_current = @floatFromInt(ctx.api_rate_limited_count),
            .metric_threshold = 1,
            .suggested_fixes = &.{
                .{ .description = "稍等后重试（网关限额窗口通常按分钟重置）", .action_type = .auto_fixable, .auto_fixable = false },
                .{ .description = "降低请求频率或切换模型/网关", .action_type = .adjust_parameter, .auto_fixable = false },
            },
        },
    };
    // Ratio path removed; api_calls_last_minute/api_rate_limit stay in
    // RuntimeContext for potential future use but no rule consumes them.
}

// ──── Rule 3: Storage integrity ────
pub fn checkStorage(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (!ctx.db_integrity_ok) {
        return .{
            .fail = .{
                .rule_id = "storage_corruption",
                .message = "数据库完整性检查失败",
                .metric_current = 0,
                .metric_threshold = 1,
                .suggested_fixes = &.{
                    .{ .description = "自动修复数据库", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "从备份恢复", .action_type = .user_input_needed, .auto_fixable = false },
                },
            },
        };
    }
    return .pass;
}

// ──── Rule 4: Context overflow (φ threshold) ────
pub fn checkContextOverflow(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (ctx.max_tokens == 0) return .pass;
    const ratio = @as(f64, @floatFromInt(ctx.current_tokens)) / @as(f64, @floatFromInt(ctx.max_tokens));
    // φ threshold: warn when usage > 61.8%
    if (ratio > math.constants.PHI) {
        return .{
            .fail = .{
                .rule_id = "context_overflow",
                .message = "上下文窗口接近上限",
                .metric_current = ratio,
                .metric_threshold = math.constants.PHI,
                .suggested_fixes = &.{
                    .{ .description = "自动摘要压缩", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "φ 浓缩保留 61.8%", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "开始新会话", .action_type = .user_input_needed, .auto_fixable = false },
                },
            },
        };
    }
    return .pass;
}

// ──── Rule 5: Task health (1-φ threshold) ────
pub fn checkTaskHealth(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (ctx.task_total_count == 0) return .pass;
    const fail_rate = @as(f64, @floatFromInt(ctx.task_failed_count)) / @as(f64, @floatFromInt(ctx.task_total_count));
    // Fail rate > 38.2% (= 1 - φ) triggers warning
    if (fail_rate > (1.0 - math.constants.PHI)) {
        return .{
            .fail = .{
                .rule_id = "task_health",
                .message = "后台任务失败率过高",
                .metric_current = fail_rate,
                .metric_threshold = 1.0 - math.constants.PHI,
                .suggested_fixes = &.{
                    .{ .description = "降低并发数（e 限制）", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "查看失败任务详情", .action_type = .user_input_needed, .auto_fixable = false },
                },
            },
        };
    }
    return .pass;
}

// ──── Rule 6: Network connectivity ────
pub fn checkNetwork(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (ctx.network_timeout_count > 3) {
        return .{
            .fail = .{
                .rule_id = "network_connectivity",
                .message = "网络不稳定，多次超时",
                .metric_current = @floatFromInt(ctx.network_timeout_count),
                .metric_threshold = 3,
                .suggested_fixes = &.{
                    .{ .description = "切换到本地模型", .action_type = .adjust_parameter, .auto_fixable = false },
                    .{ .description = "启用离线模式", .action_type = .auto_fixable, .auto_fixable = true },
                },
            },
        };
    }
    return .pass;
}

// ──── Rule 7: Concurrency pressure ────
pub fn checkConcurrency(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (ctx.max_concurrent_tasks == 0) return .pass;
    const ratio = @as(f64, @floatFromInt(ctx.active_tasks)) / @as(f64, @floatFromInt(ctx.max_concurrent_tasks));
    if (ratio > 0.9) {
        return .{
            .fail = .{
                .rule_id = "concurrency_pressure",
                .message = "并发任务接近上限",
                .metric_current = ratio,
                .metric_threshold = 0.9,
                .suggested_fixes = &.{
                    .{ .description = "排队新任务", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "拒绝新提交", .action_type = .user_input_needed, .auto_fixable = false },
                },
            },
        };
    }
    return .pass;
}

pub const builtin_rules = &[_]rules.RuntimeRule{
    .{ .id = "mem_usage_high", .name = "内存使用", .severity = .warning, .check_fn = checkMemory },
    .{ .id = "api_rate_limit", .name = "API 限速", .severity = .warning, .check_fn = checkApiRate },
    .{ .id = "storage_corruption", .name = "存储完整性", .severity = .critical, .check_fn = checkStorage },
    .{ .id = "context_overflow", .name = "上下文溢出", .severity = .warning, .check_fn = checkContextOverflow },
    .{ .id = "task_health", .name = "任务健康", .severity = .@"error", .check_fn = checkTaskHealth },
    .{ .id = "network_connectivity", .name = "网络连通", .severity = .@"error", .check_fn = checkNetwork },
    .{ .id = "concurrency_pressure", .name = "并发压力", .severity = .warning, .check_fn = checkConcurrency },
    // Removed decision_quality: it reused context_overflow's metric with a
    // HIGHER threshold (0.95 > φ), so context_overflow always fired first —
    // an unreachable duplicate. The designed rule needs a real confidence
    // data source (registered in TODO.md).
};

test "builtin_rules: all rules are defined" {
    try std.testing.expectEqual(@as(usize, 7), builtin_rules.len);
}

test "checkContextOverflow triggers at φ threshold" {
    var ctx: rules.RuntimeContext = .{
        .memory_used_bytes = 0,
        .memory_limit_bytes = 0,
        .memory_entry_count = 0,
        .api_calls_last_minute = 0,
        .api_rate_limit = 0,
        .db_integrity_ok = true,
        .current_tokens = 7000,
        .max_tokens = 10000,
        .task_failed_count = 0,
        .task_total_count = 0,
        .network_timeout_count = 0,
        .active_tasks = 0,
        .max_concurrent_tasks = 0,
    };
    // 7000/10000 = 0.7 > φ ≈ 0.618
    const result = checkContextOverflow(&ctx);
    switch (result) {
        .fail => |f| try std.testing.expectEqualStrings("context_overflow", f.rule_id),
        .pass => return error.TestUnexpectedResult,
    }
}

test "checkContextOverflow passes below φ threshold" {
    var ctx: rules.RuntimeContext = .{
        .memory_used_bytes = 0,
        .memory_limit_bytes = 0,
        .memory_entry_count = 0,
        .api_calls_last_minute = 0,
        .api_rate_limit = 0,
        .db_integrity_ok = true,
        .current_tokens = 5000,
        .max_tokens = 10000,
        .task_failed_count = 0,
        .task_total_count = 0,
        .network_timeout_count = 0,
        .active_tasks = 0,
        .max_concurrent_tasks = 0,
    };
    // 5000/10000 = 0.5 < φ
    const result = checkContextOverflow(&ctx);
    try std.testing.expect(result == .pass);
}

test "checkApiRate is evidence-based: no 429s, no warning — call volume alone never trips it" {
    // The old ratio rule fired here: 50 calls in one (broken) window
    // against a fictional 60/min ceiling read 83% after a long turn.
    var ctx = rules.RuntimeContext{
        .memory_used_bytes = 0,
        .memory_limit_bytes = 1,
        .memory_entry_count = 0,
        .api_calls_last_minute = 50,
        .api_rate_limit = 60,
        .api_rate_limited_count = 0,
        .db_integrity_ok = true,
        .current_tokens = 0,
        .max_tokens = 1000,
        .task_failed_count = 0,
        .task_total_count = 1,
        .network_timeout_count = 0,
        .active_tasks = 0,
        .max_concurrent_tasks = 0,
    };
    try std.testing.expect(checkApiRate(&ctx) == .pass);
}

test "checkApiRate warns on real 429s" {
    var ctx = rules.RuntimeContext{
        .memory_used_bytes = 0,
        .memory_limit_bytes = 1,
        .memory_entry_count = 0,
        .api_calls_last_minute = 1,
        .api_rate_limit = 60,
        .api_rate_limited_count = 2,
        .db_integrity_ok = true,
        .current_tokens = 0,
        .max_tokens = 1000,
        .task_failed_count = 0,
        .task_total_count = 1,
        .network_timeout_count = 0,
        .active_tasks = 0,
        .max_concurrent_tasks = 0,
    };
    const result = checkApiRate(&ctx);
    try std.testing.expect(result == .fail);
    try std.testing.expectEqualStrings("api_rate_limit", result.fail.rule_id);
}
