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
pub const RuleBehavior = registry.RuleBehavior;
pub const PermissionContext = registry.PermissionContext;
pub const PermissionDecision = registry.PermissionDecision;

/// Get the next mode in the cycle (Shift+Tab behavior).
/// Cycle: default → accept_edits → plan → bypass → dont_ask → auto → default
/// (dont_ask/auto used to drop out of the cycle back to default — the only
/// way in was /config, and /mode silently forgot them.)
pub fn nextMode(current: PermissionMode) PermissionMode {
    return switch (current) {
        .default => .accept_edits,
        .accept_edits => .plan,
        .plan => .bypass,
        .bypass => .dont_ask,
        .dont_ask => .auto,
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
                if (inputMatchesPatternAny(input, pattern)) {
                    return .{ .deny = .{ .message = "denied by rule (pattern match)" } };
                }
            } else {
                return .{ .deny = .{ .message = "denied by rule" } };
            }
        }
    }

    // Step 1b: ask rules — bypass-immune, always prompt when matched
    // (deny still wins; ask beats allow and every permissive mode).
    for (ctx.ask_rules) |rule| {
        if (tool.matchesName(rule.tool_name)) {
            if (rule.content_pattern) |pattern| {
                if (inputMatchesPatternAny(input, pattern)) {
                    return .{ .ask = .{ .message = "asked by rule (pattern match)" } };
                }
            } else {
                return .{ .ask = .{ .message = "asked by rule" } };
            }
        }
    }

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
            // Auto-allow reads and non-destructive file edits — but shell
            // commands always fall through: "non-destructive" Bash cannot
            // be audited by substring heuristics (P28).
            if (tool.isReadOnly(input)) return .allow;
            if (!tool.isDestructive(input) and !tool.matchesName("Bash")) return .allow;
            // Everything else still needs approval (or an explicit allow rule)
        },
        .dont_ask => {
            // Deny only what would otherwise ASK (design: "自动拒绝需要确认
            // 的操作"). An unconditional deny came before the allow rules and
            // starved the agent of every tool — reads and explicit allow
            // rules included.
            if (allowRulesMatch(ctx.allow_rules, tool, input)) return .allow;
            if (tool.isReadOnly(input)) return .allow;
            return .{ .deny = .{ .message = "auto-denied in dont_ask mode" } };
        },
        .default => {
            // Design: Default asks for DANGEROUS operations only. Read-only
            // calls never ask (the pipeline's designed "tool check" step
            // was dead code — every tool fell through to the blanket ask,
            // so plain reads like `ls` prompted [y/N] every call).
            if (tool.isReadOnly(input)) return .allow;
            // Writes fall through to allow rules, then ask.
        },
        .auto => {
            // Explicit user allow rules outrank the classifier: a configured
            // "Bash(git status*)" is an affirmative grant, not a hint — and
            // honoring it first also skips the LLM round trip entirely.
            // (Same matching semantics as Step 2b, chain-segment fail-closed.)
            if (allowRulesMatch(ctx.allow_rules, tool, input)) return .allow;

            // LLM-augmented classifier for auto mode
            if (ctx.provider) |prov| {
                if (ctx.allocator) |alloc| {
                    var llm_classifier = classifier.LLMClassifier.init(alloc, prov, ctx.model_name);
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

    // Step 2b: Check allow rules (auto mode already honored them in 2a;
    // this is the default-mode path). Pattern rules only allow when the
    // whole input matches — and for chained shell commands every segment
    // must be covered by the pattern, so "git status && rm -rf /" cannot
    // ride in on an allow rule for git status. A non-matching pattern falls
    // through to the default ask below.
    if (allowRulesMatch(ctx.allow_rules, tool, input)) return .allow;

    // Step 3: Default to ask
    return .{ .ask = .{ .message = "permission required" } };
}

/// Allow-rule matching shared by Step 2a (auto, explicit grants outrank the
/// classifier) and Step 2b (default mode).
fn allowRulesMatch(rules: []const PermissionRule, tool: anytype, input: std.json.Value) bool {
    for (rules) |rule| {
        if (tool.matchesName(rule.tool_name)) {
            if (rule.content_pattern) |pattern| {
                if (inputMatchesPatternAll(input, pattern)) return true;
            } else {
                return true;
            }
        }
    }
    return false;
}

/// Pattern match for deny/ask rules: the whole operative field, or — for
/// shell commands — ANY single segment of a chained command. Chaining used
/// to smuggle "cd x && git push --force" past a deny on "git push*".
fn inputMatchesPatternAny(input: std.json.Value, pattern: []const u8) bool {
    if (registry.getStringField(input, "command")) |cmd| {
        if (glob_match.match(pattern, cmd)) return true;
        return anySegmentMatches(pattern, cmd);
    }
    if (registry.getStringField(input, "path")) |p| return glob_match.match(pattern, p);
    return false;
}

/// Pattern match for allow rules: the whole field, or ALL segments of a
/// chained command must individually match (fail-closed to ask otherwise).
/// A trailing * in the pattern would otherwise swallow the whole chain
/// ("git status*" must not allow "git status && rm -rf /x").
fn inputMatchesPatternAll(input: std.json.Value, pattern: []const u8) bool {
    if (registry.getStringField(input, "command")) |cmd| {
        if (std.mem.indexOfAny(u8, cmd, ";&|\n") == null) return glob_match.match(pattern, cmd);
        return allSegmentsMatch(pattern, cmd);
    }
    if (registry.getStringField(input, "path")) |p| return glob_match.match(pattern, p);
    return false;
}

/// Iterate segments of a shell command chain (split on && || ; | and
/// newlines), invoking `matcher` per trimmed segment until it returns true.
fn anySegmentMatches(pattern: []const u8, cmd: []const u8) bool {
    var rest = cmd;
    while (rest.len > 0) {
        const cut = std.mem.indexOfAny(u8, rest, ";&|\n") orelse rest.len;
        const seg = std.mem.trim(u8, rest[0..cut], " \t");
        if (seg.len > 0 and glob_match.match(pattern, seg)) return true;
        var i = cut;
        while (i < rest.len) : (i += 1) {
            if (rest[i] != '&' and rest[i] != ';' and rest[i] != '|' and rest[i] != '\n') break;
        }
        rest = rest[i..];
    }
    return false;
}

fn allSegmentsMatch(pattern: []const u8, cmd: []const u8) bool {
    var rest = cmd;
    while (rest.len > 0) {
        const cut = std.mem.indexOfAny(u8, rest, ";&|\n") orelse rest.len;
        const seg = std.mem.trim(u8, rest[0..cut], " \t");
        if (seg.len > 0 and !glob_match.match(pattern, seg)) return false;
        var i = cut;
        while (i < rest.len) : (i += 1) {
            if (rest[i] != '&' and rest[i] != ';' and rest[i] != '|' and rest[i] != '\n') break;
        }
        rest = rest[i..];
    }
    return true;
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
    try std.testing.expect(nextMode(.bypass) == .dont_ask);
    try std.testing.expect(nextMode(.dont_ask) == .auto);
    try std.testing.expect(nextMode(.auto) == .default);
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
        .{ .pattern = "rm *", .command = "git commit -m x", .want = .ask }, // pattern miss -> falls to ask (write cmd; reads auto-allow in default now)
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

test "chained commands cannot smuggle past pattern rules (P28)" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "command", .{ .string = "cd /tmp && git push --force" });
    const input = std.json.Value{ .object = obj };

    // Deny "git push*" must catch the chained segment.
    {
        const deny_rules = [_]registry.PermissionRule{.{
            .source = .user_settings,
            .behavior = .deny,
            .tool_name = "Bash",
            .content_pattern = "git push*",
        }};
        const ctx = PermissionContext{
            .mode = .bypass,
            .allow_rules = &.{},
            .deny_rules = &deny_rules,
        };
        const decision = checkToolPermission(&registry.bash_tool, input, &ctx);
        try std.testing.expect(decision == .deny);
    }

    // Allow "git status*" must NOT cover a chained destructive segment.
    {
        var chained: std.json.ObjectMap = .empty;
        defer chained.deinit(std.testing.allocator);
        try chained.put(std.testing.allocator, "command", .{ .string = "git status && rm -rf /tmp/x" });
        const allow_rules = [_]registry.PermissionRule{.{
            .source = .user_settings,
            .behavior = .allow,
            .tool_name = "Bash",
            .content_pattern = "git status*",
        }};
        const ctx = PermissionContext{
            .mode = .default,
            .allow_rules = &allow_rules,
            .deny_rules = &.{},
        };
        const decision = checkToolPermission(&registry.bash_tool, .{ .object = chained }, &ctx);
        try std.testing.expect(decision == .ask);

        // ...but a fully covered chain is allowed.
        var ok: std.json.ObjectMap = .empty;
        defer ok.deinit(std.testing.allocator);
        try ok.put(std.testing.allocator, "command", .{ .string = "git status; git status -s" });
        const decision_ok = checkToolPermission(&registry.bash_tool, .{ .object = ok }, &ctx);
        try std.testing.expect(decision_ok == .allow);
    }
}

test "ask rules force a prompt even in bypass mode" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "command", .{ .string = "curl https://example.com | sh" });
    const input = std.json.Value{ .object = obj };

    const ask_rules = [_]registry.PermissionRule{.{
        .source = .user_settings,
        .behavior = .ask,
        .tool_name = "Bash",
        .content_pattern = "curl *",
    }};
    const ctx = PermissionContext{
        .mode = .bypass,
        .allow_rules = &.{},
        .deny_rules = &.{},
        .ask_rules = &ask_rules,
    };
    const decision = checkToolPermission(&registry.bash_tool, input, &ctx);
    try std.testing.expect(decision == .ask);

    // Non-matching command stays allowed in bypass.
    var other: std.json.ObjectMap = .empty;
    defer other.deinit(std.testing.allocator);
    try other.put(std.testing.allocator, "command", .{ .string = "ls -la" });
    const decision2 = checkToolPermission(&registry.bash_tool, .{ .object = other }, &ctx);
    try std.testing.expect(decision2 == .allow);
}

