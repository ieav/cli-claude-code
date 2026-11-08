//! Skill 工具门（2026-11-10 C 项）：SKILL.md 前置声明 `tools:` 从「纯
//! 展示」升级为强制——skill 生效的那一个回合里，不在清单内的工具被
//! 权限管线拒绝（CC allowed-tools 同语义）。清单为空 = 不设限（向后
//! 兼容：老 skill 无声明照常全量）。

const std = @import("std");

/// 当前生效的 skill 工具白名单（逗号分隔原串；null = 无门）。
var active_tools: ?[]const u8 = null;

/// 武装：skill 调用时（dispatch）调用。tools_str 为前置声明原串。
pub fn arm(tools_str: []const u8) void {
    active_tools = if (tools_str.len > 0) tools_str else null;
}

/// 解除：回合结束时（repl）调用。幂等。
pub fn disarm() void {
    active_tools = null;
}

pub fn armed() bool {
    return active_tools != null;
}

/// name 是否放行。未武装 → 恒 true；声明里没列 → false。
/// 名字精确匹配（含 mcp__server__tool 全名）。
pub fn allows(name: []const u8) bool {
    const list = active_tools orelse return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len > 0 and std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

test "gate: empty = unrestricted, list = exact match only" {
    disarm();
    try std.testing.expect(allows("Bash")); // 未武装恒放行
    arm("FileRead, Grep ,mcp__fs__list");
    try std.testing.expect(allows("FileRead"));
    try std.testing.expect(allows("Grep")); // 空格容忍
    try std.testing.expect(allows("mcp__fs__list"));
    try std.testing.expect(!allows("Bash"));
    try std.testing.expect(!allows("FileWrite"));
    disarm();
    try std.testing.expect(allows("Bash")); // 解除后恢复
    arm(""); // 空声明 = 不设限
    try std.testing.expect(allows("Bash"));
    disarm();
}
