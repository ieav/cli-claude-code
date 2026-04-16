/// LLM Provider abstraction — comptime vtable pattern for multi-model support.
/// Each backend (Claude, OpenAI, Ollama) implements this vtable.

const std = @import("std");

pub const MessageRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,
    thinking: []const u8,
};

pub const ToolUseBlock = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

pub const ToolResultBlock = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

pub const Message = struct {
    role: MessageRole,
    content: []ContentBlock,
    timestamp: i64,
};

pub const CompleteOptions = struct {
    max_tokens: u32 = 4096,
    temperature: f64 = 0.7,
    stop_sequences: ?[]const []const u8 = null,
};

pub const CompleteResponse = struct {
    content: []ContentBlock,
    usage: Usage,
    stop_reason: StopReason,

    pub const StopReason = enum {
        end_turn,
        max_tokens,
        stop_sequence,
        tool_use,
    };
};

pub const Usage = struct {
    input_tokens: u32,
    output_tokens: u32,
};

pub const StreamEvent = union(enum) {
    content_delta: []const u8,
    thinking_delta: []const u8,
    tool_call: ToolUseBlock,
    done: ?Usage,
    error_occurred: ProviderError,
};

pub const ProviderError = error{
    NetworkTimeout,
    RateLimit,
    AuthFailed,
    ContextOverflow,
    InvalidRequest,
    ServerError,
    Unknown,
};

pub const ProviderVTable = struct {
    complete_fn: *const fn (*anyopaque, []const Message, CompleteOptions) anyerror!CompleteResponse,
    stream_fn: *const fn (*anyopaque, []const Message, CompleteOptions, *StreamCallback) anyerror!void,
    count_tokens_fn: ?*const fn (*anyopaque, []const u8) anyerror!u32,
    supports_tool_use_fn: *const fn (*anyopaque) bool,
    supports_streaming_fn: *const fn (*anyopaque) bool,
    deinit_fn: *const fn (*anyopaque) void,
};

pub const StreamCallback = fn (StreamEvent) anyerror!void;

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const ProviderVTable,

    pub fn complete(self: Provider, messages: []const Message, opts: CompleteOptions) anyerror!CompleteResponse {
        return self.vtable.complete_fn(self.ptr, messages, opts);
    }

    pub fn stream(self: Provider, messages: []const Message, opts: CompleteOptions, cb: *StreamCallback) anyerror!void {
        return self.vtable.stream_fn(self.ptr, messages, opts, cb);
    }

    pub fn countTokens(self: Provider, text: []const u8) anyerror!u32 {
        if (self.vtable.count_tokens_fn) |fn_ptr| {
            return fn_ptr(self.ptr, text);
        }
        // Estimate: ~4 chars per token
        return @intCast(text.len / 4);
    }

    pub fn supportsToolUse(self: Provider) bool {
        return self.vtable.supports_tool_use_fn(self.ptr);
    }

    pub fn supportsStreaming(self: Provider) bool {
        return self.vtable.supports_streaming_fn(self.ptr);
    }

    pub fn deinit(self: Provider) void {
        self.vtable.deinit_fn(self.ptr);
    }
};
