/// Enhanced REPL for Ziv — reads user input, dispatches commands and queries.
/// Supports multi-model switching, tool execution, permission modes, operation history,
/// conversation management (compact/clear/context/undo/rewind), and interactive config.
/// Adapted for Zig 0.16 I/O API.
const std = @import("std");
const tools_mod = @import("tools/mod.zig");
const auth = @import("tools/auth_mode.zig");
const registry = @import("tools/registry.zig");
const op_log = @import("checkpoint/op_log.zig");
const file_history = @import("checkpoint/file_history.zig");
const rollback_mod = @import("checkpoint/rollback.zig");
const llm = @import("llm/mod.zig");
const compaction = @import("llm/compaction.zig");
const config_mod = @import("config.zig");
const util_time = @import("util/time.zig");
const system_prompt_mod = @import("system_prompt.zig");
const logger = @import("util/log.zig");
const memory_mod = @import("memory/mod.zig");
const injection_mod = @import("memory/injection.zig");
const extraction_mod = @import("memory/extraction.zig");
const reflection_mod = @import("memory/reflection.zig");
const database_mod = @import("storage/database.zig");
const math_mod = @import("math/mod.zig");
const knowledge_search = @import("knowledge/search.zig");
const researcher_mod = @import("research/optimization_researcher.zig");
const env = @import("util/env.zig");
const self_diagnostic = @import("runtime/self_diagnostic.zig");
const decision_trace = @import("runtime/decision_trace.zig");
const allocator = std.heap.smp_allocator;

const MAX_AGENT_ITERATIONS: usize = 50;
const MAX_CONTEXT_TOKENS: u32 = 128_000;

/// Active model state — holds the current model name and the provider instance.
const ModelSwitcher = struct {
    model_name_buf: [64]u8 = undefined,
    model_name_len: usize = 0,
    backend: llm.BackendType,
    io: std.Io,
    openai_provider: ?llm.OpenAIProvider = null,
    claude_provider: ?llm.ClaudeProvider = null,
    ollama_provider: ?llm.OllamaProvider = null,
    settings: config_mod.Settings,

    const Self = @This();

    pub fn modelName(self: *const Self) []const u8 {
        return self.model_name_buf[0..self.model_name_len];
    }

    pub fn init(settings: config_mod.Settings, io: std.Io) Self {
        const model = settings.default_model;
        const len = @min(model.len, 64);
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..len], model[0..len]);
        return .{
            .model_name_buf = buf,
            .model_name_len = len,
            .backend = llm.detectBackend(model),
            .io = io,
            .settings = settings,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.openai_provider) |*p| p.deinit();
        if (self.claude_provider) |*p| p.deinit();
        if (self.ollama_provider) |*p| p.deinit();
    }

    /// Switch to a new model. Returns error if API key is missing.
    pub fn switchModel(self: *Self, new_model: []const u8) !void {
        const new_backend = llm.detectBackend(new_model);

        // Validate API key availability before switching
        switch (new_backend) {
            .openai => {
                if (self.settings.api_keys.openai == null) {
                    return error.MissingApiKey;
                }
            },
            .claude => {
                if (self.settings.api_keys.anthropic == null) {
                    return error.MissingApiKey;
                }
            },
            .ollama => {},
        }

        // Deinit old provider of the same backend type
        switch (new_backend) {
            .openai => {
                if (self.openai_provider) |*p| {
                    p.deinit();
                    self.openai_provider = null;
                }
            },
            .claude => {
                if (self.claude_provider) |*p| {
                    p.deinit();
                    self.claude_provider = null;
                }
            },
            .ollama => {
                if (self.ollama_provider) |*p| {
                    p.deinit();
                    self.ollama_provider = null;
                }
            },
        }

        const len = @min(new_model.len, 64);
        @memcpy(self.model_name_buf[0..len], new_model[0..len]);
        self.model_name_len = len;
        self.backend = new_backend;

        logger.info("Model switched: {s} (backend={s})", .{ new_model, @tagName(new_backend) });
    }

    /// Get or create the provider for the current model.
    pub fn getProvider(self: *Self) !llm.Provider {
        switch (self.backend) {
            .openai => {
                if (self.openai_provider == null) {
                    const api_key = self.settings.api_keys.openai orelse return error.MissingApiKey;
                    self.openai_provider = llm.OpenAIProvider.init(allocator, self.io, .{
                        .api_key = api_key,
                        .model = self.modelName(),
                        .base_url = self.settings.api_keys.openai_base_url orelse "https://api.openai.com/v1",
                    });
                }
                return self.openai_provider.?.toProvider();
            },
            .claude => {
                if (self.claude_provider == null) {
                    const api_key = self.settings.api_keys.anthropic orelse return error.MissingApiKey;
                    self.claude_provider = llm.ClaudeProvider.init(allocator, self.io, .{
                        .api_key = api_key,
                        .model = self.modelName(),
                        .base_url = self.settings.api_keys.anthropic_base_url orelse "https://api.anthropic.com",
                    });
                }
                return self.claude_provider.?.toProvider();
            },
            .ollama => {
                if (self.ollama_provider == null) {
                    self.ollama_provider = llm.OllamaProvider.init(allocator, self.io, .{
                        .model = self.modelName(),
                        .base_url = self.settings.api_keys.ollama_host,
                    });
                }
                return self.ollama_provider.?.toProvider();
            },
        }
    }

    pub fn backendLabel(self: *const Self) []const u8 {
        return switch (self.backend) {
            .openai => "OpenAI",
            .claude => "Claude",
            .ollama => "Ollama",
        };
    }
};

