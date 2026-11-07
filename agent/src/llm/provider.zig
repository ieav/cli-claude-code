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
    /// Interactive REPL streams only: cancellation plumbing owned by the
    /// UI loop (see repl.StreamJob). The provider publishes the
    /// connection's socket fd into `cancel_fd` once connected; the UI,
    /// on Esc/Ctrl-C, sets the flag AND shutdown(2)s the fd — the pump
    /// thread's BLOCKING read fails immediately, the stream unwinds, and
    /// the killed-connection error maps to error.EscCancelled. The pump
    /// never needs to poll anything; buffered body data is consumed with
    /// correct reader semantics (the idle-poll design starved when
    /// headers+body arrived in one TCP segment — the body sat in the
    /// connection buffer while the poll watched an empty kernel socket
    /// for 180s). Background callers (subagents, reflection) MUST leave
    /// these null — there is no UI to cancel them.
    cancel_flag: ?*std.atomic.Value(bool) = null,
    cancel_fd: ?*std.atomic.Value(i32) = null,
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
    /// 网关前缀缓存命中（OpenAI 兼容 `prompt_tokens_details.cached_tokens`；
    /// 0 = 未命中/网关不报）。M3.1 观测：/stats 显示命中率，前缀稳定性
    /// 调优的效果由此可判。
    cached_tokens: u32 = 0,
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
/// Payload of the terminal `.done` stream event. `usage` stays optional
/// (some gateways never send token counts). `stop_reason` is the wire's
/// own verdict: the streaming path used to drop finish_reason entirely,
/// so a `length`-capped truncation — a reasoning model burning the whole
/// output budget on thinking — was misreported as `end_turn` and the
/// REPL's advice ("resend") reproduced the failure identically.
pub const DoneInfo = struct {
    usage: ?Usage = null,
    stop_reason: ?CompleteResponse.StopReason = null,
};

