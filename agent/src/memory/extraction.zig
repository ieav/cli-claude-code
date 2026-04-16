/// Memory extraction — extracts memorable facts from conversations.
/// Uses φ condensation to keep only the most valuable knowledge.

const std = @import("std");
const math = @import("../math/mod.zig");
const types = @import("types.zig");

pub const ExtractedFact = struct {
    content: []const u8,
    fact_type: FactType,
    importance: f64, // 0-1
};

pub const FactType = enum {
    user_preference,
    technical_fact,
    project_context,
    error_solution,
    pattern_observed,
};

pub const ExtractionEngine = struct {
    allocator: std.mem.Allocator,
    extracted_facts: std.ArrayList(ExtractedFact),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .extracted_facts = std.ArrayList(ExtractedFact).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.extracted_facts.items) |f| {
            self.allocator.free(f.content);
        }
        self.extracted_facts.deinit();
    }

    /// Extract facts from a conversation turn.
    /// In full implementation, this calls LLM. Here we use heuristic extraction.
    pub fn extractFromMessage(self: *Self, role: []const u8, content: []const u8) ![]const ExtractedFact {
        // Only extract from user and assistant messages
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) {
            return &.{};
        }

        var facts = std.ArrayList(ExtractedFact).init(self.allocator);
        defer facts.deinit();

        // Heuristic: detect preference statements
        if (std.mem.indexOf(u8, content, "prefer") != null or
            std.mem.indexOf(u8, content, "always") != null or
            std.mem.indexOf(u8, content, "never") != null or
            std.mem.indexOf(u8, content, "不要") != null or
            std.mem.indexOf(u8, content, "总是") != null or
            std.mem.indexOf(u8, content, "喜欢") != null)
        {
            try facts.append(.{
                .content = try self.allocator.dupe(u8, content),
                .fact_type = .user_preference,
                .importance = 0.9,
            });
        }

        // Heuristic: detect error solutions
        if (std.mem.indexOf(u8, content, "error") != null or
            std.mem.indexOf(u8, content, "fix") != null or
            std.mem.indexOf(u8, content, "解决") != null or
            std.mem.indexOf(u8, content, "修复") != null)
        {
            try facts.append(.{
                .content = try self.allocator.dupe(u8, content),
                .fact_type = .error_solution,
                .importance = 0.8,
            });
        }

        // Heuristic: detect technical facts (code, patterns)
        if (std.mem.indexOf(u8, content, "function") != null or
            std.mem.indexOf(u8, content, "struct") != null or
            std.mem.indexOf(u8, content, "const ") != null or
            std.mem.indexOf(u8, content, "zig") != null)
        {
            try facts.append(.{
                .content = try self.allocator.dupe(u8, content),
                .fact_type = .technical_fact,
                .importance = 0.7,
            });
        }

        if (facts.items.len == 0) return &.{};
        return try self.allocator.dupe(ExtractedFact, facts.items);
    }

    /// Condense extracted facts using φ ratio.
    /// Keeps only the top 61.8% most important facts.
    pub fn condense(self: *Self) usize {
        const target = math.condensationTarget(self.extracted_facts.items.len);
        if (target >= self.extracted_facts.items.len) return 0;

        // Sort by importance (descending) - simple bubble sort for small arrays
        const items = self.extracted_facts.items;
        for (0..items.len) |i| {
            for (i + 1..items.len) |j| {
                if (items[j].importance > items[i].importance) {
                    const tmp = items[i];
                    items[i] = items[j];
                    items[j] = tmp;
                }
            }
        }

        // Remove low-importance facts
        const to_remove = self.extracted_facts.items.len - target;
        var i: usize = self.extracted_facts.items.len - 1;
        var count: usize = 0;
        while (count < to_remove and i > 0) : ({
            i -= 1;
            count += 1;
        }) {
            self.allocator.free(self.extracted_facts.items[i].content);
            _ = self.extracted_facts.pop();
        }
        return to_remove;
    }

    pub fn factCount(self: *const Self) usize {
        return self.extracted_facts.items.len;
    }
};

test "ExtractionEngine detects preferences" {
    var engine = ExtractionEngine.init(std.testing.allocator);
    defer engine.deinit();

    const facts = try engine.extractFromMessage("user", "我 prefer 使用 Zig 而不是 Rust");
    defer std.testing.allocator.free(facts);

    try std.testing.expect(facts.len >= 1);
    try std.testing.expect(facts[0].fact_type == .user_preference);
}

test "ExtractionEngine condense with φ ratio" {
    var engine = ExtractionEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Add 10 facts
    for (0..10) |i| {
        const content = try std.fmt.allocPrint(std.testing.allocator, "fact {d}", .{i});
        defer std.testing.allocator.free(content);
        try engine.extracted_facts.append(.{
            .content = try std.testing.allocator.dupe(u8, content),
            .fact_type = .technical_fact,
            .importance = @as(f64, @floatFromInt(i)) / 10.0,
        });
    }

    try std.testing.expectEqual(@as(usize, 10), engine.factCount());
    const removed = engine.condense();
    // 10 × 0.618 ≈ 6.18, round = 6, so remove ~4
    try std.testing.expect(removed > 0);
    try std.testing.expect(engine.factCount() == math.condensationTarget(10));
}
