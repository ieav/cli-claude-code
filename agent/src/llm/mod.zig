pub const provider = @import("provider.zig");
pub const message = @import("message.zig");
pub const streaming = @import("streaming.zig");
pub const openai = @import("openai.zig");
pub const ollama = @import("ollama.zig");
pub const claude = @import("claude.zig");

pub const Provider = provider.Provider;
pub const Message = provider.Message;
pub const MessageRole = provider.MessageRole;
pub const ContentBlock = provider.ContentBlock;
pub const CompleteOptions = provider.CompleteOptions;
pub const StreamEvent = provider.StreamEvent;
pub const Usage = provider.Usage;

pub const OpenAIProvider = openai.OpenAIProvider;
pub const OpenAIConfig = openai.OpenAIConfig;
pub const OllamaProvider = ollama.OllamaProvider;
pub const OllamaConfig = ollama.OllamaConfig;
pub const ClaudeProvider = claude.ClaudeProvider;
pub const ClaudeConfig = claude.ClaudeConfig;

/// Model backend type — determines which provider handles a given model.
pub const BackendType = enum {
    openai,
    claude,
    ollama,

    pub fn label(self: BackendType) []const u8 {
        return switch (self) {
            .openai => "OpenAI",
            .claude => "Claude",
            .ollama => "Ollama",
        };
    }
};

/// Detect which backend a model name belongs to.
pub fn detectBackend(model: []const u8) BackendType {
    // Claude models
    if (std.mem.startsWith(u8, model, "claude-")) return .claude;
    if (std.mem.startsWith(u8, model, "claude_opus")) return .claude;
    if (std.mem.startsWith(u8, model, "claude_sonnet")) return .claude;
    if (std.mem.startsWith(u8, model, "claude_haiku")) return .claude;

    // OpenAI models
    if (std.mem.startsWith(u8, model, "gpt-")) return .openai;
    if (std.mem.startsWith(u8, model, "gpt4")) return .openai;
    if (std.mem.startsWith(u8, model, "o1-")) return .openai;
    if (std.mem.startsWith(u8, model, "o1")) return .openai;
    if (std.mem.startsWith(u8, model, "o3-")) return .openai;
    if (std.mem.startsWith(u8, model, "o3")) return .openai;
    if (std.mem.startsWith(u8, model, "chatgpt-")) return .openai;

    // Default: Ollama (local models)
    return .ollama;
}

/// Known model catalog for display and validation.
pub const ModelEntry = struct {
    name: []const u8,
    backend: BackendType,
    description: []const u8,
};

pub const KNOWN_MODELS = [_]ModelEntry{
    .{ .name = "claude-opus-4-6", .backend = .claude, .description = "Claude Opus 4.6 — most capable" },
    .{ .name = "claude-sonnet-4-6", .backend = .claude, .description = "Claude Sonnet 4.6 — balanced" },
    .{ .name = "claude-haiku-4-5", .backend = .claude, .description = "Claude Haiku 4.5 — fast" },
    .{ .name = "gpt-4o", .backend = .openai, .description = "GPT-4o — OpenAI flagship" },
    .{ .name = "gpt-4o-mini", .backend = .openai, .description = "GPT-4o Mini — fast & cheap" },
    .{ .name = "o3-mini", .backend = .openai, .description = "O3 Mini — reasoning" },
    .{ .name = "llama3.2", .backend = .ollama, .description = "Llama 3.2 — local (Ollama)" },
    .{ .name = "qwen2.5", .backend = .ollama, .description = "Qwen 2.5 — local (Ollama)" },
    .{ .name = "deepseek-r1", .backend = .ollama, .description = "DeepSeek R1 — local (Ollama)" },
};

/// Find a known model by exact name (returns null for custom model names).
pub fn findKnownModel(name: []const u8) ?*const ModelEntry {
    for (&KNOWN_MODELS) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

const std = @import("std");

// ── Tests ──

test "detectBackend routes Claude models" {
    try std.testing.expect(detectBackend("claude-opus-4-6") == .claude);
    try std.testing.expect(detectBackend("claude-sonnet-4-6") == .claude);
    try std.testing.expect(detectBackend("claude-haiku-4-5") == .claude);
    try std.testing.expect(detectBackend("claude-3-5-sonnet") == .claude);
}

test "detectBackend routes OpenAI models" {
    try std.testing.expect(detectBackend("gpt-4o") == .openai);
    try std.testing.expect(detectBackend("gpt-4o-mini") == .openai);
    try std.testing.expect(detectBackend("gpt-4-1106-preview") == .openai);
    try std.testing.expect(detectBackend("gpt4") == .openai);
    try std.testing.expect(detectBackend("o1-mini") == .openai);
    try std.testing.expect(detectBackend("o1-preview") == .openai);
    try std.testing.expect(detectBackend("o3-mini") == .openai);
    try std.testing.expect(detectBackend("chatgpt-4o-latest") == .openai);
}

test "detectBackend routes unknown models to Ollama" {
    try std.testing.expect(detectBackend("llama3.2") == .ollama);
    try std.testing.expect(detectBackend("qwen2.5") == .ollama);
    try std.testing.expect(detectBackend("deepseek-r1") == .ollama);
    try std.testing.expect(detectBackend("mistral") == .ollama);
    try std.testing.expect(detectBackend("my-custom-model") == .ollama);
}

test "findKnownModel finds registered models" {
    try std.testing.expect(findKnownModel("claude-sonnet-4-6") != null);
    try std.testing.expect(findKnownModel("gpt-4o") != null);
    try std.testing.expect(findKnownModel("llama3.2") != null);
    try std.testing.expect(findKnownModel("nonexistent-model") == null);
}

test "findKnownModel returns correct backend" {
    const entry = findKnownModel("claude-opus-4-6").?;
    try std.testing.expect(entry.backend == .claude);
    try std.testing.expectEqualStrings("claude-opus-4-6", entry.name);
}

test "BackendType.label returns readable names" {
    try std.testing.expectEqualStrings("Claude", BackendType.claude.label());
    try std.testing.expectEqualStrings("OpenAI", BackendType.openai.label());
    try std.testing.expectEqualStrings("Ollama", BackendType.ollama.label());
}

test "KNOWN_MODELS has 9 entries" {
    try std.testing.expectEqual(@as(usize, 9), KNOWN_MODELS.len);
}

test "KNOWN_MODELS all entries have non-empty names and descriptions" {
    for (&KNOWN_MODELS) |entry| {
        try std.testing.expect(entry.name.len > 0);
        try std.testing.expect(entry.description.len > 0);
    }
}