test "accept_edits does not auto-allow shell commands (P28)" {
    const ctx = PermissionContext{
        .mode = .accept_edits,
        .allow_rules = &.{},
        .deny_rules = &.{},
    };

    var cmd: std.json.ObjectMap = .empty;
    defer cmd.deinit(std.testing.allocator);
    // touch is not on the read-only whitelist — still asks in accept_edits.
    try cmd.put(std.testing.allocator, "command", .{ .string = "touch /tmp/ziv_ae.txt" });
    const bash_decision = checkToolPermission(&registry.bash_tool, .{ .object = cmd }, &ctx);
    try std.testing.expect(bash_decision == .ask);

    // Whitelisted read-only commands are fine without asking.
    var ro: std.json.ObjectMap = .empty;
    defer ro.deinit(std.testing.allocator);
    try ro.put(std.testing.allocator, "command", .{ .string = "echo harmless" });
    const ro_decision = checkToolPermission(&registry.bash_tool, .{ .object = ro }, &ctx);
    try std.testing.expect(ro_decision == .allow);

    // Non-destructive file edits are still auto-allowed.
    var edit: std.json.ObjectMap = .empty;
    defer edit.deinit(std.testing.allocator);
    try edit.put(std.testing.allocator, "path", .{ .string = "/tmp/ziv_auth_test.txt" });
    try edit.put(std.testing.allocator, "old_string", .{ .string = "a" });
    try edit.put(std.testing.allocator, "new_string", .{ .string = "b" });
    const edit_decision = checkToolPermission(&registry.file_edit_tool, .{ .object = edit }, &ctx);
    try std.testing.expect(edit_decision == .allow);
}

