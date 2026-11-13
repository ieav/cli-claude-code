//! Canonical slash-command catalog — single source of truth consumed by
//! the line editor's syntax coloring, the completion popup, the
//! unknown-command hint, and /help's rendered listing. The dispatch chain
//! (commands/dispatch.zig) stays the semantics layer: adding a command
//! means ONE dispatch arm + ONE row here, and every display surface
//! follows. (2026-11-13: replaced the bare-name array that had drifted —
//! /style /bg /last /trace /tasks /plan /resume were missing, so they
//! colored as "unknown" in the editor and never got did-you-mean hits.)

const std = @import("std");

pub const Group = enum {
    meta,
    model_config,
    conversation,
    task_bg,
    memory,
    mcp_skill,

    pub fn label(self: Group) []const u8 {
        return switch (self) {
            .meta => "General",
            .model_config => "Model & Config",
            .conversation => "Conversation",
            .task_bg => "Tasks & Background",
            .memory => "Memory & Self-improvement",
            .mcp_skill => "MCP & Skills",
        };
    }
};

/// One catalog row. `args` doubles as the popup's argument hint and the
/// /help usage column ("<name>", "[N]"); empty = no-arg command.
pub const CommandSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    args: []const u8 = "",
    desc: []const u8,
    group: Group,
};

pub const table = [_]CommandSpec{
    // ── General ──
    .{ .name = "help", .aliases = &.{"h"}, .desc = "Show this help", .group = .meta },
    .{ .name = "quit", .aliases = &.{ "q", "exit" }, .desc = "Exit ziv", .group = .meta },
    .{ .name = "version", .desc = "Show version", .group = .meta },
    .{ .name = "stats", .desc = "Session statistics and token usage", .group = .meta },
    .{ .name = "tools", .desc = "List registered tools (built-in + dynamic)", .group = .meta },
    .{ .name = "run", .args = "<ToolName> <json>", .desc = "Execute a tool directly (same permission gate + hooks)", .group = .meta },
    .{ .name = "terminal-setup", .desc = "Shift+Enter setup guide for this terminal", .group = .meta },
    // ── Model & Config ──
    .{ .name = "model", .aliases = &.{"models"}, .args = "[name]", .desc = "Model picker (arrows+Enter); /model <name> switches", .group = .model_config },
    .{ .name = "mode", .desc = "Cycle permission mode (persisted)", .group = .model_config },
    .{ .name = "config", .desc = "Interactive configuration menu", .group = .model_config },
    .{ .name = "style", .args = "[name]", .desc = "Output style: default | concise (also Ctrl+T)", .group = .model_config },
    // ── Conversation ──
    .{ .name = "compact", .args = "[focus|phi]", .desc = "Summarize older history (LLM); phi = truncate, no LLM", .group = .conversation },
    .{ .name = "clear", .aliases = &.{ "reset", "new" }, .desc = "Clear conversation, start fresh", .group = .conversation },
    .{ .name = "resume", .args = "[id]", .desc = "Resume a past session (picker when no id)", .group = .conversation },
    .{ .name = "context", .desc = "Context/token usage + live health checks", .group = .conversation },
    .{ .name = "trace", .desc = "Last turn's per-step timing (.ziv/traces)", .group = .conversation },
    .{ .name = "undo", .desc = "Undo last exchange", .group = .conversation },
    .{ .name = "history", .desc = "Show operation history", .group = .conversation },
    .{ .name = "rewind", .desc = "Rewind files AND conversation to a checkpoint", .group = .conversation },
    .{ .name = "plan", .args = "[goal|off]", .desc = "Plan file anchored into the system prompt", .group = .conversation },
    // ── Tasks & Background ──
    .{ .name = "tasks", .desc = "Show the task list and progress", .group = .task_bg },
    .{ .name = "bg", .desc = "Background tasks panel (status/output/stop)", .group = .task_bg },
    .{ .name = "last", .args = "[N]", .desc = "Show a recent tool's full output (N=1 newest)", .group = .task_bg },
    // ── Memory & Self-improvement ──
    .{ .name = "memory", .desc = "Show injected and stored memories", .group = .memory },
    .{ .name = "research", .args = "<topic>", .desc = "Web research with phi-curated solutions", .group = .memory },
    .{ .name = "diagnose", .args = "<concern>", .desc = "Self-diagnose a weak answer vs your concern", .group = .memory },
    .{ .name = "knowledge", .desc = "Knowledge graph stats (semantic tier)", .group = .memory },
    // ── MCP & Skills ──
    .{ .name = "skills", .desc = "List available skills (/<name> to invoke)", .group = .mcp_skill },
    .{ .name = "skill", .args = "new|show|remove|reload", .desc = "Manage skills (reload rescans both roots)", .group = .mcp_skill },
    .{ .name = "mcp", .args = "list|install|add|...", .desc = "MCP server management", .group = .mcp_skill },
    .{ .name = "agents", .args = "init|sync|reload", .desc = "Project rules (ziv.md): status and management", .group = .mcp_skill },
};

