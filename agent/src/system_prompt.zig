/// Default system prompt for Ziv agent.
/// Instructs the model on its identity and behavior guidelines.
/// 工具清单刻意不在这里枚举（2026-11-09 修订）：随请求下发的 tools
/// 数组才是唯一事实源；这里写死清单必然漂移（已漂过两次——先漏
/// TaskGet/agent，连 WebFetch 都没列上），两处信号打架还削弱模型对
/// agent 等新工具的识别（「开启多agent」实测命中率的元凶之一）。
/// 提示三段组装：head（身份）+ communication（风格段，两档）+ tail
/// （代码/并行/安全/工具声明）。风格档切换只换中段——其余段落单一
/// 事实源，杜绝两份全文常量的漂移（工具清单漂移的教训）。
const prompt_head =
    \\You are Ziv, an AI coding agent working in the user's terminal.
    \\
;

const communication_default =
    \\Communication:
    \\- Reply in the language the user writes in.
    \\- Answer directly: no preamble, no restating the question, no filler.
    \\- Report failures honestly with the real output; never claim success without having run the command.
    \\- If requirements are genuinely ambiguous, ask ONE focused question instead of guessing.
    \\
;

/// Concise Output Style（简洁输出风格）：结果优先，省略开场白/过程
/// 叙述/结尾复述。官方定义口径，glm 中文指令跟随友好。
const communication_concise =
    \\Communication（Concise Output Style · 简洁输出风格）:
    \\- 结果优先：先给答案，再给证据（文件/命令输出），最后才是必要说明。
    \\- 省略开场白、过程叙述（如"我先看看…"）与结尾的复述总结。
    \\- 代码与命令优先于散文；用户能自己读的工具输出不要复述一遍。
    \\- 只在结果不明显时解释；多步任务的中间过程不逐条播报。
    \\- Reply in the language the user writes in.
    \\
;

/// 自定义 system_prompt + concise 时的追加块（不覆盖用户提示，只叠
/// 加风格约束）。
const concise_append =
    \\
    \\Output Style（Concise）: 结果优先。省略开场白、过程叙述与结尾复述；
    \\代码与命令优先于散文；用户能自己读的输出不复述。
;

const prompt_tail =
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

pub const default_system_prompt = prompt_head ++ communication_default ++ prompt_tail;

/// 风格档选择（settings.output_style）：default = 现行为；concise = 换
/// Communication 段。未知值回落 default。
pub const STYLE_DEFAULT: []const u8 = "default";
pub const STYLE_CONCISE: []const u8 = "concise";

pub fn styleValid(s: []const u8) bool {
    return std.mem.eql(u8, s, STYLE_DEFAULT) or std.mem.eql(u8, s, STYLE_CONCISE);
}

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
pub fn buildSystemPrompt(allocator: std.mem.Allocator, custom: ?[]const u8, style: []const u8) ![]u8 {
    const concise = std.mem.eql(u8, style, STYLE_CONCISE);
    var base: []const u8 = undefined;
    if (custom) |c| {
        // 自定义提示：风格段追加其后，不覆盖用户内容。
        base = if (concise) try std.fmt.allocPrint(allocator, "{s}{s}", .{ c, concise_append }) else c;
    } else {
        base = if (concise) prompt_head ++ communication_concise ++ prompt_tail else default_system_prompt;
    }
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
    const p = try buildSystemPrompt(alloc, null, "default");
    defer alloc.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "Current local date and time") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "202") != null); // this decade
    try std.testing.expect(std.mem.indexOf(u8, p, "without calling tools") != null);
}

test "output style: concise swaps communication section, default untouched" {
    const alloc = std.testing.allocator;
    const def = try buildSystemPrompt(alloc, null, "default");
    defer alloc.free(def);
    const con = try buildSystemPrompt(alloc, null, "concise");
    defer alloc.free(con);
    // concise 换段：特征串在，default 的特征串不在。
    try std.testing.expect(std.mem.indexOf(u8, con, "Concise Output Style") != null);
    try std.testing.expect(std.mem.indexOf(u8, con, "结果优先") != null);
    try std.testing.expect(std.mem.indexOf(u8, con, "Answer directly: no preamble") == null);
    // default 现行为不变。
    try std.testing.expect(std.mem.indexOf(u8, def, "Answer directly: no preamble") != null);
    try std.testing.expect(std.mem.indexOf(u8, def, "Concise Output Style") == null);
    // 共同段两档都在（单一事实源）。
    try std.testing.expect(std.mem.indexOf(u8, con, "Working with code:") != null);
    try std.testing.expect(std.mem.indexOf(u8, def, "Working with code:") != null);
    // 未知值回落 default。
    const bogus = try buildSystemPrompt(alloc, null, "loud");
    defer alloc.free(bogus);
    try std.testing.expect(std.mem.indexOf(u8, bogus, "Answer directly: no preamble") != null);
}

test "output style: custom prompt + concise appends, never overrides" {
    const alloc = std.testing.allocator;
    const custom: []const u8 = "You are a test agent. Follow MY rules.";
    const con = try buildSystemPrompt(alloc, custom, "concise");
    defer alloc.free(con);
    try std.testing.expect(std.mem.indexOf(u8, con, "Follow MY rules.") != null); // 用户提示保留
    try std.testing.expect(std.mem.indexOf(u8, con, "Output Style（Concise）") != null); // 风格叠加
    const plain = try buildSystemPrompt(alloc, custom, "default");
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Output Style（Concise）") == null); // default 不叠
}

test "styleValid accepts exactly two values" {
    try std.testing.expect(styleValid("default") and styleValid("concise"));
    try std.testing.expect(!styleValid("verbose") and !styleValid(""));
}
