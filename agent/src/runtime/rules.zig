/// Runtime detection rules — check system health and identify issues.
/// Each rule produces a CheckResult with suggested fixes.

const std = @import("std");

pub const RuleSeverity = enum {
    info,
    warning,
    error,
    critical,
};

pub const CheckResult = union(enum) {
    pass: void,
    fail: FailedCheck,
};

pub const FailedCheck = struct {
    rule_id: []const u8,
    message: []const u8,
    metric_current: f64,
    metric_threshold: f64,
    suggested_fixes: []const SuggestedFix,
};

pub const SuggestedFix = struct {
    description: []const u8,
    action_type: enum {
        adjust_parameter,
        clear_data,
        auto_fixable,
        user_input_needed,
    },
    auto_fixable: bool,
};

pub const RuntimeRule = struct {
    id: []const u8,
    name: []const u8,
    severity: RuleSeverity,
    check_fn: *const fn (*RuntimeContext) CheckResult,
};

pub const RuntimeContext = struct {
    memory_used_bytes: usize,
    memory_limit_bytes: usize,
    memory_entry_count: usize,
    api_calls_last_minute: u32,
    api_rate_limit: u32,
    db_integrity_ok: bool,
    current_tokens: u32,
    max_tokens: u32,
    task_failed_count: usize,
    task_total_count: usize,
    network_timeout_count: u32,
    active_tasks: usize,
    max_concurrent_tasks: usize,
};
