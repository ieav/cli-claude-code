/// Default system prompt for Ziv agent.
/// Instructs the model on its identity, available tools, and behavior guidelines.
pub const default_system_prompt =
    \\You are Ziv, an AI coding assistant. You help users with software engineering tasks including reading, writing, and editing files, running shell commands, searching code, and managing projects.
    \\
    \\Guidelines:
    \\- Be concise and direct. Skip unnecessary preamble.
    \\- Use tools to accomplish tasks rather than asking the user to do things manually.
    \\- Before running destructive commands (rm, file overwrites), confirm with the user.
    \\- When editing files, prefer targeted edits over full rewrites.
    \\- Report errors clearly and suggest fixes.
    \\- If unsure about something, ask for clarification.
    \\
    \\Available tools: Bash, FileRead, FileWrite, FileEdit, Glob, Grep, WebSearch, TaskCreate, TaskList, TaskUpdate, AskUserQuestion, ToolSearch.
;

const std = @import("std");
const time_mod = @import("util/time.zig");

const weekday_names = [_][]const u8{
    "Sunday",   "Monday", "Tuesday", "Wednesday",
    "Thursday", "Friday", "Saturday",
};

/// Runtime system prompt: base prompt + current local date/time. Models have
/// no clock — without this line every date/time question ("今天几号") costs a
/// full Bash round trip (tool_use + a second LLM call) before the model can
/// answer. Built at session start and on /clear; mid-session staleness is
/// acceptable at minute granularity.
pub fn buildSystemPrompt(allocator: std.mem.Allocator, custom: ?[]const u8) ![]u8 {
    const base = custom orelse default_system_prompt;
    const dt = time_mod.localDateTime(time_mod.nowMillis());
    return allocator.print("{s}\n\nCurrent local date and time: {s}, {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}. Answer date/time questions from this directly without calling tools.", .{
        base,
        weekday_names[dt.weekday],
        dt.year,
        dt.month,
        dt.day,
        dt.hour,
        dt.minute,
    });
}

test "buildSystemPrompt embeds current date" {
    const alloc = std.testing.allocator;
    const p = try buildSystemPrompt(alloc, null);
    defer alloc.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "Current local date and time") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "202") != null); // this decade
    try std.testing.expect(std.mem.indexOf(u8, p, "without calling tools") != null);
}
