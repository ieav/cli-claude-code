/// Auto-mode classifier — decides whether to allow or block tool use.
/// Uses rule-based fast path + LLM fallback for ambiguous cases.
const std = @import("std");
const registry = @import("registry.zig");
const llm = @import("../llm/mod.zig");
const time_mod = @import("../util/time.zig");

pub const ClassifierResult = union(enum) {
    allow,
    block: struct {
        reason: []const u8,
    },
};

/// Safe tools that are always allowed in auto mode (no classifier needed).
/// (TaskGet was removed: no such tool exists in the registry.)
pub const auto_safe_tools = [_][]const u8{
    "FileRead",
    "Glob",
    "Grep",
    "ToolSearch",
    "TaskList",
};

/// Check if a tool is in the auto-allow safe list.
pub fn isAutoSafe(tool_name: []const u8) bool {
    for (auto_safe_tools) |safe| {
        if (std.mem.eql(u8, safe, tool_name)) return true;
    }
    return false;
}

/// Rule-based classification (fast path, no LLM needed).
pub fn classify(
    tool: *const registry.ToolDefinition,
    input: std.json.Value,
) ClassifierResult {
    if (isAutoSafe(tool.name)) return .allow;
    if (tool.isReadOnly(input)) return .allow;
    if (tool.isDestructive(input)) {
        return .{ .block = .{ .reason = "destructive operation" } };
    }
    return .allow;
}

/// LLM-augmented classifier for auto mode.
/// Uses rule-based check for clear cases, asks LLM for ambiguous non-destructive writes.
pub const LLMClassifier = struct {
    allocator: std.mem.Allocator,
    provider: llm.Provider,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, provider: llm.Provider) Self {
        return .{ .allocator = allocator, .provider = provider };
    }

    pub fn classify(self: *Self, tool: *const registry.ToolDefinition, input: std.json.Value) !ClassifierResult {
        // Fast path: rule-based classification
        if (isAutoSafe(tool.name)) return .allow;
        if (tool.isReadOnly(input)) return .allow;
        if (tool.isDestructive(input)) {
            return .{ .block = .{ .reason = "destructive operation" } };
        }

        // Ambiguous: non-destructive write — ask LLM
        return self.classifyViaLLM(tool, input) catch .allow;
    }

    fn classifyViaLLM(self: *Self, tool: *const registry.ToolDefinition, input: std.json.Value) !ClassifierResult {
        // Serialize input to JSON for the prompt
        const input_str = std.json.Stringify.valueAlloc(self.allocator, input, .{}) catch "{}";
        defer self.allocator.free(input_str);

        const prompt = try self.allocator.print(
            \\You are a tool safety classifier. Respond with exactly "ALLOW" or "BLOCK: reason".
            \\
            \\Tool: {s}
            \\Description: {s}
            \\Input: {s}
            \\
            \\Is this tool use safe? Respond with ALLOW or BLOCK.
        , .{ tool.name, tool.description, input_str });
        defer self.allocator.free(prompt);

        var content_blocks = [_]llm.ContentBlock{.{ .text = prompt }};
        const messages = [_]llm.Message{
            .{
                .role = .user,
                .content = &content_blocks,
                .timestamp = time_mod.nowMillis(),
            },
        };

        const response = try self.provider.complete(&messages, .{
            .max_tokens = 50,
            .temperature = 0.0,
        });
        // Release the response DOM arena (the reason string is already duped
        // onto the classifier allocator below).
        defer response.free(self.allocator);

        // Find text content in response
        var response_text: ?[]const u8 = null;
        for (response.content) |block| {
            if (block == .text) {
                response_text = block.text;
                break;
            }
        }

        const text = response_text orelse return .allow;

        // Parse BLOCK response
        if (std.mem.indexOf(u8, text, "BLOCK") != null) {
            const colon_pos = std.mem.indexOf(u8, text, ": ") orelse
                return .{ .block = .{ .reason = "LLM classified as unsafe" } };
            if (colon_pos + 2 < text.len) {
                const reason = try self.allocator.dupe(u8, std.mem.trim(u8, text[colon_pos + 2 ..], " \n\r"));
                return .{ .block = .{ .reason = reason } };
            }
            return .{ .block = .{ .reason = "LLM classified as unsafe" } };
        }

        return .allow;
    }
};

test "classifier safe tools" {
    try std.testing.expect(isAutoSafe("FileRead"));
    try std.testing.expect(isAutoSafe("Grep"));
    try std.testing.expect(!isAutoSafe("Bash"));
}

test "classifier blocks destructive" {
    var cmd_obj: std.json.ObjectMap = .empty;
    defer cmd_obj.deinit(std.testing.allocator);
    try cmd_obj.put(std.testing.allocator, "command", .{ .string = "rm -rf /" });
    const result = classify(&registry.bash_tool, .{ .object = cmd_obj });
    switch (result) {
        .block => {},
        else => return error.ExpectedBlock,
    }
}
