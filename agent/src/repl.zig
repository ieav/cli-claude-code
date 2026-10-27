/// Enhanced REPL for Ziv — reads user input, dispatches commands and queries.
/// Supports multi-model switching, tool execution, permission modes, operation history,
/// conversation management (compact/clear/context/undo/rewind), and interactive config.
/// Adapted for Zig 0.16 I/O API.
const std = @import("std");
const tools_mod = @import("tools/mod.zig");
const orchestration_mod = @import("tools/orchestration.zig");
const auth = @import("tools/auth_mode.zig");
const classifier_mod = @import("tools/classifier.zig");
const menu = @import("util/menu.zig");
const lineinput = @import("util/lineinput.zig");
const slash_cmds = @import("util/slash_commands.zig");
const runtime_registry = @import("tools/runtime_registry.zig");
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
const knowledge_graph = @import("knowledge/graph.zig");
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

    /// Backend routing, in priority order:
    ///   1. known-model table entry (authoritative — an override must not
    ///      hijack claude-*/gpt-*/table models after pinning a custom name)
    ///   2. recognizable name prefixes (claude-*, gpt-*, …)
    ///   3. explicit settings.default_backend — rescues UNRECOGNIZED names
    ///      (glm-4.6, deepseek-v3, …) into a configured compatible gateway
    ///   4. Ollama fallback (the old behavior)
    fn effectiveBackend(self: *const Self, model: []const u8) llm.BackendType {
        if (llm.findKnownModel(model)) |entry| return entry.backend;
        const detected = llm.detectBackend(model);
        if (detected != .ollama) return detected;
        if (self.settings.default_backend) |b| {
            if (std.meta.stringToEnum(llm.BackendType, b)) |be| return be;
        }
        return .ollama;
    }

    pub fn init(settings: config_mod.Settings, io: std.Io) Self {
        const model = settings.default_model;
        const len = @min(model.len, 64);
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..len], model[0..len]);
        var switcher = Self{
            .model_name_buf = buf,
            .model_name_len = len,
            .backend = llm.detectBackend(model),
            .io = io,
            .settings = settings,
        };
        switcher.backend = switcher.effectiveBackend(model);
        return switcher;
    }

    pub fn deinit(self: *Self) void {
        if (self.openai_provider) |*p| p.deinit();
        if (self.claude_provider) |*p| p.deinit();
        if (self.ollama_provider) |*p| p.deinit();
    }

    /// Switch to a new model. Returns error if API key is missing.
    pub fn switchModel(self: *Self, new_model: []const u8) !void {
        const new_backend = self.effectiveBackend(new_model);

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

        // Re-pin the backend without changing the name may pass the CURRENT
        // name back in (switchModel(modelName()) from the gateway pin flow):
        // skip the copy — @memcpy with aliasing src/dst is a panic in Zig.
        if (!std.mem.eql(u8, new_model[0..@min(new_model.len, 64)], self.modelName())) {
            const len = @min(new_model.len, 64);
            @memcpy(self.model_name_buf[0..len], new_model[0..len]);
            self.model_name_len = len;
        }
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
    var current_mode: auth.PermissionMode = switcher.settings.permission_mode;
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
    // Semantic tier: the knowledge graph shares the memory database.
    var kgraph: ?knowledge_graph.KnowledgeGraph = if (mem_db != null)
        knowledge_graph.KnowledgeGraph.init(allocator, &mem_db.?)
    else
        null;

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

    // M8-deep: live decision trace — one trace per user query, steps added
    // at each real agent-loop decision point; /diagnose reads it.
    var live_trace: ?decision_trace.DecisionTrace = null;
    defer if (live_trace) |*t| t.deinit();

    // Runtime tool registry (M1): built-ins + (later) MCP dynamic tools.
    // Everything downstream — /tools, /run, agent loop, orchestration —
    // reads this one list.
    var reg = runtime_registry.RuntimeRegistry.init(allocator);
    defer reg.deinit();

    // Input history for the line editor (up/down navigation).
    var input_history: std.ArrayList([]u8) = .empty;
    defer {
        for (input_history.items) |h| allocator.free(h);
        input_history.deinit(allocator);
    }

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
        var est_ctx = estimateHistoryTokens(history.items);
        const ctx_pct = @as(u32, @intFromFloat(@as(f64, @floatFromInt(est_ctx)) / @as(f64, @floatFromInt(MAX_CONTEXT_TOKENS)) * 100.0));
        var prompt_buf: [160]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "{s} ({s}) [{d}%] > ", .{ mode_str, switcher.modelName(), ctx_pct }) catch "> ";

        // Read line via the raw-mode editor: arrows move the cursor,
        // up/down walk history, Backspace/Delete/Home/End work. Pipes
        // (non-TTY) transparently fall back to plain line reading.
        var line_buf: [4096]u8 = undefined;
        const maybe_n = lineinput.readLine(w, r, &file_writer, prompt, &line_buf, &input_history, allocator) catch |err| {
            std.debug.print("Error reading input: {}\n", .{err});
            return;
        };
        const n = maybe_n orelse {
            try std.Io.Writer.writeAll(w, "\nGoodbye!\n");
            try std.Io.File.Writer.flush(&file_writer);
            return;
        };

        if (n == 0) continue;

        const input = std.mem.trim(u8, line_buf[0..n], " \t\r\n");
        if (input.len == 0) continue;

        // ──── Meta commands ────
        if (std.mem.startsWith(u8, input, "/")) {
            if (std.mem.eql(u8, input, "/quit") or std.mem.eql(u8, input, "/q") or std.mem.eql(u8, input, "/exit")) {
                // M4: session-end reflection on whatever the window still holds.
                if (mem_sys != null and window_queries.items.len > 0) {
                    runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, switcher.getProvider() catch null);
                }
                if (mem_sys) |*ms| extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, w) catch {};
                try std.Io.Writer.writeAll(w, "Goodbye!\n");
                try std.Io.File.Writer.flush(&file_writer);
                break;
            } else if (std.mem.eql(u8, input, "/help") or std.mem.eql(u8, input, "/h")) {
                try printHelp(w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/tools")) {
                try std.Io.Writer.writeAll(w, "Registered tools:\n");
                for (reg.definitions()) |tool| {
                    const safety = if (tool.is_concurrency_safe_fn != null) "safe" else "serial";
                    try std.Io.Writer.print(w, "  {s} - {s} [{s}|{s}]\n", .{
                        tool.name,
                        tool.description,
                        if (tool.is_read_only) "read" else "write",
                        safety,
                    });
                }
                try std.Io.Writer.print(w, "\n  Total: {d} tools\n\n", .{reg.count()});
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

                // Per-command arena: the DOM (and every string the tool
                // pulled out of it) dies at the end of the /run arm.
                var run_arena = std.heap.ArenaAllocator.init(allocator);
                defer run_arena.deinit();
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, run_arena.allocator(), json_str, .{}) catch {
                    try std.Io.Writer.writeAll(w, "Invalid JSON input\n\n");
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };

                try std.Io.Writer.print(w, "  Running {s}...\n", .{tool_name});
                try std.Io.File.Writer.flush(&file_writer);
                logger.info("Tool /run: {s}", .{tool_name});

                // Permission gate — /run goes through the same pipeline as
                // agent-loop tool calls (previously it bypassed the mode
                // entirely, letting Plan mode perform writes).
                const run_tool = reg.findByName(tool_name) orelse {
                    try std.Io.Writer.print(w, "  Unknown tool: {s}\n\n", .{tool_name});
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };
                if (!try permissionGate(run_tool, parsed, current_mode, &switcher, allocator, r, w, &file_writer)) continue;

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

                const result = run_tool.execute(allocator, parsed, io) catch |err| {
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
                allocator.free(result.output);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/mode")) {
                // Cycle permission mode
                current_mode = auth.nextMode(current_mode);
                // Persist the mode choice — it was runtime-only before, so
                // every restart silently fell back to the configured mode.
                switcher.settings.permission_mode = current_mode;
                config_mod.saveSettings(&switcher.settings, allocator, io) catch {};
                try std.Io.Writer.print(w, "  Permission mode: {s} (已保存)\n\n", .{auth.modeLabel(current_mode)});
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/model") or std.mem.eql(u8, input, "/models")) {
                // Interactive model picker (arrow keys + Enter); q shows the
                // plain text listing instead.
                try runModelPicker(w, r, &file_writer, &switcher, io);
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
                try compactHistory(&history, allocator, w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/clear") or std.mem.eql(u8, input, "/reset") or std.mem.eql(u8, input, "/new")) {
                if (mem_sys) |*ms| extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, w) catch {};
                clearHistory(&history, allocator);
                // Drop the stale memory-injection block from the surviving
                // system message so the fresh conversation isn't primed
                // with the cleared one's memories.
                if (memory_block) |mb| {
                    allocator.free(mb);
                    const fresh_blocks = try allocator.alloc(llm.ContentBlock, 1);
                    fresh_blocks[0] = .{ .text = sys_prompt };
                    allocator.free(history.items[0].content);
                    history.items[0].content = fresh_blocks;
                    memory_block = null; // the end-of-session defer must not double-free
                    injected_count = 0;
                }
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
            } else if (std.mem.eql(u8, input, "/knowledge")) {
                try printKnowledge(if (kgraph) |*g| g else null, w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.startsWith(u8, input, "/diagnose")) {
                const rest = if (input.len > "/diagnose".len) input["/diagnose".len..] else "";
                const concern = std.mem.trim(u8, rest, " \t");
                if (concern.len == 0) {
                    try std.Io.Writer.writeAll(w, "  Usage: /diagnose <your concern about the last answer>\n\n");
                } else {
                    try runDiagnose(if (live_trace) |*t| t else null, concern, injected_count, window_tools, window_errors, allocator, w);
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/undo")) {
                try undoLastExchange(&history, allocator, w);
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
                try std.Io.Writer.writeAll(w, "  Ziv v0.5.0 (Zig " ++ @import("builtin").zig_version_string ++ ")\n\n");
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else {
                try std.Io.Writer.print(w, "Unknown command: {s}", .{input});
                // Typo hints from the canonical command table.
                if (slash_cmds.suggestMatching(allocator, input) catch null) |hits| {
                    defer allocator.free(hits);
                    if (hits.len > 0) {
                        try std.Io.Writer.writeAll(w, "\nDid you mean:");
                        for (hits[0..@min(hits.len, 5)]) |h| {
                            try std.Io.Writer.print(w, " {s}", .{h});
                        }
                    }
                }
                try std.Io.Writer.writeAll(w, "\nType /help for available commands.\n\n");
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

        // Fresh decision trace for this query.
        if (live_trace) |*t| t.deinit();
        live_trace = decision_trace.DecisionTrace.init(allocator, try allocator.dupe(u8, input));
        if (live_trace) |*t| {
            // Step 1: memory retrieval (system-prompt injection status).
            traceAddStep(t, .memory_retrieval, if (injected_count > 0) 0.8 else 0.3, input, "recency-ranked e-decay injection", "injected count from startup", allocator) catch {};
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
            maybeCompact(&history, allocator, w, &file_writer);
            // est_ctx goes stale across tool rounds (history grows) — refresh
            est_ctx = estimateHistoryTokens(history.items);

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
            if (live_trace) |*t| {
                var ctx_buf: [96]u8 = undefined;
                const out_desc = std.fmt.bufPrint(&ctx_buf, "history={d} ctx~{d}t", .{ history.items.len, est_ctx }) catch "history";
                traceAddStep(t, .context_assembly, if (est_ctx < MAX_CONTEXT_TOKENS) 0.9 else 0.5, "messages + memory block", out_desc, "compaction-checked assembly", allocator) catch {};
            }
            logger.notice("LLM call: model={s} history_len={d} max_tokens={d}", .{
                switcher.modelName(), history.items.len, switcher.settings.max_tokens,
            });
            // Stream the response: text deltas print live as they arrive.
            const llm_t0 = util_time.nowMillis();
            const response = streamComplete(prov, history.items, .{
                .max_tokens = switcher.settings.max_tokens,
                .temperature = 0.7,
                // Declare the tools so the model can actually call them.
                .tools = reg.toolSpecs(),
            }, w, &file_writer, allocator) catch |err| {
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

            // Live decision trace: generation step.
            if (live_trace) |*t| {
                const gen_conf: f64 = if (response.usage.output_tokens > 0) 0.9 else 0.4;
                const out_desc: []const u8 = if (response.content.len > 0) "content blocks" else "empty response";
                traceAddStep(t, .llm_generation, gen_conf, "history + system prompt", out_desc, @tagName(response.stop_reason), allocator) catch {};
            }

            // Text/thinking deltas were already printed live by streamComplete;
            // only tool info remains to show here.
            for (response.content) |block| {
                switch (block) {
                    .tool_use => |tc| {
                        try std.Io.Writer.print(w, "  [tool_use: {s}]\n", .{tc.name});
                    },
                    .tool_result => |tr| {
                        const label = if (tr.is_error) "error" else "result";
                        try std.Io.Writer.print(w, "  [tool {s}: {s}]\n", .{ label, tr.content });
                    },
                    else => {},
                }
            }
            const llm_elapsed_s = @as(f64, @floatFromInt(util_time.nowMillis() - llm_t0)) / 1000.0;
            try std.Io.Writer.print(w, "  [tokens: in={d} out={d} | stop: {s} | {d:.1}s]\n", .{
                response.usage.input_tokens,
                response.usage.output_tokens,
                @tagName(response.stop_reason),
                llm_elapsed_s,
            });
            try std.Io.File.Writer.flush(&file_writer);

            // Append assistant response to history. The streaming aggregator
            // already produced REPL-owned blocks (strings duped onto the
            // session allocator; no DOM arena involved), so no deep copy
            // or arena release is needed here.
            const stop_reason = response.stop_reason;
            try history.append(allocator, .{
                .role = .assistant,
                .content = response.content,
                .timestamp = util_time.nowMillis(),
            });

            // Record in operation log
            _ = log.record("LLMResponse", input, "response", null, false) catch {};
            if (live_trace) |*t| {
                traceAddStep(t, .response_postprocess, 0.95, "stream aggregation", "blocks appended to history", "REPL-owned copy", allocator) catch {};
            }

            // Check if tool calling is needed
            if (stop_reason != .tool_use) break;

            // Execute tool calls — reuse result_blocks, clear from previous iteration
            result_blocks.clearRetainingCapacity();

            var has_tool_use = false;
            // Phase 1 (serial): permission gate + pre-execution backup for
            // every tool_use; approved calls are collected for phase 2.
            var prepared = std.ArrayList(PreparedCall).empty;
            var total_calls: u32 = 0;
            defer prepared.deinit(allocator);

            // Iterate the owned copy in history — the response was freed above.
            const last_assistant = history.items[history.items.len - 1].content;
            for (last_assistant) |block| {
                if (block == .tool_use) {
                    has_tool_use = true;
                    total_calls += 1;
                    const tc = block.tool_use;

                    // Find tool definition
                    const tool_def = reg.findByName(tc.name) orelse {
                        try std.Io.Writer.print(w, "  [Unknown tool: {s}]\n", .{tc.name});
                        try result_blocks.append(allocator, .{ .tool_result = .{
                            .tool_use_id = tc.id,
                            .content = "Tool not found",
                            .is_error = true,
                        } });
                        continue;
                    };

                    // Backup file before modification (for rollback support)
                    var snap_id: ?[16]u8 = null;
                    if (isFileModifyingTool(tc.name)) {
                        if (registry.getStringField(tc.input, "path")) |fp| {
                            var sid: [16]u8 = undefined;
                            const ts = util_time.nowMillis();
                            for (&sid, 0..) |*byte, i| {
                                byte.* = @truncate(@as(u64, @bitCast(ts)) +% @as(u64, i) *% 0x9e3779b97f4a7c15);
                            }
                            fhist.trackEdit(fp, sid, io) catch {};
                            snap_id = sid;
                        }
                    }

                    // Permission check (shared gate; auto mode may delegate
                    // the ambiguous ask case to the LLM classifier).
                    const approved = try permissionGate(tool_def, tc.input, current_mode, &switcher, allocator, r, w, &file_writer);
                    if (!approved) {
                        try result_blocks.append(allocator, .{ .tool_result = .{
                            .tool_use_id = tc.id,
                            .content = "denied by permission gate",
                            .is_error = true,
                        } });
                        continue;
                    }

                    try prepared.append(allocator, .{
                        .call = .{ .tool_name = tc.name, .input = tc.input, .tool_use_id = tc.id },
                        .snap_id = snap_id,
                    });
                }
            }

            // Live decision trace: selection step (permission outcomes).
            if (live_trace) |*t| {
                if (total_calls > 0) {
                    const conf: f64 = if (total_calls == 0) 0.9 else @as(f64, @floatFromInt(prepared.items.len)) / @as(f64, @floatFromInt(total_calls));
                    var sel_buf: [96]u8 = undefined;
                    const out_desc = std.fmt.bufPrint(&sel_buf, "approved={d} rejected={d}", .{ prepared.items.len, total_calls - prepared.items.len }) catch "selection";
                    traceAddStep(t, .tool_selection, conf, "tool_use blocks", out_desc, "permission gate", allocator) catch {};
                }
            }

            // Phase 2: execute approved calls. partitionToolCalls groups
            // concurrency-safe tools into batches that run in parallel on
            // the e-bounded thread pool; unsafe tools run serially. Results
            // come back in the original call order.
            if (prepared.items.len > 0) {
                const call_view = try allocator.alloc(orchestration_mod.ToolCall, prepared.items.len);
                defer allocator.free(call_view);
                for (prepared.items, 0..) |p, i| call_view[i] = p.call;

                const batches = try orchestration_mod.partitionToolCalls(call_view, reg.definitions(), allocator);
                defer {
                    for (batches) |b| allocator.free(b.calls);
                    allocator.free(batches);
                }
                const results = try orchestration_mod.executeBatches(batches, allocator, io, reg.definitions());
                defer allocator.free(results);

                var batch_errors: u32 = 0;
                for (prepared.items, 0..) |p, i| {
                    window_tools += 1;
                    const errored = try finishToolCall(p, results[i].result, allocator, &log, &result_blocks, w, &file_writer);
                    if (errored) {
                        window_errors += 1;
                        batch_errors += 1;
                    }
                }

                // Live decision trace: execution step for this batch.
                if (live_trace) |*t| {
                    const conf = 1.0 - @as(f64, @floatFromInt(batch_errors)) / @as(f64, @floatFromInt(prepared.items.len));
                    var step_buf: [96]u8 = undefined;
                    const out_desc = std.fmt.bufPrint(&step_buf, "tools={d} errors={d}", .{ prepared.items.len, batch_errors }) catch "batch";
                    traceAddStep(t, .tool_execution, conf, "approved batch", out_desc, "permission gate + thread pool", allocator) catch {};
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
            runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, switcher.getProvider() catch null);
            if (live_trace) |*t| {
                traceAddStep(t, .reflection_trigger, 0.9, "query window", "insights stored", "phi/e heuristics", allocator) catch {};
            }
        }

        try std.Io.Writer.writeAll(w, "\n");
        try std.Io.File.Writer.flush(&file_writer);
    }
}

/// Check if a tool is likely to modify files (and should be backed up).
/// Extract memorable facts from this session and persist them to the
/// episodic tier, so the next session can inject them (T3.1).
/// φ condensation keeps only the top 61.8% of candidates by importance.
/// Stored facts also become knowledge-graph nodes (semantic tier), chained
/// by "co_extracted" edges within the session.
fn extractSessionMemories(mem: *memory_mod.MemorySystem, kg: ?*knowledge_graph.KnowledgeGraph, history: *std.ArrayList(llm.Message), w: *std.Io.Writer) !void {
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
    var last_node_id: ?i64 = null;
    for (candidates.items[0..target]) |f| {
        const now = util_time.nowMillis();
        mem.store(.{
            .id = injection_mod.memoryId(f.content, @tagName(f.fact_type)),
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

        // Semantic tier: mirror the stored fact as a graph node.
        if (kg) |g| {
            if (g.addNode(f.content[0..@min(48, f.content.len)], entityTypeForFact(f.fact_type), @tagName(f.fact_type)) catch null) |nid| {
                if (last_node_id) |prev| {
                    g.addEdge(prev, nid, "co_extracted", 0.618) catch {};
                }
                last_node_id = nid;
            }
        }
    }
    if (stored > 0) {
        try w.print("  Saved {d} memories for future sessions.\n", .{stored});
    }
}

/// M4: run a reflection pass over the query window and persist the insight
/// as a feedback memory. Resets the window.
/// Ownership: dupes every string it keeps onto the session allocator before the
/// window slices (cleared right after) are reused; the reflection insight is
/// owned by the memory system after store. No borrows outlive this call.
fn runReflection(
    reflector: *reflection_mod.ReflectionEngine,
    mem: *memory_mod.MemorySystem,
    window_queries: *std.ArrayList([]u8),
    window_tools: *u32,
    window_errors: *u32,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    provider: ?llm.Provider,
) void {
    const reflection = reflector.reflect(window_queries.items, window_tools.*, window_errors.*, .on_query_complete) catch return orelse return;

    // LLM augmentation: when a provider is reachable, ask it to summarize
    // the query window into one improvement insight; heuristics stay as
    // the fallback (and quality score source).
    var llm_insights: ?[]u8 = null;
    if (provider) |p| {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        const pw = &aw.writer;
        pw.writeAll("Recent queries in this session:\n") catch {};
        for (window_queries.items) |q| {
            pw.print("- {s}\n", .{q}) catch {};
        }
        var prompt_list = aw.toArrayList();
        defer prompt_list.deinit(alloc);

        const sys_blocks = alloc.alloc(llm.ContentBlock, 1) catch null;
        if (sys_blocks) |sb| {
            sb[0] = .{ .text = "你是反思引擎。用一句中文总结这些交互的改进点，不超过40字，只输出总结本身。" };
            const user_blocks = alloc.alloc(llm.ContentBlock, 1) catch null;
            if (user_blocks) |ub| {
                ub[0] = .{ .text = prompt_list.items };
                const msgs = [_]llm.Message{
                    .{ .role = .system, .content = sb, .timestamp = util_time.nowMillis() },
                    .{ .role = .user, .content = ub, .timestamp = util_time.nowMillis() },
                };
                if (p.complete(&msgs, .{ .max_tokens = 100, .temperature = 0.3 })) |resp| {
                    var r = resp;
                    defer r.free(alloc);
                    if (r.content.len > 0 and r.content[0] == .text) {
                        llm_insights = alloc.dupe(u8, r.content[0].text) catch null;
                    }
                } else |_| {}
                alloc.free(ub);
            }
            alloc.free(sb);
        }
    }
    const insights: []const u8 = llm_insights orelse reflection.insights;
    defer if (llm_insights) |li| alloc.free(li);

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "reflection q={d} tools={d}", .{ window_queries.items.len, window_tools.* }) catch "reflection";
    const now = util_time.nowMillis();
    mem.store(.{
        .id = injection_mod.memoryId(insights, "reflection"),
        .mem_type = .feedback,
        .name = name,
        .description = @tagName(reflection.trigger),
        .content = insights,
        .access_count = 0,
        .created_at = now,
        .updated_at = now,
    }) catch {};
    logger.info("reflection: quality={d:.2} insights stored (llm={})", .{ reflection.quality_score, llm_insights != null });
    w.print("  [Reflection] {s}\n", .{insights}) catch {};

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
    live: ?*decision_trace.DecisionTrace,
    concern: []const u8,
    injected_count: usize,
    window_tools: u32,
    window_errors: u32,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
) !void {
    var fallback_trace: ?decision_trace.DecisionTrace = null;
    defer if (fallback_trace) |*t| t.deinit();

    // Prefer the live trace recorded by the agent loop; fall back to a
    // static 3-step construction when no query has run yet.
    const trace: *decision_trace.DecisionTrace = blk: {
        if (live) |t| break :blk t;
        fallback_trace = decision_trace.DecisionTrace.init(alloc, try alloc.dupe(u8, concern));
        const t: *decision_trace.DecisionTrace = &fallback_trace.?;

        const mem_conf: f64 = if (injected_count > 0) 0.8 else 0.3;
        try t.addStep(.{
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
        const tool_conf: f64 = if (window_tools == 0)
            0.9
        else
            1.0 - @as(f64, @floatFromInt(window_errors)) / @as(f64, @floatFromInt(window_tools));
        try t.addStep(.{
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
        try t.addStep(.{
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
        break :blk t;
    };
    trace.complete();

    const source: []const u8 = if (live != null) "live agent-loop trace" else "static fallback";
    try std.Io.Writer.print(w, "  Diagnosing ({s}, {d} steps)…\n", .{ source, trace.getSteps().len });

    var diag = self_diagnostic.SelfDiagnostic.init(alloc);
    const report = diag.diagnose(trace, concern) catch {
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

/// Semantic tier listing: /knowledge shows graph size and recent nodes.
fn printKnowledge(kg: ?*knowledge_graph.KnowledgeGraph, w: *std.Io.Writer) !void {
    if (kg == null) {
        try std.Io.Writer.writeAll(w, "  Knowledge graph unavailable (database disabled).\n\n");
        return;
    }
    const g: *knowledge_graph.KnowledgeGraph = kg.?;
    const total = g.nodeCount() catch 0;
    if (total == 0) {
        try std.Io.Writer.writeAll(w, "  Knowledge graph is empty — nodes are added when sessions extract memories.\n\n");
        return;
    }
    const rows = g.recentNodes(5) catch {
        try std.Io.Writer.writeAll(w, "  (failed to read knowledge graph)\n\n");
        return;
    };
    defer g.freeNodeRows(rows);
    try std.Io.Writer.print(w, "  Knowledge graph: {d} nodes. Most recent:\n", .{total});
    for (rows) |r| {
        const entity = r.entity[0..@min(r.entity.len, 60)];
        const src = r.source orelse "";
        try std.Io.Writer.print(w, "    #{d} [{s}] {s} (from {s})\n", .{ r.id, r.entity_type, entity, src });
    }
    try std.Io.Writer.writeAll(w, "\n");
}

/// Append one step to the live decision trace (all strings duped; the
/// trace frees them in deinit).
fn traceAddStep(
    t: *decision_trace.DecisionTrace,
    phase: decision_trace.DecisionPhase,
    confidence: f64,
    input: []const u8,
    output: []const u8,
    reasoning: []const u8,
    alloc: std.mem.Allocator,
) !void {
    try t.addStep(.{
        .step_id = @intCast(t.getSteps().len + 1),
        .phase = phase,
        .timestamp = util_time.nowMillis(),
        .input = try alloc.dupe(u8, input),
        .output = try alloc.dupe(u8, output),
        .reasoning = try alloc.dupe(u8, reasoning),
        .confidence = confidence,
        .duration_ms = 0,
        .alternatives = &.{},
        .dependencies = &.{},
    });
}

/// Streaming aggregation state: prints text deltas live while assembling a
/// CompleteResponse equivalent owned by the REPL (no DOM arena).
const StreamAgg = struct {
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    text: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(llm.provider.ToolUseBlock) = .empty,
    usage: llm.provider.Usage = .{ .input_tokens = 0, .output_tokens = 0 },
    stop_reason: llm.provider.CompleteResponse.StopReason = .end_turn,
    saw_error: ?llm.provider.ProviderError = null,

    fn deinit(self: *StreamAgg) void {
        self.text.deinit(self.alloc);
        // Tool strings are session-lifetime (freed with history); just drop the list.
        self.tools.deinit(self.alloc);
    }
};

fn streamCb(ctx_opaque: ?*anyopaque, event: llm.provider.StreamEvent) anyerror!void {
    const self: *StreamAgg = @ptrCast(@alignCast(ctx_opaque.?));
    switch (event) {
        .content_delta => |d| {
            // Live print: this is the whole point of streaming.
            try std.Io.Writer.writeAll(self.w, d);
            std.Io.File.Writer.flush(self.file_writer) catch {};
            try self.text.appendSlice(self.alloc, d);
        },
        .thinking_delta => {},
        .tool_call => |tu| {
            try std.Io.Writer.print(self.w, "\n  [calling tool: {s}]\n", .{tu.name});
            std.Io.File.Writer.flush(self.file_writer) catch {};
            try self.tools.append(self.alloc, .{
                .id = try self.alloc.dupe(u8, tu.id),
                .name = try self.alloc.dupe(u8, tu.name),
                .input = try dupeJsonValue(self.alloc, tu.input),
            });
            self.stop_reason = .tool_use;
        },
        .done => |u| {
            if (u) |uu| self.usage = uu;
        },
        .error_occurred => |e| self.saw_error = e,
    }
}

/// Stream the completion, printing deltas live; returns REPL-owned blocks.
fn streamComplete(
    prov: llm.Provider,
    history: []const llm.Message,
    opts: llm.provider.CompleteOptions,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    alloc: std.mem.Allocator,
) !llm.provider.CompleteResponse {
    var agg = StreamAgg{ .alloc = alloc, .w = w, .file_writer = file_writer };
    defer agg.deinit();

    try prov.stream(history, opts, @ptrCast(&agg), streamCb);
    if (agg.saw_error) |e| {
        // These dupes never made it into history — free them here.
        for (agg.tools.items) |*tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
            freeJsonValue(alloc, tu.input);
        }
        return e;
    }

    var blocks: std.ArrayList(llm.ContentBlock) = .empty;
    errdefer blocks.deinit(alloc);
    if (agg.text.items.len > 0) {
        const t = try alloc.dupe(u8, agg.text.items);
        try blocks.append(alloc, .{ .text = t });
    }
    for (agg.tools.items) |tu| {
        try blocks.append(alloc, .{ .tool_use = tu });
    }

    try std.Io.Writer.writeAll(w, "\n");
    return .{
        .content = try blocks.toOwnedSlice(alloc),
        .usage = agg.usage,
        .stop_reason = agg.stop_reason,
    };
}

/// Map an extracted fact type to a knowledge-graph entity type.
fn entityTypeForFact(f: extraction_mod.FactType) knowledge_graph.EntityType {
    return switch (f) {
        .user_preference => .concept,
        .technical_fact => .technology,
        .pattern_observed => .code_pattern,
        .error_solution => .custom,
        .project_context => .organization,
    };
}

/// Shared permission gate for the agent loop and /run.
/// deny → prints and returns false; allow → true; ask → interactive y/N,
/// except in auto mode where a reachable LLM classifier decides (with the
/// rule-based fallback of "allow" on classifier failure).
fn permissionGate(
    tool_def: *const registry.ToolDefinition,
    input: std.json.Value,
    mode: auth.PermissionMode,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
) !bool {
    const perm_ctx = registry.PermissionContext{
        .mode = mode,
        .allow_rules = switcher.settings.allow_rules,
        .deny_rules = switcher.settings.deny_rules,
        .ask_rules = switcher.settings.ask_rules,
        .provider = switcher.getProvider() catch null,
        .allocator = alloc,
    };
    var decision = auth.checkToolPermission(tool_def, input, &perm_ctx);

    // Auto mode: delegate ambiguous (ask) calls to the LLM classifier.
    if (mode == .auto and decision == .ask) {
        if (switcher.getProvider() catch null) |p| {
            var lc = classifier_mod.LLMClassifier.init(alloc, p);
            // Fail CLOSED: on classifier error fall back to asking the user
            // (fail-open silently allowed writes when the LLM was down).
            const cr = lc.classify(tool_def, input) catch classifier_mod.ClassifierResult{ .block = .{ .reason = "classifier unavailable — confirm manually" } };
            decision = switch (cr) {
                .allow => .{ .allow = {} },
                .block => |b| .{ .deny = .{ .message = b.reason } },
            };
            logger.info("classifier(auto): {s} -> {s}", .{ tool_def.name, switch (cr) {
                .allow => "allow",
                .block => "block",
            } });
        }
    }

    switch (decision) {
        .deny => |d| {
            try std.Io.Writer.print(w, "  [Permission denied: {s}]\n", .{d.message});
            try std.Io.File.Writer.flush(file_writer);
            return false;
        },
        .allow => return true,
        .ask => |a| {
            try std.Io.Writer.print(w, "  Tool {s}: {s}. Allow? [y/N]: ", .{ tool_def.name, a.message });
            try std.Io.File.Writer.flush(file_writer);

            // Allocating answer buffer: the old fixed 64-byte reader turned
            // a long pasted answer into "Cancelled" and left the tail of the
            // line polluting the next read.
            var ans_aw: std.Io.Writer.Allocating = .init(alloc);
            defer ans_aw.deinit();
            _ = std.Io.Reader.streamDelimiter(r, &ans_aw.writer, '\n') catch {
                try std.Io.Writer.writeAll(w, "\n  [Cancelled]\n");
                try std.Io.File.Writer.flush(file_writer);
                return false;
            };
            r.toss(1);
            const ans = std.mem.trim(u8, ans_aw.written(), " \t\r\n");
            if (!std.mem.eql(u8, ans, "y") and !std.mem.eql(u8, ans, "Y")) {
                try std.Io.Writer.writeAll(w, "  [Denied by user]\n");
                try std.Io.File.Writer.flush(file_writer);
                return false;
            }
            return true;
        },
    }
}

fn isFileModifyingTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "FileWrite") or
        std.mem.eql(u8, tool_name, "FileEdit") or
        std.mem.eql(u8, tool_name, "Write") or
        std.mem.eql(u8, tool_name, "Edit");
}

/// Execute a single tool call and record result.
/// A tool_use that passed the permission gate in phase 1 and is queued for
/// execution (possibly in parallel) in phase 2.
const PreparedCall = struct {
    call: orchestration_mod.ToolCall,
    snap_id: ?[16]u8,
};

/// Phase 2 tail: print the outcome, truncate oversized output, record in the
/// operation log, append the tool_result block. Returns true on tool error.
fn finishToolCall(
    p: PreparedCall,
    result: registry.ToolResult,
    alloc: std.mem.Allocator,
    log: *op_log.OperationLog,
    result_blocks: *std.ArrayList(llm.ContentBlock),
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
) !bool {
    logger.info("Tool execute: {s}", .{p.call.tool_name});

    // Truncate large outputs for history — must dupe before freeing
    const max_result = 4096;
    const raw = result.output;
    const truncated = raw.len > max_result;

    try std.Io.Writer.print(w, "  [{s}: {s}]\n", .{
        p.call.tool_name,
        if (raw.len > 200) raw[0..200] else raw,
    });

    const content_for_history: []const u8 = if (truncated)
        try alloc.dupe(u8, raw[0..max_result])
    else
        raw; // ownership transfers, no dupe needed

    try result_blocks.append(alloc, .{ .tool_result = .{
        .tool_use_id = p.call.tool_use_id,
        .content = content_for_history,
        .is_error = result.is_error,
    } });
    _ = log.record(p.call.tool_name, "executed", result.output, p.snap_id, p.snap_id != null) catch {};
    if (truncated) {
        // History owns the dupe; the original (error or not) is spent.
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
fn maybeCompact(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer, file_writer: *std.Io.File.Writer) void {
    const current_tokens = estimateHistoryTokens(history.items);
    if (!compaction.needsCompaction(current_tokens, MAX_CONTEXT_TOKENS)) return;

    compactHistoryImpl(history, alloc);
    std.Io.Writer.print(w, "  [Context auto-compacted: {d} messages remaining]\n", .{history.items.len}) catch {};
    std.Io.File.Writer.flush(file_writer) catch {};
}

/// Force compact history (used by /compact command).
fn compactHistory(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    if (history.items.len <= 2) {
        try std.Io.Writer.writeAll(w, "  Nothing to compact.\n\n");
        return;
    }
    const before = history.items.len;
    compactHistoryImpl(history, alloc);
    const est = estimateHistoryTokens(history.items);
    try std.Io.Writer.print(w, "  Compacted: {d} → {d} messages (~{d} tokens)\n\n", .{ before, history.items.len, est });
}

/// Core compaction: keep system prompt + recent 61.8% of messages.
fn compactHistoryImpl(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) void {
    if (history.items.len <= 2) return;

    // Keep system prompt (index 0) and recent messages up to phi target
    const total = history.items.len - 1; // exclude system prompt
    const target = compaction.condensationTarget(total);
    if (target >= total) return;

    // Remove the oldest non-system messages down to the phi target,
    // freeing their content — previously every removal leaked.
    const new_len = 1 + target; // system + remaining
    while (history.items.len > new_len) {
        const msg = history.orderedRemove(1);
        freeMessage(msg, alloc);
    }
}

/// Clear history, keep only system prompt.
/// Free one history message's content blocks (strings + JSON trees).
fn freeMessage(msg: llm.Message, alloc: std.mem.Allocator) void {
    freeContentBlocks(alloc, msg.content);
}

fn clearHistory(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) void {
    while (history.items.len > 1) {
        const msg = history.orderedRemove(1);
        freeMessage(msg, alloc);
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
fn undoLastExchange(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
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
            const msg = history.pop().?;
            freeMessage(msg, alloc);
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
                const msg = history.pop().?;
                freeMessage(msg, alloc);
                removed += 1;
            }
        }
    }

    // Remove trailing user message (the original prompt)
    if (history.items.len > 1) {
        const last = history.items[history.items.len - 1];
        if (last.role == .user) {
            const msg = history.pop().?;
            freeMessage(msg, alloc);
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

fn autoSaveSettings(w: *std.Io.Writer, file_writer: *std.Io.File.Writer, switcher: *ModelSwitcher, alloc: std.mem.Allocator, io: std.Io) void {
    config_mod.saveSettings(&switcher.settings, alloc, io) catch |err| {
        w.print("  保存失败: {any}\n", .{err}) catch {};
        return;
    };
    w.writeAll("  ✓ 已自动保存\n") catch {};
    std.Io.File.Writer.flush(file_writer) catch {};
}

/// Arrow-key driven configuration menu. Every change auto-saves to
/// ~/.config/ziv/settings.json immediately.
fn runConfigMenu(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    while (true) {
        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        var b3: [64]u8 = undefined;
        var b4: [64]u8 = undefined;
        var b5: [64]u8 = undefined;
        const items = [_][]const u8{
            "API Keys",
            try_std_fmt(&b1, "默认模型: {s}", .{switcher.settings.default_model}),
            try_std_fmt(&b2, "最大 tokens: {d}", .{switcher.settings.max_tokens}),
            try_std_fmt(&b3, "权限模式: {s}", .{auth.modeLabel(switcher.settings.permission_mode)}),
            try_std_fmt(&b4, "检查点: {s}", .{if (switcher.settings.checkpointing_enabled) "开" else "关"}),
            try_std_fmt(&b5, "系统提示词: {s}", .{if (switcher.settings.system_prompt != null) "(自定义)" else "(默认)"}),
            "退出",
        };
        const picked = (menu.select(w, r, file_writer, "=== Ziv 配置 ===", &items, 0) catch break) orelse break;

        switch (picked) {
            0 => try runApiKeysMenu(w, r, file_writer, switcher, alloc, io),
            1 => try configPickModel(w, r, file_writer, switcher, alloc, io),
            2 => {
                var vbuf: [32]u8 = undefined;
                const val = menu.readLine(r, w, file_writer, "  最大 tokens (1-128000): ", &vbuf) catch continue;
                if (val.len == 0) continue;
                const mt = std.fmt.parseInt(u32, val, 10) catch {
                    try std.Io.Writer.writeAll(w, "  无效数字\n");
                    continue;
                };
                if (mt > 0 and mt <= 128000) {
                    switcher.settings.max_tokens = mt;
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                } else try std.Io.Writer.writeAll(w, "  超出范围\n");
            },
            3 => {
                const mode_items = [_][]const u8{ "Default — 危险操作询问", "Accept Edits — 自动接受编辑", "Plan — 只读", "Bypass — 跳过检查", "Don't Ask — 自动拒绝", "Auto — LLM 分类" };
                const mode_map = [_]auth.PermissionMode{ .default, .accept_edits, .plan, .bypass, .dont_ask, .auto };
                const mp = (menu.select(w, r, file_writer, "选择权限模式:", &mode_items, 0) catch continue) orelse continue;
                switcher.settings.permission_mode = mode_map[mp];
                autoSaveSettings(w, file_writer, switcher, alloc, io);
            },
            4 => {
                switcher.settings.checkpointing_enabled = !switcher.settings.checkpointing_enabled;
                autoSaveSettings(w, file_writer, switcher, alloc, io);
            },
            5 => {
                const sp_items = [_][]const u8{ "输入自定义提示词", "恢复默认", "返回" };
                const sp = (menu.select(w, r, file_writer, "系统提示词:", &sp_items, 0) catch continue) orelse continue;
                if (sp == 0) {
                    var pbuf: [4096]u8 = undefined;
                    const pval = menu.readLine(r, w, file_writer, "  提示词内容: ", &pbuf) catch continue;
                    if (pval.len > 0) {
                        switcher.settings.system_prompt = try alloc.dupe(u8, pval);
                        autoSaveSettings(w, file_writer, switcher, alloc, io);
                    }
                } else if (sp == 1) {
                    switcher.settings.system_prompt = null;
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                }
            },
            6 => break,
            else => {},
        }
    }
    try std.Io.Writer.writeAll(w, "\n");
}

fn try_std_fmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch fmt;
}

/// Shared custom-model entry: read the name, and when it is unrecognized
/// while a compatible gateway is configured, ask which backend serves it.
fn promptCustomModel(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
) !?[]const u8 {
    var vbuf: [128]u8 = undefined;
    const val = menu.readLine(r, w, file_writer, "  模型名（如 glm-4.6 / deepseek-v3）: ", &vbuf) catch return null;
    if (val.len == 0) return null;
    // vbuf is a stack buffer — dupe BEFORE any further calls, otherwise the
    // returned slice dangles (first bytes got clobbered: "glm-5.3" -> " lm-5.3").
    const owned = try alloc.dupe(u8, val);

    if (llm.detectBackend(val) == .ollama and (switcher.settings.api_keys.openai != null or switcher.settings.api_keys.anthropic != null)) {
        const be_items = [_][]const u8{ "OpenAI 兼容接入（用已配的 OpenAI Key/网关）", "Anthropic 兼容接入（用已配的 Anthropic Key/网关）", "Ollama 本地" };
        const be = menu.select(w, r, file_writer, "该模型走哪个后端？", &be_items, 0) catch null;
        if (be) |choice| {
            switcher.settings.default_backend = switch (choice) {
                0 => "openai",
                1 => "claude",
                else => "ollama",
            };
        }
    }
    return owned;
}

/// Default-model picker shared by /config: known models + custom entry.
fn configPickModel(w: *std.Io.Writer, r: *std.Io.Reader, file_writer: *std.Io.File.Writer, switcher: *ModelSwitcher, alloc: std.mem.Allocator, io: std.Io) !void {
    var labels: [llm.KNOWN_MODELS.len + 2][]const u8 = undefined;
    for (&llm.KNOWN_MODELS, 0..) |entry, i| {
        const marker: []const u8 = if (std.mem.eql(u8, entry.name, switcher.settings.default_model)) " ●" else "";
        labels[i] = try std.fmt.allocPrint(alloc, "{s:<20} {s}{s}", .{ entry.name, entry.description, marker });
    }
    labels[llm.KNOWN_MODELS.len] = "自定义…（手动输入）";
    labels[llm.KNOWN_MODELS.len + 1] = "取消";
    defer for (labels[0..llm.KNOWN_MODELS.len]) |l| alloc.free(l);

    const picked = (menu.select(w, r, file_writer, "选择默认模型:", &labels, 0) catch return) orelse return;
    if (picked == llm.KNOWN_MODELS.len + 1) return;
    const name: []const u8 = if (picked == llm.KNOWN_MODELS.len) blk: {
        break :blk (try promptCustomModel(w, r, file_writer, switcher, alloc)) orelse return;
    } else llm.KNOWN_MODELS[picked].name;

    // Persist AND switch the live session — previously this only wrote the
    // settings file, so nothing changed until a restart (and it looked like
    // "configuring the model did nothing").
    switcher.settings.default_model = try alloc.dupe(u8, name);
    switcher.switchModel(name) catch |err| {
        autoSaveSettings(w, file_writer, switcher, alloc, io);
        if (err == error.MissingApiKey) {
            try std.Io.Writer.print(w, "  已保存默认模型 {s}，但该后端未配 API key（当前会话暂未切换）。\n  请先在「API Keys」里配置，或 /quit 重启后使用。\n", .{name});
        } else {
            try std.Io.Writer.print(w, "  已保存，但切换失败: {any}\n", .{err});
        }
        try std.Io.File.Writer.flush(file_writer);
        return;
    };
    autoSaveSettings(w, file_writer, switcher, alloc, io);
    try std.Io.Writer.print(w, "  ✓ 已切换并保存: {s} ({s})\n", .{ switcher.modelName(), switcher.backendLabel() });
    try std.Io.File.Writer.flush(file_writer);
}

/// Fetch the model list a configured endpoint exposes.
/// OpenAI-compatible: GET {base}/models (Bearer); Anthropic: GET {base}/v1/models
/// (x-api-key); Ollama: GET {host}/api/tags. Caller frees each name + slice.
fn fetchGatewayModels(alloc: std.mem.Allocator, io: std.Io, switcher: *ModelSwitcher, backend: llm.BackendType) ![][]const u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    var auth_buf: [512]u8 = undefined;
    const url: []const u8, const key: ?[]const u8 = switch (backend) {
        .openai => .{
            std.fmt.bufPrint(&url_buf, "{s}/models", .{switcher.settings.api_keys.openai_base_url orelse "https://api.openai.com/v1"}) catch return error.BadURL,
            switcher.settings.api_keys.openai,
        },
        .claude => .{
            std.fmt.bufPrint(&url_buf, "{s}/v1/models", .{switcher.settings.api_keys.anthropic_base_url orelse "https://api.anthropic.com"}) catch return error.BadURL,
            switcher.settings.api_keys.anthropic,
        },
        .ollama => .{
            std.fmt.bufPrint(&url_buf, "{s}/api/tags", .{switcher.settings.api_keys.ollama_host}) catch return error.BadURL,
            null,
        },
    };

    const uri = try std.Uri.parse(url);
    var auth_header: []const u8 = "";
    var auth_val: std.http.Client.Request.Headers.Value = .default;
    if (backend == .openai and key != null) {
        auth_header = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key.?});
        auth_val = .{ .override = auth_header };
    }
    var extra: [1]std.http.Header = undefined;
    var n_extra: usize = 0;
    if (backend == .claude and key != null) {
        extra[0] = .{ .name = "x-api-key", .value = key.? };
        n_extra = 1;
    }

    var req = try client.request(.GET, uri, .{
        .headers = .{ .authorization = auth_val },
        .extra_headers = extra[0..n_extra],
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status.class() != .success) return error.FetchFailed;

    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = try readHttpBodyCapped(reader, alloc);
    defer alloc.free(body);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return error.BadJSON;

    // openai/claude: {data:[{id:...}]}; ollama: {models:[{name:...}]}
    const arr = if (parsed.object.get("data")) |d| d.array.items else if (parsed.object.get("models")) |m| m.array.items else return error.BadJSON;
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    for (arr) |item| {
        const id = item.object.get("id") orelse item.object.get("name") orelse continue;
        if (id != .string) continue;
        try names.append(alloc, try alloc.dupe(u8, id.string));
    }
    return names.toOwnedSlice(alloc);
}

fn readHttpBodyCapped(reader: *std.Io.Reader, alloc: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var chunk: [8192]u8 = undefined;
    while (list.items.len < 4 * 1024 * 1024) {
        const n = reader.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try list.appendSlice(alloc, chunk[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

/// After configuring an endpoint, offer the models it actually serves.
fn offerGatewayModels(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    io: std.Io,
    backend: llm.BackendType,
) !void {
    const names = fetchGatewayModels(alloc, io, switcher, backend) catch return;
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    if (names.len == 0) return;

    try std.Io.Writer.print(w, "\n  网关上发现 {d} 个模型。\n", .{names.len});
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(alloc);
    for (names) |n| try labels.append(alloc, n);
    try labels.append(alloc, "跳过");
    const picked = (menu.select(w, r, file_writer, "选一个作为当前模型？", labels.items, 0) catch return) orelse return;
    if (picked >= names.len) return;

    const model = names[picked];
    switcher.settings.default_model = try alloc.dupe(u8, model);
    if (llm.detectBackend(model) == .ollama and backend != .ollama) {
        switcher.settings.default_backend = switch (backend) {
            .openai => "openai",
            .claude => "claude",
            .ollama => null,
        };
    }
    switcher.switchModel(model) catch {};
    autoSaveSettings(w, file_writer, switcher, alloc, io);
    try std.Io.Writer.print(w, "  ✓ 已切换: {s}\n", .{switcher.modelName()});
}

fn runApiKeysMenu(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    while (true) {
        var b1: [80]u8 = undefined;
        var b2: [80]u8 = undefined;
        const items = [_][]const u8{
            try_std_fmt(&b1, "OpenAI 接入（Key + 网关地址）: {s}", .{if (switcher.settings.api_keys.openai) |k| maskKey(k) else "(未配置)"}),
            try_std_fmt(&b2, "Anthropic 接入（Key + 网关地址）: {s}", .{if (switcher.settings.api_keys.anthropic) |k| maskKey(k) else "(未配置)"}),
            "Brave Key（网络搜索）",
            "Ollama Host（本地模型）",
            "返回",
        };
        const picked = (menu.select(w, r, file_writer, "=== 模型接入配置 ===", &items, 0) catch break) orelse break;
        switch (picked) {
            0, 1 => {
                const is_openai = picked == 0;
                const key_prompt: []const u8 = if (is_openai) "  API Key: " else "  API Key: ";
                var kbuf: [256]u8 = undefined;
                const key = menu.readLine(r, w, file_writer, key_prompt, &kbuf) catch continue;
                // Guard: typing menu-ish escape hatches ("q", "/quit") at the
                // value prompt used to store them AS the key — producing
                // confusing 401s on the next LLM call.
                if (std.mem.eql(u8, key, "q") or std.mem.eql(u8, key, "/quit") or std.mem.indexOfScalar(u8, key, ' ') != null) {
                    try std.Io.Writer.writeAll(w, "  (忽略：疑似误输入的命令/含空格，配置未更改)\n");
                    continue;
                }
                var ubuf: [256]u8 = undefined;
                const url_prompt: []const u8 = if (is_openai)
                    "  Base URL（兼容网关填这里，回车=官方，-=清除）: "
                else
                    "  Base URL（兼容网关填这里，回车=官方，-=清除）: ";
                const url = menu.readLine(r, w, file_writer, url_prompt, &ubuf) catch continue;

                if (key.len > 0) {
                    const kd = try alloc.dupe(u8, key);
                    if (is_openai) switcher.settings.api_keys.openai = kd else switcher.settings.api_keys.anthropic = kd;
                }
                if (url.len > 0) {
                    const ud: ?[]const u8 = if (std.mem.eql(u8, url, "-")) null else try alloc.dupe(u8, url);
                    if (is_openai) switcher.settings.api_keys.openai_base_url = ud else switcher.settings.api_keys.anthropic_base_url = ud;
                }
                // Drop cached providers so the new key/URL takes effect now.
                if (switcher.openai_provider) |*p| {
                    p.deinit();
                    switcher.openai_provider = null;
                }
                if (switcher.claude_provider) |*p| {
                    p.deinit();
                    switcher.claude_provider = null;
                }
                autoSaveSettings(w, file_writer, switcher, alloc, io);
                try offerGatewayModels(w, r, file_writer, switcher, alloc, io, if (is_openai) .openai else .claude);

                // Routing hint: if the current model would NOT use this
                // gateway (name detection sends it to Ollama), offer to pin
                // the backend so the configuration actually takes effect.
                const want: llm.BackendType = if (is_openai) .openai else .claude;
                if (switcher.backend != want and switcher.backend == .ollama) {
                    const pin_items = [_][]const u8{ "是，走此接入", "否" };
                    try std.Io.Writer.print(w, "\n  当前模型 {s} 被按名字路由到了 Ollama。\n", .{switcher.modelName()});
                    const pin = (menu.select(w, r, file_writer, "让它走刚配置的接入吗？", &pin_items, 0) catch continue) orelse continue;
                    if (pin == 0) {
                        switcher.settings.default_backend = if (is_openai) "openai" else "claude";
                        autoSaveSettings(w, file_writer, switcher, alloc, io);
                        switcher.switchModel(switcher.modelName()) catch {};
                    }
                }
            },
            2 => {
                var vbuf: [256]u8 = undefined;
                const val = menu.readLine(r, w, file_writer, "  Brave API Key: ", &vbuf) catch continue;
                if (val.len > 0) switcher.settings.api_keys.brave_api_key = try alloc.dupe(u8, val);
                autoSaveSettings(w, file_writer, switcher, alloc, io);
            },
            3 => {
                var vbuf: [256]u8 = undefined;
                const val = menu.readLine(r, w, file_writer, "  Ollama Host: ", &vbuf) catch continue;
                if (val.len > 0) switcher.settings.api_keys.ollama_host = try alloc.dupe(u8, val);
                // The provider caches base_url at init — drop it so the new
                // host takes effect this session, then list local models.
                if (switcher.ollama_provider) |*p| {
                    p.deinit();
                    switcher.ollama_provider = null;
                }
                autoSaveSettings(w, file_writer, switcher, alloc, io);
                try offerGatewayModels(w, r, file_writer, switcher, alloc, io, .ollama);
            },
            else => break,
        }
    }
    try std.Io.Writer.writeAll(w, "\n");
}
var mask_buf: [16]u8 = undefined;

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

/// Interactive model picker: arrow keys + Enter to switch at runtime.
fn runModelPicker(w: *std.Io.Writer, r: *std.Io.Reader, file_writer: *std.Io.File.Writer, switcher: *ModelSwitcher, io: std.Io) !void {
    var labels: [llm.KNOWN_MODELS.len + 2][]const u8 = undefined;
    for (&llm.KNOWN_MODELS, 0..) |entry, i| {
        const marker: []const u8 = if (std.mem.eql(u8, entry.name, switcher.modelName())) " ●" else "";
        labels[i] = try std.fmt.allocPrint(std.heap.smp_allocator, "{s:<20} {s}{s}", .{ entry.name, entry.description, marker });
    }
    labels[llm.KNOWN_MODELS.len] = "自定义…（输入模型名，兼容网关可用）";
    labels[llm.KNOWN_MODELS.len + 1] = "取消 (q)";
    defer for (labels[0..llm.KNOWN_MODELS.len]) |l| std.heap.smp_allocator.free(l);

    const picked = menu.select(w, r, file_writer, "选择模型 (Enter 切换):", &labels, 0) catch {
        try printModelInfo(w, switcher);
        return;
    } orelse {
        try printModelInfo(w, switcher); // cancelled — show the table
        return;
    };

    if (picked == llm.KNOWN_MODELS.len + 1) return; // 取消
    const name: []const u8 = if (picked == llm.KNOWN_MODELS.len) blk: {
        break :blk (try promptCustomModel(w, r, file_writer, switcher, std.heap.smp_allocator)) orelse return;
    } else llm.KNOWN_MODELS[picked].name;
    switcher.switchModel(name) catch |err| {
        if (err == error.MissingApiKey) {
            const be: llm.BackendType = if (picked < llm.KNOWN_MODELS.len) llm.KNOWN_MODELS[picked].backend else switcher.effectiveBackend(name);
            try std.Io.Writer.print(w, "  Error: API key not configured for {s}.\n  Use /config to set keys.\n\n", .{be.label()});
        } else {
            try std.Io.Writer.print(w, "  Error switching model: {}\n\n", .{err});
        }
        return;
    };
    switcher.settings.default_model = name;
    config_mod.saveSettings(&switcher.settings, std.heap.smp_allocator, io) catch {};
    try std.Io.Writer.print(w, "  ✓ 已切换: {s} ({s})\n\n", .{ switcher.modelName(), switcher.backendLabel() });
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
        \\  /knowledge         Browse the knowledge graph (semantic tier)
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

test "effectiveBackend priority: table > prefixes > explicit override > fallback" {
    const s1 = config_mod.Settings{};
    var sw1 = ModelSwitcher.init(s1, undefined);
    // 1) Table entries are authoritative even with an override set.
    sw1.settings.default_backend = "openai";
    try std.testing.expect(sw1.effectiveBackend("claude-sonnet-4-6") == .claude);
    try std.testing.expect(sw1.effectiveBackend("llama3.2") == .ollama);
    // 2) Recognizable prefix beats the override.
    try std.testing.expect(sw1.effectiveBackend("gpt-5-turbo") == .openai);
    try std.testing.expect(sw1.effectiveBackend("claude-future-model") == .claude);
    // 3) Unrecognized name + override -> the gateway backend.
    try std.testing.expect(sw1.effectiveBackend("glm-4.6") == .openai);
    // 4) Unrecognized name, no override -> Ollama fallback.
    sw1.settings.default_backend = null;
    try std.testing.expect(sw1.effectiveBackend("glm-4.6") == .ollama);
}
