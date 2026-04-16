/// Built-in runtime detection rules — 8 rules with φ/e thresholds.

const std = @import("std");
const math = @import("../math/mod.zig");
const rules = @import("rules.zig");

// ──── Rule 1: Memory usage ────
pub fn checkMemory(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (ctx.memory_limit_bytes == 0) return .pass;
    const ratio = @as(f64, @floatFromInt(ctx.memory_used_bytes)) / @as(f64, @floatFromInt(ctx.memory_limit_bytes));
    const pressure = math.sigmoid(2.0 * (ratio - 0.7));
    if (pressure > 0.8) {
        const target = math.condensationTarget(ctx.memory_entry_count);
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
pub fn checkApiRate(ctx: *rules.RuntimeContext) rules.CheckResult {
    if (ctx.api_rate_limit == 0) return .pass;
    const ratio = @as(f64, @floatFromInt(ctx.api_calls_last_minute)) / @as(f64, @floatFromInt(ctx.api_rate_limit));
    if (ratio > 0.8) {
        return .{
            .fail = .{
                .rule_id = "api_rate_limit",
                .message = "API 调用接近速率限制",
                .metric_current = ratio,
                .metric_threshold = 0.8,
                .suggested_fixes = &.{
                    .{ .description = "降低后台任务频率", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "切换到本地模型", .action_type = .adjust_parameter, .auto_fixable = false },
                    .{ .description = "暂停非关键任务", .action_type = .auto_fixable, .auto_fixable = true },
                },
            },
        };
    }
    return .pass;
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

// ──── Rule 8: Decision quality (φ threshold on confidence) ────
pub fn checkDecisionQuality(ctx: *rules.RuntimeContext) rules.CheckResult {
    // Reuse context_overflow metric as proxy for decision quality
    // Low confidence decisions tracked via episodic memory
    if (ctx.max_tokens == 0) return .pass;
    const util = @as(f64, @floatFromInt(ctx.current_tokens)) / @as(f64, @floatFromInt(ctx.max_tokens));
    if (util > 0.95) {
        return .{
            .fail = .{
                .rule_id = "decision_quality",
                .message = "决策空间不足，上下文几乎耗尽",
                .metric_current = util,
                .metric_threshold = 0.95,
                .suggested_fixes = &.{
                    .{ .description = "触发紧急浓缩", .action_type = .auto_fixable, .auto_fixable = true },
                    .{ .description = "回溯最近决策", .action_type = .user_input_needed, .auto_fixable = false },
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
    .{ .id = "task_health", .name = "任务健康", .severity = .error, .check_fn = checkTaskHealth },
    .{ .id = "network_connectivity", .name = "网络连通", .severity = .error, .check_fn = checkNetwork },
    .{ .id = "concurrency_pressure", .name = "并发压力", .severity = .warning, .check_fn = checkConcurrency },
    .{ .id = "decision_quality", .name = "决策质量", .severity = .error, .check_fn = checkDecisionQuality },
};

test "builtin_rules: all rules are defined" {
    try std.testing.expectEqual(@as(usize, 8), builtin_rules.len);
}

test "checkContextOverflow triggers at φ threshold" {
    var ctx: rules.RuntimeContext = .{
        .memory_used_bytes = 0, .memory_limit_bytes = 0, .memory_entry_count = 0,
        .api_calls_last_minute = 0, .api_rate_limit = 0,
        .db_integrity_ok = true,
        .current_tokens = 7000, .max_tokens = 10000,
        .task_failed_count = 0, .task_total_count = 0,
        .network_timeout_count = 0,
        .active_tasks = 0, .max_concurrent_tasks = 0,
    };
    // 7000/10000 = 0.7 > φ ≈ 0.618
    const result = checkContextOverflow(&ctx);
    switch (result) {
        .fail => |f| try std.testing.expectEqualStrings("context_overflow", f.rule_id),
        .pass => return std.testing.fail("expected fail"),
    }
}

test "checkContextOverflow passes below φ threshold" {
    var ctx: rules.RuntimeContext = .{
        .memory_used_bytes = 0, .memory_limit_bytes = 0, .memory_entry_count = 0,
        .api_calls_last_minute = 0, .api_rate_limit = 0,
        .db_integrity_ok = true,
        .current_tokens = 5000, .max_tokens = 10000,
        .task_failed_count = 0, .task_total_count = 0,
        .network_timeout_count = 0,
        .active_tasks = 0, .max_concurrent_tasks = 0,
    };
    // 5000/10000 = 0.5 < φ
    const result = checkContextOverflow(&ctx);
    try std.testing.expect(result == .pass);
}
