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
    // Skill 工具门（2026-11-10）：skill 生效回合内，前置声明 tools:
    // 之外的工具一律拒——声明即授权边界，权限模式不可放宽它。
    if (@import("../skills/gate.zig").armed()) {
        if (!@import("../skills/gate.zig").allows(tool.name)) {
            return .{ .deny = .{ .message = "denied by skill tools gate (not in declared tools:)" } };
        }
    }
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

    // Step 1d: Safety path checks（写类 + 非 bypass 模式）。
    // 2026-11-09 修订（用户裁定 bypass 还问授权不合理）：
    //   · bypass 模式整体跳过——bypass 的语义就是"用户显式放弃审批"，
    //     硬编码守卫覆盖用户选择属越权；要拦 .git//etc 用户自配 deny
    //     规则（Step 1 仍在 bypass 生效）。
    //   · 纯读永不因路径被问——FileRead /etc/hosts、读 .git/config 无
    //     破坏面，先前的"所有模式都问"是纯摩擦；守卫只保护写类操作。
    if (ctx.mode != .bypass and !tool.isReadOnly(input)) {
        if (hasProtectedPathInput(input)) {
            return .{ .ask = .{ .message = "protected path requires approval" } };
        }
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

/// T2.2 always-allow 规则合成（2026-11-19）：ask 门选「a」时从工具入参
/// 提取最窄可复用 pattern。保守原则——
///   · command 类（Bash）：首个链段的前两个 token + `*`
///     （`git push origin main` → `git push*`）。allow 是全段 glob：链式
///     命令的其余段不被该 pattern 覆盖 → 仍会询问（fail-closed 不变）。
///   · path 类（文件工具）：原值精确匹配（无通配 = 只放行这个文件）。
///   · 无 command/path 字段：不合成（调用方退化为一次性放行）。
/// 返回的字符串分配在 alloc 上，调用方随 settings 生命周期持有。
pub fn synthesizeAllowRule(alloc: std.mem.Allocator, tool_name: []const u8, input: std.json.Value) ?PermissionRule {
    if (input != .object) return null;
    if (registry.getStringField(input, "command")) |cmd| {
        if (cmd.len == 0) return null;
        const seg = firstChainSegment(cmd);
        // 复审加固（2026-11-19）：两类「盲切出过宽规则」不合成——
        // ① 首段含引号：分隔符在引号内会被切开（`sh -c 'a && b'` 切出
        //   `sh -c` → `sh -c*` = 永久放行任意 sh 命令，fail-open）；
        // ② 首 token 是解释器/提权器：`sh -c git push`（无引号形态）
        //   同样合成 `sh -c*`，其后任意载荷全部命中。
        // 两者都退化为一次性放行（用户本次明确允许的只是这一条命令）。
        if (std.mem.indexOfAny(u8, seg, "\"'`") != null) return null;
        var tit = std.mem.tokenizeAny(u8, seg, " \t");
        if (tit.next()) |t1| {
            if (interpreterToken(t1)) return null;
        }
        var it = std.mem.tokenizeAny(u8, seg, " \t");
        const t1 = it.next() orelse return null;
        const pat = if (it.next()) |t2|
            alloc.print("{s} {s}*", .{ t1, t2 }) catch return null
        else
            alloc.print("{s}*", .{t1}) catch return null;
        return .{
            .source = .local_settings,
            .behavior = .allow,
            .tool_name = alloc.dupe(u8, tool_name) catch return null,
            .content_pattern = pat,
        };
    }
    if (registry.getStringField(input, "path")) |p| {
        if (p.len == 0) return null;
        return .{
            .source = .local_settings,
            .behavior = .allow,
            .tool_name = alloc.dupe(u8, tool_name) catch return null,
            .content_pattern = alloc.dupe(u8, p) catch return null,
        };
    }
    return null;
}

/// 解释器/提权器 token：它们的首两词后跟任意载荷，`X -c*` 形态的
/// allow 规则等于放行该解释器的全部调用。
fn interpreterToken(t: []const u8) bool {
    const hosts = [_][]const u8{ "sh", "bash", "zsh", "dash", "ksh", "env", "ssh", "sudo", "xargs", "osascript", "pwsh", "powershell", "nohup", "exec" };
    for (hosts) |h| {
        if (std.ascii.eqlIgnoreCase(t, h)) return true;
    }
    return false;
}

/// 链式命令取首段（与 inputMatchesPatternAny 的分段符一致子集）。
fn firstChainSegment(cmd: []const u8) []const u8 {
    var seg = cmd;
    const seps = [_][]const u8{ "&&", "||", ";", "|", "&" };
    for (seps) |s| {
        if (std.mem.indexOf(u8, seg, s)) |i| seg = seg[0..i];
    }
    return seg;
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

test "protected-path guard: writes-only, and never in bypass (2026-11-09 修订)" {
    const alloc = std.testing.allocator;
    const mkInput = struct {
        fn mk(cmd_or_path: []const u8) std.json.Value {
            return .{ .string = cmd_or_path };
        }
    }.mk;
    _ = alloc;
    _ = mkInput;
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);

    // bypass + 命令涉 /.git/ → 放行（bypass 就是 bypass）。
    try obj.put(std.testing.allocator, "command", .{ .string = "ls /repo/.git/refs" });
    const by_ctx = PermissionContext{ .mode = .bypass, .allow_rules = &.{}, .deny_rules = &.{}, .ask_rules = &.{} };
    try std.testing.expect(checkToolPermission(&registry.bash_tool, .{ .object = obj }, &by_ctx) == .allow);

    // default + 纯读涉 /etc/ → 放行（读永不因路径被问；default 读自动放行）。
    var obj2: std.json.ObjectMap = .empty;
    defer obj2.deinit(std.testing.allocator);
    try obj2.put(std.testing.allocator, "command", .{ .string = "cat /etc/hosts" });
    const d_ctx = PermissionContext{ .mode = .default, .allow_rules = &.{}, .deny_rules = &.{}, .ask_rules = &.{} };
    try std.testing.expect(checkToolPermission(&registry.bash_tool, .{ .object = obj2 }, &d_ctx) == .allow);

    // default + 写类涉 /etc/ → 仍 ask（守卫保留在它有价值的形态上）。
    var obj3: std.json.ObjectMap = .empty;
    defer obj3.deinit(std.testing.allocator);
    try obj3.put(std.testing.allocator, "command", .{ .string = "rm /etc/hosts.bak" });
    try std.testing.expect(checkToolPermission(&registry.bash_tool, .{ .object = obj3 }, &d_ctx) == .ask);

    // default + FileWrite 到 .git 内 → ask；FileRead 同路径 → 放行。
    var w: std.json.ObjectMap = .empty;
    defer w.deinit(std.testing.allocator);
    try w.put(std.testing.allocator, "path", .{ .string = "/repo/.git/config" });
    try std.testing.expect(checkToolPermission(&registry.file_write_tool, .{ .object = w }, &d_ctx) == .ask);
    try std.testing.expect(checkToolPermission(&registry.file_read_tool, .{ .object = w }, &d_ctx) == .allow);
}

test "T2.2 synthesizeAllowRule: conservative pattern extraction" {
    const alloc = std.testing.allocator;

    // Bash 双 token：`git push origin main` → `git push*`
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const two = parseInputForTest(a, "{\"command\":\"git push origin main\"}");
    if (synthesizeAllowRule(alloc, "Bash", two)) |r| {
        defer {
            alloc.free(r.tool_name);
            alloc.free(r.content_pattern.?);
        }
        try std.testing.expectEqualStrings("Bash", r.tool_name);
        try std.testing.expectEqualStrings("git push*", r.content_pattern.?);
        try std.testing.expect(r.behavior == .allow);
        try std.testing.expect(r.source == .local_settings);
    } else return error.NoRule;

    // 单 token：`make` → `make*`
    const one = parseInputForTest(a, "{\"command\":\"make\"}");
    if (synthesizeAllowRule(alloc, "Bash", one)) |r| {
        defer {
            alloc.free(r.tool_name);
            alloc.free(r.content_pattern.?);
        }
        try std.testing.expectEqualStrings("make*", r.content_pattern.?);
    } else return error.NoRule;

    // 链式：只取首段（`git push && rm -rf /` → `git push*`，其余段不被
    // 覆盖 → 链式命令仍会询问）
    const chain = parseInputForTest(a, "{\"command\":\"git push && rm -rf /\"}");
    if (synthesizeAllowRule(alloc, "Bash", chain)) |r| {
        defer {
            alloc.free(r.tool_name);
            alloc.free(r.content_pattern.?);
        }
        try std.testing.expectEqualStrings("git push*", r.content_pattern.?);
    } else return error.NoRule;

    // path：精确原值（无通配 = 只放行这个文件）
    const path_in = parseInputForTest(a, "{\"path\":\"/tmp/notes/a.txt\"}");
    if (synthesizeAllowRule(alloc, "FileWrite", path_in)) |r| {
        defer {
            alloc.free(r.tool_name);
            alloc.free(r.content_pattern.?);
        }
        try std.testing.expectEqualStrings("/tmp/notes/a.txt", r.content_pattern.?);
    } else return error.NoRule;

    // 复审：引号链与解释器首 token 不合成（过宽防线）
    const quoted = parseInputForTest(a, "{\"command\":\"sh -c 'git push && evil'\"}");
    try std.testing.expect(synthesizeAllowRule(alloc, "Bash", quoted) == null);
    const interp = parseInputForTest(a, "{\"command\":\"bash -c git push\"}");
    try std.testing.expect(synthesizeAllowRule(alloc, "Bash", interp) == null);

    // 无 command/path：不合成
    const bare = parseInputForTest(a, "{\"query\":\"hello\"}");
    try std.testing.expect(synthesizeAllowRule(alloc, "WebSearch", bare) == null);
    // 空串也不合成
    const empty_cmd = parseInputForTest(a, "{\"command\":\"\"}");
    try std.testing.expect(synthesizeAllowRule(alloc, "Bash", empty_cmd) == null);
}

/// 测试缝：字符串 → std.json.Value（leaky 进 arena；调用方用
/// ArenaAllocator 包 testing.allocator，deinit 时统一归还）。
fn parseInputForTest(arena_alloc: std.mem.Allocator, s: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena_alloc, s, .{}) catch unreachable;
}
