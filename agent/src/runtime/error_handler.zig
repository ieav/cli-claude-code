/// Error handler — formats errors for user display with analysis and fix options.

const std = @import("std");

pub const ErrorReport = struct {
    code: []const u8,
    message: []const u8,
    analysis: []const u8,
    fixes: []const FixOption,
};

pub const FixOption = struct {
    index: u32,
    description: []const u8,
    is_recommended: bool,
};

/// Format a TaskError into a user-friendly report.
pub fn formatErrorReport(allocator: std.mem.Allocator, code: []const u8, message: []const u8) !ErrorReport {
    const analysis = try analyzeError(allocator, code, message);
    const fixes = try suggestFixes(allocator, code);

    return .{
        .code = code,
        .message = message,
        .analysis = analysis,
        .fixes = fixes,
    };
}

fn analyzeError(allocator: std.mem.Allocator, code: []const u8, message: []const u8) ![]u8 {
    // Provide Chinese analysis based on error code
    if (std.mem.eql(u8, code, "network_timeout")) {
        return allocator.dupe(u8, "网络连接超时。可能原因：网络不稳定、服务端过载、DNS 解析问题。");
    }
    if (std.mem.eql(u8, code, "api_rate_limit")) {
        return allocator.dupe(u8, "API 调用频率超过限制。后台任务可能占用了过多配额。");
    }
    if (std.mem.eql(u8, code, "context_overflow")) {
        return allocator.dupe(u8, "对话上下文超过模型窗口限制。信息量过大导致截断。");
    }
    if (std.mem.eql(u8, code, "storage_full")) {
        return allocator.dupe(u8, "存储空间不足。记忆和知识数据可能需要清理。");
    }
    if (std.mem.eql(u8, code, "embedding_failed")) {
        return allocator.dupe(u8, "向量嵌入生成失败。嵌入模型可能不可用。");
    }
    if (std.mem.eql(u8, code, "knowledge_conflict")) {
        return allocator.dupe(u8, "知识冲突：新旧信息存在矛盾。");
    }
    // Generic fallback
    return std.fmt.allocPrint(allocator, "发生错误: {s} - {s}", .{ code, message });
}

fn suggestFixes(allocator: std.mem.Allocator, code: []const u8) ![]const FixOption {
    var fixes = std.ArrayList(FixOption).init(allocator);
    defer fixes.deinit();

    if (std.mem.eql(u8, code, "network_timeout")) {
        try fixes.append(.{ .index = 1, .description = "重试（推荐）", .is_recommended = true });
        try fixes.append(.{ .index = 2, .description = "切换到本地模型", .is_recommended = false });
        try fixes.append(.{ .index = 3, .description = "启用离线模式", .is_recommended = false });
    } else if (std.mem.eql(u8, code, "api_rate_limit")) {
        try fixes.append(.{ .index = 1, .description = "暂停后台任务（推荐）", .is_recommended = true });
        try fixes.append(.{ .index = 2, .description = "降低调用频率", .is_recommended = false });
        try fixes.append(.{ .index = 3, .description = "切换到本地模型", .is_recommended = false });
    } else if (std.mem.eql(u8, code, "context_overflow")) {
        try fixes.append(.{ .index = 1, .description = "φ 浓缩对话（推荐）", .is_recommended = true });
        try fixes.append(.{ .index = 2, .description = "开始新会话", .is_recommended = false });
    } else {
        try fixes.append(.{ .index = 1, .description = "重试", .is_recommended = true });
        try fixes.append(.{ .index = 2, .description = "跳过", .is_recommended = false });
    }

    return allocator.dupe(FixOption, fixes.items);
}

test "formatErrorReport network_timeout" {
    const report = try formatErrorReport(std.testing.allocator, "network_timeout", "Connection timed out");
    defer std.testing.allocator.free(report.analysis);
    defer std.testing.allocator.free(report.fixes);

    try std.testing.expect(report.fixes.len >= 2);
    try std.testing.expect(report.fixes[0].is_recommended);
}