/// Table index of the command whose name or alias equals `query`
/// (case-insensitive), or null. The REPL's exit trio is accepted in any
/// case; matching is uniform here so /QUIT highlights like /quit.
pub fn indexOfCommand(query: []const u8) ?usize {
    if (query.len == 0) return null;
    for (table, 0..) |c, i| {
        if (std.ascii.eqlIgnoreCase(c.name, query)) return i;
        for (c.aliases) |a| {
            if (std.ascii.eqlIgnoreCase(a, query)) return i;
        }
    }
    return null;
}

/// True when `tok` (a full first token like "/run") is a known command.
/// Partial words ("/mod") are not commands — they color dim until complete.
pub fn isKnownCommand(tok: []const u8) bool {
    if (tok.len < 2 or tok[0] != '/') return false;
    return indexOfCommand(tok[1..]) != null;
}

/// A ranked catalog hit for the completion popup / did-you-mean.
/// `via_alias` is set when the query matched an alias rather than the
/// name (display "(alias)" like Claude Code does).
pub const Match = struct {
    idx: usize,
    via_alias: ?[]const u8 = null,
};

/// Match quality, lower = better. Claude Code's priority skeleton:
/// exact name > exact alias > name prefix (shorter first) > alias prefix
/// > description substring.
const Rank = enum(u8) {
    exact_name = 0,
    exact_alias = 1,
    name_prefix = 2,
    alias_prefix = 3,
    desc_substring = 4,
};

const Ranked = struct {
    match: Match,
    rank: Rank,
    /// Secondary key within name/alias prefix ranks: shorter target first
    /// (closer to exact).
    key: usize,
};

const RankInfo = struct {
    rank: Rank,
    key: usize,
    via_alias: ?[]const u8 = null,
};

fn rankQuery(c: CommandSpec, q: []const u8) ?RankInfo {
    if (std.ascii.eqlIgnoreCase(c.name, q)) return .{ .rank = .exact_name, .key = 0 };
    for (c.aliases) |a| {
        if (std.ascii.eqlIgnoreCase(a, q)) return .{ .rank = .exact_alias, .key = 0, .via_alias = a };
    }
    if (std.ascii.startsWithIgnoreCase(c.name, q)) return .{ .rank = .name_prefix, .key = c.name.len };
    for (c.aliases) |a| {
        if (std.ascii.startsWithIgnoreCase(a, q)) return .{ .rank = .alias_prefix, .key = a.len, .via_alias = a };
    }
    // Single letters hitting descriptions would drown the list in noise —
    // require at least 2 chars for the description tier.
    if (q.len >= 2 and ciContains(c.desc, q)) return .{ .rank = .desc_substring, .key = 0 };
    return null;
}

/// Case-insensitive substring (std.ascii has no indexOfIgnoreCase in
/// 0.17; same naive scan as lineinput's ciContains).
fn ciContains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(hay[i + j]) == std.ascii.toLower(needle[j])) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

/// Filter the catalog for `query` (WITHOUT the leading '/'; empty = the
/// whole catalog in table order) and rank Claude-Code-style. Caller owns
/// the returned slice. Stable within equal rank+key (table order).
pub fn filterRanked(allocator: std.mem.Allocator, query: []const u8) ![]Match {
    var ranked: std.ArrayList(Ranked) = .empty;
    errdefer ranked.deinit(allocator);
    for (table, 0..) |c, i| {
        // Empty query (bare "/"): the whole catalog, UNIFORM rank+key so
        // the stable sort degenerates to table order (grouped listing).
        const r: Ranked = if (query.len == 0)
            .{ .match = .{ .idx = i }, .rank = .name_prefix, .key = 0 }
        else if (rankQuery(c, query)) |r0|
            .{ .match = .{ .idx = i, .via_alias = r0.via_alias }, .rank = r0.rank, .key = r0.key }
        else
            continue;
        try ranked.append(allocator, r);
    }
    const slice = try ranked.toOwnedSlice(allocator);
    // Insertion sort: stable, and n ≤ 30 makes the O(n²) irrelevant.
    std.sort.insertion(Ranked, slice, {}, struct {
        fn before(_: void, a: Ranked, b: Ranked) bool {
            if (a.rank != b.rank) return @intFromEnum(a.rank) < @intFromEnum(b.rank);
            return a.key < b.key;
        }
    }.before);
    const out = try allocator.alloc(Match, slice.len);
    for (slice, 0..) |r, i| out[i] = r.match;
    allocator.free(slice);
    return out;
}

