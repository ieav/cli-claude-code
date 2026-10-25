/// Authorization mode system — permission pipeline with 6 execution modes.
/// Extracted from Claude Code CLI's permission system (src/utils/permissions/).
const std = @import("std");
const registry = @import("registry.zig");
const sanitization = @import("../util/sanitization.zig");
const classifier = @import("classifier.zig");

// Re-export from registry
pub const PermissionMode = registry.PermissionMode;
pub const PermissionRule = registry.PermissionRule;
pub const PermissionContext = registry.PermissionContext;
pub const PermissionDecision = registry.PermissionDecision;

/// Get the next mode in the cycle (Shift+Tab behavior).
/// Cycle: default → accept_edits → plan → bypass → default
pub fn nextMode(current: PermissionMode) PermissionMode {
    return switch (current) {
        .default => .accept_edits,
        .accept_edits => .plan,
        .plan => .bypass,
        .bypass => .default,
        .dont_ask => .default,
        .auto => .default,
    };
}

/// Get a human-readable label for each mode.
pub fn modeLabel(mode: PermissionMode) []const u8 {
    return switch (mode) {
        .default => "Default",
        .accept_edits => "Accept Edits",
        .plan => "Plan (read-only)",
        .bypass => "Bypass All",
        .dont_ask => "Don't Ask",
        .auto => "Auto",
    };
}

/// Core permission pipeline — six-step check.
/// Mirrors TS hasPermissionsToUseToolInner flow.
pub fn checkToolPermission(
    tool: *const registry.ToolDefinition,
    input: std.json.Value,
    ctx: *const PermissionContext,
) PermissionDecision {
    // Step 1a: Check deny rules — blanket deny
    for (ctx.deny_rules) |rule| {
        if (tool.matchesName(rule.tool_name)) {
            if (rule.content_pattern) |pattern| {
                // Content-specific deny
                _ = pattern; // TODO: match against input
            }
            return .{ .deny = .{ .message = "denied by rule" } };
        }
    }

    // Step 1b: Check ask rules — bypass-immune
    // (These always prompt regardless of mode)

    // Step 1c: Tool-specific permission check
    const tool_decision = tool.checkPermissions(input, ctx);
    switch (tool_decision) {
        .deny => |d| return .{ .deny = d },
        .ask => |a| return .{ .ask = a },
        .allow => {},
    }

    // Step 1d: Safety path checks (bypass-immune)
    if (hasProtectedPathInput(input)) {
        return .{ .ask = .{ .message = "protected path requires approval" } };
    }

    // Step 2a: Mode-based behavior
    switch (ctx.mode) {
        .bypass => return .allow,
        .plan => {
            if (!tool.isReadOnly(input)) {
                return .{ .deny = .{ .message = "write operation blocked in plan mode" } };
            }
            return .allow;
        },
        .accept_edits => {
            // Auto-allow non-destructive file operations
            if (tool.isReadOnly(input)) return .allow;
            if (!tool.isDestructive(input)) return .allow;
            // Destructive ops still need approval
        },
        .dont_ask => {
            // Auto-deny everything that would ask
            return .{ .deny = .{ .message = "auto-denied in dont_ask mode" } };
        },
        .default => {
            // Will fall through to allow rules check
        },
        .auto => {
            // LLM-augmented classifier for auto mode
            if (ctx.provider) |prov| {
                if (ctx.allocator) |alloc| {
                    var llm_classifier = classifier.LLMClassifier.init(alloc, prov);
                    const result = llm_classifier.classify(tool, input) catch
                        return .{ .ask = .{ .message = "classification failed" } };
                    switch (result) {
                        .allow => return .allow,
                        .block => |b| return .{ .deny = .{ .message = b.reason } },
                    }
                }
            }
            // No LLM available, fall through to rule-based default
        },
    }

    // Step 2b: Check allow rules
    for (ctx.allow_rules) |rule| {
        if (tool.matchesName(rule.tool_name)) {
            if (rule.content_pattern) |pattern| {
                _ = pattern; // TODO: match against input
            }
            return .allow;
        }
    }

    // Step 3: Default to ask
    return .{ .ask = .{ .message = "permission required" } };
}

/// Check if the input contains references to protected paths.
fn hasProtectedPathInput(input: std.json.Value) bool {
    const path_str = registry.getStringField(input, "path") orelse
        registry.getStringField(input, "command") orelse
        return false;

    if (sanitization.isGitPath(path_str)) return true;
    if (sanitization.isClaudePath(path_str)) return true;
    if (sanitization.isProtectedPath(path_str)) return true;
    return false;
}

test "nextMode cycle" {
    try std.testing.expect(nextMode(.default) == .accept_edits);
    try std.testing.expect(nextMode(.accept_edits) == .plan);
    try std.testing.expect(nextMode(.plan) == .bypass);
    try std.testing.expect(nextMode(.bypass) == .default);
}

test "checkToolPermission bypass mode" {
    const ctx = PermissionContext{
        .mode = .bypass,
        .allow_rules = &.{},
        .deny_rules = &.{},
    };
    const decision = checkToolPermission(&registry.bash_tool, .{}, &ctx);
    try std.testing.expect(decision == .allow);
}

test "checkToolPermission plan mode blocks writes" {
    const ctx = PermissionContext{
        .mode = .plan,
        .allow_rules = &.{},
        .deny_rules = &.{},
    };
    const decision = checkToolPermission(&registry.file_write_tool, .{}, &ctx);
    switch (decision) {
        .deny => {},
        else => return error.UnexpectedDecision,
    }
}
