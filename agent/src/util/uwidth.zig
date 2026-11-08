//! 宽度判定的唯一事实源（2026-11-10 起）：utf8proc 的 Unicode 表
//! （East Asian Width + 字素属性），替代手写首字节分类——歧义宽度
//! （—±×÷ 等）按 1 列、CJK/宽 emoji 按 2 列、组合符 0 列，与主流
//! 终端渲染一致。deps/utf8proc（MIT）随 sqlite3.c 一起编进二进制。

const c = @import("utf8proc");

/// 码点的显示宽度（列）。无效码点按 1（保守可显）。
pub fn charWidth(cp: u21) usize {
    const w = c.utf8proc_charwidth(@intCast(cp));
    return @intCast(@max(w, 0));
}

test "utf8proc widths: ambiguous narrow, CJK wide, combining zero" {
    try std.testing.expectEqual(@as(usize, 1), charWidth(0x2014)); // — em dash（用户取证）
    try std.testing.expectEqual(@as(usize, 1), charWidth(0x00B1)); // ±
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x4E2D)); // 中
    try std.testing.expectEqual(@as(usize, 2), charWidth(0x1F389)); // 🎉
    try std.testing.expectEqual(@as(usize, 1), charWidth('a'));
    try std.testing.expectEqual(@as(usize, 0), charWidth(0x0301)); // 组合尖音符
}

const std = @import("std");