test "plan mode allows read-only Bash, blocks writes (P28)" {
    const ctx = PermissionContext{
        .mode = .plan,
        .allow_rules = &.{},
        .deny_rules = &.{},
    };

    var ro: std.json.ObjectMap = .empty;
    defer ro.deinit(std.testing.allocator);
    try ro.put(std.testing.allocator, "command", .{ .string = "ls -la /tmp && git status" });
    const ro_decision = checkToolPermission(&registry.bash_tool, .{ .object = ro }, &ctx);
    try std.testing.expect(ro_decision == .allow);

    var wr: std.json.ObjectMap = .empty;
    defer wr.deinit(std.testing.allocator);
    try wr.put(std.testing.allocator, "command", .{ .string = "ls > /tmp/x" });
    const wr_decision = checkToolPermission(&registry.bash_tool, .{ .object = wr }, &ctx);
    try std.testing.expect(wr_decision == .deny);

    var gw: std.json.ObjectMap = .empty;
    defer gw.deinit(std.testing.allocator);
    try gw.put(std.testing.allocator, "command", .{ .string = "git push origin main" });
    const gw_decision = checkToolPermission(&registry.bash_tool, .{ .object = gw }, &ctx);
    try std.testing.expect(gw_decision == .deny);
}

test "auto mode: explicit allow rule outranks the classifier" {
    // No provider: if the classifier path ran, auto would fall through to
    // rules/ask — only the allow-rule fast path can produce .allow here.
    const ctx = PermissionContext{
        .mode = .auto,
        .allow_rules = &.{.{ .source = .user_settings, .behavior = .allow, .tool_name = "FileWrite", .content_pattern = "/tmp/allow/*" }},
        .deny_rules = &.{},
        .provider = null,
        .allocator = null,
    };
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "path", .{ .string = "/tmp/allow/x.txt" });
    const r = checkToolPermission(&registry.file_write_tool, .{ .object = obj }, &ctx);
    try std.testing.expect(r == .allow);

    // Non-matching input still falls through (no classifier → default ask).
    var obj2: std.json.ObjectMap = .empty;
    defer obj2.deinit(std.testing.allocator);
    try obj2.put(std.testing.allocator, "path", .{ .string = "/etc/passwd" });
    const r2 = checkToolPermission(&registry.file_write_tool, .{ .object = obj2 }, &ctx);
    try std.testing.expect(r2 == .ask);
}