pub fn run(io: std.Io, stdin_file: std.Io.File, stdout_file: std.Io.File) !void {
    // Writer setup
    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(stdout_file, io, &write_buf);
    const w = &file_writer.interface;

    // Reader setup
    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(stdin_file, io, &read_buf);
    const r = &file_reader.interface;

    // Load settings
    var settings = config_mod.loadSettings(allocator, io) catch config_mod.Settings{};

    // Initialize model switcher
    var switcher = ModelSwitcher.init(settings, io);
    defer switcher.deinit();

    // Session state
    var current_mode: auth.PermissionMode = .default;
    var log = op_log.OperationLog.init(allocator);
    defer log.deinit();
    var fhist = file_history.FileHistoryState.init(allocator, try allocator.dupe(u8, ".ziv/checkpoints"));
    defer fhist.deinit();
    var rollback_engine = rollback_mod.RollbackEngine.init(allocator, &fhist, &log);
    var message_count: usize = 0;

    // ──── Conversation history ────
    var history = std.ArrayList(llm.Message).empty;
    defer history.deinit(allocator);

    // ──── Persistent memory (episodic tier, cross-session) ────
    var injected_count: usize = 0;
    std.Io.Dir.cwd().createDirPath(io, ".ziv") catch {};
    var mem_db: ?database_mod.Database = blk: {
        var db = database_mod.Database.init(allocator, ".ziv/memory.db") catch break :blk null;
        db.runMigrations() catch {
            logger.warning("memory: migrations failed, memory disabled", .{});
            db.deinit();
            break :blk null;
        };
        break :blk db;
    };
    defer if (mem_db) |*db| db.deinit();
    var mem_sys: ?memory_mod.MemorySystem = if (mem_db != null)
        memory_mod.MemorySystem.init(allocator, &mem_db.?)
    else
        null;
    defer if (mem_sys) |*ms| ms.deinit();

    // Add system prompt as first message, appending cross-session memories
    // recovered from .ziv/memory.db (most recent first, token-budgeted).
    const sys_prompt = switcher.settings.system_prompt orelse system_prompt_mod.default_system_prompt;
    var memory_block: ?[]u8 = null;
    defer if (memory_block) |mb| allocator.free(mb);
    if (mem_sys) |*ms| {
        if (ms.episodic_mem.retrieveRecent(20) catch null) |entries| {
            defer ms.episodic_mem.freeEntries(entries);
            memory_block = injection_mod.buildMemoryBlock(allocator, entries, 800) catch null;
            if (memory_block != null) {
                injected_count = entries.len;
                logger.info("memory: injected {d} entries into system prompt", .{entries.len});
            }
        }
    }
    const sys_block_count: usize = if (memory_block != null) 2 else 1;
    var sys_blocks = try allocator.alloc(llm.ContentBlock, sys_block_count);
    sys_blocks[0] = .{ .text = sys_prompt };
    if (memory_block) |mb| sys_blocks[1] = .{ .text = mb };
    try history.append(allocator, .{
        .role = .system,
        .content = sys_blocks,
        .timestamp = util_time.nowMillis(),
    });

    // Session token tracking
    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;

    // ──── Reflection window (M4: periodic self-review) ────
    var reflector = reflection_mod.ReflectionEngine.init(allocator);
    defer reflector.deinit();
    var window_queries: std.ArrayList([]u8) = .empty;
    defer {
        for (window_queries.items) |q| allocator.free(q);
        window_queries.deinit(allocator);
    }
    var window_tools: u32 = 0;
    var window_errors: u32 = 0;

    try std.Io.Writer.writeAll(w,
        \\Type your message (or /help for commands):
        \\
    );
    try std.Io.File.Writer.flush(&file_writer);

    while (true) {
        // Prompt with mode indicator + model + context usage
        const mode_str = switch (current_mode) {
            .default => "ziv",
            .accept_edits => "ziv[edit]",
            .plan => "ziv[plan]",
            .bypass => "ziv[bypass]",
            .dont_ask => "ziv[dontask]",
            .auto => "ziv[auto]",
        };
        const est_ctx = estimateHistoryTokens(history.items);
        const ctx_pct = @as(u32, @intFromFloat(@as(f64, @floatFromInt(est_ctx)) / @as(f64, @floatFromInt(MAX_CONTEXT_TOKENS)) * 100.0));
        try std.Io.Writer.print(w, "{s} ({s}) [{d}%] > ", .{ mode_str, switcher.modelName(), ctx_pct });
        try std.Io.File.Writer.flush(&file_writer);

        // Read line
        var line_buf: [4096]u8 = undefined;
        var line_writer = std.Io.Writer.fixed(&line_buf);
        const lw = &line_writer;

        const n = std.Io.Reader.streamDelimiter(r, lw, '\n') catch |err| {
            if (err == error.EndOfStream or err == error.ReadFailed) {
                try std.Io.Writer.writeAll(w, "\nGoodbye!\n");
                try std.Io.File.Writer.flush(&file_writer);
                return;
            }
            std.debug.print("Error reading input: {}\n", .{err});
            return;
        };
        r.toss(1); // consume the delimiter byte

        if (n == 0) continue;

        const input = std.mem.trim(u8, line_buf[0..n], " \t\r\n");
        if (input.len == 0) continue;

        // ──── Meta commands ────
        if (std.mem.startsWith(u8, input, "/")) {
            if (std.mem.eql(u8, input, "/quit") or std.mem.eql(u8, input, "/q") or std.mem.eql(u8, input, "/exit")) {
                // M4: session-end reflection on whatever the window still holds.
                if (mem_sys != null and window_queries.items.len > 0) {
                    runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w);
                }
                if (mem_sys) |*ms| extractSessionMemories(ms, &history, w) catch {};
                try std.Io.Writer.writeAll(w, "Goodbye!\n");
                try std.Io.File.Writer.flush(&file_writer);
                break;
            } else if (std.mem.eql(u8, input, "/help") or std.mem.eql(u8, input, "/h")) {
                try printHelp(w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/tools")) {
                try std.Io.Writer.writeAll(w, "Registered tools:\n");
                inline for (tools_mod.default_tools) |tool| {
                    const safety = if (tool.is_concurrency_safe_fn != null) "safe" else "serial";
                    try std.Io.Writer.print(w, "  {s} - {s} [{s}|{s}]\n", .{
                        tool.name,
                        tool.description,
                        if (tool.is_read_only) "read" else "write",
                        safety,
                    });
                }
                try std.Io.Writer.print(w, "\n  Total: {d} tools\n\n", .{tools_mod.default_tools.len});
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.startsWith(u8, input, "/run ")) {
                const rest = input[5..];
                const space_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse {
                    try std.Io.Writer.writeAll(w, "Usage: /run <ToolName> <json-input>\n\n");
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };
                const tool_name = rest[0..space_idx];
                const json_str = rest[space_idx + 1 ..];

                const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, json_str, .{}) catch {
                    try std.Io.Writer.writeAll(w, "Invalid JSON input\n\n");
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };

                try std.Io.Writer.print(w, "  Running {s}...\n", .{tool_name});
                try std.Io.File.Writer.flush(&file_writer);
                logger.info("Tool /run: {s}", .{tool_name});

                // Backup file before modification (for /run commands)
                var run_snap_id: ?[16]u8 = null;
                if (isFileModifyingTool(tool_name)) {
                    if (registry.getStringField(parsed, "path")) |fp| {
                        var sid: [16]u8 = undefined;
                        const ts = util_time.nowMillis();
                        for (&sid, 0..) |*byte, i| {
                            byte.* = @truncate(@as(u64, @bitCast(ts)) +% @as(u64, i) *% 0x9e3779b97f4a7c15);
                        }
                        fhist.trackEdit(fp, sid, io) catch {};
                        run_snap_id = sid;
                    }
                }

                const result = tools_mod.DefaultRegistry.execute(tool_name, allocator, parsed, io) catch |err| {
                    logger.err("Tool /run failed: {s} error={}", .{ tool_name, err });
                    try std.Io.Writer.print(w, "  Tool error: {}\n\n", .{err});
                    _ = log.record(tool_name, "execution", "error", run_snap_id, false) catch {};
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };

                if (result.is_error) {
                    try std.Io.Writer.print(w, "  ERROR: {s}\n\n", .{result.output});
                } else {
                    try std.Io.Writer.print(w, "  {s}\n\n", .{result.output});
                }
                _ = log.record(tool_name, "executed", result.output, run_snap_id, run_snap_id != null) catch {};
                if (!result.is_error) allocator.free(result.output);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/mode")) {
                // Cycle permission mode
                current_mode = auth.nextMode(current_mode);
                try std.Io.Writer.print(w, "  Permission mode: {s}\n\n", .{auth.modeLabel(current_mode)});
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/model") or std.mem.eql(u8, input, "/models")) {
                // Show current model + available models
                try printModelInfo(w, &switcher);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.startsWith(u8, input, "/model ")) {
                // Switch model: /model <name>
                const new_model = input[7..];
                switcher.switchModel(new_model) catch |err| {
                    if (err == error.MissingApiKey) {
                        const detected = llm.detectBackend(new_model);
                        try std.Io.Writer.print(w, "  Error: API key not configured for {s} backend.\n", .{detected.label()});
                        try std.Io.Writer.writeAll(w, "  Use /config to set API keys, or add to ~/.config/ziv/settings.json.\n\n");
                    } else {
                        try std.Io.Writer.print(w, "  Error switching model: {}\n\n", .{err});
                    }
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };
                try std.Io.Writer.print(w, "  Switched to {s} ({s})\n\n", .{ switcher.modelName(), switcher.backendLabel() });
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/config")) {
                try runConfigMenu(w, r, &file_writer, &switcher, allocator, io);
                // Re-sync settings reference after config may have changed
                settings = switcher.settings;
                continue;
            } else if (std.mem.eql(u8, input, "/compact")) {
                try compactHistory(&history, w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/clear") or std.mem.eql(u8, input, "/reset") or std.mem.eql(u8, input, "/new")) {
                if (mem_sys) |*ms| extractSessionMemories(ms, &history, w) catch {};
                clearHistory(&history, sys_prompt);
                message_count = 0;
                total_input_tokens = 0;
                total_output_tokens = 0;
                _ = log.record("ClearHistory", "/", "/", null, false) catch {};
                try std.Io.Writer.writeAll(w, "  Conversation cleared. Starting fresh.\n\n");
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/context")) {
                try showContext(&history, total_input_tokens, total_output_tokens, w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/memory")) {
                try printMemoryStatus(if (mem_sys) |*ms| ms else null, injected_count, w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.startsWith(u8, input, "/research ")) {
                const topic = std.mem.trim(u8, input["/research ".len..], " \t");
                if (topic.len == 0) {
                    try std.Io.Writer.writeAll(w, "  Usage: /research <topic>\n\n");
                } else {
                    try runResearch(topic, allocator, io, w);
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.startsWith(u8, input, "/diagnose")) {
                const rest = if (input.len > "/diagnose".len) input["/diagnose".len..] else "";
                const concern = std.mem.trim(u8, rest, " \t");
                if (concern.len == 0) {
                    try std.Io.Writer.writeAll(w, "  Usage: /diagnose <your concern about the last answer>\n\n");
                } else {
                    try runDiagnose(concern, injected_count, window_tools, window_errors, allocator, w);
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/undo")) {
                try undoLastExchange(&history, w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/history")) {
                if (log.records.items.len == 0) {
                    try std.Io.Writer.writeAll(w, "  No operations recorded yet.\n\n");
                } else {
                    try std.Io.Writer.print(w, "  Operation history ({d} operations):\n", .{log.records.items.len});
                    for (log.records.items, 0..) |rec, i| {
                        try std.Io.Writer.print(w, "    [{d}] {s}\n", .{ i + 1, rec.tool_name });
                    }
                    try std.Io.Writer.writeAll(w, "\n");
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/rewind")) {
                try rewindOperation(&rollback_engine, w, r, &file_writer, allocator, io);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/stats")) {
                const est_tokens = estimateHistoryTokens(history.items);
                try std.Io.Writer.print(w, "  Messages: {d} | History tokens: ~{d} | Operations: {d}\n", .{
                    message_count,
                    est_tokens,
                    log.records.items.len,
                });
                try std.Io.Writer.print(w, "  Mode: {s} | Model: {s} ({s})\n", .{
                    auth.modeLabel(current_mode),
                    switcher.modelName(),
                    switcher.backendLabel(),
                });
                try std.Io.Writer.print(w, "  Total: {d} in / {d} out tokens\n\n", .{
                    total_input_tokens,
                    total_output_tokens,
                });
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/version")) {
                try std.Io.Writer.writeAll(w, "  Ziv v0.3.0 (Zig " ++ @import("builtin").zig_version_string ++ ")\n\n");
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else {
                try std.Io.Writer.print(w, "Unknown command: {s}\nType /help for available commands.\n\n", .{input});
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            }
        }

        // ──── Process message — Agent Loop ────
        message_count += 1;

        _ = log.record("UserMessage", input, "(awaiting LLM response)", null, false) catch {};

        try std.Io.Writer.print(w, "\n  [Processing: \"{s}\"]\n", .{input});
        try std.Io.File.Writer.flush(&file_writer);

        // Track query for the reflection window (cap at 20; drop oldest)
        {
            const q = try allocator.dupe(u8, input);
            errdefer allocator.free(q);
            try window_queries.append(allocator, q);
            if (window_queries.items.len > 20) {
                const old = window_queries.orderedRemove(0);
                allocator.free(old);
            }
        }

        // Append user message to history
        var user_blocks = try allocator.alloc(llm.ContentBlock, 1);
        user_blocks[0] = .{ .text = try allocator.dupe(u8, input) };
        try history.append(allocator, .{
            .role = .user,
            .content = user_blocks,
            .timestamp = util_time.nowMillis(),
        });

        // Agent loop
        var agent_iterations: usize = 0;
        var result_blocks = std.ArrayList(llm.ContentBlock).empty;
        defer result_blocks.deinit(allocator);

        while (agent_iterations < MAX_AGENT_ITERATIONS) : (agent_iterations += 1) {
            // Compaction check
            maybeCompact(&history, w, &file_writer);

            // Get provider
            const prov = switcher.getProvider() catch |err| {
                if (err == error.MissingApiKey) {
                    try std.Io.Writer.print(w, "  [No API key for {s} — use /config to set it]\n\n", .{switcher.backendLabel()});
                } else {
                    try std.Io.Writer.print(w, "  [Provider error: {}]\n\n", .{err});
                }
                try std.Io.File.Writer.flush(&file_writer);
                break;
            };

            // Call LLM with full history
            logger.info("LLM call: model={s} history_len={d} max_tokens={d}", .{
                switcher.modelName(), history.items.len, switcher.settings.max_tokens,
            });
            const response = prov.complete(history.items, .{
                .max_tokens = switcher.settings.max_tokens,
                .temperature = 0.7,
            }) catch |err| {
                logger.err("LLM call failed: {}", .{err});
                try std.Io.Writer.print(w, "  [LLM error: {}]\n\n", .{err});
                try std.Io.File.Writer.flush(&file_writer);
                break;
            };

            logger.info("LLM response: stop={s} tokens_in={d} tokens_out={d} blocks={d}", .{
                @tagName(response.stop_reason),
                response.usage.input_tokens,
                response.usage.output_tokens,
                response.content.len,
            });

            // Track token usage
            total_input_tokens += response.usage.input_tokens;
            total_output_tokens += response.usage.output_tokens;

            // Print response content
            for (response.content) |block| {
                switch (block) {
                    .text => |t| {
                        try std.Io.Writer.writeAll(w, "  ");
                        try std.Io.Writer.writeAll(w, t);
                        try std.Io.Writer.writeAll(w, "\n");
                    },
                    .thinking => |t| {
                        try std.Io.Writer.print(w, "  [thinking: {s}]\n", .{t});
                    },
                    .tool_use => |tc| {
                        try std.Io.Writer.print(w, "  [calling tool: {s}]\n", .{tc.name});
                    },
                    .tool_result => |tr| {
                        const label = if (tr.is_error) "error" else "result";
                        try std.Io.Writer.print(w, "  [tool {s}: {s}]\n", .{ label, tr.content });
                    },
                }
            }
            try std.Io.Writer.print(w, "  [tokens: in={d} out={d} | stop: {s}]\n", .{
                response.usage.input_tokens,
                response.usage.output_tokens,
                @tagName(response.stop_reason),
            });
            try std.Io.File.Writer.flush(&file_writer);

            // Append assistant response to history. Deep-copy the blocks
            // first: their strings (and tool_use JSON trees) live in the
            // response's DOM arena, which is freed right after — history
            // must own its memory. This closes the per-response DOM leak.
            const stop_reason = response.stop_reason;
            const owned_blocks = try cloneContentBlocks(allocator, response.content);
            errdefer freeContentBlocks(allocator, owned_blocks);
            try history.append(allocator, .{
                .role = .assistant,
                .content = owned_blocks,
                .timestamp = util_time.nowMillis(),
            });
            response.free(allocator);

            // Record in operation log
            _ = log.record("LLMResponse", input, "response", null, false) catch {};

            // Check if tool calling is needed
            if (stop_reason != .tool_use) break;

            // Execute tool calls — reuse result_blocks, clear from previous iteration
            result_blocks.clearRetainingCapacity();

            var has_tool_use = false;
            // Iterate the owned copy in history — the response was freed above.
            const last_assistant = history.items[history.items.len - 1].content;
            for (last_assistant) |block| {
                if (block == .tool_use) {
                    has_tool_use = true;
                    const tc = block.tool_use;

                    // Find tool definition
                    const tool_def = tools_mod.DefaultRegistry.findByName(tc.name);
                    if (tool_def == null) {
                        try std.Io.Writer.print(w, "  [Unknown tool: {s}]\n", .{tc.name});
                        try result_blocks.append(allocator, .{ .tool_result = .{
                            .tool_use_id = tc.id,
                            .content = "Tool not found",
                            .is_error = true,
                        } });
                        continue;
                    }

                    // Permission check
                    const perm_ctx = registry.PermissionContext{
                        .mode = current_mode,
                        .allow_rules = switcher.settings.allow_rules,
                        .deny_rules = switcher.settings.deny_rules,
                        .provider = switcher.getProvider() catch null,
                        .allocator = allocator,
                    };
                    const decision = auth.checkToolPermission(tool_def.?, tc.input, &perm_ctx);

                    switch (decision) {
                        .deny => |d| {
                            try std.Io.Writer.print(w, "  [Permission denied: {s}]\n", .{d.message});
                            try result_blocks.append(allocator, .{ .tool_result = .{
                                .tool_use_id = tc.id,
                                .content = d.message,
                                .is_error = true,
                            } });
                        },
                        .ask => |a| {
                            try std.Io.Writer.print(w, "  Tool {s}: {s}. Allow? [y/N]: ", .{ tc.name, a.message });
                            try std.Io.File.Writer.flush(&file_writer);

                            // Read approval
                            var ans_buf: [64]u8 = undefined;
                            var ans_writer = std.Io.Writer.fixed(&ans_buf);
                            _ = std.Io.Reader.streamDelimiter(r, &ans_writer, '\n') catch {
                                try result_blocks.append(allocator, .{ .tool_result = .{
                                    .tool_use_id = tc.id,
                                    .content = "Failed to read approval",
                                    .is_error = true,
                                } });
                                continue;
                            };
                            r.toss(1);
                            const ans = std.mem.trim(u8, ans_buf[0..@min(ans_writer.end, ans_buf.len)], " \t\r\n");
                            if (!std.mem.eql(u8, ans, "y") and !std.mem.eql(u8, ans, "Y")) {
                                try std.Io.Writer.writeAll(w, "  [Denied by user]\n");
                                try result_blocks.append(allocator, .{ .tool_result = .{
                                    .tool_use_id = tc.id,
                                    .content = "denied by user",
                                    .is_error = true,
                                } });
                                try std.Io.File.Writer.flush(&file_writer);
                                continue;
                            }
                            // Approved — fall through to execute
                            const tool_errored = try executeAndRecord(tc, allocator, io, &log, &fhist, &result_blocks, w, &file_writer);
                            window_tools += 1;
                            if (tool_errored) window_errors += 1;
                        },
                        .allow => {
                            const tool_errored = try executeAndRecord(tc, allocator, io, &log, &fhist, &result_blocks, w, &file_writer);
                            window_tools += 1;
                            if (tool_errored) window_errors += 1;
                        },
                    }
                }
            }

            if (!has_tool_use) break; // Safety: no tool_use blocks despite stop_reason

            // Append tool results as user message to history
            const result_slice = try result_blocks.toOwnedSlice(allocator);
            if (result_slice.len > 0) {
                try history.append(allocator, .{
                    .role = .user,
                    .content = result_slice,
                    .timestamp = util_time.nowMillis(),
                });
            }

            try std.Io.File.Writer.flush(&file_writer);
        }

        if (agent_iterations >= MAX_AGENT_ITERATIONS) {
            try std.Io.Writer.print(w, "  [Agent loop limit ({d}) reached]\n", .{MAX_AGENT_ITERATIONS});
        }

        // M4: periodic reflection on the query window (every N exchanges
        // or after a π-spaced interval; see ReflectionEngine.shouldReflect).
        if (mem_sys != null and reflector.shouldReflect()) {
            runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w);
        }

        try std.Io.Writer.writeAll(w, "\n");
        try std.Io.File.Writer.flush(&file_writer);
    }
}

/// Check if a tool is likely to modify files (and should be backed up).
/// Extract memorable facts from this session and persist them to the
/// episodic tier, so the next session can inject them (T3.1).
/// φ condensation keeps only the top 61.8% of candidates by importance.
fn extractSessionMemories(mem: *memory_mod.MemorySystem, history: *std.ArrayList(llm.Message), w: *std.Io.Writer) !void {
    var engine = extraction_mod.ExtractionEngine.init(mem.allocator);
    defer engine.deinit();

    // Collect candidates across the whole session first.
    var candidates: std.ArrayList(extraction_mod.ExtractedFact) = .empty;
    defer {
        for (candidates.items) |f| mem.allocator.free(f.content);
        candidates.deinit(mem.allocator);
    }
    for (history.items) |msg| {
        if (msg.role != .user and msg.role != .assistant) continue;
        for (msg.content) |block| {
            if (block != .text) continue;
            const facts = engine.extractFromMessage(@tagName(msg.role), block.text) catch continue;
            defer mem.allocator.free(facts);
            for (facts) |f| {
                if (f.content.len < 8) {
                    mem.allocator.free(f.content);
                    continue; // skip echoes and short noise
                }
                try candidates.append(mem.allocator, f);
            }
        }
    }

    // φ: keep the top condensationTarget(n) by importance.
    const target = math_mod.condensationTarget(candidates.items.len);
    const ByImportance = struct {
        fn lessThan(_: void, a: extraction_mod.ExtractedFact, b: extraction_mod.ExtractedFact) bool {
            return a.importance > b.importance;
        }
    };
    std.sort.pdq(extraction_mod.ExtractedFact, candidates.items, {}, ByImportance.lessThan);

    var stored: usize = 0;
    for (candidates.items[0..target]) |f| {
        const now = util_time.nowMillis();
        mem.store(.{
            .id = injection_mod.memoryId(f.content),
            .mem_type = switch (f.fact_type) {
                .user_preference => .user,
                .project_context, .technical_fact, .error_solution, .pattern_observed => .project,
            },
            .name = f.content[0..@min(48, f.content.len)],
            .description = @tagName(f.fact_type),
            .content = f.content,
            .access_count = 0,
            .created_at = now,
            .updated_at = now,
        }) catch continue;
        stored += 1;
    }
    if (stored > 0) {
        try w.print("  Saved {d} memories for future sessions.\n", .{stored});
    }
}

/// M4: run a reflection pass over the query window and persist the insight
/// as a feedback memory. Resets the window.
fn runReflection(
    reflector: *reflection_mod.ReflectionEngine,
    mem: *memory_mod.MemorySystem,
    window_queries: *std.ArrayList([]u8),
    window_tools: *u32,
    window_errors: *u32,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
) void {
    const reflection = reflector.reflect(window_queries.items, window_tools.*, window_errors.*, .on_query_complete) catch return orelse return;

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "reflection q={d} tools={d}", .{ window_queries.items.len, window_tools.* }) catch "reflection";
    const now = util_time.nowMillis();
    mem.store(.{
        .id = injection_mod.memoryId(reflection.insights),
        .mem_type = .feedback,
        .name = name,
        .description = @tagName(reflection.trigger),
        .content = reflection.insights,
        .access_count = 0,
        .created_at = now,
        .updated_at = now,
    }) catch {};
    logger.info("reflection: quality={d:.2} insights stored", .{reflection.quality_score});
    w.print("  [Reflection] {s}\n", .{reflection.insights}) catch {};

    // Reset the window.
    for (window_queries.items) |q| alloc.free(q);
    window_queries.clearRetainingCapacity();
    window_tools.* = 0;
    window_errors.* = 0;
}

/// M4: /memory — show what was injected this session and what is stored.
fn printMemoryStatus(mem_sys: ?*memory_mod.MemorySystem, injected_count: usize, w: *std.Io.Writer) !void {
    if (mem_sys == null) {
        try std.Io.Writer.writeAll(w, "  Memory disabled (database unavailable).\n\n");
        return;
    }
    const ms: *memory_mod.MemorySystem = mem_sys.?;
    try std.Io.Writer.print(w, "  Memory: injected {d} entries into this session's system prompt\n", .{injected_count});

    const entries = ms.episodic_mem.retrieveRecent(5) catch {
        try std.Io.Writer.writeAll(w, "  (failed to read memory store)\n\n");
        return;
    };
    defer ms.episodic_mem.freeEntries(entries);
    if (entries.len == 0) {
        try std.Io.Writer.writeAll(w, "  Store is empty — memories are extracted when you /quit or /clear.\n\n");
        return;
    }
    try std.Io.Writer.print(w, "  Most recent {d} stored:\n", .{entries.len});
    for (entries) |e| {
        const name = e.name[0..@min(e.name.len, 60)];
        try w.print("    [{s}] {s}\n", .{ @tagName(e.mem_type), name });
    }
    try std.Io.Writer.writeAll(w, "\n");
}

/// M8: /research — run the φ-curated optimization researcher over the web
/// (same backend selection as the WebSearch tool) and print its report.
fn runResearch(topic: []const u8, alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer) !void {
    try std.Io.Writer.writeAll(w, "  Researching (φ-optimized queries, ~30s budget)…\n");

    const brave_key = env.get("BRAVE_API_KEY");
    const backend: knowledge_search.SearchBackend = if (brave_key != null) .brave else .duckduckgo;
    var ws = knowledge_search.WebSearch.init(alloc, io, backend, if (brave_key) |k| try alloc.dupe(u8, k) else null);
    defer ws.deinit();

    var researcher = researcher_mod.OptimizationResearcher.init(alloc, &ws);
    var result = researcher.research(topic, .solve_problem) catch |err| {
        try std.Io.Writer.print(w, "  Research failed: {s}\n\n", .{@errorName(err)});
        return;
    };
    defer researcher.deinit(&result);

    try std.Io.Writer.print(w, "  Sources: {d} | candidates: {d} | {d}ms\n", .{ result.sources_searched, result.candidates_found, result.search_duration_ms });
    for (result.top_solutions, 0..) |sol, i| {
        const marker: []const u8 = if (i == result.recommendation_index) " ★ recommended" else "";
        try std.Io.Writer.print(w, "\n  [{d}] {s}{s}\n      {s}\n      source: {s}\n", .{ i + 1, sol.name, marker, sol.description, sol.source });
    }
    if (result.reasoning.len > 0) {
        try std.Io.Writer.print(w, "\n  {s}\n", .{result.reasoning});
    }
    try std.Io.Writer.writeAll(w, "\n");
}

/// M8: /diagnose — build a lightweight decision trace from real session
/// stats and run the self-diagnostic engine against the user's concern.
fn runDiagnose(
    concern: []const u8,
    injected_count: usize,
    window_tools: u32,
    window_errors: u32,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
) !void {
    // DecisionTrace takes ownership of query (freed in deinit) — dupe it.
    var trace = decision_trace.DecisionTrace.init(alloc, try alloc.dupe(u8, concern));
    defer trace.deinit();

    // Step 1: memory retrieval — confidence drops when nothing was injected.
    const mem_conf: f64 = if (injected_count > 0) 0.8 else 0.3;
    try trace.addStep(.{
        .step_id = 1,
        .phase = .memory_retrieval,
        .timestamp = util_time.nowMillis(),
        .input = try alloc.dupe(u8, concern),
        .output = try alloc.print("injected={d}", .{injected_count}),
        .reasoning = try alloc.dupe(u8, "recency-ranked e-decay injection"),
        .confidence = mem_conf,
        .duration_ms = 0,
        .alternatives = &.{},
        .dependencies = &.{},
    });
    // Step 2: tool execution — confidence tracks the error rate.
    const tool_conf: f64 = if (window_tools == 0)
        0.9
    else
        1.0 - @as(f64, @floatFromInt(window_errors)) / @as(f64, @floatFromInt(window_tools));
    try trace.addStep(.{
        .step_id = 2,
        .phase = .tool_execution,
        .timestamp = util_time.nowMillis(),
        .input = try alloc.dupe(u8, "session tool window"),
        .output = try alloc.print("tools={d} errors={d}", .{ window_tools, window_errors }),
        .reasoning = try alloc.dupe(u8, "permission pipeline + thread pool"),
        .confidence = tool_conf,
        .duration_ms = 0,
        .alternatives = &.{},
        .dependencies = &.{},
    });
    // Step 3: LLM generation.
    try trace.addStep(.{
        .step_id = 3,
        .phase = .llm_generation,
        .timestamp = util_time.nowMillis(),
        .input = try alloc.dupe(u8, "history + system prompt"),
        .output = try alloc.dupe(u8, "assistant message"),
        .reasoning = try alloc.dupe(u8, "provider stream + tool_use loop"),
        .confidence = 0.9,
        .duration_ms = 0,
        .alternatives = &.{},
        .dependencies = &.{},
    });
    trace.complete();

    var diag = self_diagnostic.SelfDiagnostic.init(alloc);
    const report = diag.diagnose(&trace, concern) catch {
        try std.Io.Writer.writeAll(w, "  Diagnosis failed.\n\n");
        return;
    };
    defer report.free(alloc);

    try std.Io.Writer.print(w, "  Diagnosis ({d} gaps, weakest confidence {d:.2}):\n", .{ report.identified_gaps.len, report.trace_summary.weakest_confidence });
    if (report.root_cause) |rc| {
        try std.Io.Writer.print(w, "  Root cause (step {d}): {s}\n", .{ rc.step_id, rc.description });
    }
    for (report.suggestions) |s| {
        try std.Io.Writer.print(w, "  → {s}\n", .{s.suggestion});
    }
    try std.Io.Writer.writeAll(w, "\n");
}

/// Deep-copy a json.Value tree onto `alloc` (the response DOM is arena-owned
/// and freed after history takes over).
fn dupeJsonValue(alloc: std.mem.Allocator, v: std.json.Value) anyerror!std.json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .string, .number_string => |s| blk: {
            const d = try alloc.dupe(u8, s);
            break :blk if (v == .string) .{ .string = d } else .{ .number_string = d };
        },
        .array => |arr| blk: {
            var out = std.json.Array.init(alloc);
            for (arr.items) |item| try out.append(try dupeJsonValue(alloc, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            errdefer out.deinit(alloc);
            var it = obj.iterator();
            while (it.next()) |e| {
                try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), try dupeJsonValue(alloc, e.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

fn freeJsonValue(alloc: std.mem.Allocator, v: std.json.Value) void {
    switch (v) {
        .null, .bool, .integer, .float => {},
        .string, .number_string => |s| alloc.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(alloc, item);
            var mut = arr;
            mut.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |e| {
                alloc.free(e.key_ptr.*);
                freeJsonValue(alloc, e.value_ptr.*);
            }
            var mut = obj;
            mut.deinit(alloc);
        },
    }
}

/// Deep-copy content blocks so history owns every string and JSON tree.
fn cloneContentBlocks(alloc: std.mem.Allocator, blocks: []const llm.ContentBlock) ![]llm.ContentBlock {
    const out = try alloc.alloc(llm.ContentBlock, blocks.len);
    var filled: usize = 0;
    errdefer freeContentBlocks(alloc, out[0..filled]);
    for (blocks, 0..) |b, i| {
        out[i] = switch (b) {
            .text => |t| .{ .text = try alloc.dupe(u8, t) },
            .thinking => |t| .{ .thinking = try alloc.dupe(u8, t) },
            .tool_use => |tu| .{ .tool_use = .{
                .id = try alloc.dupe(u8, tu.id),
                .name = try alloc.dupe(u8, tu.name),
                .input = try dupeJsonValue(alloc, tu.input),
            } },
            .tool_result => |tr| .{ .tool_result = .{
                .tool_use_id = try alloc.dupe(u8, tr.tool_use_id),
                .content = try alloc.dupe(u8, tr.content),
                .is_error = tr.is_error,
            } },
        };
        filled = i + 1;
    }
    return out;
}

fn freeContentBlocks(alloc: std.mem.Allocator, blocks: []const llm.ContentBlock) void {
    for (blocks) |b| {
        switch (b) {
            .text => |t| alloc.free(t),
            .thinking => |t| alloc.free(t),
            .tool_use => |tu| {
                alloc.free(tu.id);
                alloc.free(tu.name);
                freeJsonValue(alloc, tu.input);
            },
            .tool_result => |tr| {
                alloc.free(tr.tool_use_id);
                alloc.free(tr.content);
            },
        }
    }
    alloc.free(@constCast(blocks));
}

fn isFileModifyingTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "FileWrite") or
        std.mem.eql(u8, tool_name, "FileEdit") or
        std.mem.eql(u8, tool_name, "Write") or
        std.mem.eql(u8, tool_name, "Edit");
}

/// Execute a single tool call and record result.
fn executeAndRecord(
    tc: llm.provider.ToolUseBlock,
    alloc: std.mem.Allocator,
    io: std.Io,
    log: *op_log.OperationLog,
    fhist: *file_history.FileHistoryState,
    result_blocks: *std.ArrayList(llm.ContentBlock),
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
) !bool {
    try std.Io.Writer.print(w, "  [Executing: {s}]\n", .{tc.name});
    try std.Io.File.Writer.flush(file_writer);
    logger.info("Tool execute: {s}", .{tc.name});

    // Backup file before modification (for rollback support)
    var snap_id: ?[16]u8 = null;
    if (isFileModifyingTool(tc.name)) {
        if (registry.getStringField(tc.input, "path")) |fp| {
            // Generate snapshot ID
            var sid: [16]u8 = undefined;
            const ts = util_time.nowMillis();
            for (&sid, 0..) |*byte, i| {
                byte.* = @truncate(@as(u64, @bitCast(ts)) +% @as(u64, i) *% 0x9e3779b97f4a7c15);
            }
            fhist.trackEdit(fp, sid, io) catch {};
            snap_id = sid;
        }
    }

    const result = tools_mod.DefaultRegistry.execute(tc.name, alloc, tc.input, io) catch {
        logger.err("Tool failed: {s}", .{tc.name});
        try result_blocks.append(alloc, .{ .tool_result = .{
            .tool_use_id = tc.id,
            .content = "Tool execution failed",
            .is_error = true,
        } });
        _ = log.record(tc.name, "execution", "error", null, false) catch {};
        return true;
    };

    // Truncate large outputs for history — must dupe before freeing
    const max_result = 4096;
    const raw = result.output;
    const truncated = raw.len > max_result;

    try std.Io.Writer.print(w, "  [Result: {s}]\n", .{if (raw.len > 200) raw[0..200] else raw});

    const content_for_history: []const u8 = if (truncated)
        try alloc.dupe(u8, raw[0..max_result])
    else
        raw; // ownership transfers, no dupe needed

    try result_blocks.append(alloc, .{ .tool_result = .{
        .tool_use_id = tc.id,
        .content = content_for_history,
        .is_error = result.is_error,
    } });
    _ = log.record(tc.name, "executed", result.output, snap_id, snap_id != null) catch {};
    if (truncated and !result.is_error) {
        alloc.free(result.output);
    }
    // If not truncated, content_for_history == result.output; ownership moved into history
    try std.Io.File.Writer.flush(file_writer);
    return result.is_error;
}

// ──── Conversation management helpers ────

/// Estimate total tokens across all history messages.
fn estimateHistoryTokens(history: []const llm.Message) u32 {
    var total: u32 = 0;
    for (history) |msg| {
        for (msg.content) |block| {
            switch (block) {
                .text => |t| total += @intCast(t.len / 4),
                .tool_use => total += 50,
                .tool_result => |tr| total += @intCast(tr.content.len / 4),
                .thinking => |t| total += @intCast(t.len / 4),
            }
        }
    }
    return total;
}

/// Auto-compact if history exceeds phi threshold.
fn maybeCompact(history: *std.ArrayList(llm.Message), w: *std.Io.Writer, file_writer: *std.Io.File.Writer) void {
    const current_tokens = estimateHistoryTokens(history.items);
    if (!compaction.needsCompaction(current_tokens, MAX_CONTEXT_TOKENS)) return;

    compactHistoryImpl(history);
    std.Io.Writer.print(w, "  [Context auto-compacted: {d} messages remaining]\n", .{history.items.len}) catch {};
    std.Io.File.Writer.flush(file_writer) catch {};
}

/// Force compact history (used by /compact command).
fn compactHistory(history: *std.ArrayList(llm.Message), w: *std.Io.Writer) !void {
    if (history.items.len <= 2) {
        try std.Io.Writer.writeAll(w, "  Nothing to compact.\n\n");
        return;
    }
    const before = history.items.len;
    compactHistoryImpl(history);
    const est = estimateHistoryTokens(history.items);
    try std.Io.Writer.print(w, "  Compacted: {d} → {d} messages (~{d} tokens)\n\n", .{ before, history.items.len, est });
}

/// Core compaction: keep system prompt + recent 61.8% of messages.
fn compactHistoryImpl(history: *std.ArrayList(llm.Message)) void {
    if (history.items.len <= 2) return;

    // Keep system prompt (index 0) and recent messages up to phi target
    const total = history.items.len - 1; // exclude system prompt
    const target = compaction.condensationTarget(total);
    if (target >= total) return;

    const remove_count = total - target;
    // Remove messages [1..remove_count+1] (keep system at 0, keep recent)
    const new_len = 1 + target; // system + remaining
    for (history.items[1 .. remove_count + 1]) |_| {
        _ = history.orderedRemove(1);
    }
    // Ensure we have the right count
    while (history.items.len > new_len) {
        _ = history.orderedRemove(1);
    }
}

/// Clear history, keep only system prompt.
fn clearHistory(history: *std.ArrayList(llm.Message), _: []const u8) void {
    while (history.items.len > 1) {
        _ = history.orderedRemove(1);
    }
}

/// Show current context usage.
fn showContext(history: *std.ArrayList(llm.Message), total_in: u64, total_out: u64, w: *std.Io.Writer) !void {
    const est = estimateHistoryTokens(history.items);
    const pct = @as(f64, @floatFromInt(est)) / @as(f64, @floatFromInt(MAX_CONTEXT_TOKENS)) * 100.0;

    // Count by role
    var counts = [_]usize{ 0, 0, 0, 0 }; // system, user, assistant, tool
    for (history.items) |msg| {
        switch (msg.role) {
            .system => counts[0] += 1,
            .user => counts[1] += 1,
            .assistant => counts[2] += 1,
            .tool => counts[3] += 1,
        }
    }

    const threshold = compaction.condensationTarget(MAX_CONTEXT_TOKENS);
    try std.Io.Writer.print(w, "\n  Context: {d} / {d} tokens ({d:.1}%)\n", .{ est, MAX_CONTEXT_TOKENS, pct });
    try std.Io.Writer.print(w, "  Messages: {d} system, {d} user, {d} assistant, {d} tool\n", .{
        counts[0], counts[1], counts[2], counts[3],
    });
    try std.Io.Writer.print(w, "  Compaction threshold: {d} tokens (61.8%)\n", .{threshold});
    try std.Io.Writer.print(w, "  Session total: {d} in / {d} out tokens\n\n", .{ total_in, total_out });
}

/// Undo last exchange (remove last assistant + any tool results).
fn undoLastExchange(history: *std.ArrayList(llm.Message), w: *std.Io.Writer) !void {
    // Need at least system prompt + one user message + one assistant message
    if (history.items.len < 3) {
        try std.Io.Writer.writeAll(w, "  Nothing to undo.\n\n");
        return;
    }

    var removed: usize = 0;

    // Remove trailing assistant message
    if (history.items.len > 0) {
        const last = history.items[history.items.len - 1];
        if (last.role == .assistant) {
            _ = history.pop();
            removed += 1;
        }
    }

    // Remove trailing tool-result user message (from agent loop)
    if (history.items.len > 0) {
        const last = history.items[history.items.len - 1];
        if (last.role == .user) {
            // Check if it contains tool_result blocks (agent loop feedback)
            var has_tool_result = false;
            for (last.content) |block| {
                if (block == .tool_result) {
                    has_tool_result = true;
                    break;
                }
            }
            if (has_tool_result) {
                _ = history.pop();
                removed += 1;
            }
        }
    }

    // Remove trailing user message (the original prompt)
    if (history.items.len > 1) {
        const last = history.items[history.items.len - 1];
        if (last.role == .user) {
            _ = history.pop();
            removed += 1;
        }
    }

    if (removed == 0) {
        try std.Io.Writer.writeAll(w, "  Nothing to undo.\n\n");
    } else {
        try std.Io.Writer.print(w, "  Undone: removed {d} message(s). History now has {d} messages.\n\n", .{ removed, history.items.len });
    }
}

/// Rewind: show rollback points and restore files to a previous checkpoint.
fn rewindOperation(
    engine: *rollback_mod.RollbackEngine,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    const rollback_points = engine.listRollbackPoints() catch {
        try std.Io.Writer.writeAll(w, "  Error listing rollback points.\n\n");
        return;
    };
    defer alloc.free(rollback_points);

    if (rollback_points.len == 0) {
        try std.Io.Writer.writeAll(w, "  No rollback points available.\n");
        try std.Io.Writer.writeAll(w, "  Rollback requires file-modifying tools (FileWrite, FileEdit) to have been executed.\n\n");
        return;
    }

    try std.Io.Writer.print(w, "  Rollback points ({d}):\n", .{rollback_points.len});
    try std.Io.Writer.writeAll(w, "    [0] Session start (undo all file changes)\n");
    for (rollback_points, 0..) |rp, i| {
        try std.Io.Writer.print(w, "    [{d}] {s} (files: {d})\n", .{ i + 1, rp.tool_name, rp.files_affected });
    }
    try std.Io.Writer.writeAll(w, "\n  Select rollback point (or Enter to cancel): ");
    try std.Io.File.Writer.flush(file_writer);

    var ans_buf: [64]u8 = undefined;
    var ans_writer = std.Io.Writer.fixed(&ans_buf);
    const n = std.Io.Reader.streamDelimiter(r, &ans_writer, '\n') catch {
        try std.Io.Writer.writeAll(w, "\n");
        return;
    };
    r.toss(1);
    const ans = std.mem.trim(u8, ans_buf[0..n], " \t\r\n");
    if (ans.len == 0) {
        try std.Io.Writer.writeAll(w, "  Cancelled.\n\n");
        return;
    }

    const idx = std.fmt.parseInt(usize, ans, 10) catch {
        try std.Io.Writer.writeAll(w, "  Invalid selection.\n\n");
        return;
    };
    if (idx > rollback_points.len) {
        try std.Io.Writer.writeAll(w, "  Invalid selection.\n\n");
        return;
    }

    // [0] rolls everything back to the session start state.
    const target_op_id = if (idx == 0)
        rollback_mod.session_start_op_id
    else
        rollback_points[idx - 1].op_id;

    // Preview first
    const preview = engine.previewRollback(target_op_id) catch {
        try std.Io.Writer.writeAll(w, "  Error previewing rollback.\n\n");
        return;
    };

    try std.Io.Writer.print(w, "\n  Rollback preview:\n", .{});
    try std.Io.Writer.print(w, "    Files to restore: {d}\n", .{preview.files_to_restore});
    try std.Io.Writer.print(w, "    Files to delete:  {d}\n", .{preview.files_to_delete});
    try std.Io.Writer.print(w, "    Operations to undo: {d}\n", .{preview.operations_to_undo});
    try std.Io.Writer.writeAll(w, "  Proceed? [y/N]: ");
    try std.Io.File.Writer.flush(file_writer);

    var confirm_buf: [16]u8 = undefined;
    var confirm_writer = std.Io.Writer.fixed(&confirm_buf);
    _ = std.Io.Reader.streamDelimiter(r, &confirm_writer, '\n') catch {
        try std.Io.Writer.writeAll(w, "\n");
        return;
    };
    r.toss(1);
    const confirm = std.mem.trim(u8, confirm_buf[0..confirm_writer.end], " \t\r\n");
    if (!std.mem.eql(u8, confirm, "y") and !std.mem.eql(u8, confirm, "Y")) {
        try std.Io.Writer.writeAll(w, "  Cancelled.\n\n");
        return;
    }

    // Execute rollback
    const result = engine.rollbackTo(target_op_id, io) catch |err| {
        try std.Io.Writer.print(w, "  Rollback failed: {}\n\n", .{err});
        return;
    };

    try std.Io.Writer.print(w, "  Rollback complete:\n", .{});
    for (result.restored_files) |fp| {
        try std.Io.Writer.print(w, "    Restored: {s}\n", .{fp});
    }
    for (result.deleted_files) |fp| {
        try std.Io.Writer.print(w, "    Deleted:  {s}\n", .{fp});
    }
    for (result.errors) |e| {
        try std.Io.Writer.print(w, "    Error: {s}: {s}\n", .{ e.file_path, e.message });
    }
    try std.Io.Writer.print(w, "  ({d} restored, {d} deleted, {d} errors)\n\n", .{
        result.restored_files.len,
        result.deleted_files.len,
        result.errors.len,
    });

    engine.freeResult(result);
}

// ──── Interactive config menu ────

fn runConfigMenu(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    var dirty = false;

    while (true) {
        // Main menu
        try std.Io.Writer.writeAll(w, "\n=== Ziv Configuration ===\n");
        try std.Io.Writer.print(w, "  1. API Keys\n", .{});
        try std.Io.Writer.print(w, "  2. Default model       : {s}\n", .{switcher.settings.default_model});
        try std.Io.Writer.print(w, "  3. Max tokens          : {d}\n", .{switcher.settings.max_tokens});
        try std.Io.Writer.print(w, "  4. Permission mode     : {s}\n", .{auth.modeLabel(switcher.settings.permission_mode)});
        try std.Io.Writer.print(w, "  5. Checkpointing       : {s}\n", .{if (switcher.settings.checkpointing_enabled) "on" else "off"});
        const sp_display = if (switcher.settings.system_prompt != null) "(custom)" else "(default)";
        try std.Io.Writer.print(w, "  6. System prompt       : {s}\n", .{sp_display});
        try std.Io.Writer.writeAll(w, "  7. Save & Exit\n");
        try std.Io.Writer.writeAll(w, "  8. Exit without saving\n");
        try std.Io.Writer.writeAll(w, "\n  Select [1-8]: ");
        try std.Io.File.Writer.flush(file_writer);

        var buf: [4096]u8 = undefined;
        var bw = std.Io.Writer.fixed(&buf);
        const n = std.Io.Reader.streamDelimiter(r, &bw, '\n') catch break;
        r.toss(1);
        const sel = std.mem.trim(u8, buf[0..n], " \t\r\n");

        if (std.mem.eql(u8, sel, "1")) {
            try runApiKeysMenu(w, r, file_writer, switcher, alloc);
            dirty = true;
        } else if (std.mem.eql(u8, sel, "2")) {
            try std.Io.Writer.writeAll(w, "  Enter default model: ");
            try std.Io.File.Writer.flush(file_writer);
            var vbuf: [256]u8 = undefined;
            var vw = std.Io.Writer.fixed(&vbuf);
            const vn = std.Io.Reader.streamDelimiter(r, &vw, '\n') catch continue;
            r.toss(1);
            const val = std.mem.trim(u8, vbuf[0..vn], " \t\r\n");
            if (val.len > 0) {
                switcher.settings.default_model = try alloc.dupe(u8, val);
                dirty = true;
            }
        } else if (std.mem.eql(u8, sel, "3")) {
            try std.Io.Writer.writeAll(w, "  Enter max tokens (1-128000): ");
            try std.Io.File.Writer.flush(file_writer);
            var vbuf: [32]u8 = undefined;
            var vw = std.Io.Writer.fixed(&vbuf);
            const vn = std.Io.Reader.streamDelimiter(r, &vw, '\n') catch continue;
            r.toss(1);
            const val = std.mem.trim(u8, vbuf[0..vn], " \t\r\n");
            if (val.len > 0) {
                const mt = std.fmt.parseInt(u32, val, 10) catch {
                    try std.Io.Writer.writeAll(w, "  Invalid number.\n");
                    continue;
                };
                if (mt > 0 and mt <= 128000) {
                    switcher.settings.max_tokens = mt;
                    dirty = true;
                } else {
                    try std.Io.Writer.writeAll(w, "  Value out of range.\n");
                }
            }
        } else if (std.mem.eql(u8, sel, "4")) {
            try std.Io.Writer.writeAll(w,
                \\  Select permission mode:
                \\    1. Default      — Ask for dangerous operations
                \\    2. Accept Edits — Auto-accept file edits
                \\    3. Plan         — Read-only mode
                \\    4. Bypass       — Skip all permission checks
                \\    5. Don't Ask    — Auto-deny prompts
                \\    6. Auto         — LLM-classified (future)
                \\
            );
            try std.Io.Writer.writeAll(w, "  Select [1-6]: ");
            try std.Io.File.Writer.flush(file_writer);
            var vbuf: [16]u8 = undefined;
            var vw = std.Io.Writer.fixed(&vbuf);
            const vn = std.Io.Reader.streamDelimiter(r, &vw, '\n') catch continue;
            r.toss(1);
            const val = std.mem.trim(u8, vbuf[0..vn], " \t\r\n");
            if (val.len == 1) {
                const mode: ?auth.PermissionMode = switch (val[0]) {
                    '1' => .default,
                    '2' => .accept_edits,
                    '3' => .plan,
                    '4' => .bypass,
                    '5' => .dont_ask,
                    '6' => .auto,
                    else => null,
                };
                if (mode) |m| {
                    switcher.settings.permission_mode = m;
                    dirty = true;
                }
            }
        } else if (std.mem.eql(u8, sel, "5")) {
            switcher.settings.checkpointing_enabled = !switcher.settings.checkpointing_enabled;
            try std.Io.Writer.print(w, "  Checkpointing: {s}\n", .{if (switcher.settings.checkpointing_enabled) "on" else "off"});
            dirty = true;
        } else if (std.mem.eql(u8, sel, "6")) {
            try std.Io.Writer.writeAll(w, "  1. Enter custom system prompt\n");
            try std.Io.Writer.writeAll(w, "  2. Reset to default\n");
            try std.Io.Writer.writeAll(w, "  3. Back\n");
            try std.Io.Writer.writeAll(w, "  Select [1-3]: ");
            try std.Io.File.Writer.flush(file_writer);
            var vbuf: [16]u8 = undefined;
            var vw = std.Io.Writer.fixed(&vbuf);
            const vn = std.Io.Reader.streamDelimiter(r, &vw, '\n') catch continue;
            r.toss(1);
            const val = std.mem.trim(u8, vbuf[0..vn], " \t\r\n");
            if (std.mem.eql(u8, val, "1")) {
                try std.Io.Writer.writeAll(w, "  Enter system prompt: ");
                try std.Io.File.Writer.flush(file_writer);
                var pbuf: [4096]u8 = undefined;
                var pw = std.Io.Writer.fixed(&pbuf);
                const pn = std.Io.Reader.streamDelimiter(r, &pw, '\n') catch continue;
                r.toss(1);
                const pval = std.mem.trim(u8, pbuf[0..pn], " \t\r\n");
                if (pval.len > 0) {
                    switcher.settings.system_prompt = try alloc.dupe(u8, pval);
                    dirty = true;
                }
            } else if (std.mem.eql(u8, val, "2")) {
                switcher.settings.system_prompt = null;
                dirty = true;
                try std.Io.Writer.writeAll(w, "  Reset to default.\n");
            }
        } else if (std.mem.eql(u8, sel, "7")) {
            // Save & Exit
            config_mod.saveSettings(&switcher.settings, alloc, io) catch |err| {
                try std.Io.Writer.print(w, "  Error saving: {}\n", .{err});
                try std.Io.File.Writer.flush(file_writer);
                continue;
            };
            try std.Io.Writer.writeAll(w, "  Settings saved to ~/.config/ziv/settings.json\n\n");
            break;
        } else if (std.mem.eql(u8, sel, "8") or sel.len == 0) {
            if (dirty) {
                try std.Io.Writer.writeAll(w, "  Changes discarded.\n\n");
            }
            break;
        }
    }
}

fn runApiKeysMenu(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
) !void {
    while (true) {
        try std.Io.Writer.writeAll(w, "\n=== API Keys ===\n");

        // OpenAI
        if (switcher.settings.api_keys.openai) |k| {
            try std.Io.Writer.print(w, "  1. OpenAI API Key     : {s}\n", .{maskKey(k)});
        } else {
            try std.Io.Writer.writeAll(w, "  1. OpenAI API Key     : (not set)\n");
        }

        // Anthropic
        if (switcher.settings.api_keys.anthropic) |k| {
            try std.Io.Writer.print(w, "  2. Anthropic API Key  : {s}\n", .{maskKey(k)});
        } else {
            try std.Io.Writer.writeAll(w, "  2. Anthropic API Key  : (not set)\n");
        }

        // Brave
        if (switcher.settings.api_keys.brave_api_key) |k| {
            try std.Io.Writer.print(w, "  3. Brave API Key      : {s}\n", .{maskKey(k)});
        } else {
            try std.Io.Writer.writeAll(w, "  3. Brave API Key      : (not set)\n");
        }

        try std.Io.Writer.print(w, "  4. Ollama Host        : {s}\n", .{switcher.settings.api_keys.ollama_host});
        try std.Io.Writer.writeAll(w, "  5. Back\n");
        try std.Io.Writer.writeAll(w, "\n  Select [1-5]: ");
        try std.Io.File.Writer.flush(file_writer);

        var buf: [4096]u8 = undefined;
        var bw = std.Io.Writer.fixed(&buf);
        const n = std.Io.Reader.streamDelimiter(r, &bw, '\n') catch break;
        r.toss(1);
        const sel = std.mem.trim(u8, buf[0..n], " \t\r\n");

        if (std.mem.eql(u8, sel, "1")) {
            try std.Io.Writer.writeAll(w, "  Enter OpenAI API Key (or Enter to keep): ");
            try std.Io.File.Writer.flush(file_writer);
            var vbuf: [256]u8 = undefined;
            var vw = std.Io.Writer.fixed(&vbuf);
            const vn = std.Io.Reader.streamDelimiter(r, &vw, '\n') catch continue;
            r.toss(1);
            const val = std.mem.trim(u8, vbuf[0..vn], " \t\r\n");
            if (val.len > 0) {
                switcher.settings.api_keys.openai = try alloc.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, sel, "2")) {
            try std.Io.Writer.writeAll(w, "  Enter Anthropic API Key (or Enter to keep): ");
            try std.Io.File.Writer.flush(file_writer);
            var vbuf: [256]u8 = undefined;
            var vw = std.Io.Writer.fixed(&vbuf);
            const vn = std.Io.Reader.streamDelimiter(r, &vw, '\n') catch continue;
            r.toss(1);
            const val = std.mem.trim(u8, vbuf[0..vn], " \t\r\n");
            if (val.len > 0) {
                switcher.settings.api_keys.anthropic = try alloc.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, sel, "3")) {
            try std.Io.Writer.writeAll(w, "  Enter Brave API Key (or Enter to keep): ");
            try std.Io.File.Writer.flush(file_writer);
            var vbuf: [256]u8 = undefined;
            var vw = std.Io.Writer.fixed(&vbuf);
            const vn = std.Io.Reader.streamDelimiter(r, &vw, '\n') catch continue;
            r.toss(1);
            const val = std.mem.trim(u8, vbuf[0..vn], " \t\r\n");
            if (val.len > 0) {
                switcher.settings.api_keys.brave_api_key = try alloc.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, sel, "4")) {
            try std.Io.Writer.writeAll(w, "  Enter Ollama Host URL: ");
            try std.Io.File.Writer.flush(file_writer);
            var vbuf: [256]u8 = undefined;
            var vw = std.Io.Writer.fixed(&vbuf);
            const vn = std.Io.Reader.streamDelimiter(r, &vw, '\n') catch continue;
            r.toss(1);
            const val = std.mem.trim(u8, vbuf[0..vn], " \t\r\n");
            if (val.len > 0) {
                switcher.settings.api_keys.ollama_host = try alloc.dupe(u8, val);
            }
        } else {
            break; // Back or invalid
        }
    }
}

/// Mask a key for display: show "sk-...xyz" format.
/// Returns a static buffer (overwritten on next call — fine for display).
var mask_buf: [64]u8 = undefined;
fn maskKey(key: []const u8) []const u8 {
    if (key.len <= 6) return "***";
    const prefix_len = @min(@as(usize, 3), key.len);
    const suffix_start = key.len - @min(@as(usize, 3), key.len);
    var i: usize = 0;
    for (key[0..prefix_len]) |ch| {
        mask_buf[i] = ch;
        i += 1;
    }
    mask_buf[i] = '.';
    i += 1;
    mask_buf[i] = '.';
    i += 1;
    mask_buf[i] = '.';
    i += 1;
    for (key[suffix_start..]) |ch| {
        mask_buf[i] = ch;
        i += 1;
    }
    return mask_buf[0..i];
}

fn printModelInfo(w: *std.Io.Writer, switcher: *ModelSwitcher) !void {
    try std.Io.Writer.writeAll(w, "\n  Current model: ");
    try std.Io.Writer.print(w, "{s} ({s})\n\n", .{ switcher.modelName(), switcher.backendLabel() });

    try std.Io.Writer.writeAll(w, "  Available models:\n");
    try std.Io.Writer.writeAll(w, "  ┌─────────────────────┬──────────┬──────────────────────────────┐\n");
    try std.Io.Writer.writeAll(w, "  │ Model               │ Backend  │ Description                  │\n");
    try std.Io.Writer.writeAll(w, "  ├─────────────────────┼──────────┼──────────────────────────────┤\n");

    for (&llm.KNOWN_MODELS) |entry| {
        const marker = if (std.mem.eql(u8, entry.name, switcher.modelName())) " *" else "  ";
        const backend_str = switch (entry.backend) {
            .claude => "Claude",
            .openai => "OpenAI",
            .ollama => "Ollama",
        };
        try std.Io.Writer.print(w, " {s} {s:<20} {s:<10} {s}\n", .{ marker, entry.name, backend_str, entry.description });
    }

    try std.Io.Writer.writeAll(w, "\n  * = current model\n");
    try std.Io.Writer.writeAll(w, "  Usage: /model <name>  (e.g. /model claude-sonnet-4-6)\n\n");
}

fn printHelp(w: *std.Io.Writer) !void {
    try std.Io.Writer.writeAll(w,
        \\Available commands:
        \\  /help, /h         Show this help
        \\  /quit, /q         Exit ziv
        \\  /version          Show version
        \\  /stats            Show session statistics and token usage
        \\  /tools            List registered tools (12 tools)
        \\  /run <t> <json>   Execute a tool directly
        \\
        \\Model & Config:
        \\  /model            Show current model and available models
        \\  /model <name>     Switch to a different model
        \\  /mode             Cycle permission mode
        \\  /config           Interactive configuration menu
        \\
        \\Conversation:
        \\  /compact          Compress conversation history to free tokens
        \\  /clear            Clear conversation, start fresh (alias: /reset, /new)
        \\  /context          Show current context/token usage
        \\  /undo             Undo last exchange
        \\  /history          Show operation history
        \\  /rewind           Rollback to a checkpoint
        \\  /memory           Show injected and stored memories
        \\  /research <topic> Web research with phi-curated solutions
        \\  /diagnose <q>     Self-diagnose a weak answer vs your concern
        \\
        \\Models (use /model to switch):
        \\  Claude:   claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5
        \\  OpenAI:   gpt-4o, gpt-4o-mini, o3-mini
        \\  Ollama:   llama3.2, qwen2.5, deepseek-r1 (local)
        \\
        \\Permission modes (cycle with /mode):
        \\  Default       — Ask for dangerous operations
        \\  Accept Edits  — Auto-accept file edits
        \\  Plan          — Read-only mode
        \\  Bypass        — Skip all permission checks
        \\
        \\Example:
        \\  /config                       Open configuration menu
        \\  /model claude-sonnet-4-6      Switch to Claude Sonnet
        \\  /compact                      Free up context tokens
        \\  /run Bash {"command":"ls"}
        \\
    );
}

test "cloneContentBlocks deep-copies text and tool_use JSON trees" {
    const alloc = std.testing.allocator;

    var input_obj: std.json.ObjectMap = .empty;
    defer input_obj.deinit(alloc);
    try input_obj.put(alloc, "command", .{ .string = "ls -la" });
    var nested_arr = std.json.Array.init(alloc);
    defer nested_arr.deinit(); // the map copy shares this buffer; freed once here
    try nested_arr.append(.{ .integer = 1 });
    try nested_arr.append(.{ .string = "two" });
    try input_obj.put(alloc, "nested", .{ .array = nested_arr });

    const blocks = [_]llm.ContentBlock{
        .{ .text = "hello" },
        .{ .tool_use = .{ .id = "tu_1", .name = "Bash", .input = .{ .object = input_obj } } },
    };

    const owned = try cloneContentBlocks(alloc, &blocks);
    defer freeContentBlocks(alloc, owned);

    try std.testing.expectEqualStrings("hello", owned[0].text);
    try std.testing.expectEqualStrings("tu_1", owned[1].tool_use.id);
    // Nested JSON survives the deep copy.
    const cmd = registry.getStringField(owned[1].tool_use.input, "command");
    try std.testing.expectEqualStrings("ls -la", cmd.?);
    const nested = owned[1].tool_use.input.object.get("nested").?;
    try std.testing.expectEqual(@as(i64, 1), nested.array.items[0].integer);
    try std.testing.expectEqualStrings("two", nested.array.items[1].string);
}
