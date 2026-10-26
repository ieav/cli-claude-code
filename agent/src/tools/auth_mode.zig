/// Authorization mode system — permission pipeline with 6 execution modes.
/// Extracted from Claude Code CLI's permission system (src/utils/permissions/).
const std = @import("std");
const registry = @import("registry.zig");
const sanitization = @import("../util/sanitization.zig");
const classifier = @import("classifier.zig");
const glob_match = @import("../util/glob_match.zig");

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
    // Step 1a: Check deny rules. A rule without a pattern denies the tool
    // outright; a rule with a pattern only denies when the input matches it.
    for (ctx.deny_rules) |rule| {
        if (tool.matchesName(rule.tool_name)) {
            if (rule.content_pattern) |pattern| {
                if (inputMatchesPattern(input, pattern)) {
                    return .{ .deny = .{ .message = "denied by rule (pattern match)" } };
                }
            } else {
                return .{ .deny = .{ .message = "denied by rule" } };
            }
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

    // Step 2b: Check allow rules. Pattern rules only allow on match; a
    // non-matching pattern falls through to the default ask below.
    for (ctx.allow_rules) |rule| {
        if (tool.matchesName(rule.tool_name)) {
            if (rule.content_pattern) |pattern| {
                if (inputMatchesPattern(input, pattern)) return .allow;
            } else {
                return .allow;
            }
        }
    }

    // Step 3: Default to ask
    return .{ .ask = .{ .message = "permission required" } };
}

/// Match a rule's content pattern against the operative input field
/// (command for Bash, path for file tools). Glob syntax via glob_match.
fn inputMatchesPattern(input: std.json.Value, pattern: []const u8) bool {
    const target = registry.getStringField(input, "command") orelse
        registry.getStringField(input, "path") orelse
        return false;
    return glob_match.match(pattern, target);
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
    const decision = checkToolPermission(&registry.bash_tool, .null, &ctx);
    try std.testing.expect(decision == .allow);
}

test "checkToolPermission plan mode blocks writes" {
    const ctx = PermissionContext{
        .mode = .plan,
        .allow_rules = &.{},
        .deny_rules = &.{},
    };
    const decision = checkToolPermission(&registry.file_write_tool, .null, &ctx);
    switch (decision) {
        .deny => {},
        else => return error.UnexpectedDecision,
    }
}

test "content patterns: table-driven deny/allow matching" {
    // Each case: (rule pattern, command, expected decision tag)
    const Case = struct { pattern: ?[]const u8, command: ?[]const u8, want: enum { deny, allow, ask } };
    const cases = [_]Case{
        // Deny rules (blanket + pattern)
        .{ .pattern = null, .command = "ls", .want = .deny }, // blanket deny
        .{ .pattern = "rm *", .command = "rm -rf /tmp/x", .want = .deny }, // pattern hit
        .{ .pattern = "rm *", .command = "ls -la", .want = .ask }, // pattern miss -> falls to ask
        .{ .pattern = "git push*", .command = "git push origin main", .want = .deny },
        // Allow rules
        .{ .pattern = null, .command = "echo hi", .want = .allow }, // blanket allow
        .{ .pattern = "git status*", .command = "git status -s", .want = .allow },
        .{ .pattern = "git status*", .command = "git push", .want = .ask }, // miss -> default ask
        .{ .pattern = "cat *", .command = null, .want = .ask }, // no command field -> cannot match pattern
    };

    for (cases, 0..) |c, i| {
        var input: std.json.Value = .null;
        var obj: std.json.ObjectMap = .empty;
        defer obj.deinit(std.testing.allocator);
        if (c.command) |cmd| {
            try obj.put(std.testing.allocator, "command", .{ .string = cmd });
            input = .{ .object = obj };
        }

        const deny_rules = [_]registry.PermissionRule{.{
            .source = .user_settings,
            .behavior = .deny,
            .tool_name = "Bash",
            .content_pattern = c.pattern,
        }};
        const allow_rules = [_]registry.PermissionRule{.{
            .source = .user_settings,
            .behavior = .allow,
            .tool_name = "Bash",
            .content_pattern = c.pattern,
        }};

        // Interpret want: deny cases use ctx with deny_rules, others allow_rules.
        const use_deny = c.want == .deny;
        const ctx = PermissionContext{
            .mode = .default,
            .allow_rules = if (use_deny) &.{} else &allow_rules,
            .deny_rules = if (use_deny) &deny_rules else &.{},
        };
        const decision = checkToolPermission(&registry.bash_tool, input, &ctx);
        const got: []const u8 = switch (decision) {
            .deny => "deny",
            .allow => "allow",
            .ask => "ask",
        };
        const want_str = @tagName(c.want);
        std.testing.expectEqualStrings(want_str, got) catch |err| {
            std.debug.print("case {d}: pattern={?s} command={?s} want={s} got={s}\n", .{ i, c.pattern, c.command, want_str, got });
            return err;
        };
    }
}
