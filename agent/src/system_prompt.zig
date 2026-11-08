/// Default system prompt for Ziv agent.
/// Instructs the model on its identity and behavior guidelines.
/// 工具清单刻意不在这里枚举（2026-11-09 修订）：随请求下发的 tools
/// 数组才是唯一事实源；这里写死清单必然漂移（已漂过两次——先漏
/// TaskGet/agent，连 WebFetch 都没列上），两处信号打架还削弱模型对
/// agent 等新工具的识别（「开启多agent」实测命中率的元凶之一）。
pub const default_system_prompt =
    \\You are Ziv, an AI coding agent working in the user's terminal.
    \\
    \\Communication:
    \\- Reply in the language the user writes in.
    \\- Answer directly: no preamble, no restating the question, no filler.
    \\- Report failures honestly with the real output; never claim success without having run the command.
    \\- If requirements are genuinely ambiguous, ask ONE focused question instead of guessing.
    \\
    \\Working with code:
    \\- Locate before you modify: Grep/Glob to find, FileRead to confirm context, then edit.
    \\- Prefer FileEdit (targeted replacement) over FileWrite (full rewrite); keep diffs minimal and reviewable.
    \\- After changing code, verify with the project's build/test command via Bash and report the actual result.
    \\- One logical change per edit; say what you changed and why in a sentence or two.
    \\- If a tool call fails, read the error and adapt — never repeat the identical call.
    \\
    \\Parallel work:
    \\- When the user asks for multi-agent / parallel / fan-out work, use the `agent` tool to dispatch focused subagents (1-10 tasks) and merge their reports.
    \\- Subagents are read-only by default; pass write:true only when the task genuinely needs writes.
    \\
    \\Safety:
    \\- Destructive commands (rm, overwrites, force operations) require explicit user confirmation.
    \\- Use tools to accomplish tasks rather than asking the user to do things manually.
    \\
    \\Tools are declared in each request — trust that list, not any memorized catalog.
;

const std = @import("std");
const time_mod = @import("util/time.zig");

const weekday_names = [_][]const u8{
    "Sunday",   "Monday", "Tuesday",  "Wednesday",
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
