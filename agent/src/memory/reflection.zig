/// Reflection engine — analyzes past decisions and generates improvement insights.
/// Triggered periodically (π × 10min ≈ 31.4min) or after user feedback.

const std = @import("std");
const math = @import("../math/mod.zig");
const types = @import("types.zig");

pub const ReflectionTrigger = enum {
    on_query_complete,
    on_session_end,
    on_timer,
    on_user_concern,
};

pub const Reflection = struct {
    id: [16]u8,
    trigger: ReflectionTrigger,
    input_summary: []const u8,
    decisions_made: []const u8,
    insights: []const u8,
    action_items: []const u8,
    quality_score: f64, // 0-1, quality of the interaction
    created_at: i64,
};

pub const ReflectionEngine = struct {
    allocator: std.mem.Allocator,
    reflections: std.ArrayList(Reflection),
    query_count: std.atomic.Value(usize),
    last_reflection_at: std.atomic.Value(i64),

    const Self = @This();

    // Reflect after every N queries (adjustable via φ)
    pub const REFLECT_EVERY_N: usize = 10;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .reflections = std.ArrayList(Reflection).init(allocator),
            .query_count = std.atomic.Value(usize).init(0),
            .last_reflection_at = std.atomic.Value(i64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.reflections.items) |r| {
            self.allocator.free(r.input_summary);
            self.allocator.free(r.decisions_made);
            self.allocator.free(r.insights);
            self.allocator.free(r.action_items);
        }
        self.reflections.deinit();
    }

    /// Called after each query. Returns true if reflection should be triggered.
    pub fn shouldReflect(self: *Self) bool {
        const count = self.query_count.fetchAdd(1, .monotonic) + 1;
        if (count % REFLECT_EVERY_N == 0) return true;

        // Also check time-based trigger (π × 10min)
        const now = std.time.milliTimestamp();
        const last = self.last_reflection_at.load(.monotonic);
        const pi_interval: i64 = @intFromFloat(math.constants.PI * 10.0 * 60.0 * 1000.0);
        if (last > 0 and (now - last) > pi_interval) return true;

        return false;
    }

    /// Run reflection on recent interactions and produce insights.
    /// In full implementation, this calls LLM. Here we use heuristic analysis.
    pub fn reflect(
        self: *Self,
        recent_queries: []const []const u8,
        recent_tools_used: u32,
        recent_errors: u32,
    ) !?Reflection {
        if (recent_queries.len == 0) return null;

        // Build summary
        var summary_buf = std.ArrayList(u8).empty;
        defer summary_buf.deinit(self.allocator);
        for (recent_queries) |q| {
            try summary_buf.appendSlice(self.allocator, q);
            try summary_buf.appendSlice(self.allocator, "; ");
        }

        // Analyze patterns
        const error_rate = if (recent_queries.len > 0)
            @as(f64, @floatFromInt(recent_errors)) / @as(f64, @floatFromInt(recent_queries.len))
        else
            0.0;

        // Quality score: e-based decay of error rate
        const quality_score = math.sigmoid(-3.0 * (error_rate - 0.3));

        // Generate insights based on patterns
        var insights_buf = std.ArrayList(u8).empty;
        defer insights_buf.deinit(self.allocator);

        if (error_rate > (1.0 - math.constants.PHI)) {
            // Error rate > 38.2%
            try insights_buf.appendSlice(self.allocator, "错误率过高。建议减少并发任务或切换到更稳定的模型。");
        } else if (recent_tools_used > recent_queries.len * 3) {
            try insights_buf.appendSlice(self.allocator, "工具调用频繁。可能需要优化提示词以减少不必要的工具调用。");
        } else if (quality_score > math.constants.PHI) {
            try insights_buf.appendSlice(self.allocator, "交互质量良好。当前策略有效，继续保持。");
        } else {
            try insights_buf.appendSlice(self.allocator, "交互质量一般。建议关注上下文管理和信息检索策略。");
        }

        // Generate action items
        var actions_buf = std.ArrayList(u8).empty;
        defer actions_buf.deinit(self.allocator);

        if (quality_score < math.constants.PHI) {
            try actions_buf.appendSlice(self.allocator, "1. 回顾最近的低置信度决策\n2. 考虑增加记忆检索范围\n3. 检查工具选择是否合理");
        } else {
            try actions_buf.appendSlice(self.allocator, "无需立即行动");
        }

        const reflection = Reflection{
            .id = std.mem.zeroes([16]u8),
            .trigger = .on_timer,
            .input_summary = try self.allocator.dupe(u8, summary_buf.items),
            .decisions_made = try std.fmt.allocPrint(self.allocator, "queries={d} tools={d} errors={d}", .{ recent_queries.len, recent_tools_used, recent_errors }),
            .insights = try self.allocator.dupe(u8, insights_buf.items),
            .action_items = try self.allocator.dupe(u8, actions_buf.items),
            .quality_score = quality_score,
            .created_at = std.time.milliTimestamp(),
        };

        try self.reflections.append(reflection);
        self.last_reflection_at.store(reflection.created_at, .release);

        return reflection;
    }

    /// Get recent reflections for injection into future prompts.
    pub fn getRecentReflections(self: *Self, max: usize) []const Reflection {
        const count = @min(max, self.reflections.items.len);
        if (count == 0) return &.{};
        return self.reflections.items[self.reflections.items.len - count ..];
    }

    pub fn reflectionCount(self: *const Self) usize {
        return self.reflections.items.len;
    }

    /// Decay old reflections using e-based relevance decay.
    /// Reflections older than threshold have reduced relevance.
    pub fn decayOldReflections(self: *Self, max_age_ms: i64) usize {
        const now = std.time.milliTimestamp();
        var removed: usize = 0;
        // Remove reflections older than max_age with low quality
        var i: usize = 0;
        while (i < self.reflections.items.len) {
            const r = &self.reflections.items[i];
            const age = now - r.created_at;
            if (age > max_age_ms and r.quality_score < math.constants.PHI) {
                self.allocator.free(r.input_summary);
                self.allocator.free(r.decisions_made);
                self.allocator.free(r.insights);
                self.allocator.free(r.action_items);
                _ = self.reflections.orderedRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }
};

test "ReflectionEngine shouldReflect triggers every N queries" {
    var engine = ReflectionEngine.init(std.testing.allocator);
    defer engine.deinit();

    var triggered = false;
    for (0..12) |_| {
        if (engine.shouldReflect()) {
            triggered = true;
        }
    }
    try std.testing.expect(triggered);
}

test "ReflectionEngine reflect produces insights" {
    var engine = ReflectionEngine.init(std.testing.allocator);
    defer engine.deinit();

    const queries = &[_][]const u8{ "query1", "query2" };
    const result = try engine.reflect(queries, 5, 0);
    try std.testing.expect(result != null);
    try std.testing.expect(engine.reflectionCount() == 1);
}
