/// LLM Provider abstraction — comptime vtable pattern for multi-model support.
/// Each backend (Claude, OpenAI, Ollama) implements this vtable.
const std = @import("std");
const logger = @import("../util/log.zig");

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
    content: []const ContentBlock,
    timestamp: i64,
};

/// Provider-agnostic tool declaration sent in request bodies. `input_schema`
/// is raw JSON Schema text (not a JSON string) — backends embed it verbatim
/// in their wire format.
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

pub const CompleteOptions = struct {
    max_tokens: u32 = 4096,
    temperature: f64 = 0.7,
    stop_sequences: ?[]const []const u8 = null,
    /// Tool declarations the model may call. null = plain chat (no tools).
    tools: ?[]const ToolSpec = null,
};

pub const CompleteResponse = struct {
    content: []const ContentBlock,
    usage: Usage,
    stop_reason: StopReason,
    /// Owns the JSON DOM that backs the string slices in `content`.
    /// Providers that parse with this arena must keep it alive as long as
    /// any content slice is readable; call free() to release everything.
    dom_arena: ?*std.heap.ArenaAllocator = null,

    /// Free the content slice and the backing DOM arena.
    /// Note: any slices copied out of `content` dangle after this call.
    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        if (self.content.len > 0) allocator.free(@constCast(self.content));
        if (self.dom_arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
    }

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

/// A streaming event delivered through StreamCallback.
///
/// Ownership contract (binding for ALL backends): every payload slice —
/// delta text, and a tool_call's id/name/input DOM — is only guaranteed
/// valid for the duration of the callback invocation. Backends back them
/// with per-chunk or stream-scoped arenas that may be released as soon as
/// the callback returns (Ollama frees tool_call strings with the line;
/// OpenAI/Claude keep them until the stream state deinits — never rely on
/// that longer lifetime). Consumers must dupe synchronously anything they
/// keep.
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

// ── HTTP error-response handling (shared by all backends) ──

/// Best-effort read of an HTTP error response body (≤4 KiB). The gateway's
/// rejection reason ("messages with role 'tool' must follow a 'tool_calls'
/// message", "maximum context length is …") lives here — a bare status code
/// is undiagnosable. Returns "" when the body cannot be read. Caller frees.
pub fn readErrorBody(alloc: std.mem.Allocator, response: anytype) []const u8 {
    var buf: [4096]u8 = undefined;
    const reader = response.reader(&buf);
    return reader.allocRemaining(alloc, .limited(4096)) catch "";
}

/// Read the gateway's error body, log it on one [ERR] line, and map the
/// status to a ProviderError. Every backend funnels its non-2xx responses
/// through here so a 400 always carries its actual reason into the log
/// instead of a bare `status=400`.
pub fn failRequest(alloc: std.mem.Allocator, tag: []const u8, response: anytype) ProviderError {
    const status: u16 = @backingInt(response.head.status);
    const body = readErrorBody(alloc, response);
    defer if (body.len > 0) alloc.free(@constCast(body));

    if (body.len == 0) {
        logger.err("{s} error: status={d} (no error body)", .{ tag, status });
    } else {
        // Collapse newlines and cap at 300 chars so the [ERR] log stays a
        // single greppable line.
        var flat: [300]u8 = undefined;
        var n: usize = 0;
        for (body) |c| {
            if (n >= flat.len) break;
            flat[n] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
            n += 1;
        }
        logger.err("{s} error: status={d} body={s}", .{ tag, status, flat[0..n] });
    }

    if (status == 400 and isContextOverflowBody(body)) return error.ContextOverflow;
    return switch (status) {
        401, 403 => error.AuthFailed,
        429 => error.RateLimit,
        400, 404, 422 => error.InvalidRequest,
        else => error.ServerError,
    };
}

/// Heuristic: does a 400 body say the input no longer fits the model's
/// context? Remedy differs from a generic InvalidRequest (compact vs fix
/// the request), and gateways word it in at least three languages.
/// Rough context-window estimate for the active model (T1.2): no backend
/// reports windows reliably through the chat API, so known families map to
/// their typical sizes and everything else conserves at 32K. Feeds the
/// memory-budget scaler; being off by 2x only shifts the budget one notch.
pub fn contextEstimate(model: []const u8, backend: anytype) u32 {
    if (backend == .ollama) return 8192; // local models: assume the small end
    var buf: [128]u8 = undefined;
    if (model.len > buf.len) return 32_768; // absurd name: default, no assert panic
    const name = std.ascii.lowerString(&buf, model);
    if (std.mem.indexOf(u8, name, "claude") != null) return 200_000;
    if (std.mem.indexOf(u8, name, "gpt-4") != null or
        std.mem.indexOf(u8, name, "gpt-5") != null or
        std.mem.indexOf(u8, name, "glm-4") != null or
        std.mem.indexOf(u8, name, "glm-5") != null or
        std.mem.indexOf(u8, name, "deepseek") != null or
        std.mem.indexOf(u8, name, "qwen") != null or
        std.mem.indexOf(u8, name, "kimi") != null or
        std.mem.indexOf(u8, name, "moonshot") != null) return 131_072;
    return 32_768;
}


/// Model capability tier (T2.1): gates the memory flywheel's auxiliary
/// LLM calls — weak/local models produce noise insights that poison the
/// next session's injected memories (defect ⑧).
pub const CapabilityTier = enum {
    full, // strong tool-use model: reflection LLM augmentation allowed
    flash, // fast/cheap tier: heuristics only, no LLM insights
    local, // ollama & friends: heuristics only, lean budgets
};

pub fn capabilityTier(model: []const u8, backend: anytype) CapabilityTier {
    if (backend == .ollama) return .local;
    var buf: [128]u8 = undefined;
    if (model.len > buf.len) return .full; // absurd name: default, no assert panic
    const name = std.ascii.lowerString(&buf, model);
    const flash_markers = [_][]const u8{ "flash", "mini", "haiku", "lite", "small", "turbo" };
    for (flash_markers) |m| {
        if (std.mem.indexOf(u8, name, m) != null) return .flash;
    }
    return .full;
}

fn isContextOverflowBody(body: []const u8) bool {
    const markers = [_][]const u8{
        "context length", "context window", "maximum context", "too long",
        "too many tokens", "token limit",    "input length",  "最大",
    };
    for (markers) |m| {
        if (containsIgnoreCase(body, m)) return true;
    }
    return false;
}

/// ASCII case-insensitive substring search (std has no such helper in 0.17).
/// Non-ASCII bytes compare verbatim, so UTF-8 needles work byte-wise.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

test "isContextOverflowBody recognizes gateway overflow wording" {
    try std.testing.expect(isContextOverflowBody("This model's maximum context length is 8192 tokens"));
    try std.testing.expect(isContextOverflowBody("{\"error\":{\"message\":\"prompt is too long: 200000 tokens > 128000 maximum\"}}"));
    try std.testing.expect(isContextOverflowBody("{\"error\":{\"message\":\"输入长度超出模型最大限制\"}}"));
    // A structural rejection must not be misread as overflow.
    try std.testing.expect(!isContextOverflowBody("{\"error\":{\"message\":\"Invalid parameter: messages with role 'tool'\"}}"));
}

pub const ProviderVTable = struct {
    complete_fn: *const fn (*anyopaque, []const Message, CompleteOptions) anyerror!CompleteResponse,
    stream_fn: *const fn (*anyopaque, []const Message, CompleteOptions, ?*anyopaque, *const StreamCallback) anyerror!void,
    count_tokens_fn: ?*const fn (*anyopaque, []const u8) anyerror!u32,
    supports_tool_use_fn: *const fn (*anyopaque) bool,
    supports_streaming_fn: *const fn (*anyopaque) bool,
    deinit_fn: *const fn (*anyopaque) void,
};

pub const StreamCallback = fn (?*anyopaque, StreamEvent) anyerror!void;

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const ProviderVTable,

    pub fn complete(self: Provider, messages: []const Message, opts: CompleteOptions) anyerror!CompleteResponse {
        return self.vtable.complete_fn(self.ptr, messages, opts);
    }

    pub fn stream(self: Provider, messages: []const Message, opts: CompleteOptions, ctx: ?*anyopaque, cb: *const StreamCallback) anyerror!void {
        return self.vtable.stream_fn(self.ptr, messages, opts, ctx, cb);
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