/// Suggest known commands for the unknown-command hint (dispatch).
/// `input` is the raw submitted line ("/pla"). Returns STATIC name/alias
/// slices (no leading '/', nothing to free beyond the outer slice).
pub fn suggestMatching(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    const q = if (input.len > 0 and input[0] == '/') input[1..] else input;
    const hits = try filterRanked(allocator, q);
    defer allocator.free(hits);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (hits) |h| {
        const c = table[h.idx];
        try out.append(allocator, if (h.via_alias) |a| a else c.name);
    }
    return out.toOwnedSlice(allocator);
}

test "isKnownCommand matches full commands and aliases" {
    try std.testing.expect(isKnownCommand("/run"));
    try std.testing.expect(isKnownCommand("/q"));
    try std.testing.expect(isKnownCommand("/models")); // alias of /model
    try std.testing.expect(isKnownCommand("/bg")); // 2026-11-13 gap fix
    try std.testing.expect(isKnownCommand("/style"));
    try std.testing.expect(isKnownCommand("/plan"));
    try std.testing.expect(isKnownCommand("/resume"));
    try std.testing.expect(!isKnownCommand("/mod"));
    try std.testing.expect(!isKnownCommand("run"));
    try std.testing.expect(!isKnownCommand(""));
    try std.testing.expect(!isKnownCommand("/"));
}

test "table integrity: unique names, aliases collide with nothing, every row has a desc" {
    for (table, 0..) |c, i| {
        try std.testing.expect(c.desc.len > 0);
        // name uniqueness
        for (table[i + 1 ..]) |d| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(c.name, d.name));
        }
        // an alias must not collide with ANY name or other alias —
        // indexOfCommand would become ambiguous
        for (c.aliases) |a| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(a, c.name));
            for (table, 0..) |d, j| {
                if (i == j) continue;
                try std.testing.expect(!std.ascii.eqlIgnoreCase(a, d.name));
                for (d.aliases) |b| {
                    try std.testing.expect(!std.ascii.eqlIgnoreCase(a, b));
                }
            }
        }
    }
}

test "filterRanked: exact beats prefix, empty query lists the catalog" {
    const all = try filterRanked(std.testing.allocator, "");
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(table.len, all.len);

    // "mode" exact-matches /mode; /model is only a prefix match and ranks below
    const hits = try filterRanked(std.testing.allocator, "mode");
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len >= 2);
    try std.testing.expectEqualStrings("mode", table[hits[0].idx].name);
    try std.testing.expectEqualStrings("model", table[hits[1].idx].name);

    // alias prefix: "mo" should surface /model via name prefix; "res" finds
    // /resume (name) and /reset via alias
    const res = try filterRanked(std.testing.allocator, "res");
    defer std.testing.allocator.free(res);
    var saw_resume = false;
    var saw_clear_via_reset = false;
    for (res) |h| {
        if (std.mem.eql(u8, table[h.idx].name, "resume") and h.via_alias == null) saw_resume = true;
        if (std.mem.eql(u8, table[h.idx].name, "clear") and h.via_alias != null and std.mem.eql(u8, h.via_alias.?, "reset")) saw_clear_via_reset = true;
    }
    try std.testing.expect(saw_resume);
    try std.testing.expect(saw_clear_via_reset);
}

test "suggestMatching finds prefixes (display names, no slash)" {
    const hits = try suggestMatching(std.testing.allocator, "/m");
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len >= 3); // mode model memory mcp...
    const pla = try suggestMatching(std.testing.allocator, "/pla");
    defer std.testing.allocator.free(pla);
    try std.testing.expectEqual(@as(usize, 1), pla.len); // the drift bug: /plan was invisible
    try std.testing.expectEqualStrings("plan", pla[0]);
}
