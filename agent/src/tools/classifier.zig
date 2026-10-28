/// Auto-mode classifier — decides whether to allow or block tool use.
/// Uses rule-based fast path + LLM fallback for ambiguous cases.
const std = @import("std");
const registry = @import("registry.zig");
const llm = @import("../llm/mod.zig");
const time_mod = @import("../util/time.zig");
const logger = @import("../util/log.zig");

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
    /// Scopes the verdict cache: switching models starts a fresh verdict
    /// history instead of replaying the previous model's decisions.
    model_name: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, provider: llm.Provider, model_name: []const u8) Self {
        return .{ .allocator = allocator, .provider = provider, .model_name = model_name };
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
        // Serialize input to JSON for the prompt (and the cache key)
        const input_str = std.json.Stringify.valueAlloc(self.allocator, input, .{}) catch "{}";
        defer self.allocator.free(input_str);

        // Verdict cache. The permission gate runs serially in agent-loop
        // phase 1 (parallel batches only execute already-approved calls),
        // so no lock is needed; entries are process-lifetime. This is the
        // classifier's latency fix: auto mode used to block on a full LLM
        // round trip for EVERY ask-level call, including exact repeats of
        // one the user just saw.
        {
            const cached = verdictCacheGet(tool.name, self.model_name, input_str);
            if (cached) |v| {
                logger.notice("classifier(auto): cache hit for {s} -> {s}", .{ tool.name, if (v.allow) "allow" else "block" });
                return if (v.allow) .allow else .{ .block = .{ .reason = v.reason } };
            }
        }

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

        // Parse BLOCK response. `reason` points into the response DOM — it
        // dies with the deferred response.free(), so the cache stores its
        // own copy and a miss returns a dupe on self.allocator.
        var allow = true;
        var reason: []const u8 = "";
        if (std.mem.indexOf(u8, text, "BLOCK") != null) {
            allow = false;
            const colon_pos = std.mem.indexOf(u8, text, ": ") orelse
                std.mem.indexOf(u8, text, ":");
            reason = blk: {
                if (colon_pos) |cp| {
                    if (cp + 2 <= text.len) {
                        break :blk std.mem.trim(u8, text[cp + 2 ..], " \n\r");
                    }
                }
                break :blk "LLM classified as unsafe";
            };
        }

        verdictCachePut(tool.name, self.model_name, input_str, .{ .allow = allow, .reason = reason });

        if (allow) return .allow;
        // The cache now owns the reason copy — read it back so the returned
        // block reason never needs its own allocation (and never dangles).
        // If caching was skipped (oversized input), fall back to a literal.
        if (verdictCacheGet(tool.name, self.model_name, input_str)) |v| {
            return .{ .block = .{ .reason = v.reason } };
        }
        return .{ .block = .{ .reason = "LLM classified as unsafe" } };
    }
};

/// Process-lifetime verdict cache (see classifyViaLLM). The reason string is
/// cache-owned and outlives the ClassifierResult — callers only print it.
const Verdict = struct {
    allow: bool,
    reason: []const u8,
};

var verdict_cache: std.StringHashMapUnmanaged(Verdict) = .empty;
/// Fixed allocator so cached entries never entangle with a caller's
/// testing.allocator (leak detector ignores smp).
const cache_alloc = std.heap.c_allocator;

fn verdictCacheGet(tool: []const u8, model: []const u8, input_json: []const u8) ?Verdict {
    var key_buf: [640]u8 = undefined;
    const key = cacheKey(&key_buf, tool, model, input_json) orelse return null;
    return verdict_cache.get(key);
}

fn verdictCachePut(tool: []const u8, model: []const u8, input_json: []const u8, v: Verdict) void {
    var key_buf: [640]u8 = undefined;
    const key = cacheKey(&key_buf, tool, model, input_json) orelse return; // oversized input: skip caching
    const owned_key = cache_alloc.dupe(u8, key) catch return;
    const owned_reason = cache_alloc.dupe(u8, if (v.reason.len > 128) v.reason[0..128] else v.reason) catch {
        cache_alloc.free(owned_key);
        return;
    };
    verdict_cache.put(cache_alloc, owned_key, .{ .allow = v.allow, .reason = owned_reason }) catch {
        cache_alloc.free(owned_key);
        cache_alloc.free(owned_reason);
    };
}

fn cacheKey(buf: []u8, tool: []const u8, model: []const u8, input_json: []const u8) ?[]const u8 {
    if (tool.len + 1 + model.len + 1 + input_json.len > buf.len) return null;
    var n: usize = 0;
    @memcpy(buf[n..][0..tool.len], tool);
    n += tool.len;
    buf[n] = 0;
    n += 1;
    @memcpy(buf[n..][0..model.len], model);
    n += model.len;
    buf[n] = 0;
    n += 1;
    @memcpy(buf[n..][0..input_json.len], input_json);
    n += input_json.len;
    return buf[0..n];
}

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

test "verdict cache roundtrip and key separation" {
    verdictCachePut("FileWrite", "glm-4.6", "{\"path\":\"a\"}", .{ .allow = false, .reason = "nope" });
    const hit = verdictCacheGet("FileWrite", "glm-4.6", "{\"path\":\"a\"}").?;
    try std.testing.expect(!hit.allow);
    try std.testing.expectEqualStrings("nope", hit.reason);
    // Same tool, different input → miss; different tool → miss; different
    // model → miss (model switch re-judges).
    try std.testing.expect(verdictCacheGet("FileWrite", "glm-4.6", "{\"path\":\"b\"}") == null);
    try std.testing.expect(verdictCacheGet("FileEdit", "glm-4.6", "{\"path\":\"a\"}") == null);
    try std.testing.expect(verdictCacheGet("FileWrite", "claude-x", "{\"path\":\"a\"}") == null);
}