pub const StreamEvent = union(enum) {
    content_delta: []const u8,
    thinking_delta: []const u8,
    tool_call: ToolUseBlock,
    done: DoneInfo,
    error_occurred: ProviderError,
    /// ~100ms passed with no socket data. The REPL renders the elapsed-
    /// time status row from it — a stalled gateway must be VISIBLE
    /// ("等待响应 12.4s…"), not a dead screen.
    tick,
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
/// Human-readable reason for the most recent provider failure (gateway
/// status + body excerpt). The error union carries only a TAG; this
/// side-channel carries the WHY so the TUI can show the gateway's own
/// message instead of leaning on a raw stderr log line.
var detail_buf: [512]u8 = undefined;
var detail_len: usize = 0;
/// Tiny spin lock (std.Thread.Mutex is gone in 0.17): critical sections
/// are a bufPrint and a slice copy — nanoseconds under lock.
var detail_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn detailLock() void {
    while (detail_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}

fn detailUnlock() void {
    detail_lock.store(false, .release);
}

pub fn setErrorDetail(comptime fmt: []const u8, args: anytype) void {
    detailLock();
    defer detailUnlock();
    const s = std.fmt.bufPrint(&detail_buf, fmt, args) catch detail_buf[0..0];
    detail_len = s.len;
}

pub fn lastErrorDetail() []const u8 {
    detailLock();
    defer detailUnlock();
    return detail_buf[0..detail_len];
}

/// Reset the side channel at request start. Without this, an error that
/// never passes through failRequest (connection refused, socket timeout,
/// TTFT kill, mid-stream transport failure) would leave the PREVIOUS
/// request's gateway reason in place — and the REPL would pin that stale
/// reason on this request's failure. Both Provider entry points call it,
/// so every backend and every caller is covered.
pub fn clearErrorDetail() void {
    detailLock();
    defer detailUnlock();
    detail_len = 0;
}

/// Write a detail only when none is set for this request. Mid-stream
/// transport failures use this: if an in-band error payload already
/// recorded the gateway's own message, that reason wins over a generic
/// "transport error: X".
pub fn setErrorDetailIfEmpty(comptime fmt: []const u8, args: anytype) void {
    detailLock();
    const empty = detail_len == 0;
    detailUnlock();
    if (empty) setErrorDetail(fmt, args);
}

/// Record the reason carried by an in-band error payload — HTTP 200, then
/// {"error":{"message":"…"}} in a data chunk (OpenAI/Ollama) or an SSE
/// "error" event (Claude). The mapped tag (ServerError) says nothing; the
/// gateway's own message is the diagnosable reason. Newlines are flattened
/// and capped like failRequest so the [网关返回: …] line stays one line.
pub fn noteInBandError(backend: []const u8, parsed: std.json.Value) void {
    const e = parsed.object.get("error") orelse return;
    var msg: []const u8 = "";
    if (e == .object) {
        if (e.object.get("message")) |m| {
            if (m == .string) msg = m.string;
        }
    } else if (e == .string) msg = e.string;
    var flat: [300]u8 = undefined;
    var n: usize = 0;
    for (msg) |c| {
        if (n >= flat.len) break;
        flat[n] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
        n += 1;
    }
    if (n == 0) {
        setErrorDetail("{s}: in-band error (no message field)", .{backend});
    } else {
        setErrorDetail("{s}: in-band error: {s}", .{ backend, flat[0..n] });
    }
}

test "error-detail side channel lifecycle" {
    clearErrorDetail();
    try std.testing.expectEqual(@as(usize, 0), lastErrorDetail().len);
    setErrorDetail("openai: status=429 rate limited", .{});
    // IfEmpty must NOT clobber an existing reason.
    setErrorDetailIfEmpty("openai stream: transport error: X", .{});
    try std.testing.expectEqualStrings("openai: status=429 rate limited", lastErrorDetail());
    // Clear + IfEmpty writes the fallback when nothing better exists.
    clearErrorDetail();
    setErrorDetailIfEmpty("openai stream: transport error: {s}", .{"ConnectionResetByPeer"});
    try std.testing.expectEqualStrings("openai stream: transport error: ConnectionResetByPeer", lastErrorDetail());
    clearErrorDetail();
}

test "noteInBandError extracts the gateway's message" {
    clearErrorDetail();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed_op = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"error":{"message":"model `foo` not found"}}
    , .{});
    noteInBandError("ollama", parsed_op);
    try std.testing.expectEqualStrings("ollama: in-band error: model `foo` not found", lastErrorDetail());
    // Claude shape: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    const parsed_cl = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    , .{});
    noteInBandError("claude", parsed_cl);
    try std.testing.expectEqualStrings("claude: in-band error: Overloaded", lastErrorDetail());
    // No message field → placeholder, not silence.
    const parsed_bare = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"error":true}
    , .{});
    noteInBandError("openai", parsed_bare);
    try std.testing.expectEqualStrings("openai: in-band error (no message field)", lastErrorDetail());
    // Multi-line message collapses to one line.
    const parsed_ml = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"error":{"message":"line1\nline2"}}
    , .{});
    noteInBandError("openai", parsed_ml);
    try std.testing.expectEqualStrings("openai: in-band error: line1 line2", lastErrorDetail());
    clearErrorDetail();
}

pub fn failRequest(alloc: std.mem.Allocator, tag: []const u8, response: anytype) ProviderError {
    const status: u16 = @backingInt(response.head.status);
    const body = readErrorBody(alloc, response);
    defer if (body.len > 0) alloc.free(@constCast(body));

    if (body.len == 0) {
        logger.err("{s} error: status={d} (no error body)", .{ tag, status });
        setErrorDetail("{s}: status={d} (no error body)", .{ tag, status });
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
        setErrorDetail("{s}: status={d} {s}", .{ tag, status, flat[0..n] });
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
        "context length",  "context window", "maximum context", "too long",
        "too many tokens", "token limit",    "input length",
        "最大",
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
        // Fresh error-detail per request: an error that sets no detail of
        // its own must surface "no reason" — never the previous request's.
        clearErrorDetail();
        return self.vtable.complete_fn(self.ptr, messages, opts);
    }

    pub fn stream(self: Provider, messages: []const Message, opts: CompleteOptions, ctx: ?*anyopaque, cb: *const StreamCallback) anyerror!void {
        clearErrorDetail();
        return self.vtable.stream_fn(self.ptr, messages, opts, ctx, cb);
    }

    pub fn countTokens(self: Provider, text: []const u8) anyerror!u32 {
        if (self.vtable.count_tokens_fn) |fn_ptr| {
            return fn_ptr(self.ptr, text);
        }
        // Char-class-aware estimate (CJK-aware) — see util/tokens.zig.
        return @import("../util/tokens.zig").estimateTokens(text);
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
