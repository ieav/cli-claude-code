/// Canonical slash-command table — single source of truth for the line
/// editor's syntax coloring. Keep in sync with the dispatch chain in
/// repl.zig (the else branch prints "Unknown command" using this list's
/// suggestions too).
const std = @import("std");

/// All commands the REPL understands, including aliases and arg-taking
/// prefixes (/run, /model, /research).
pub const commands = [_][]const u8{
    "/quit",  "/q",     "/exit",  "/help",  "/h",      "/tools",
    "/run",   "/mode",  "/model", "/models", "/config", "/compact",
    "/clear", "/reset", "/new",   "/context", "/memory", "/research",
    "/knowledge", "/diagnose", "/undo", "/history", "/rewind", "/stats",
    "/skills", "/mcp",
    "/version", "/terminal-setup",
};

/// True when `tok` (a full first token like "/run") is a known command.
/// Partial words ("/mod") are not commands — they color dim until complete.
pub fn isKnownCommand(tok: []const u8) bool {
    for (commands) |c| {
        // Case-insensitive: /QUIT must highlight like /quit (the REPL also
        // accepts the exit trio in any case).
        if (std.ascii.eqlIgnoreCase(tok, c)) return true;
    }
    return false;
}

/// Suggest known commands sharing the prefix (for the unknown-command hint).
/// Caller owns the returned slice.
pub fn suggestMatching(allocator: std.mem.Allocator, prefix: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (commands) |c| {
        if (std.mem.startsWith(u8, c, prefix)) try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

test "isKnownCommand matches full commands only" {
    try std.testing.expect(isKnownCommand("/run"));
    try std.testing.expect(isKnownCommand("/q"));
    try std.testing.expect(!isKnownCommand("/mod"));
    try std.testing.expect(!isKnownCommand("run"));
    try std.testing.expect(!isKnownCommand(""));
}

test "suggestMatching finds prefixes" {
    const hits = try suggestMatching(std.testing.allocator, "/m");
    defer std.testing.allocator.free(hits);
    try std.testing.expect(hits.len >= 3); // /mode /model /models /memory
}
