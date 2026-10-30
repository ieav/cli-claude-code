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
const skills_mod = @import("skills/mod.zig");
const mcp_mod = @import("mcp/mod.zig");
const registry = @import("tools/registry.zig");
const denial_tracker_mod = @import("tools/denial_tracker.zig");
const version_mod = @import("util/version.zig");
const op_log = @import("checkpoint/op_log.zig");
const file_history = @import("checkpoint/file_history.zig");
const rollback_mod = @import("checkpoint/rollback.zig");
const llm = @import("llm/mod.zig");
const compaction = @import("llm/compaction.zig");
const config_mod = @import("config.zig");
const util_time = @import("util/time.zig");
const file_cache_mod = @import("util/file_cache.zig");
const system_prompt_mod = @import("system_prompt.zig");
const logger = @import("util/log.zig");
const fs_ops = @import("util/fs_ops.zig");
const memory_mod = @import("memory/mod.zig");
const injection_mod = @import("memory/injection.zig");
const extraction_mod = @import("memory/extraction.zig");
const reflection_mod = @import("memory/reflection.zig");
const database_mod = @import("storage/database.zig");
const math_mod = @import("math/mod.zig");
const embedding_mod = @import("util/embedding.zig");
const tokens_mod = @import("util/tokens.zig");
const task_mod = @import("task/mod.zig");
const agent_dispatch = @import("tools/agent_dispatch.zig");


const knowledge_search = @import("knowledge/search.zig");
const knowledge_graph = @import("knowledge/graph.zig");
const researcher_mod = @import("research/optimization_researcher.zig");
const env = @import("util/env.zig");
const format_mod = @import("util/format.zig");
const self_diagnostic = @import("runtime/self_diagnostic.zig");
const decision_trace = @import("runtime/decision_trace.zig");
const error_handler = @import("runtime/error_handler.zig");
const allocator = std.heap.smp_allocator;

const MAX_AGENT_ITERATIONS: usize = 50;
const MAX_CONTEXT_TOKENS: u32 = 128_000;

/// Baseline fingerprint of all settings files, refreshed by (a) startup,
/// (b) every own-save (autoSaveSettings, /mode, model picker). When a prompt
/// observes a different fingerprint, the file was edited externally → reload.
var settings_fp_baseline: u64 = 0;

/// Active model state — holds the current model name and the provider instance.
const ModelSwitcher = struct {
    model_name_buf: [64]u8 = undefined,
    model_name_len: usize = 0,
    backend: llm.BackendType,
    io: std.Io,
    openai_provider: ?llm.OpenAIProvider = null,
    claude_provider: ?llm.ClaudeProvider = null,
    ollama_provider: ?llm.OllamaProvider = null,
    /// A provider retired by a model switch but NOT deinit'd yet: a
    /// detached reflection worker (3 s deadline abandon) may still be
    /// running a request on it — deinit-ing in place was a use-after-free
    /// on /model switches. Parked here and freed at switcher deinit
    /// (process exit). At most one detached worker exists at a time, so
    /// one slot suffices.
    retired: ?RetiredProvider = null,
    settings: config_mod.Settings,

    const RetiredProvider = union(enum) {
        openai: llm.OpenAIProvider,
        claude: llm.ClaudeProvider,
        ollama: llm.OllamaProvider,
    };

    const Self = @This();

    pub fn modelName(self: *const Self) []const u8 {
        return self.model_name_buf[0..self.model_name_len];
    }

    /// Park the current provider of `backend` into the retired slot instead
    /// of deinit-ing it (the slot is nulled either way, so getProvider
    /// rebuilds with the new model name — semantics unchanged).
    fn retireProvider(self: *Self, backend: llm.BackendType) void {
        if (self.retired != null) self.freeRetired(); // previous retiree must die now
        switch (backend) {
            .openai => if (self.openai_provider) |p| {
                self.retired = .{ .openai = p };
                self.openai_provider = null;
            },
            .claude => if (self.claude_provider) |p| {
                self.retired = .{ .claude = p };
                self.claude_provider = null;
            },
            .ollama => if (self.ollama_provider) |p| {
                self.retired = .{ .ollama = p };
                self.ollama_provider = null;
            },
        }
    }

    fn freeRetired(self: *Self) void {
        if (self.retired) |*r| {
            switch (r.*) {
                .openai => |*p| p.deinit(),
                .claude => |*p| p.deinit(),
                .ollama => |*p| p.deinit(),
            }
            self.retired = null;
        }
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
        self.freeRetired();
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

        // Park the old provider of the same backend type in `retired`
        // (deinit-in-place was a UAF for a detached reflection worker
        // still mid-request on it; see retireProvider).
        self.retireProvider(new_backend);

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
    const settings = config_mod.loadSettings(allocator, io) catch config_mod.Settings{};

    // Initialize model switcher
    var switcher = ModelSwitcher.init(settings, io);
    defer switcher.deinit();

    // Session state
    var current_mode: auth.PermissionMode = switcher.settings.permission_mode;
    settings_fp_baseline = config_mod.settingsFingerprint(allocator, io);
    var log = op_log.OperationLog.init(allocator);
    defer log.deinit();
    // Process-wide FileRead cache (repeat reads of unchanged files skip IO
    // and re-formatting); freshness is validated per read via stat.
    file_cache_mod.globalInit(allocator);
    defer file_cache_mod.deinitGlobal();
    var fhist = file_history.FileHistoryState.init(allocator, try allocator.dupe(u8, ".ziv/checkpoints"));
    // The /config snapshot cap used to be write-only — the state hardcoded
    // 100 and nothing read the setting.
    fhist.max_snapshots = switcher.settings.max_snapshots;
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

    // MCP (T3/T4/M6): mcp.json config + live stdio sessions. Tools are
    // bridged into the runtime registry as mcp__<server>__<tool> on connect.
    var mcp_cfg = mcp_mod.config.McpConfig.init(allocator, io);
    defer mcp_cfg.deinit();
    mcp_cfg.load();
    var mcp_sessions = std.ArrayList(*mcp_mod.session.McpSession).empty;
    defer {
        for (mcp_sessions.items) |sess| {
            sess.disconnect(io);
            sess.deinit();
            allocator.destroy(sess);
        }
        mcp_sessions.deinit(allocator);
    }

    // Skills (T7/T8): SKILL.md packs from ~/.config/ziv/skills + ./.ziv/skills.
    var skill_loader = skills_mod.loader.SkillLoader.init(allocator, io);
    defer skill_loader.deinit();
    skill_loader.load();
    if (skill_loader.skills.items.len > 0) {
        logger.info("skills: {d} loaded", .{skill_loader.skills.items.len});
    }

    // Add system prompt as first message, appending cross-session memories
    // recovered from .ziv/memory.db (most recent first, token-budgeted).
    // The runtime build embeds the current date/time so date questions don't
    // cost a Bash round trip; on build failure fall back to the static prompt.
    var sys_prompt_owned = system_prompt_mod.buildSystemPrompt(allocator, switcher.settings.system_prompt) catch null;
    defer if (sys_prompt_owned) |sp| allocator.free(sp);
    var sys_prompt: []const u8 = sys_prompt_owned orelse system_prompt_mod.default_system_prompt;
    // What the baked history[0] prompt was built from — /config and the
    // settings hot reload compare against it to know when to rebuild.
    var applied_prompt_setting: ?[]const u8 = switcher.settings.system_prompt;
    var memory_block: ?[]u8 = null;
    defer if (memory_block) |mb| allocator.free(mb);
    // T1.3 topic-drift re-anchor state: baseline = the topic vector the
    // CURRENT memory block was ranked for (adopted from the first 3 user
    // turns); a live-topic cosine below 1/φ (≈0.618) re-ranks the block
    // around the new topic — at most once per session (prompt-cache
    // friendly) and only when a block exists to re-rank.
    var mem_topic_baseline: ?[]f32 = null;
    defer if (mem_topic_baseline) |v| allocator.free(v);
    var mem_block_rebuilt = false;
    // T8: plan-file anchor — .ziv/plan.md summarized into the system
    // prompt (own 150-token budget), refreshed by content fingerprint.
    var plan_block: ?[]u8 = null;
    defer if (plan_block) |pb| allocator.free(pb);
    var plan_raw_last: ?[]u8 = null;
    defer if (plan_raw_last) |pr| allocator.free(pr);
    // T4.2: key-facts block distilled by every compaction — survives
    // truncation in the system prompt (≤200 tokens).
    var facts_block: ?[]u8 = null;
    defer if (facts_block) |f| allocator.free(f);
    // T3.1: the task pool (e-bounded workers) — serves the subagent fan-out
    // (T6.4). Started eagerly, joined on every exit path; queued work at
    // exit completes or dies with the process (by design).
    var pool: task_mod.ThreadPool = task_mod.ThreadPool.init(allocator) catch {
        logger.warning("thread pool unavailable — subagents will run inline", .{});
        unreachable; // init only allocates a struct; failure = OOM
    };
    pool.start() catch {
        logger.warning("thread pool start failed — subagents will run inline", .{});
    };
    defer pool.deinit();


    if (mem_sys) |*ms| {
        // Candidate pool of 200, not 20: the e-decay + cosine ranking only
        // reorders what SQL already returned — with LIMIT 20, older
        // high-value memories were evicted before ranking ever saw them.
        if (ms.episodic_mem.retrieveRecent(200) catch null) |entries| {
            defer ms.episodic_mem.freeEntries(entries);
            // T1.2: scale the manual budget by the active model's context
            // window (8K→x0.66 … 128K→x1.66) — small local models keep a
            // lean workspace, large contexts get recall headroom.
            const ctx_est = llm.provider.contextEstimate(switcher.modelName(), switcher.backend);
            const eff_budget = injection_mod.effectiveBudget(switcher.settings.memory_budget_tokens, ctx_est);
            if (injection_mod.buildMemoryBlock(allocator, entries, eff_budget) catch null) |block| {
                memory_block = block.text;
                // Truthful count: entries that FIT the budget, not the
                // candidate pool size (the old count over-reported when
                // truncation hit).
                injected_count = block.included;
                logger.info("memory: injected {d} entries into system prompt", .{block.included});
            }
        }
    }
    // Skill manifest: one line per skill, budgeted (bodies load on invoke).
    var skill_manifest: ?[]u8 = null;
    defer if (skill_manifest) |m| allocator.free(m);
    skill_manifest = skill_loader.buildManifest(allocator, 300) catch null;
    const sys_block_count: usize = 1 + @as(usize, @intFromBool(memory_block != null)) + @as(usize, @intFromBool(skill_manifest != null));
    var sys_blocks = try allocator.alloc(llm.ContentBlock, sys_block_count);
    sys_blocks[0] = .{ .text = sys_prompt };
    var sys_i: usize = 1;
    if (memory_block) |mb| {
        sys_blocks[sys_i] = .{ .text = mb };
        sys_i += 1;
    }
    if (skill_manifest) |sm| sys_blocks[sys_i] = .{ .text = sm };
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
    // Arm the π×10min timer from session START — it used to stay 0 until
    // the first successful reflection, so short sessions (<10 queries)
    // never got a time-based trigger.
    reflector.last_reflection_at.store(util_time.nowMillis(), .monotonic);
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

    // AskUserQuestion: hand the stub the live REPL reader/writer so "ask
    // the user" actually asks (it used to return "(Awaiting user response)"
    // and the model kept going on a fabricated answer). Attached before any
    // defs cache is built.
    var ask_ctx = AskUserCtx{ .r = r, .w = w, .file_writer = &file_writer };
    for (reg.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.def.name, "AskUserQuestion")) {
            entry.def.execute_ctx_fn = askUserExecute;
            entry.def.execute_ctx = @ptrCast(&ask_ctx);
        }

    // T6.3: register the parallel-subagent dispatch tool. ctx borrows
    // stable references (model_name_buf updates in place on hot switches;
    // retired settings slices are never freed, so key snapshots stay
    // readable) — workers build their OWN provider per job from these.
    var dispatch_ctx = agent_dispatch.DispatchCtx{
        .alloc = allocator,
        .io = io,
        .tools = &reg,
        .pool = &pool,
        .backend = switcher.backend,
        .model = switcher.modelName(),
        .api_key = switch (switcher.backend) {
            .openai => switcher.settings.api_keys.openai,
            .claude => switcher.settings.api_keys.anthropic,
            .ollama => null,
        },
        .base_url = switch (switcher.backend) {
            .openai => switcher.settings.api_keys.openai_base_url,
            .claude => switcher.settings.api_keys.anthropic_base_url,
            .ollama => null,
        },
        .ollama_host = switcher.settings.api_keys.ollama_host,
    };
    reg.registerDynamic(
        "agent",
        "Run 1-3 focused read-only subagents in parallel. Each gets its own context and the read-only tools, then reports back. Use for independent research or verification subtasks (e.g. 'check X in the codebase', 'verify the failing paths'), NOT for sequential work.",
        "{\"type\":\"object\",\"properties\":{\"tasks\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"1-3 self-contained task descriptions\"}},\"required\":[\"tasks\"]}",
        agent_dispatch.executeWithCtx,
        @ptrCast(&dispatch_ctx),
        false,
    ) catch |e| logger.warning("agent tool registration failed: {}", .{e});
    }

    // Consecutive-denial watchdog (designed anti-loop for dont_ask/auto
    // modes): after N denials in a row, say so instead of silently
    // starving the agent.
    var denial_state = denial_tracker_mod.DenialTracker.init(5);

    // Input history for the line editor (up/down navigation).
    var input_history: std.ArrayList([]u8) = .empty;
    defer {
        for (input_history.items) |h| allocator.free(h);
        input_history.deinit(allocator);
    }
    // Last submitted input — the Esc-recall source (interrupt or short
    // window after submit). Owned here; lineinput only borrows it.
    var last_sent: ?[]u8 = null;
    defer if (last_sent) |ls| allocator.free(ls);
    // Cross-session: ↑-recall survives restarts. Without this a fresh ziv
    // shows no history (the magenta recall styling silently did nothing)
    // until the user submits a new line — reported as "feature broken".
    loadInputHistory(allocator, io, &input_history);

    try std.Io.Writer.writeAll(w,
        \\Type your message (or /help for commands):
        \\
    );
    try std.Io.File.Writer.flush(&file_writer);

    while (true) {
        // Hot-reload: a settings file changed on disk since the last prompt
        // (external edit) → reload everything and resync the live permission
        // mode. Own saves refresh the baseline, so this never fires for them.
        const settings_fp = config_mod.settingsFingerprint(allocator, io);
        if (settings_fp != settings_fp_baseline) {
            settings_fp_baseline = settings_fp;
            if (config_mod.loadSettings(allocator, io)) |fresh| {
                const old_model = switcher.modelName();
                applyReloadedSettings(&switcher, fresh);
                current_mode = switcher.settings.permission_mode;
                // Model changed on disk: re-apply to the live name buffer,
                // or the prompt and every request keep the OLD model while
                // /config shows the new one (双源状态分裂).
                if (!std.mem.eql(u8, fresh.default_model, old_model)) {
                    switcher.switchModel(fresh.default_model) catch |err| {
                        logger.warning("reload: model switch to {s} failed: {}", .{ fresh.default_model, err });
                    };
                }
                reapplySystemPromptIfNeeded(&applied_prompt_setting, &sys_prompt_owned, &sys_prompt, &history, allocator, switcher.settings.system_prompt);
                logger.info("settings reloaded: mode={s}", .{@tagName(current_mode)});
                try std.Io.Writer.print(w, "  [settings reloaded | mode: {s}]\n\n", .{auth.modeLabel(current_mode)});
                try std.Io.File.Writer.flush(&file_writer);
            } else |_| {}
        }

        // T8: sync the plan anchor with .ziv/plan.md (fingerprint-gated;
        // also covers the very first prompt — the file may predate us).
        refreshPlanAnchor(&history, &plan_block, &plan_raw_last, allocator, io);

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
        // Parity: the prompt % uses the SAME adaptive ceiling as maybeCompact
        // (contextEstimate of the active model) — display and decision must
        // not diverge on small-context models.
        const ctx_ceiling = llm.provider.contextEstimate(switcher.modelName(), switcher.backend);
        const ctx_pct = @as(u32, @intFromFloat(@as(f64, @floatFromInt(est_ctx)) / @as(f64, @floatFromInt(ctx_ceiling)) * 100.0));
        var prompt_buf: [160]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "{s} ({s}) [{d}%] > ", .{ mode_str, switcher.modelName(), ctx_pct }) catch "> ";

        // Read line via the raw-mode editor: arrows move the cursor,
        // up/down walk history (or move between lines on multi-line input),
        // Backspace/Delete/Home/End work, pasted multi-line text arrives as
        // ONE input. The returned slice is allocator-owned and may exceed
        // 4 KiB after a big paste — freed at the end of this iteration.
        const maybe_line = lineinput.readLine(w, r, &file_writer, prompt, &input_history, allocator) catch |err| {
            std.debug.print("Error reading input: {}\n", .{err});
            return;
        };
        const line = maybe_line orelse {
            // Ctrl-D on an empty line (EOF): same session-end cleanup as
            // /quit — this path used to skip reflection + memory extraction,
            // silently losing the session's learnings on a common exit habit.
            // Extract first, reflect last — see the /quit path note.
            if (mem_sys) |*ms| {
                const ext_t0 = util_time.nowMillis();
                extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, w) catch {};
                logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
            }
            if (mem_sys != null and window_queries.items.len > 0) {
                runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, null, .full); // exit path: heuristic-only (detached LLM worker would race the provider deinit)
            }
            try std.Io.Writer.writeAll(w, "\nGoodbye!\n");
            try std.Io.File.Writer.flush(&file_writer);
            return;
        };
        // Loop-body scope: freed on every continue/break/return below.
        defer allocator.free(line);

        if (line.len == 0) continue;

        const input = std.mem.trim(u8, line, " \t\r\n");
        if (input.len == 0) continue;
        saveInputHistory(allocator, &input_history);

        var skill_injected = false;
        // ──── Meta commands ────
        // Multi-line input (pasted text, `\`+Enter drafts) is always a
        // MESSAGE — a pasted blob that happens to start with '/' must not
        // trip the command dispatcher.
        if (std.mem.startsWith(u8, input, "/") and std.mem.indexOfScalar(u8, input, '\n') == null) {
            if (std.ascii.eqlIgnoreCase(input, "/quit") or std.ascii.eqlIgnoreCase(input, "/q") or std.ascii.eqlIgnoreCase(input, "/exit")) {
                // M4: session-end reflection on whatever the window still holds.
                // Extract memories FIRST (valuable, durable, ms) — reflection
                // is best-effort behind it; killing the window mid-exit
                // used to lose the whole session's learnings.
                if (mem_sys) |*ms| {
                    const ext_t0 = util_time.nowMillis();
                    extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, w) catch {};
                    logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
                }
                if (mem_sys != null and window_queries.items.len > 0) {
                    runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, null, .full); // exit path: heuristic-only (detached LLM worker would race the provider deinit)
                }
                try std.Io.Writer.writeAll(w, "Goodbye!\n");
                try std.Io.File.Writer.flush(&file_writer);
                break;
            } else if (std.mem.eql(u8, input, "/help") or std.mem.eql(u8, input, "/h")) {
                try printHelp(w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.startsWith(u8, input, "/mcp")) {
                const rest_mcp = std.mem.trim(u8, input[4..], " \t");
                if (rest_mcp.len == 0 or std.mem.eql(u8, rest_mcp, "list")) {
                    if (mcp_cfg.servers.items.len == 0) {
                        try std.Io.Writer.writeAll(w, "  No MCP servers configured. /mcp install <name> | /mcp add <name> <command>\n\n");
                    } else {
                        try std.Io.Writer.writeAll(w, "  MCP servers:\n");
                        for (mcp_cfg.servers.items) |srv| {
                            const sess = findMcpSession(mcp_sessions.items, srv.name);
                            const state = if (sess) |ss| (if (ss.connected) "connected" else "down") else "off";
                            try std.Io.Writer.print(w, "    {s} [{s}] — {s}\n", .{ srv.name, state, if (srv.url) |u| u else srv.command });
                        }
                        try std.Io.Writer.writeAll(w, "\n");
                    }
                } else if (std.mem.startsWith(u8, rest_mcp, "install ")) {
                    const want = std.mem.trim(u8, rest_mcp[8..], " \t");
                    var found = false;
                    for (mcp_mod.config.McpConfig.known_servers) |ks| {
                        if (std.mem.eql(u8, ks.name, want)) {
                            try mcp_cfg.upsert(ks.name, ks.command);
                            try std.Io.Writer.print(w, "  Installed {s} -> {s}\n  Connect with: /mcp connect {s}\n\n", .{ ks.name, ks.command, ks.name });
                            found = true;
                            break;
                        }
                    }
                    if (!found) try std.Io.Writer.print(w, "  Unknown package '{s}'. Known: playwright, filesystem, memory, fetch, sequential-thinking\n\n", .{want});
                } else if (std.mem.startsWith(u8, rest_mcp, "add ")) {
                    const args_str = std.mem.trim(u8, rest_mcp[4..], " \t");
                    const sp = std.mem.indexOfScalar(u8, args_str, ' ') orelse {
                        try std.Io.Writer.writeAll(w, "  Usage: /mcp add <name> <command...>\n\n");
                        try std.Io.File.Writer.flush(&file_writer);
                        continue;
                    };
                    const val = std.mem.trim(u8, args_str[sp + 1 ..], " \t");
                    if (std.mem.startsWith(u8, val, "http://") or std.mem.startsWith(u8, val, "https://")) {
                        try mcp_cfg.upsertUrl(args_str[0..sp], val);
                    } else {
                        try mcp_cfg.upsert(args_str[0..sp], val);
                    }
                    try std.Io.Writer.print(w, "  Added. Connect with: /mcp connect {s}\n\n", .{args_str[0..sp]});
                } else if (std.mem.startsWith(u8, rest_mcp, "remove ")) {
                    const want = std.mem.trim(u8, rest_mcp[7..], " \t");
                    if (findMcpSession(mcp_sessions.items, want)) |sess| {
                        mcp_mod.session.unbridgeSessionTools(sess, &reg);
                        sess.disconnect(io);
                    }
                    if (mcp_cfg.remove(want)) {
                        try std.Io.Writer.print(w, "  Removed {s}\n\n", .{want});
                    } else {
                        try std.Io.Writer.print(w, "  No such server: {s}\n\n", .{want});
                    }
                } else if (std.mem.startsWith(u8, rest_mcp, "connect ")) {
                    const want = std.mem.trim(u8, rest_mcp[8..], " \t");
                    const entry = mcp_cfg.find(want) orelse {
                        try std.Io.Writer.print(w, "  No such server: {s} (see /mcp list)\n\n", .{want});
                        try std.Io.File.Writer.flush(&file_writer);
                        continue;
                    };
                    try connectMcpServer(entry, &mcp_sessions, &reg, allocator, io, w, &file_writer);
                } else if (std.mem.startsWith(u8, rest_mcp, "disconnect ")) {
                    const want = std.mem.trim(u8, rest_mcp[11..], " \t");
                    if (findMcpSession(mcp_sessions.items, want)) |sess| {
                        mcp_mod.session.unbridgeSessionTools(sess, &reg);
                        sess.disconnect(io);
                        try std.Io.Writer.print(w, "  {s} disconnected\n\n", .{want});
                    } else {
                        try std.Io.Writer.print(w, "  {s} was not connected\n\n", .{want});
                    }
                } else {
                    try std.Io.Writer.writeAll(w, "  Usage: /mcp [list|install|add|remove|connect|disconnect] ...\n\n");
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/skills")) {
                if (skill_loader.skills.items.len == 0) {
                    try std.Io.Writer.writeAll(w, "  No skills found. Add SKILL.md packs under ~/.config/ziv/skills/<name>/ or .ziv/skills/<name>/\n\n");
                } else {
                    try std.Io.Writer.writeAll(w, "  Skills (invoke with /<name>):\n");
                    for (skill_loader.skills.items) |skill| {
                        try std.Io.Writer.print(w, "    /{s} — {s} [{s}]\n", .{ skill.name, skill.description, @tagName(skill.source) });
                    }
                    try std.Io.Writer.writeAll(w, "\n");
                }
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
                if (!try permissionGate(run_tool, parsed, current_mode, &switcher, allocator, r, w, &file_writer, &denial_state)) continue;

                // Backup file before modification (for /run commands)
                var run_snap_id: ?[16]u8 = null;
                if (isFileModifyingTool(tool_name)) {
                    if (registry.getStringField(parsed, "path")) |fp| {
                        var sid: [16]u8 = undefined;
                        const ts = util_time.nowMillis();
                        for (&sid, 0..) |*byte, i| {
                            byte.* = @truncate(@as(u64, @bitCast(ts)) +% @as(u64, i) *% 0x9e3779b97f4a7c15);
                        }
                        if (switcher.settings.checkpointing_enabled) {
                            fhist.trackEdit(fp, sid, io) catch {};
                            run_snap_id = sid;
                        }
                    }
                }

                const result = run_tool.execute(allocator, parsed, io) catch |err| {
                    logger.err("Tool /run failed: {s} error={}", .{ tool_name, err });
                    try std.Io.Writer.print(w, "  Tool error: {}\n\n", .{err});
                    _ = log.record(tool_name, "execution", "error", run_snap_id, false, history.items.len) catch {};
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };

                if (result.is_error) {
                    try std.Io.Writer.print(w, "  ERROR: {s}\n\n", .{result.output});
                } else {
                    try std.Io.Writer.print(w, "  {s}\n\n", .{result.output});
                }
                _ = log.record(tool_name, "executed", result.output, run_snap_id, run_snap_id != null, history.items.len) catch {};
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
                settings_fp_baseline = config_mod.settingsFingerprint(allocator, io);
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
                        // Report the backend that VALIDATED the key
                        // (effectiveBackend honors default_backend) — the
                        // name-prefix detector could point at Ollama
                        // (keyless) while the gateway backend rejected us.
                        try std.Io.Writer.print(w, "  Error: API key not configured for {s} backend.\n", .{switcher.effectiveBackend(new_model).label()});
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
                // The live permission gate reads `current_mode`, which the
                // menu never touched — without this resync a mode picked in
                // /config never reached the gate until restart.
                current_mode = switcher.settings.permission_mode;
                // A changed system prompt must reach the baked history[0]
                // this session, not after the next restart.
                reapplySystemPromptIfNeeded(&applied_prompt_setting, &sys_prompt_owned, &sys_prompt, &history, allocator, switcher.settings.system_prompt);
                continue;
            } else if (std.mem.eql(u8, input, "/compact")) {
                // Claude-style: LLM summarizes the conversation, the summary
                // replaces the history (context condensed, not dropped).
                try compactHistory(&history, &switcher, &log, allocator, w, &file_writer, &total_input_tokens, &total_output_tokens);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/compact phi")) {
                // Original φ truncation strategy, kept as an explicit option
                // (also what auto-compaction runs).
                try compactHistoryPhi(&history, allocator, w, &log, &facts_block);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/clear") or std.mem.eql(u8, input, "/reset") or std.mem.eql(u8, input, "/new")) {
                // Reflect BEFORE the window is orphaned: /quit and Ctrl-D
                // both reflect first; /clear used to skip it, leaking the
                // cleared conversation's queries into the next one's
                // reflection window.
                // Extract memories FIRST (valuable, durable, ms) — reflection
                // is best-effort behind it; killing the window mid-exit
                // used to lose the whole session's learnings.
                if (mem_sys) |*ms| {
                    const ext_t0 = util_time.nowMillis();
                    extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, w) catch {};
                    logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
                }
                if (mem_sys != null and window_queries.items.len > 0) {
                    runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, null, .full); // exit path: heuristic-only (detached LLM worker would race the provider deinit)
                }
                clearHistory(&history, allocator);
                log.bumpEpoch();
                // Drop the stale memory-injection block from the surviving
                // system message so the fresh conversation isn't primed
                // with the cleared one's memories.
                if (memory_block) |mb| {
                    allocator.free(mb);
                    // Rebuild the prompt so the embedded date/time is fresh —
                    // a session crossing midnight must not keep answering
                    // date questions with yesterday. (defer frees whatever
                    // sys_prompt_owned holds at scope exit, so swapping here
                    // stays single-ownership.)
                    if (sys_prompt_owned) |sp| allocator.free(sp);
                    sys_prompt_owned = system_prompt_mod.buildSystemPrompt(allocator, switcher.settings.system_prompt) catch null;
                    sys_prompt = sys_prompt_owned orelse system_prompt_mod.default_system_prompt;
                    const fresh_count: usize = 1 + @as(usize, @intFromBool(skill_manifest != null));
                    const fresh_blocks = try allocator.alloc(llm.ContentBlock, fresh_count);
                    fresh_blocks[0] = .{ .text = sys_prompt };
                    // The skill manifest must survive /clear — rebuilding a
                    // single-block message dropped it, leaving the model
                    // blind to every /<skill> until restart (the manifest
                    // string stays owned by the outer defer).
                    if (skill_manifest) |sm| fresh_blocks[1] = .{ .text = sm };
                    allocator.free(history.items[0].content);
                    history.items[0].content = fresh_blocks;
                    memory_block = null; // the end-of-session defer must not double-free
                    injected_count = 0;
                }
                message_count = 0;
                total_input_tokens = 0;
                total_output_tokens = 0;
                _ = log.record("ClearHistory", "/", "/", null, false, 0) catch {};
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
                    try runResearch(topic, allocator, io, w, switcher.settings.api_keys.brave_api_key, if (mem_sys) |*ms| ms else null, if (kgraph) |*g| g else null);
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
                    try runDiagnose(if (live_trace) |*t| t else null, concern, injected_count, window_tools, window_errors, if (mem_sys) |*ms| ms else null, allocator, w);
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/undo")) {
                // Only invalidate older rewind points when something was
                // actually removed — a no-op undo must not rewrite history.
                if (try undoLastExchange(&history, allocator, w) > 0) {
                    log.bumpEpoch();
                }
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
                try rewindOperation(&rollback_engine, &history, w, r, &file_writer, allocator, io);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/plan") or std.mem.startsWith(u8, input, "/plan ")) {
                const plan_arg = std.mem.trim(u8, input[5..], " \t");
                if (std.mem.eql(u8, plan_arg, "off")) {
                    std.Io.Dir.cwd().deleteFile(io, ".ziv/plan.md") catch {};
                    refreshPlanAnchor(&history, &plan_block, &plan_raw_last, allocator, io);
                    try std.Io.Writer.writeAll(w, "  计划已停用（.ziv/plan.md 已删除，system 锚点已移除）\n\n");
                } else if (plan_arg.len == 0) {
                    if (plan_raw_last) |pr| {
                        try std.Io.Writer.print(w, "  当前计划（.ziv/plan.md）：\n{s}\n\n", .{pr});
                    } else {
                        try std.Io.Writer.writeAll(w, "  当前无计划。用法：/plan <目标> 创建 ｜ /plan off 停用\n\n");
                    }
                } else {
                    std.Io.Dir.cwd().createDirPath(io, ".ziv") catch {};
                    var tp: [4096]u8 = undefined;
                    const template = std.fmt.bufPrint(&tp, "# 计划：{s}\n\n- [ ] （补充步骤；勾选为 [x] 后，system 注入的摘要自动更新）\n", .{plan_arg}) catch "";
                    if (template.len > 0) {
                        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".ziv/plan.md", .data = template }) catch {
                            try std.Io.Writer.writeAll(w, "  写入 .ziv/plan.md 失败\n\n");
                            try std.Io.File.Writer.flush(&file_writer);
                            continue;
                        };
                        refreshPlanAnchor(&history, &plan_block, &plan_raw_last, allocator, io);
                        try std.Io.Writer.writeAll(w, "  计划已创建并锚定到 system prompt（每轮自动同步勾选进度）\n\n");
                    }
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/stats")) {
                const est_tokens = estimateHistoryTokens(history.items);
                try std.Io.Writer.print(w, "  Messages: {d} | History tokens: ~{d} | Operations: {d}\n", .{
                    message_count,
                    est_tokens,
                    log.records.items.len,
                });
                try std.Io.Writer.print(w, "  Mode: {s} | Model: {s} ({s}) | Tier: {s}\n", .{
                    auth.modeLabel(current_mode),
                    switcher.modelName(),
                    switcher.backendLabel(),
                    @tagName(llm.provider.capabilityTier(switcher.modelName(), switcher.backend)),
                });
                const ps = pool.stats();
                try std.Io.Writer.print(w, "  Pool: {d}/{d} active | {d} done {d} failed\n", .{ ps.active, ps.max_concurrent, ps.completed, ps.failed });
                try std.Io.Writer.print(w, "  Total: {d} in / {d} out tokens\n\n", .{
                    total_input_tokens,
                    total_output_tokens,
                });
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/terminal-setup")) {
                // Claude-Code-style Shift+Enter enabler: ziv understands the
                // sequences; this tells the TERMINAL to actually send one.
                const term = env.get("TERM_PROGRAM") orelse "";
                try std.Io.Writer.writeAll(w,
                    \\  Shift+Enter 换行配置指引
                    \\
                    \\  ─ kitty 键盘协议终端（开箱即用）────────────────
                    \\    kitty / WezTerm / foot / ghostty / Alacritty ≥0.13 /
                    \\    iTerm2 ≥3.5 / VS Code（较新 xterm.js）：
                    \\    ziv 启动时已自动启用协议，Shift+Enter 直接换行。
                    \\
                    \\  ─ 通用（所有终端立即可用）────────────────────────
                    \\    · 行尾反斜杠 `\` + Enter   续行
                    \\    · Ctrl+J                  插入换行
                    \\
                );
                if (std.mem.eql(u8, term, "vscode")) {
                    try std.Io.Writer.writeAll(w,
                        \\
                        \\  ─ VS Code 集成终端 ────────────────────────────
                        \\    Settings → Keyboard Shortcuts → Terminal: Run Recent Command?
                        \\    简单做法：keybindings.json 加一条
                        \\      { "key": "shift+enter", "command": "workbench.action.terminal.sendSequence",
                        \\        "args": { "text": "\n" }, "when": "terminalFocus" }
                        \\
                    );
                } else if (std.mem.eql(u8, term, "iTerm.app")) {
                    try std.Io.Writer.writeAll(w,
                        \\
                        \\  ─ iTerm2 ──────────────────────────────────────
                        \\    Settings → Profiles → Keys → Key Mappings → +:
                        \\      Shortcut: Shift+Enter  Action: Send Escape Sequence
                        \\      Esc+ 输入: \r    （ziv 识别 ESC+CR 为换行）
                        \\
                    );
                } else if (std.mem.eql(u8, term, "WezTerm")) {
                    try std.Io.Writer.writeAll(w,
                        \\
                        \\  ─ WezTerm ─────────────────────────────────────
                        \\    wezterm.lua:
                        \\      keys = { { key="Enter", mods="SHIFT", action=wezterm.action{SendString="\n"} } }
                        \\
                    );
                } else {
                    try std.Io.Writer.writeAll(w,
                        \\
                        \\  ─ 其他终端（含 Apple Terminal）─────────────────
                        \\    Apple Terminal 不支持 kitty 协议，也不支持单键改映射，
                        \\    推荐用 `\`+Enter 或 Ctrl+J。
                        \\
                    );
                }
                try std.Io.Writer.writeAll(w, "\n");
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/version")) {
                try std.Io.Writer.writeAll(w, "  Ziv v" ++ version_mod.version ++ " (Zig " ++ @import("builtin").zig_version_string ++ ")\n\n");
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (input.len > 1 and skill_loader.findByName(if (std.mem.indexOfScalar(u8, input[1..], ' ')) |sp| input[1 .. 1 + sp] else input[1..]) != null) {
                // /<skill-name> [task...]: known skill -> inject its body as
                // the user message (v1: prompt-only skills) and fall through
                // to the normal agent path.
                const rest = input[1..];
                const sp_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
                const skill = skill_loader.findByName(rest[0..sp_end]).?;
                const task = std.mem.trim(u8, rest[sp_end..], " \t");
                const body = skill_loader.readBody(skill, allocator) catch "";
                // T7.2: trigger-time preview — the user sees the declared
                // shape (steps + advisory tools) before the model runs it.
                {
                    const steps = skills_mod.loader.countSteps(body);
                    var pb: [96]u8 = undefined;
                    const prev = std.fmt.bufPrint(&pb, "  ▶ skill {s} · {d} 步{s}{s}\n", .{
                        skill.name,
                        steps,
                        if (skill.tools.len > 0) " · 工具: " else "",
                        skill.tools,
                    }) catch "  ▶ skill\n";
                    try std.Io.Writer.writeAll(w, prev);
                    try std.Io.File.Writer.flush(&file_writer);
                }
                defer if (body.len > 0) allocator.free(body);
                // $ARGUMENTS substitution: skills can template the whole
                // argument string into their body (Claude-compatible).
                var expanded: []const u8 = body;
                var did_subst = false;
                if (std.mem.indexOf(u8, body, "$ARGUMENTS") != null) {
                    const arg_val = if (task.len > 0) task else "";
                    // Only mark ownership on success — the old catch-body
                    // fallback aliased `expanded` to `body` while did_subst
                    // stayed true, double-freeing one of them at scope exit.
                    if (std.mem.replaceOwned(u8, allocator, body, "$ARGUMENTS", arg_val)) |replaced| {
                        expanded = replaced;
                        did_subst = true;
                    } else |_| {}
                }
                defer if (did_subst) allocator.free(expanded);
                const msg = std.fmt.allocPrint(allocator, "[Skill: {s}]\n{s}\n\nTask: {s}", .{
                    skill.name,
                    expanded,
                    if (task.len > 0) task else "follow the skill instructions",
                }) catch continue;
                var skill_blocks = try allocator.alloc(llm.ContentBlock, 1);
                skill_blocks[0] = .{ .text = msg };
                try history.append(allocator, .{
                    .role = .user,
                    .content = skill_blocks,
                    .timestamp = util_time.nowMillis(),
                });
                skill_injected = true;
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

        // Append user message to history (skill invocations already did)
        if (!skill_injected) {
            var user_blocks = try allocator.alloc(llm.ContentBlock, 1);
            user_blocks[0] = .{ .text = try allocator.dupe(u8, input) };
            try history.append(allocator, .{
                .role = .user,
                .content = user_blocks,
                .timestamp = util_time.nowMillis(),
            });
        }

        // Reflection window + message counter (M4): reflect() bails on an
        // empty window — without this append the whole reflection subsystem
        // silently never ran (the block was dropped in the skill commit).
        message_count += 1;
        if (allocator.dupe(u8, input)) |q| {
            window_queries.append(allocator, q) catch allocator.free(q);
            if (window_queries.items.len > 20) {
                allocator.free(window_queries.orderedRemove(0));
            }
        } else |_| {}

        // Arm Esc-recall: Esc during generation (interrupt) or within a few
        // seconds at the next empty prompt pulls this text back into the
        // editor for editing/resending.
        if (last_sent) |ls| allocator.free(ls);
        last_sent = allocator.dupe(u8, input) catch null;
        lineinput.recall_text = last_sent;

        // M8-deep: one fresh decision trace per query; /diagnose reads it
        // live instead of always synthesizing the static fallback.
        if (live_trace) |*t| t.deinit();
        if (allocator.dupe(u8, input)) |q| {
            live_trace = decision_trace.DecisionTrace.init(allocator, q);
        } else |_| {}

        // First link of the designed 7-phase chain. The static fallback in
        // runDiagnose carries this phase, but once live traces exist that
        // fallback never runs — without this step no live trace could ever
        // flag the memory tier as a diagnosis root cause.
        if (live_trace) |*t| {
            traceAddStep(t, .memory_retrieval, if (injected_count > 0) 0.8 else 0.3, "session start", "memory block", if (injected_count > 0) "recency-ranked e-decay injection" else "no memories injected", 0, allocator) catch {};
        }

        // Agent loop
        var agent_iterations: usize = 0;
        var result_blocks = std.ArrayList(llm.ContentBlock).empty;
        defer result_blocks.deinit(allocator);
        // One emergency compaction per turn on ContextOverflow — a second
        // overflow after compacting falls through to the manual hint.
        var overflow_compacted = false;

        while (agent_iterations < MAX_AGENT_ITERATIONS) : (agent_iterations += 1) {
            // Compaction check + context estimate in one pass.
            est_ctx = maybeCompact(&history, allocator, w, &file_writer, &log, &facts_block, switcher.modelName(), switcher.backend);

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
                traceAddStep(t, .context_assembly, if (est_ctx < MAX_CONTEXT_TOKENS) 0.9 else 0.5, "messages + memory block", out_desc, "compaction-checked assembly", 0, allocator) catch {};
            }
            // Pre-call log demoted to debug: the user-facing summary line after
            // the call carries model/history/tokens — printing both cluttered
            // the REPL with a duplicate [INF] line per turn.
            logger.debug("LLM call: model={s} history_len={d} max_tokens={d}", .{
                switcher.modelName(), history.items.len, switcher.settings.max_tokens,
            });
            // Stream the response: text deltas print live as they arrive.
            const llm_t0 = util_time.nowMillis();
            const response = streamComplete(prov, history.items, .{
                .max_tokens = switcher.settings.max_tokens,
                .temperature = 0.7,
                // Declare the tools so the model can actually call them.
                .tools = reg.toolSpecs(),
            }, r, w, &file_writer, allocator) catch |err| {
                if (err == error.EscCancelled) {
                    // Esc: abort this exchange and pull the input back into
                    // the editor (history keeps the user message; no
                    // assistant reply was appended).
                    try std.Io.Writer.print(w, "\n  [Esc — 已中断，输入已撤回，可直接编辑重发]\n\n", .{});
                    lineinput.recall_text = last_sent;
                    lineinput.recall_prefill = true;
                    try std.Io.File.Writer.flush(&file_writer);
                    break;
                }
                logger.err("LLM call failed: {}", .{err});
                // Context overflow: compact once and retry instead of
                // stranding the session — every retry would otherwise send
                // the same oversized history and fail identically.
                if (err == error.ContextOverflow and !overflow_compacted) {
                    overflow_compacted = true;
                    applyFactsUpdate(&history, &facts_block, allocator, compactHistoryImpl(&history, allocator, facts_block));
                    log.bumpEpoch();
                    try std.Io.Writer.print(w, "  [Context overflow — history auto-compacted, retrying]\n", .{});
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                }
                try std.Io.Writer.print(w, "  [LLM error: {}]\n", .{err});
                // Designed error-feedback closure (§四): classified analysis
                // + numbered fixes with the recommended one marked. The
                // formatter existed since v0.3 with zero callers.
                {
                    const err_code: []const u8 = switch (err) {
                        error.NetworkTimeout => "network_timeout",
                        error.RateLimit => "api_rate_limit",
                        error.ContextOverflow => "context_overflow",
                        else => @errorName(err),
                    };
                    if (error_handler.formatErrorReport(allocator, err_code, @errorName(err))) |report| {
                        defer {
                            allocator.free(report.analysis);
                            allocator.free(report.fixes);
                        }
                        try std.Io.Writer.print(w, "  {s}\n", .{report.analysis});
                        for (report.fixes) |f| {
                            try std.Io.Writer.print(w, "    [{d}] {s}{s}\n", .{ f.index, f.description, if (f.is_recommended) " ★" else "" });
                        }
                    } else |_| {}
                }
                if (err == error.ContextOverflow) {
                    try std.Io.Writer.print(w, "  [Still too long after compaction — try /compact phi or /clear]\n", .{});
                } else if (err == error.InvalidRequest) {
                    try std.Io.Writer.print(w, "  [The gateway rejected the request — its reason is on the [ERR] body line above]\n", .{});
                }
                try std.Io.Writer.writeAll(w, "\n");
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
                traceAddStep(t, .llm_generation, gen_conf, "history + system prompt", out_desc, @tagName(response.stop_reason), @intCast(util_time.nowMillis() - llm_t0), allocator) catch {};
            }

            // Text/thinking deltas were already printed live by streamComplete;
            // tool calls too ([calling tool: X] on the stream event) — a
            // second announce here was pure duplication.
            for (response.content) |block| {
                switch (block) {
                    .tool_use => {},
                    .tool_result => |tr| {
                        const label = if (tr.is_error) "error" else "result";
                        try std.Io.Writer.print(w, "  [tool {s}: ", .{label});
                        var at_ls = false;
                        try writeMarginLines(w, tr.content, "  ", &at_ls);
                        try std.Io.Writer.writeAll(w, "]\n");
                    },
                    else => {},
                }
            }
            const llm_elapsed_s = @as(f64, @floatFromInt(util_time.nowMillis() - llm_t0)) / 1000.0;
            try std.Io.Writer.print(w, "  [{s} | in={d} out={d} | hist={d} | stop: {s} | {d:.1}s]\n", .{
                switcher.modelName(),
                response.usage.input_tokens,
                response.usage.output_tokens,
                history.items.len,
                @tagName(response.stop_reason),
                llm_elapsed_s,
            });
            try std.Io.File.Writer.flush(&file_writer);

            // Append assistant response to history. The streaming aggregator
            // already produced REPL-owned blocks (strings duped onto the
            // session allocator; no DOM arena involved), so no deep copy
            // or arena release is needed here.
            const stop_reason = response.stop_reason;
            // Skip fully-empty responses: they pollute history, and the
            // Claude wire format would carry them as an empty-content
            // message some endpoints reject (OpenAI/Ollama skip them).
            if (response.content.len > 0) {
                try history.append(allocator, .{
                    .role = .assistant,
                    .content = response.content,
                    .timestamp = util_time.nowMillis(),
                });
            } else {
                // Ownership never moved to history — release the (empty)
                // block slice ourselves; zero-length free is a no-op-safe.
                allocator.free(@constCast(response.content));
            }

            // Record in operation log
            _ = log.record("LLMResponse", input, "response", null, false, 0) catch {};
            if (live_trace) |*t| {
                traceAddStep(t, .response_postprocess, 0.95, "stream aggregation", "blocks appended to history", "REPL-owned copy", 0, allocator) catch {};
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
                        // History blocks own every string: the id must be
                        // duped (it borrows the assistant message's copy —
                        // freeing both was a double free) and literals too.
                        try result_blocks.append(allocator, .{ .tool_result = .{
                            .tool_use_id = try allocator.dupe(u8, tc.id),
                            .content = try allocator.dupe(u8, "Tool not found"),
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
                            // The /config toggle used to be a placebo —
                            // snapshots were taken unconditionally.
                            if (switcher.settings.checkpointing_enabled) {
                                fhist.trackEdit(fp, sid, io) catch {};
                                snap_id = sid;
                            }
                        }
                    }

                    // Permission check (shared gate; auto mode may delegate
                    // the ambiguous ask case to the LLM classifier).
                    const approved = try permissionGate(tool_def, tc.input, current_mode, &switcher, allocator, r, w, &file_writer, &denial_state);
                    if (!approved) {
                        try result_blocks.append(allocator, .{ .tool_result = .{
                            .tool_use_id = try allocator.dupe(u8, tc.id),
                            .content = try allocator.dupe(u8, "denied by permission gate"),
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
                    traceAddStep(t, .tool_selection, conf, "tool_use blocks", out_desc, "permission gate", 0, allocator) catch {};
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
                const batch_t0 = util_time.nowMillis();
                const results = try orchestration_mod.executeBatches(batches, allocator, io, reg.definitions());
                defer allocator.free(results);

                var batch_errors: u32 = 0;
                for (prepared.items, 0..) |p, i| {
                    window_tools += 1;
                    const errored = try finishToolCall(p, results[i].result, allocator, &log, &result_blocks, w, &file_writer, history.items.len);
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
                    traceAddStep(t, .tool_execution, conf, "approved batch", out_desc, "permission gate + thread pool", @intCast(util_time.nowMillis() - batch_t0), allocator) catch {};
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

        // T1.3: topic-drift re-anchor — checked after EVERY completed turn
        // (cheap: ≤3 hash embeddings + one cosine), fires at most once.
        if (!mem_block_rebuilt and memory_block != null) {
            if (mem_sys) |*ms| {
                if (topicVectorOfLastUserTurns(&history, allocator)) |cur| {
                    if (mem_topic_baseline) |base| {
                        if (shouldReanchor(base, cur)) {
                            const ctx_est = llm.provider.contextEstimate(switcher.modelName(), switcher.backend);
                            const eff_budget = injection_mod.effectiveBudget(switcher.settings.memory_budget_tokens, ctx_est);
                            if (ms.episodic_mem.retrieveRecent(200) catch null) |entries| {
                                const ents = entries;
                                defer ms.episodic_mem.freeEntries(ents);
                                if (injection_mod.buildMemoryBlockAnchored(allocator, ents, eff_budget, cur) catch null) |nb| {
                                    if (swapMemoryBlockText(&history, allocator, memory_block.?, nb.text)) {
                                        allocator.free(memory_block.?);
                                        memory_block = nb.text;
                                        mem_block_rebuilt = true;
                                        logger.info("memory: re-anchored after topic drift (cosine < 0.618)", .{});
                                    } else allocator.free(nb.text); // no block matched: don't leak
                                }
                            }
                        }
                    } else {
                        mem_topic_baseline = allocator.dupe(f32, cur) catch null;
                    }
                    allocator.free(cur);
                }
            }
        }

        // M4: periodic reflection on the query window (every N exchanges
        // or after a π-spaced interval; see ReflectionEngine.shouldReflect).
        if (mem_sys != null and reflector.shouldReflect()) {
            runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, switcher.getProvider() catch null, llm.provider.capabilityTier(switcher.modelName(), switcher.backend));
            if (live_trace) |*t| {
                traceAddStep(t, .reflection_trigger, 0.9, "query window", "insights stored", "phi/e heuristics", 0, allocator) catch {};
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
/// T2.3 noise gate: mostly punctuation/symbols carries no signal but
/// scores like real content in the hash-wordbag ranking and φ condensation.
fn isLowSignal(content: []const u8) bool {
    if (content.len == 0) return true;
    var signal: usize = 0;
    var runes: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        const seq = std.unicode.utf8ByteSequenceLength(content[i]) catch 1;
        if (i + seq > content.len) break;
        const r = std.unicode.utf8Decode(content[i .. i + seq]) catch 0xFFFD;
        runes += 1;
        if (r < 0x80) {
            if (std.ascii.isAlphanumeric(@intCast(r))) signal += 1;
        } else if ((r >= 0x4E00 and r <= 0x9FFF) or // CJK unified ideographs
            (r >= 0x3040 and r <= 0x30FF) or // kana
            (r >= 0xAC00 and r <= 0xD7AF)) signal += 1; // hangul
        // everything else (ASCII/CJK punctuation, symbols, emoji) is noise
        i += seq;
    }
    if (runes == 0) return true;
    return signal * 4 < runes * 3; // <75% signal runes
}

fn splitTokens(text: []const u8, out: *[16][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r,.;:!?()[]{}\"'`");
    while (it.next()) |t| {
        if (n >= out.len) break;
        out[n] = t;
        n += 1;
    }
    return n;
}

/// Bag-Jaccard over whitespace tokens (approximation, allocation-free).
fn jaccardTokens(a: []const u8, b: []const u8) f64 {
    var ta: [16][]const u8 = undefined;
    var tb: [16][]const u8 = undefined;
    const na = splitTokens(a, &ta);
    const nb = splitTokens(b, &tb);
    if (na == 0 or nb == 0) return if (na == nb) 1.0 else 0.0;
    var inter: usize = 0;
    for (ta[0..na]) |x| {
        for (tb[0..nb]) |y| {
            if (std.mem.eql(u8, x, y)) {
                inter += 1;
                break;
            }
        }
    }
    const union_n: usize = na + nb - inter;
    return @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(union_n));
}

/// T2.3 near-duplicate: the store's content-hash only catches EXACT
/// repeats — re-extracted variants (same words, one changed) used to all
/// enter φ condensation and crowd out distinct facts.
fn isNearDuplicate(accepted: []const extraction_mod.ExtractedFact, content: []const u8) bool {
    for (accepted) |a| {
        if (jaccardTokens(a.content, content) > 0.8) return true;
    }
    return false;
}

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
                if (f.content.len < 8 or isLowSignal(f.content) or
                    isNearDuplicate(candidates.items, f.content))
                {
                    mem.allocator.free(f.content);
                    continue; // echoes, symbol noise, re-extracted variants
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
            .name = f.content[0..injection_mod.utf8Boundary(f.content, 48)],
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
/// Write text with a left margin: `indent` before every line. `at_line_start`
/// carries the line position ACROSS calls (streaming deltas split lines
/// mid-chunk) — display only, the stored text stays raw.
fn writeMarginLines(w: *std.Io.Writer, s: []const u8, indent: []const u8, at_line_start: *bool) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (at_line_start.*) {
            try w.writeAll(indent);
            at_line_start.* = false;
        }
        const nl = std.mem.indexOfScalar(u8, s[i..], '\n') orelse {
            try w.writeAll(s[i..]);
            return;
        };
        try w.writeAll(s[i .. i + nl + 1]);
        at_line_start.* = true;
        i += nl + 1;
    }
}

/// Drop the reflection window (shared by the actionable and clean paths).
fn resetReflectionWindow(
    window_queries: *std.ArrayList([]u8),
    window_tools: *u32,
    window_errors: *u32,
    alloc: std.mem.Allocator,
) void {
    for (window_queries.items) |q| alloc.free(q);
    window_queries.clearRetainingCapacity();
    window_tools.* = 0;
    window_errors.* = 0;
}

/// Reflection LLM call under a hard deadline: a hung gateway must not
/// stall the exit (or the prompt). Safety contract for the abandon path:
///   · Shared lives on the HEAP — a detached worker keeps writing to it
///     after this frame returns (a stack Shared was a dangling-frame write).
///   · queries are duped up front — the caller's window list can be freed
///     while a slow worker is still copying them.
///   · on timeout the worker, the Shared block and the dupes are all
///     abandoned (leak with the process) — never freed under a live worker.
fn reflectLlmWithTimeout(
    provider: llm.Provider,
    queries: []const []const u8,
    alloc: std.mem.Allocator,
    deadline_ms: i64,
) ?[]u8 {
    const Shared = struct {
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result: ?[]u8 = null,
    };
    const shared = alloc.create(Shared) catch return null;
    shared.* = .{};

    // Own copies of the query strings (see contract above).
    const qs = alloc.alloc([]const u8, queries.len) catch {
        alloc.destroy(shared);
        return null;
    };
    var filled: usize = 0;
    for (queries) |q| {
        qs[filled] = alloc.dupe(u8, q) catch {
            for (qs[0..filled]) |d| alloc.free(d);
            alloc.free(qs);
            alloc.destroy(shared);
            return null;
        };
        filled += 1;
    }

    const Worker = struct {
        fn run(p: llm.Provider, q_list: []const []const u8, a: std.mem.Allocator, sh: *Shared) void {
            var aw: std.Io.Writer.Allocating = .init(a);
            defer aw.deinit();
            const pw = &aw.writer;
            pw.writeAll("Recent queries in this session:\n") catch {
                sh.done.store(true, .release);
                return;
            };
            for (q_list) |q| {
                pw.print("- {s}\n", .{q}) catch break;
            }
            var prompt_list = aw.toArrayList();
            defer prompt_list.deinit(a);

            const sys_blocks = a.alloc(llm.ContentBlock, 1) catch null;
            if (sys_blocks) |sb| {
                sb[0] = .{ .text = "你是反思引擎。用一句中文总结这些交互的改进点，不超过40字，只输出总结本身。" };
                const user_blocks = a.alloc(llm.ContentBlock, 1) catch null;
                if (user_blocks) |ub| {
                    ub[0] = .{ .text = prompt_list.items };
                    const msgs = [_]llm.Message{
                        .{ .role = .system, .content = sb, .timestamp = util_time.nowMillis() },
                        .{ .role = .user, .content = ub, .timestamp = util_time.nowMillis() },
                    };
                    if (p.complete(&msgs, .{ .max_tokens = 100, .temperature = 0.3 })) |resp| {
                        var r = resp;
                        defer r.free(a);
                        if (r.content.len > 0 and r.content[0] == .text) {
                            sh.result = a.dupe(u8, r.content[0].text) catch null;
                        }
                    } else |_| {}
                    a.free(ub);
                }
                a.free(sb);
            }
            sh.done.store(true, .release);
        }
    }.run;

    const t = std.Thread.spawn(.{}, Worker, .{ provider, qs, alloc, shared }) catch {
        Worker(provider, qs, alloc, shared); // spawn failed: inline fallback
        const res = shared.result;
        for (qs) |d| alloc.free(d);
        alloc.free(qs);
        alloc.destroy(shared);
        return res;
    };
    const t0 = util_time.nowMillis();
    while (util_time.nowMillis() - t0 < deadline_ms) {
        if (shared.done.load(.acquire)) {
            t.join();
            const res = shared.result;
            for (qs) |d| alloc.free(d);
            alloc.free(qs);
            alloc.destroy(shared);
            return res;
        }
        var poll_req: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&poll_req, null);
    }
    t.detach();
    logger.warning("reflection LLM exceeded {d}ms — heuristic fallback", .{deadline_ms});
    return null; // worker + shared + dupes leak with the process (by design)
}

fn runReflection(
    reflector: *reflection_mod.ReflectionEngine,
    mem: *memory_mod.MemorySystem,
    window_queries: *std.ArrayList([]u8),
    window_tools: *u32,
    window_errors: *u32,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    provider: ?llm.Provider,
    tier: llm.provider.CapabilityTier,
) void {
    const reflect_t0 = util_time.nowMillis();
    const reflection = reflector.reflect(window_queries.items, window_tools.*, window_errors.*, .on_query_complete) catch return orelse return;

    // Gate: only ACTIONABLE windows pay the LLM round trip (and the print
    // and the stored row). A clean session is routine — it used to be
    // billed 1-3 s at exit plus a junk "良好" memory entry every session.
    if (!reflection.actionable) {
        resetReflectionWindow(window_queries, window_tools, window_errors, alloc);
        return;
    }

    // LLM augmentation for windows with real signal: sharper insight than
    // the heuristic template, capped at 3 s so a hung gateway cannot
    // stall the exit or the prompt.
    var llm_insights: ?[]u8 = null;
    // T2.2 quality gate: only the full tier pays the reflection LLM —
    // flash/local models produce noise insights that poison the next
    // session's injected memories (defect ⑧). Heuristics still run.
    if (provider != null and tier == .full and window_queries.items.len >= 3) {
        // T3.2 (approved deviation): 1s cap, not full backgrounding —
        // SQLITE_THREADSAFE=0 forbids pool-side DB writes and the engine
        // keeps mutable archive state, so the turn pays ≤1s only when the
        // full tier + actionable gates have already passed.
        llm_insights = reflectLlmWithTimeout(provider.?, window_queries.items, alloc, 1000);
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
    w.print("  [Reflection {d}ms] {s}\n", .{ util_time.nowMillis() - reflect_t0, insights }) catch {};

    resetReflectionWindow(window_queries, window_tools, window_errors, alloc);
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
/// `configured_brave_key` is the /config-stored key — the env var wins,
/// but without this fallback a key entered in the menu was write-only and
/// /research silently stayed on DuckDuckGo.
fn runResearch(topic: []const u8, alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, configured_brave_key: ?[]const u8, mem: ?*memory_mod.MemorySystem, kg: ?*knowledge_graph.KnowledgeGraph) !void {
    try std.Io.Writer.writeAll(w, "  Researching (φ-optimized queries, ~30s budget)…\n");

    const brave_key = env.get("BRAVE_API_KEY") orelse configured_brave_key;
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

    // Designed Step 6 (learning closure): the recommended solution used to
    // vanish with the printout. Persist it as a memory + knowledge node so
    // later sessions (and /knowledge) can retrieve what the research found.
    if (result.top_solutions.len > 0) {
        const sol = result.top_solutions[result.recommendation_index];
        var buf: [700]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "[research:{s}] {s} — {s} ({s})", .{ topic, sol.name, sol.description, sol.source }) catch null;
        if (summary) |s| {
            if (mem) |m| {
                const now = util_time.nowMillis();
                m.store(.{
                    .id = injection_mod.memoryId(s, "research"),
                    .mem_type = .reference,
                    .name = "research result",
                    .description = "web research recommendation",
                    .content = s,
                    .access_count = 0,
                    .created_at = now,
                    .updated_at = now,
                }) catch {};
            }
            if (kg) |g| {
                _ = g.addNode(s, .technology, "research") catch {};
            }
        }
    }
}

/// M8: /diagnose — build a lightweight decision trace from real session
/// stats and run the self-diagnostic engine against the user's concern.
fn runDiagnose(
    live: ?*decision_trace.DecisionTrace,
    concern: []const u8,
    injected_count: usize,
    window_tools: u32,
    window_errors: u32,
    mem: ?*memory_mod.MemorySystem,
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

    // Designed step-by-step review (§九): walk the chain with ✓/⚠ per step
    // (conf ≥ φ passes) before the gap summary.
    for (trace.getSteps()) |step| {
        const mark: []const u8 = if (step.confidence >= math_mod.constants.PHI) "✓" else "⚠";
        try std.Io.Writer.print(w, "  {s} {s} (conf {d:.2}, {d}ms)\n", .{ mark, @tagName(step.phase), step.confidence, step.duration_ms });
    }

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

    // Designed learning closure (§九 step 5): persist the diagnosis as a
    // .feedback memory so the next session's injection can surface it —
    // reports used to be printed and dropped. Working/episodic store both
    // copy, so a stack buffer is safe to hand over.
    if (mem) |m| {
        if (report.root_cause) |rc| {
            var buf: [512]u8 = undefined;
            const summary = std.fmt.bufPrint(&buf, "诊断「{s}」根因: {s}", .{ concern, rc.description }) catch null;
            if (summary) |s| {
                const now = util_time.nowMillis();
                m.store(.{
                    .id = injection_mod.memoryId(s, "diagnosis"),
                    .mem_type = .feedback,
                    .name = "diagnosis learning",
                    .description = "self-diagnosis",
                    .content = s,
                    .access_count = 0,
                    .created_at = now,
                    .updated_at = now,
                }) catch {};
            }
        }
    }
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
    duration_ms: i64,
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
        .duration_ms = duration_ms,
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
    /// One-shot dim "(thinking…)" marker: reasoning streams (GLM
    /// reasoning_content / Claude thinking) used to render as dead silence
    /// for seconds, reading like a hang.
    thinking_shown: bool = false,
    thinking_newline_needed: bool = false,
    /// Response left margin: every displayed response line opens with one
    /// space (user preference); the flag survives across delta chunks so a
    /// line broken between chunks still gets its margin.
    at_line_start: bool = true,
    /// Esc-interrupt: when set, streamCb polls stdin (throttled) so Esc
    /// cancels generation and recalls the input for editing.
    esc_probe_r: ?*std.Io.Reader = null,
    last_esc_check: i64 = 0,

    fn deinit(self: *StreamAgg) void {
        self.text.deinit(self.alloc);
        // Tool strings are session-lifetime (freed with history); just drop the list.
        self.tools.deinit(self.alloc);
    }
};

/// Claude-Code-style one-line tool call display: `⏺ Bash(ls -la)`. Picks
/// the most informative argument field for the tool; falls back to the raw
/// JSON. Returned slice is caller-owned (arena/temporary use); empty when
/// nothing useful to show.
fn toolArgSummary(alloc: std.mem.Allocator, tool: []const u8, input: std.json.Value) []const u8 {
    _ = tool;
    const interesting = [_][]const u8{ "command", "path", "pattern", "query", "topic", "url", "name" };
    var pick: []const u8 = "";
    for (interesting) |field| {
        if (input == .object) {
            if (input.object.get(field)) |v| {
                if (v == .string and v.string.len > 0) {
                    pick = v.string;
                    break;
                }
            }
        }
    }
    if (pick.len == 0) {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        std.json.Stringify.value(input, .{}, &aw.writer) catch return "";
        pick = aw.written();
        if (pick.len <= 2) return ""; // "{}"
    }
    const s = summarize(alloc, pick) catch return "";
    return std.fmt.allocPrint(alloc, "({s})", .{s}) catch "";
}

/// "(summary)" — first line, display-width-capped (CJK-aware, per CHAR not
/// per byte), control bytes stripped, never cut mid-UTF-8.
fn summarize(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var end = @min(s.len, std.mem.indexOfScalar(u8, s, '\n') orelse s.len);
    if (end > 80) end = 80;
    // Back off to a char boundary (byte cuts used to split CJK chars and
    // print mojibake).
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;

    var out = std.ArrayList(u8).empty;
    var w: usize = 0;
    var i: usize = 0;
    while (i < end) {
        const c = s[i];
        if (c < 0x20) {
            i += 1;
            continue;
        }
        const cw: usize = if (c >= 0xE0) 2 else 1;
        if (w + cw > 48) break;
        var j = i + 1;
        while (j < end and (s[j] & 0xC0) == 0x80) j += 1;
        try out.appendSlice(alloc, s[i..j]);
        w += cw;
        i = j;
    }
    if (i < s.len or w >= 48) try out.appendSlice(alloc, "…");
    return out.toOwnedSlice(alloc);
}

fn streamCb(ctx_opaque: ?*anyopaque, event: llm.provider.StreamEvent) anyerror!void {
    const self: *StreamAgg = @ptrCast(@alignCast(ctx_opaque.?));
    // Esc interrupts generation (Claude-Code style): poll stdin at most
    // every 50 ms — an error return here aborts the provider stream.
    if (self.esc_probe_r != null) {
        const now = util_time.nowMillis();
        if (now - self.last_esc_check >= 50) {
            self.last_esc_check = now;
            if (lineinput.escProbe(self.esc_probe_r.?)) {
                return error.EscCancelled;
            }
        }
    }
    switch (event) {
        .content_delta => |d| {
            // Close the "(thinking…)" marker line before the first real text.
            if (self.thinking_newline_needed) {
                self.thinking_newline_needed = false;
                try std.Io.Writer.writeAll(self.w, "\n");
            }
            // Live print with the one-space response margin (display only —
            // self.text keeps the raw text for history).
            try writeMarginLines(self.w, d, " ", &self.at_line_start);
            std.Io.File.Writer.flush(self.file_writer) catch {};
            try self.text.appendSlice(self.alloc, d);
        },
        .thinking_delta => {
            if (!self.thinking_shown) {
                self.thinking_shown = true;
                self.thinking_newline_needed = true;
                try std.Io.Writer.writeAll(self.w, "\x1b[2m(thinking…)\x1b[0m");
                std.Io.File.Writer.flush(self.file_writer) catch {};
            }
        },
        .tool_call => |tu| {
            // Per-event arena: the summary strings are print-and-done.
            var sum_arena = std.heap.ArenaAllocator.init(self.alloc);
            defer sum_arena.deinit();
            try self.w.print("\n  ⏺ \x1b[1m{s}\x1b[0m{s}\n", .{ tu.name, toolArgSummary(sum_arena.allocator(), tu.name, tu.input) });
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
    r: ?*std.Io.Reader,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    alloc: std.mem.Allocator,
) !llm.provider.CompleteResponse {
    var agg = StreamAgg{ .alloc = alloc, .w = w, .file_writer = file_writer, .esc_probe_r = r };
    defer agg.deinit();

    // Keep the terminal RAW for the whole generation: readLine restores
    // cooked mode when it returns, and under cooked input discipline the
    // Esc probe is crippled — ESC parks in the line buffer until some
    // later \r flushes the line (ICRNL rewriting it to \n on the way in,
    // which then leaked into the editor as a newline), and 0x7f is eaten
    // as ERASE, deleting the queued Esc entirely. Raw makes Esc visible
    // within one 50 ms probe.
    var esc_guard = menu.RawGuard{};
    if (r != null) {
        esc_guard.enterNoSig();
        if (esc_guard.active) {
            // Drain bytes that queued during the cooked tool-execution
            // window between two generations: an Esc pressed THERE must
            // not cancel this generation's very first stream event. The
            // drain loop keeps ordinary typed-ahead bytes (escProbe stashes
            // them) and drops the stale Esc.
            while (lineinput.escProbe(r.?)) {}
        }
    }
    defer if (r != null) esc_guard.restore();

    prov.stream(history, opts, @ptrCast(&agg), streamCb) catch |err| {
        // Hard transport failure before any event: the saw_error path below
        // never runs, so free the duped tool strings here — they never
        // reached history.
        for (agg.tools.items) |*tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
            freeJsonValue(alloc, tu.input);
        }
        return err;
    };
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

fn findMcpSession(sessions: []*mcp_mod.session.McpSession, name: []const u8) ?*mcp_mod.session.McpSession {
    for (sessions) |sess| {
        if (std.mem.eql(u8, sess.name, name)) return sess;
    }
    return null;
}

/// Spawn + handshake + bridge one server's tools into the runtime registry.
fn connectMcpServer(
    entry: *mcp_mod.config.ServerEntry,
    sessions: *std.ArrayList(*mcp_mod.session.McpSession),
    reg: *runtime_registry.RuntimeRegistry,
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
) !void {
    if (findMcpSession(sessions.items, entry.name)) |existing| {
        if (existing.connected) {
            try std.Io.Writer.print(w, "  {s} already connected ({d} tools)\n\n", .{ entry.name, existing.tool_names.items.len });
            return;
        }
        // Stale "down" session from a failed attempt: reap it so we never
        // hold two entries for one server.
        mcp_mod.session.unbridgeSessionTools(existing, reg);
        existing.disconnect(io);
        existing.deinit();
        alloc.free(existing.name);
        alloc.destroy(existing);
        for (sessions.items, 0..) |sess, i| {
            if (sess == existing) {
                _ = sessions.orderedRemove(i);
                break;
            }
        }
    }
    const sess = try alloc.create(mcp_mod.session.McpSession);
    errdefer alloc.destroy(sess);
    sess.* = .{ .allocator = alloc, .name = try alloc.dupe(u8, entry.name), .allocator_io = io };
    errdefer alloc.free(sess.name);
    var cfg = mcp_mod.session.ServerConfig{ .name = entry.name };
    if (entry.url) |u| {
        cfg.url = u;
    } else {
        cfg.argv = mcp_mod.config.splitCommand(alloc, entry.command) catch {
            try std.Io.Writer.writeAll(w, "  Failed to parse command\n\n");
            sess.deinit();
            alloc.free(sess.name);
            alloc.destroy(sess);
            return;
        };
    }
    defer if (cfg.argv.len > 0) alloc.free(cfg.argv);
    sess.connect(io, cfg) catch |err| {
        try std.Io.Writer.print(w, "  Connect failed: {s}\n  ({s}: {s})\n\n", .{ @errorName(err), if (entry.url != null) "url" else "command", if (entry.url) |u| u else entry.command });
        sess.deinit();
        alloc.free(sess.name);
        alloc.destroy(sess);
        try std.Io.File.Writer.flush(file_writer);
        return;
    };
    sessions.append(allocator, sess) catch {
        // Append failed: the child is already spawned — close it before
        // the errdefers free the session.
        sess.disconnect(io);
        return error.OutOfMemory;
    };
    mcp_mod.session.bridgeSessionTools(sess, reg) catch {};
    logger.info("mcp: {s} connected ({d} tools bridged)", .{ entry.name, sess.tool_names.items.len });
    try std.Io.Writer.print(w, "  {s} connected: {d} tools available as mcp__{s}__*\n\n", .{ entry.name, sess.tool_names.items.len, entry.name });
    try std.Io.File.Writer.flush(file_writer);
}

/// AskUserQuestion execution context: the live REPL reader/writer.
const AskUserCtx = struct {
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
};

/// Real AskUserQuestion body — prompt the user and return their answer.
fn askUserExecute(ctx_opaque: ?*anyopaque, alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    _ = io;
    const ctx: *AskUserCtx = @ptrCast(@alignCast(ctx_opaque orelse return error.NoAskContext));
    const question = registry.getStringField(input, "question") orelse
        return registry.ToolResult{ .output = "Missing required field: question", .is_error = true };
    try std.Io.Writer.print(ctx.w, "\n  [model asks] {s}\n  Your answer (Enter to skip): ", .{question});
    try std.Io.File.Writer.flush(ctx.file_writer);
    var ans_aw: std.Io.Writer.Allocating = .init(alloc);
    defer ans_aw.deinit();
    _ = std.Io.Reader.streamDelimiter(ctx.r, &ans_aw.writer, '\n') catch {
        return registry.ToolResult{ .output = "user input unavailable", .is_error = true };
    };
    ctx.r.toss(1);
    const ans = std.mem.trim(u8, ans_aw.written(), " \t\r\n");
    return registry.ToolResult{
        .output = try alloc.dupe(u8, if (ans.len > 0) ans else "(no answer given)"),
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
    denials: *denial_tracker_mod.DenialTracker,
) !bool {
    const perm_ctx = registry.PermissionContext{
        .mode = mode,
        .allow_rules = switcher.settings.allow_rules,
        .deny_rules = switcher.settings.deny_rules,
        .ask_rules = switcher.settings.ask_rules,
        .provider = switcher.getProvider() catch null,
        .allocator = alloc,
        .model_name = switcher.modelName(),
    };
    var decision = auth.checkToolPermission(tool_def, input, &perm_ctx);

    // Auto mode: delegate ambiguous (ask) calls to the LLM classifier.
    if (mode == .auto and decision == .ask) {
        if (switcher.getProvider() catch null) |p| {
            var lc = classifier_mod.LLMClassifier.init(alloc, p, switcher.modelName());
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
            if (denials.recordDenial()) {
                try std.Io.Writer.print(w, "  [{d} consecutive denials — the agent is being starved; try /mode, an allow rule, or /config]\n", .{denials.consecutive_denials});
            }
            try std.Io.Writer.print(w, "  [Permission denied: {s}]\n", .{d.message});
            try std.Io.File.Writer.flush(file_writer);
            return false;
        },
        .allow => {
            denials.recordApproval();
            return true;
        },
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
                _ = denials.recordDenial();
                try std.Io.Writer.writeAll(w, "  [Denied by user]\n");
                try std.Io.File.Writer.flush(file_writer);
                return false;
            }
            denials.recordApproval();
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
    history_len: usize,
) !bool {
    logger.info("Tool execute: {s}", .{p.call.tool_name});

    // Truncate large outputs for history — must dupe before freeing
    const max_result = 4096;
    const raw = result.output;
    const truncated = raw.len > max_result;

    // Preview with a 2-space left margin on continuation lines (raw output
    // often embeds newlines; those lines used to slam into column 0).
    try std.Io.Writer.print(w, "  [{s}: ", .{p.call.tool_name});
    var at_ls = false;
    try writeMarginLines(w, if (raw.len > 200) raw[0..200] else raw, "  ", &at_ls);
    try std.Io.Writer.writeAll(w, "]\n");

    const content_for_history: []const u8 = if (truncated)
        try alloc.dupe(u8, raw[0..max_result])
    else
        raw; // ownership transfers, no dupe needed

    try result_blocks.append(alloc, .{
        .tool_result = .{
            // Duped: p.call.tool_use_id borrows the assistant message's id —
            // history must own its own copy or clearHistory double-frees.
            .tool_use_id = try alloc.dupe(u8, p.call.tool_use_id),
            .content = content_for_history,
            .is_error = result.is_error,
        },
    });
    _ = log.record(p.call.tool_name, "executed", result.output, p.snap_id, p.snap_id != null, history_len) catch {};
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
                .text => |t| total += estimateTextTokens(t),
                .tool_use => total += 50,
                .tool_result => |tr| total += estimateTextTokens(tr.content),
                .thinking => |t| total += estimateTextTokens(t),
            }
        }
    }
    return total;
}

/// ASCII runs ~4 bytes/token, but CJK text runs ~2 bytes/token under
/// GLM-class tokenizers. The old uniform bytes/4 under-counted Chinese-heavy
/// sessions by ~2×, so real requests could blow past the model's context
/// (a 400 on every subsequent call) long before the estimate ever reached
/// the auto-compaction threshold. Over-estimating is safe (compacts a
/// little early); under-estimating strands the session.
fn estimateTextTokens(text: []const u8) u32 {
    var ascii: usize = 0;
    var wide: usize = 0;
    for (text) |c| {
        if (c < 0x80) ascii += 1 else wide += 1;
    }
    return @intCast(ascii / 4 + wide / 2);
}

/// Auto-compact if history exceeds phi threshold. Returns the history's
/// token estimate AFTER any compaction — callers reuse it instead of
/// re-scanning the whole history (the loop used to run the same O(n)
/// estimate twice per iteration).
fn maybeCompact(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer, file_writer: *std.Io.File.Writer, log: *op_log.OperationLog, facts: *?[]u8, model: []const u8, backend: llm.BackendType) u32 {
    const current_tokens = estimateHistoryTokens(history.items);
    // T4.1: the ceiling follows the ACTIVE model's context estimate, not
    // the old hardcoded 128K — an 8K local model now compacts at ~5K
    // instead of overflowing first.
    const ceiling = llm.provider.contextEstimate(model, backend);
    if (!compaction.needsCompaction(current_tokens, ceiling)) return current_tokens;

    applyFactsUpdate(history, facts, alloc, compactHistoryImpl(history, alloc, facts.*));
    log.bumpEpoch();
    std.Io.Writer.print(w, "  [Context auto-compacted: {d} messages remaining]\n", .{history.items.len}) catch {};
    std.Io.File.Writer.flush(file_writer) catch {};
    return estimateHistoryTokens(history.items);
}

/// Force compact history via LLM summary (used by /compact) — Claude-style:
/// the current provider summarizes the conversation and the summary replaces
/// the history, so earlier context is condensed instead of dropped. On any
/// failure the history is left untouched and the user is pointed at
/// /compact phi (truncation) rather than silently losing context.
fn compactHistory(
    history: *std.ArrayList(llm.Message),
    switcher: *ModelSwitcher,
    log: *op_log.OperationLog,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    total_in: *u64,
    total_out: *u64,
) !void {
    if (history.items.len <= 2) {
        try std.Io.Writer.writeAll(w, "  Nothing to compact.\n\n");
        return;
    }

    const prov = switcher.getProvider() catch |err| {
        try std.Io.Writer.print(w, "  Summary model unavailable ({}).\n  History untouched — try /compact phi for plain truncation.\n\n", .{err});
        return;
    };

    const before_msgs = history.items.len;
    const before_tokens = estimateHistoryTokens(history.items);
    try std.Io.Writer.print(w, "  Compacting: summarizing {d} messages (~{d} tokens)…\n", .{ before_msgs - 1, before_tokens });
    std.Io.File.Writer.flush(file_writer) catch {};

    const transcript = compaction.renderTranscript(alloc, history.items[1..]) catch |err| {
        try std.Io.Writer.print(w, "  Compaction failed: {}\n  History untouched — try /compact phi.\n\n", .{err});
        return;
    };
    defer alloc.free(transcript);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    defer alloc.free(sys_blocks);
    sys_blocks[0] = .{ .text = compaction.SUMMARY_INSTRUCTION };
    const user_blocks = try alloc.alloc(llm.ContentBlock, 1);
    defer alloc.free(user_blocks);
    user_blocks[0] = .{ .text = transcript };
    const msgs = [_]llm.Message{
        .{ .role = .system, .content = sys_blocks, .timestamp = util_time.nowMillis() },
        .{ .role = .user, .content = user_blocks, .timestamp = util_time.nowMillis() },
    };
    var resp = prov.complete(&msgs, .{
        .max_tokens = @min(switcher.settings.max_tokens, 2048),
        .temperature = 0.3,
    }) catch |err| {
        try std.Io.Writer.print(w, "  Summary call failed: {}.\n  History untouched — try /compact phi.\n\n", .{err});
        return;
    };
    // Extract the summary text before the response DOM arena is freed.
    var summary = std.ArrayList(u8).empty;
    defer summary.deinit(alloc);
    for (resp.content) |block| {
        if (block == .text) summary.appendSlice(alloc, block.text) catch break;
    }
    const usage = resp.usage;
    resp.free(alloc);
    total_in.* += usage.input_tokens;
    total_out.* += usage.output_tokens;

    if (summary.items.len == 0) {
        try std.Io.Writer.writeAll(w, "  Summary came back empty — history untouched.\n  Try /compact phi for plain truncation.\n\n");
        return;
    }

    try replaceHistoryWithSummary(history, alloc, summary.items);
    log.bumpEpoch();

    const after_tokens = estimateHistoryTokens(history.items);
    try std.Io.Writer.print(w, "  Compacted: {d} → {d} messages (~{d} → ~{d} tokens | summary call {d} in / {d} out)\n\n", .{
        before_msgs, history.items.len, before_tokens, after_tokens, usage.input_tokens, usage.output_tokens,
    });
}

/// Replace everything after the system prompt with a single user message
/// carrying the LLM summary (Claude-style compact outcome).
fn replaceHistoryWithSummary(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, summary: []const u8) !void {
    clearHistory(history, alloc);
    const text = try alloc.print(
        "Here is a summary of the conversation so far:\n\n{s}\n\nThis summary replaces the earlier conversation history. Continue from here.",
        .{summary},
    );
    errdefer alloc.free(text);
    const blocks = try alloc.alloc(llm.ContentBlock, 1);
    errdefer alloc.free(blocks);
    blocks[0] = .{ .text = text };
    try history.append(alloc, .{
        .role = .user,
        .content = blocks,
        .timestamp = util_time.nowMillis(),
    });
}

/// Force compact via phi truncation (used by /compact phi). This is the
/// original strategy: keep the system prompt + most recent 61.8% of
/// messages, drop the rest.
fn compactHistoryPhi(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer, log: *op_log.OperationLog, facts: *?[]u8) !void {
    if (history.items.len <= 2) {
        try std.Io.Writer.writeAll(w, "  Nothing to compact.\n\n");
        return;
    }
    const before = history.items.len;
    applyFactsUpdate(history, facts, alloc, compactHistoryImpl(history, alloc, facts.*));
    log.bumpEpoch();
    const est = estimateHistoryTokens(history.items);
    try std.Io.Writer.print(w, "  Compacted (phi): {d} → {d} messages (~{d} tokens)\n\n", .{ before, history.items.len, est });
}

/// T4.2: fold compaction's returned facts into the owned block + the
/// live history (swap by identity; append on first use). No-op on null
/// (nothing new — the block stays byte-identical, cache intact).
fn applyFactsUpdate(history: *std.ArrayList(llm.Message), facts: *?[]u8, alloc: std.mem.Allocator, new_facts: ?[]u8) void {
    const nf = new_facts orelse return;
    if (facts.*) |of| {
        const swapped = swapMemoryBlockText(history, alloc, of, nf);
        if (!swapped) {
            if (!appendSystemBlock(history, alloc, nf)) {
                alloc.free(nf);
                return; // OOM: keep the old block
            }
        }
        alloc.free(of);
    } else if (!appendSystemBlock(history, alloc, nf)) {
        alloc.free(nf);
        return;
    }
    facts.* = nf;
}

/// T4.2 signal words: lines from DROPPED messages that carry irreversible
/// facts (decisions, paths, constraints) survive truncation in a bounded
/// "key facts" block instead of being lost with the phi cut.
const fact_markers = [_][]const u8{
    "决定", "改用", "换成", "选定", "decision", "switch to", "instead", "let's", "we'll", "use ",
    "必须", "不要", "禁止", "不能", "must", "never", "always", "require",
};
const path_hint_bytes = "/";

fn lineIsKeyFact(line: []const u8) bool {
    if (line.len < 8 or line.len > 300) return false;
    for (fact_markers) |m| {
        if (std.mem.indexOf(u8, line, m) != null) return true;
    }
    return std.mem.indexOf(u8, line, path_hint_bytes) != null and
        (std.mem.indexOf(u8, line, ".zig") != null or
            std.mem.indexOf(u8, line, ".rs") != null or
            std.mem.indexOf(u8, line, ".ts") != null or
            std.mem.indexOf(u8, line, ".py") != null or
            std.mem.indexOf(u8, line, ".md") != null or
            std.mem.indexOf(u8, line, ".sql") != null or
            std.mem.indexOf(u8, line, ".json") != null);
}

/// Build/merge the key-facts text: NEW facts first (recent decisions
/// matter more), then surviving old ones, capped at ~200 tokens.
fn mergeKeyFacts(alloc: std.mem.Allocator, dropped: []const llm.Message, existing: ?[]const u8) ?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    aw.writer.writeAll("Key facts kept through compaction:\n") catch return null;
    var count: usize = 0;
    var i = dropped.len;
    while (i > 0) {
        i -= 1;
        const msg = dropped[i];
        if (msg.role != .user and msg.role != .assistant) continue;
        for (msg.content) |block| switch (block) {
            .text => |t| {
                var lines = std.mem.splitScalar(u8, t, '\n');
                while (lines.next()) |ln| {
                    const t2 = std.mem.trim(u8, ln, " \t>-*# ");
                    if (!lineIsKeyFact(t2)) continue;
                    // dedupe against what we already collected
                    if (std.mem.indexOf(u8, aw.written(), t2) != null) continue;
                    if (existing) |ex| {
                        if (std.mem.indexOf(u8, ex, t2) != null and count >= 8) continue; // keep old copy only via merge below
                    }
                    aw.writer.print("- {s}\n", .{t2}) catch return null;
                    count += 1;
                    if (tokens_mod.estimateTokens(aw.written()) > 180) break;
                }
            },
            else => {},
        };
        if (tokens_mod.estimateTokens(aw.written()) > 180) break;
    }
    // Append surviving old facts that still fit (they were already paid for).
    if (existing) |ex| {
        var lines = std.mem.splitScalar(u8, ex, '\n');
        while (lines.next()) |ln| {
            const t2 = std.mem.trim(u8, ln, " \t-");
            if (t2.len == 0 or std.mem.startsWith(u8, t2, "Key facts")) continue;
            if (std.mem.indexOf(u8, aw.written(), t2) != null) continue;
            if (tokens_mod.estimateTokens(aw.written()) + tokens_mod.estimateTokens(t2) > 200) break;
            aw.writer.print("- {s}\n", .{t2}) catch break;
        }
    }
    if (count == 0 and existing == null) return null;
    return alloc.dupe(u8, aw.written()) catch null;
}

/// Core compaction: keep system prompt + recent 61.8% of messages.
/// T4.2: before freeing the dropped messages, irreversible facts
/// (decisions/paths/constraints) are distilled into `facts_out`.
fn compactHistoryImpl(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, existing_facts: ?[]const u8) ?[]u8 {
    if (history.items.len <= 2) return null;

    // Keep system prompt (index 0) and recent messages up to phi target
    const total = history.items.len - 1; // exclude system prompt
    const target = compaction.condensationTarget(total);
    if (target >= total) return null;

    // Remove the oldest non-system messages down to the phi target,
    // freeing their content — previously every removal leaked.
    const new_len = 1 + target; // system + remaining
    var dropped: std.ArrayList(llm.Message) = .empty;
    defer dropped.deinit(alloc);
    while (history.items.len > new_len) {
        const msg = history.orderedRemove(1);
        dropped.append(alloc, msg) catch freeMessage(msg, alloc);
    }

    // T4.2: distill key facts from the dropped tail; free the messages
    // only after extraction. The RETURNED slice belongs to the caller —
    // it swaps the block into history and frees the previous text. Null
    // means "nothing new" (keep the existing block byte-identical).
    const new_facts = mergeKeyFacts(alloc, dropped.items, existing_facts);
    for (dropped.items) |msg| freeMessage(msg, alloc);

    // An index-based cut can split a tool_use/tool_result pair at the head;
    // repair trims the orphan so the next request stays wire-valid.
    repairToolPairing(history, alloc);
    return new_facts;
}

/// Clear history, keep only system prompt.
/// Free one history message's content blocks (strings + JSON trees).
fn freeMessage(msg: llm.Message, alloc: std.mem.Allocator) void {
    freeContentBlocks(alloc, msg.content);
}

/// True when every block is a tool_result — the agent loop's feedback
/// message. On the OpenAI wire each block becomes a standalone
/// `role:"tool"` message that is only valid right after the assistant
/// `tool_calls` message it answers.
fn isPureToolResultMessage(msg: llm.Message) bool {
    if (msg.content.len == 0) return false;
    for (msg.content) |block| {
        if (block != .tool_result) return false;
    }
    return true;
}

fn messageHasToolUse(msg: llm.Message) bool {
    for (msg.content) |block| {
        if (block == .tool_use) return true;
    }
    return false;
}

/// Repair tool_use/tool_result pairing after history surgery (compaction,
/// undo, rewind). Strict OpenAI-compatible gateways 400 the entire request
/// when a `role:"tool"` message outlives the assistant `tool_calls` it
/// answered (orphan head), or an assistant `tool_calls` loses its result
/// messages (dangling tail) — so both ends are trimmed back to a valid
/// boundary.
fn repairToolPairing(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) void {
    // Head: orphan tool results — the assistant tool_use before them was
    // removed by an index-based cut.
    while (history.items.len > 1 and isPureToolResultMessage(history.items[1])) {
        const msg = history.orderedRemove(1);
        freeMessage(msg, alloc);
    }
    // Tail: dangling tool_use — the results message after it was removed.
    while (history.items.len > 1) {
        const last = history.items[history.items.len - 1];
        if (last.role != .assistant or !messageHasToolUse(last)) break;
        const msg = history.pop().?;
        freeMessage(msg, alloc);
    }
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
/// Returns how many messages were actually removed — callers must only
/// bumpEpoch on a non-zero result (a no-op undo used to invalidate every
/// older rollback point's dialogue rewind).
fn undoLastExchange(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer) !usize {
    // Need at least system prompt + one user message + one assistant message
    if (history.items.len < 3) {
        try std.Io.Writer.writeAll(w, "  Nothing to undo.\n\n");
        return 0;
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

    // Removing the results message above can strand the assistant tool_use
    // it answered — a dangling tool_calls gets the next request 400'd.
    const len_before_repair = history.items.len;
    repairToolPairing(history, alloc);
    removed += len_before_repair - history.items.len;

    if (removed == 0) {
        try std.Io.Writer.writeAll(w, "  Nothing to undo.\n\n");
    } else {
        try std.Io.Writer.print(w, "  Undone: removed {d} message(s). History now has {d} messages.\n\n", .{ removed, history.items.len });
    }
    return removed;
}

/// Rewind: show rollback points and restore files to a previous checkpoint.
/// Claude-style: the conversation is rewound too — every message newer than
/// the checkpoint's timestamp is dropped, so files AND dialogue return to
/// that moment (the system prompt always survives).
fn rewindOperation(
    engine: *rollback_mod.RollbackEngine,
    history: *std.ArrayList(llm.Message),
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
    // Rewind boundary for the conversation: the message count at the moment
    // the op was recorded (index-precise — ms timestamps cannot split
    // messages inside one fast tool turn). Session start keeps only the
    // system prompt. A stale epoch (history rewritten by compact/clear/undo
    // since the point) invalidates the index — files rewind, dialogue does
    // not, instead of deleting innocent post-rewrite messages.
    const point_epoch: u64 = if (idx == 0) engine.op_log.epoch else rollback_points[idx - 1].epoch;
    const epoch_valid = point_epoch == engine.op_log.epoch;
    const truncate_to: usize = if (idx == 0) 1 else rollback_points[idx - 1].history_len;

    // Preview first
    const preview = engine.previewRollback(target_op_id) catch {
        try std.Io.Writer.writeAll(w, "  Error previewing rollback.\n\n");
        return;
    };

    const messages_to_drop: usize = if (epoch_valid and history.items.len > truncate_to) history.items.len - truncate_to else 0;

    try std.Io.Writer.print(w, "\n  Rollback preview:\n", .{});
    try std.Io.Writer.print(w, "    Files to restore: {d}\n", .{preview.files_to_restore});
    try std.Io.Writer.print(w, "    Files to delete:  {d}\n", .{preview.files_to_delete});
    try std.Io.Writer.print(w, "    Operations to undo: {d}\n", .{preview.operations_to_undo});
    if (epoch_valid) {
        try std.Io.Writer.print(w, "    Messages to drop: {d} (conversation rewinds with the files)\n", .{messages_to_drop});
    } else {
        try std.Io.Writer.writeAll(w, "    Messages to drop: 0 (history was compacted/cleared since this point — files rewind only)\n");
    }
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
    // Conversation rewind: pop messages down to the checkpoint length
    // (system prompt at index 0 always survives). Skipped on stale epoch.
    var dropped: usize = 0;
    while (epoch_valid and history.items.len > @max(truncate_to, 1)) {
        const msg = history.orderedRemove(history.items.len - 1);
        freeMessage(msg, alloc);
        dropped += 1;
    }
    // The recorded history_len can fall between a tool_use and its results —
    // trim the stranded pair end so the next request stays wire-valid.
    const len_before_repair = history.items.len;
    repairToolPairing(history, alloc);
    dropped += len_before_repair - history.items.len;

    try std.Io.Writer.print(w, "  ({d} restored, {d} deleted, {d} errors, {d} messages rewound)\n\n", .{
        result.restored_files.len,
        result.deleted_files.len,
        result.errors.len,
        dropped,
    });

    engine.freeResult(result);
}

// ──── Interactive config menu ────

fn autoSaveSettings(w: *std.Io.Writer, file_writer: *std.Io.File.Writer, switcher: *ModelSwitcher, alloc: std.mem.Allocator, io: std.Io) void {
    config_mod.saveSettings(&switcher.settings, alloc, io) catch |err| {
        w.print("  保存失败: {any}\n", .{err}) catch {};
        return;
    };
    // Own save — refresh the hot-reload baseline so the next prompt does
    // not "reload" what we just wrote ourselves.
    settings_fp_baseline = config_mod.settingsFingerprint(alloc, io);
    w.writeAll("  ✓ 已自动保存\n") catch {};
    std.Io.File.Writer.flush(file_writer) catch {};
}

/// Cross-session input history for the line editor: `.ziv/input_history` in
/// the working directory, newest last, capped at INPUT_HISTORY_MAX entries.
/// Whole-file rewrite on every commit (≤ ~50 KB) — no append mode needed and
/// rotation comes for free.
const INPUT_HISTORY_FILE = ".ziv/input_history";
/// Cross-process mutex for history saves. Locked via createFile's atomic
/// flock (blocking); its inode never changes — locking the history file
/// itself would be voided by the tmp+rename swap that replaces it.
const INPUT_HISTORY_LOCK = ".ziv/input_history.lock";
const INPUT_HISTORY_MAX: usize = 500;

fn loadInputHistory(alloc: std.mem.Allocator, io: std.Io, history: *std.ArrayList([]u8)) void {
    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, INPUT_HISTORY_FILE, alloc, std.Io.Limit.limited(256 * 1024)) catch return;
    defer alloc.free(contents);
    // Collect first, keep the TAIL: breaking early on an oversized file would
    // recall the OLDEST entries and silently drop the newest ones.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines.append(alloc, line) catch return;
    }
    const start = if (lines.items.len > INPUT_HISTORY_MAX) lines.items.len - INPUT_HISTORY_MAX else 0;
    for (lines.items[start..]) |line| {
        if (history.items.len > 0 and std.mem.eql(u8, history.items[history.items.len - 1], line)) continue;
        const owned = alloc.dupe(u8, line) catch return;
        history.append(alloc, owned) catch {
            alloc.free(owned);
            return;
        };
    }
}

/// Merge this session's entries with whatever another concurrent window has
/// written since our startup snapshot. Pure function over line lists
/// (borrowed slices); returns the tail-capped merge, caller owns the result.
fn mergeInputHistory(alloc: std.mem.Allocator, file_lines: []const []const u8, session: []const []const u8) ![]const []const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    errdefer merged.deinit(alloc);
    try merged.appendSlice(alloc, file_lines);
    for (session, 0..) |line, i| {
        // Consecutive duplicates collapse (matches the pre-concurrency
        // save behavior).
        if (merged.items.len > 0 and std.mem.eql(u8, merged.items[merged.items.len - 1], line)) continue;
        // Present elsewhere: a startup-loaded echo — skip. The FINAL session
        // line is the just-typed command: move it to the tail so a re-typed
        // old command recalls last, exactly like the single-window behavior
        // this merge replaced (a global skip used to strand it mid-file).
        const is_final = i + 1 == session.len;
        var found: ?usize = null;
        for (merged.items, 0..) |m, mi| {
            if (std.mem.eql(u8, m, line)) {
                found = mi;
                break;
            }
        }
        if (found) |mi| {
            if (is_final) {
                const moved = merged.orderedRemove(mi);
                try merged.append(alloc, moved);
            }
            continue;
        }
        try merged.append(alloc, line);
    }
    const start = if (merged.items.len > INPUT_HISTORY_MAX) merged.items.len - INPUT_HISTORY_MAX else 0;
    const tail = try alloc.dupe([]const u8, merged.items[start..]);
    merged.deinit(alloc);
    return tail;
}

/// Persist the in-memory input history (the line editor already appended the
/// just-committed line, with consecutive-duplicate suppression). Concurrent
/// windows in the same directory MERGE instead of last-writer-wins, and the
/// write is tmp+rename atomic so a parallel reader never sees a half file.
fn saveInputHistory(alloc: std.mem.Allocator, history: *std.ArrayList([]u8)) void {
    if (history.items.len == 0) return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // Session tail (single-line entries only — the file is one entry per
    // line; multi-line pastes stay session-only, up-arrow recall works).
    var session: std.ArrayList([]const u8) = .empty;
    defer session.deinit(alloc);
    const start = if (history.items.len > INPUT_HISTORY_MAX) history.items.len - INPUT_HISTORY_MAX else 0;
    for (history.items[start..]) |line| {
        if (std.mem.indexOfScalar(u8, line, '\n') != null) continue;
        session.append(alloc, line) catch return;
    }

    // What's on disk right now (another window may have written since our
    // startup snapshot): merge, keeping their entries and ours. The whole
    // read-merge-write runs under a cross-process flock — two windows
    // committing in the same millisecond used to last-writer-wins anyway.
    // flock goes through libc directly (blocking), NOT via the Io vtable:
    // createFile's embedded .lock under std.Io.Threaded failed silently and
    // the losing window skipped its save entirely.
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    var lock_file = std.Io.Dir.cwd().createFile(io_state.io(), INPUT_HISTORY_LOCK, .{
        .read = true,
        .truncate = false,
    }) catch blk: {
        // No lock file, no lock — but the history still deserves a save.
        break :blk null;
    };
    defer if (lock_file) |*lf| lf.close(io_state.io());
    var contents_owned: ?[]u8 = null;
    defer if (contents_owned) |c| alloc.free(c);
    var history_locked = false;
    defer if (history_locked) {
        _ = std.c.flock(lock_file.?.handle, std.posix.LOCK.UN);
    };
    if (lock_file != null) {
        // Bounded acquisition: a suspended (Ctrl-Z'd) holder never releases,
        // and a blocking LOCK.EX on the Enter path would freeze this prompt
        // forever. Retry briefly, then degrade to a lockless save — same
        // semantics as the no-lock-file fallback.
        var tries: usize = 0;
        while (tries < 5) : (tries += 1) {
            if (std.c.flock(lock_file.?.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) == 0) {
                history_locked = true;
                break;
            }
            var req: std.c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&req, null);
        }
        if (!history_locked) {
            logger.warning("input history lock busy — saving without lock", .{});
            lock_file.?.close(io_state.io());
            lock_file = null;
        }
    }
    var file_lines: std.ArrayList([]const u8) = .empty;
    defer file_lines.deinit(alloc);
    if (std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io_state.io(), INPUT_HISTORY_FILE, alloc, std.Io.Limit.limited(256 * 1024))) |contents| {
        // OWNERSHIP: file_lines borrows slices into `contents`, so it must
        // outlive the if-block — a defer inside the block freed it on block
        // exit and merge then read freed memory (0xAA garbage entries).
        contents_owned = contents;
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            file_lines.append(alloc, line) catch break;
        }
    } else |_| {}

    const merged = mergeInputHistory(alloc, file_lines.items, session.items) catch return;
    defer alloc.free(merged);
    for (merged) |line| {
        buf.appendSlice(alloc, line) catch return;
        buf.append(alloc, '\n') catch return;
    }

    fs_ops.ensureDir(".ziv") catch return;
    var tmp_buf: [128]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp{d}", .{ INPUT_HISTORY_FILE, std.c.getpid() }) catch return;
    fs_ops.writeFile(tmp, buf.items) catch
        return logger.warning("input history save failed", .{});
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), INPUT_HISTORY_FILE, io_state.io()) catch {
        // Rename failed — fall back to a plain write so the history is at
        // least saved, not silently dropped.
        fs_ops.writeFile(INPUT_HISTORY_FILE, buf.items) catch
            logger.warning("input history save failed", .{});
    };
}

/// Swap in freshly loaded (hot-reloaded) settings, dropping cached providers
/// whose credentials changed so the next getProvider() rebuilds them.
fn applyReloadedSettings(switcher: *ModelSwitcher, fresh: config_mod.Settings) void {
    invalidateStaleProviders(switcher, &fresh);
    switcher.settings = fresh;
}

/// True when both slice-optionals are null or hold equal bytes.
fn sameOptSlice(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Rebuild the baked system-prompt text (history[0] block 0) after the
/// setting changed via /config or a settings hot reload. Without this the
/// menu reported "(已保存)" while the model kept answering with the old
/// prompt until /clear or restart — the baked-in variant of
/// "配置仅启动加载" (bug-patterns.md).
fn reapplySystemPromptIfNeeded(
    applied: *?[]const u8,
    owned: *?[]u8,
    prompt: *[]const u8,
    history: *std.ArrayList(llm.Message),
    alloc: std.mem.Allocator,
    setting: ?[]const u8,
) void {
    if (sameOptSlice(applied.*, setting)) return;
    applied.* = setting;
    if (owned.*) |sp| alloc.free(sp);
    owned.* = system_prompt_mod.buildSystemPrompt(alloc, setting) catch null;
    prompt.* = owned.* orelse system_prompt_mod.default_system_prompt;
    if (history.items.len == 0) return;
    // Content blocks are const — rebuild the slice with the new prompt,
    // carrying over any memory/skill-manifest blocks after it.
    const old = history.items[0].content;
    const nb = alloc.alloc(llm.ContentBlock, old.len) catch return;
    nb[0] = .{ .text = prompt.* };
    for (old[1..], 1..) |b, i| nb[i] = b;
    alloc.free(@constCast(old));
    history.items[0].content = nb;
}

/// φ drift gate (T1.3): live-topic cosine below 1/PHI_INVERSE (≈0.618)
/// means the session's ranking anchor no longer matches the conversation.
fn shouldReanchor(baseline: []const f32, current: []const f32) bool {
    const drift_threshold: f32 = @floatCast(1.0 / math_mod.constants.PHI_INVERSE);
    return embedding_mod.cosine(baseline, current) < drift_threshold;
}

/// First text block of a message's content (user turns may carry tool
/// blocks; the typed text is what defines the topic).
fn firstTextOf(blocks: []const llm.ContentBlock) ?[]const u8 {
    for (blocks) |b| switch (b) {
        .text => |t| return t,
        else => {},
    };
    return null;
}

/// Mean embedding of the last ≤3 user turns — the "live topic" vector.
/// Null before any non-empty user turn. Caller frees the result.
fn topicVectorOfLastUserTurns(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) ?[]f32 {
    var texts: [3][]const u8 = undefined;
    var n: usize = 0;
    var i = history.items.len;
    while (i > 0 and n < texts.len) {
        i -= 1;
        const m = history.items[i];
        if (m.role != .user) continue;
        if (firstTextOf(m.content)) |t| {
            if (t.len > 0) {
                texts[n] = t;
                n += 1;
            }
        }
    }
    if (n == 0) return null;
    const sum = alloc.alloc(f32, embedding_mod.DIMS) catch return null;
    var owned = false; // handed to caller on success
    defer if (!owned) alloc.free(sum);
    @memset(sum, 0);
    var count: usize = 0;
    for (texts[0..n]) |t| {
        const ev = embedding_mod.embed(alloc, t) catch continue;
        defer alloc.free(ev);
        for (sum, 0..) |*sv, k| sv.* += ev[k];
        count += 1;
    }
    if (count == 0) return null;
    owned = true;
    const inv = 1.0 / @as(f32, @floatFromInt(count));
    for (sum) |*sv| sv.* *= inv;
    return sum;
}

/// Replace the memory block's text inside history[0] (rebuild the block
/// slice like reapplySystemPromptIfNeeded does — content slices are const).
/// Identified by the OLD text slice identity; returns false without
/// touching history when no block matches (caller frees the new text).
fn swapMemoryBlockText(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, old_text: []const u8, new_text: []const u8) bool {
    if (history.items.len == 0) return false;
    const old = history.items[0].content;
    const nb = alloc.alloc(llm.ContentBlock, old.len) catch return false;
    var hit = false;
    for (old, 0..) |b, bi| {
        if (!hit) switch (b) {
            .text => |t| if (t.ptr == old_text.ptr and t.len == old_text.len) {
                nb[bi] = .{ .text = new_text };
                hit = true;
                continue;
            },
            else => {},
        };
        nb[bi] = b;
    }
    if (!hit) {
        alloc.free(nb);
        return false;
    }
    alloc.free(@constCast(old));
    history.items[0].content = nb;
    return true;
}

/// T8: append one block to history[0]'s system content (rebuild + grow,
/// same ownership pattern as the swap above).
fn appendSystemBlock(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, text: []const u8) bool {
    if (history.items.len == 0) return false;
    const old = history.items[0].content;
    const nb = alloc.alloc(llm.ContentBlock, old.len + 1) catch return false;
    @memcpy(nb[0..old.len], old);
    nb[old.len] = .{ .text = text };
    alloc.free(@constCast(old));
    history.items[0].content = nb;
    return true;
}

/// T8: drop the block whose text slice matches (rebuild + shrink).
fn removeSystemBlockByText(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, text: []const u8) bool {
    if (history.items.len == 0) return false;
    const old = history.items[0].content;
    var hit: ?usize = null;
    for (old, 0..) |b, i| switch (b) {
        .text => |t| if (t.ptr == text.ptr and t.len == text.len) {
            hit = i;
            break;
        },
        else => {},
    };
    const idx = hit orelse return false;
    const nb = alloc.alloc(llm.ContentBlock, old.len - 1) catch return false;
    @memcpy(nb[0..idx], old[0..idx]);
    @memcpy(nb[idx..], old[idx + 1 ..]);
    alloc.free(@constCast(old));
    history.items[0].content = nb;
    return true;
}

/// T8: read .ziv/plan.md (≤8 KiB). Null when absent/unreadable.
fn readPlanFile(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, ".ziv/plan.md", alloc, .limited(8 * 1024)) catch null;
}

/// T8: the plan's system-prompt summary — trimmed non-empty lines under
/// its own ~150-token budget (independent of the memory block's).
fn planSummaryText(alloc: std.mem.Allocator, raw: []const u8) ?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    aw.writer.writeAll("Active plan (.ziv/plan.md):\n") catch return null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0) continue;
        aw.writer.print("- {s}\n", .{t}) catch return null;
        if (tokens_mod.estimateTokens(aw.written()) > 150) break;
    }
    if (aw.written().len == 0) return null;
    return alloc.dupe(u8, aw.written()) catch null;
}

/// T8: keep the plan anchor block in sync with .ziv/plan.md — call at
/// every prompt. Content fingerprint (not mtime) decides, so a touch
/// never churns the prompt; removing the file removes the block.
fn refreshPlanAnchor(
    history: *std.ArrayList(llm.Message),
    plan_block: *?[]u8,
    plan_raw: *?[]u8,
    alloc: std.mem.Allocator,
    io: std.Io,
) void {
    const raw = readPlanFile(alloc, io) orelse {
        if (plan_block.*) |pb| {
            if (removeSystemBlockByText(history, alloc, pb)) {
                alloc.free(pb);
                plan_block.* = null;
            }
        }
        if (plan_raw.*) |pr| {
            alloc.free(pr);
            plan_raw.* = null;
        }
        return;
    };
    const changed = if (plan_raw.*) |pr| !std.mem.eql(u8, pr, raw) else true;
    if (!changed) {
        alloc.free(raw);
        return;
    }
    if (plan_raw.*) |pr| alloc.free(pr);
    plan_raw.* = raw;
    const summary = planSummaryText(alloc, raw) orelse {
        if (plan_block.*) |pb| {
            if (removeSystemBlockByText(history, alloc, pb)) {
                alloc.free(pb);
                plan_block.* = null;
            }
        }
        return;
    };
    const old = plan_block.*;
    plan_block.* = null;
    if (old) |pb| {
        const swapped = swapMemoryBlockText(history, alloc, pb, summary);
        if (!swapped) _ = removeSystemBlockByText(history, alloc, pb);
        alloc.free(pb);
        if (swapped) {
            plan_block.* = summary;
            return;
        }
    }
    if (appendSystemBlock(history, alloc, summary)) {
        plan_block.* = summary;
    } else alloc.free(summary);
}

/// Old settings slices are intentionally not freed: reloads happen once per
/// external file edit (rare), and a bounded leak is cheaper than retrofitting
/// ownership through every Settings consumer.
fn invalidateStaleProviders(switcher: *ModelSwitcher, fresh: *const config_mod.Settings) void {
    const differs = struct {
        fn f(a: ?[]const u8, b: ?[]const u8) bool {
            if (a == null and b == null) return false;
            if (a == null or b == null) return true;
            return !std.mem.eql(u8, a.?, b.?);
        }
    }.f;
    const old = switcher.settings;
    if (switcher.openai_provider != null and
        (differs(old.api_keys.openai, fresh.api_keys.openai) or
            differs(old.api_keys.openai_base_url, fresh.api_keys.openai_base_url)))
    {
        if (switcher.openai_provider) |*p| p.deinit();
        switcher.openai_provider = null;
    }
    if (switcher.claude_provider != null and
        (differs(old.api_keys.anthropic, fresh.api_keys.anthropic) or
            differs(old.api_keys.anthropic_base_url, fresh.api_keys.anthropic_base_url)))
    {
        if (switcher.claude_provider) |*p| p.deinit();
        switcher.claude_provider = null;
    }
    if (switcher.ollama_provider != null and
        !std.mem.eql(u8, old.api_keys.ollama_host, fresh.api_keys.ollama_host))
    {
        if (switcher.ollama_provider) |*p| p.deinit();
        switcher.ollama_provider = null;
    }
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
        var b6: [64]u8 = undefined;
        const items = [_][]const u8{
            "API Keys",
            try_std_fmt(&b1, "默认模型: {s}", .{switcher.settings.default_model}),
            try_std_fmt(&b2, "最大 tokens: {d}", .{switcher.settings.max_tokens}),
            try_std_fmt(&b6, "记忆注入预算: {d} tokens", .{switcher.settings.memory_budget_tokens}),
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
                var mbbuf: [32]u8 = undefined;
                const mval = menu.readLine(r, w, file_writer, "  记忆注入预算 tokens (200-8000): ", &mbbuf) catch continue;
                if (mval.len == 0) continue;
                const mbt = std.fmt.parseInt(u32, mval, 10) catch {
                    try std.Io.Writer.writeAll(w, "  无效数字\n");
                    continue;
                };
                if (mbt >= 200 and mbt <= 8000) {
                    switcher.settings.memory_budget_tokens = mbt;
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                } else try std.Io.Writer.writeAll(w, "  超出范围\n");
            },
            4 => {
                const mode_items = [_][]const u8{ "Default — 危险操作询问", "Accept Edits — 自动接受编辑", "Plan — 只读", "Bypass — 跳过检查", "Don't Ask — 自动拒绝", "Auto — LLM 分类" };
                const mode_map = [_]auth.PermissionMode{ .default, .accept_edits, .plan, .bypass, .dont_ask, .auto };
                const mp = (menu.select(w, r, file_writer, "选择权限模式:", &mode_items, 0) catch continue) orelse continue;
                switcher.settings.permission_mode = mode_map[mp];
                autoSaveSettings(w, file_writer, switcher, alloc, io);
            },
            5 => {
                switcher.settings.checkpointing_enabled = !switcher.settings.checkpointing_enabled;
                autoSaveSettings(w, file_writer, switcher, alloc, io);
            },
            6 => {
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
            7 => break,
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
    // promptCustomModel returns a heap string; static table names are not.
    // Track which one we hold so it is freed exactly once (default_model
    // gets its own dupe below — the old code leaked the prompt's copy).
    var owned_name: ?[]const u8 = null;
    defer if (owned_name) |n| alloc.free(n);
    const name: []const u8 = if (picked == llm.KNOWN_MODELS.len) blk: {
        const n = (try promptCustomModel(w, r, file_writer, switcher, alloc)) orelse return;
        owned_name = n;
        break :blk n;
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
    // DOM lives in an arena that dies here; model names are duped out below
    // (the old leaky parse left the whole DOM behind on the session heap).
    var dom_arena = std.heap.ArenaAllocator.init(alloc);
    defer dom_arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, dom_arena.allocator(), body, .{}) catch return error.BadJSON;

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
    // Pipes/scripts get the text table directly — the interactive picker
    // used to spin its redraw loop on the piped byte stream.
    if (!menu.isTty()) {
        try printModelInfo(w, switcher);
        return;
    }
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
    settings_fp_baseline = config_mod.settingsFingerprint(std.heap.smp_allocator, io);
    try std.Io.Writer.print(w, "  ✓ 已切换: {s} ({s})\n\n", .{ switcher.modelName(), switcher.backendLabel() });
}

fn printModelInfo(w: *std.Io.Writer, switcher: *ModelSwitcher) !void {
    try std.Io.Writer.writeAll(w, "\n  Current model: ");
    try std.Io.Writer.print(w, "{s} ({s})\n\n", .{ switcher.modelName(), switcher.backendLabel() });

    try std.Io.Writer.writeAll(w, "  Available models:\n");
    try std.Io.Writer.writeAll(w, "  ┌─────────────────────┬──────────┬────────────────────────────────┐\n");
    try std.Io.Writer.writeAll(w, "  │ Model               │ Backend  │ Description                    │\n");
    try std.Io.Writer.writeAll(w, "  ├─────────────────────┼──────────┼────────────────────────────────┤\n");

    for (&llm.KNOWN_MODELS) |entry| {
        const marker: []const u8 = if (std.mem.eql(u8, entry.name, switcher.modelName())) "*" else " ";
        const backend_str = switch (entry.backend) {
            .claude => "Claude",
            .openai => "OpenAI",
            .ollama => "Ollama",
        };
        // Bordered rows matching the header (the old space-padded rows
        // under a box header were the "table that isn't a table"); padding
        // is display-width aware so non-ASCII stays aligned.
        var cell: [40]u8 = undefined;
        const name_cell = std.fmt.bufPrint(&cell, "{s} {s}", .{ marker, entry.name }) catch entry.name;
        try std.Io.Writer.writeAll(w, "  │ ");
        try format_mod.writePadded(w, name_cell, 19);
        try std.Io.Writer.writeAll(w, " │ ");
        try format_mod.writePadded(w, backend_str, 8);
        try std.Io.Writer.writeAll(w, " │ ");
        try format_mod.writePadded(w, entry.description, 30);
        try std.Io.Writer.writeAll(w, " │\n");
    }
    try std.Io.Writer.writeAll(w, "  └─────────────────────┴──────────┴────────────────────────────────┘\n");

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
        \\  /compact          Summarize the conversation (LLM) to free tokens
        \\  /compact phi      Truncate history to the recent 61.8% (no LLM call)
        \\  /clear            Clear conversation, start fresh (alias: /reset, /new)
        \\  /context          Show current context/token usage
        \\  /undo             Undo last exchange
        \\  /history          Show operation history
        \\  /rewind           Rewind files AND conversation to a checkpoint
        \\  /memory           Show injected and stored memories
        \\  /research <topic> Web research with phi-curated solutions
        \\  /diagnose <q>     Self-diagnose a weak answer vs your concern
        \\  /knowledge         Browse the knowledge graph (semantic tier)
        \\  /skills            List available skills (/<name> to invoke)
        \\  /mcp               MCP servers: list/connect/disconnect
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
        \\  Don't Ask     — Auto-deny whatever would ask (reads still run)
        \\  Auto          — LLM classifier decides
        \\
        \\Example:
        \\  /config                       Open configuration menu
        \\  /model claude-sonnet-4-6      Switch to Claude Sonnet
        \\  /compact                      Summarize the conversation (LLM)
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

test "replaceHistoryWithSummary swaps history for one summary message" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc);

    // System prompt + two exchanges, all heap-owned strings.
    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    sys_blocks[0] = .{ .text = try alloc.dupe(u8, "system prompt") };
    try history.append(alloc, .{ .role = .system, .content = sys_blocks, .timestamp = 0 });
    for ([_][]const u8{ "q1", "a1", "q2" }) |txt| {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, txt) };
        try history.append(alloc, .{ .role = .user, .content = b, .timestamp = 0 });
    }
    try std.testing.expectEqual(@as(usize, 4), history.items.len);

    try replaceHistoryWithSummary(&history, alloc, "1. Primary Request: test the compact swap");

    try std.testing.expectEqual(@as(usize, 2), history.items.len);
    try std.testing.expect(history.items[0].role == .system);
    try std.testing.expect(history.items[1].role == .user);
    try std.testing.expect(std.mem.indexOf(u8, history.items[1].content[0].text, "Primary Request: test the compact swap") != null);

    // Full teardown with the production free path (zero leaks).
    clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
}

test "clearHistory survives assistant tool_use + tool_result pair (no double free)" {
    // Regression for the /clear crash: the tool_result's tool_use_id used to
    // BORROW the assistant message's id (same allocation), so freeing the
    // pair double-freed it; literal result contents were freed as well.
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    sys_blocks[0] = .{ .text = try alloc.dupe(u8, "sys") };
    try history.append(alloc, .{ .role = .system, .content = sys_blocks, .timestamp = 0 });

    const owned_id = try alloc.dupe(u8, "call_x");
    const tu_blocks = try alloc.alloc(llm.ContentBlock, 1);
    tu_blocks[0] = .{ .tool_use = .{ .id = owned_id, .name = try alloc.dupe(u8, "FileWrite"), .input = .null } };
    try history.append(alloc, .{ .role = .assistant, .content = tu_blocks, .timestamp = 0 });

    // Simulate what the fixed construction produces: duped id + owned content.
    const tr_blocks = try alloc.alloc(llm.ContentBlock, 1);
    tr_blocks[0] = .{ .tool_result = .{
        .tool_use_id = try alloc.dupe(u8, owned_id),
        .content = try alloc.dupe(u8, "wrote 2 bytes"),
    } };
    try history.append(alloc, .{ .role = .user, .content = tr_blocks, .timestamp = 0 });

    // The production free path must not double-free the shared-looking id.
    clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
}

test "estimateTextTokens weights CJK above bytes/4" {
    // 8 CJK chars = 24 bytes: bytes/4 says 6 tokens, real usage is 8-12 —
    // the old uniform estimate under-counted Chinese-heavy sessions ~2×.
    try std.testing.expectEqual(@as(u32, 12), estimateTextTokens("一二三四五六七八"));
    try std.testing.expect(estimateTextTokens("一二三四五六七八") > "一二三四五六七八".len / 4);
    // ASCII keeps the classic chars/4 approximation.
    try std.testing.expectEqual(@as(u32, 1), estimateTextTokens("abcd"));
}

test "compactHistoryImpl repairs tool pairing after the phi cut" {
    // Regression for the mid-session 400: the index-based cut could leave an
    // orphan tool_result at the head — on the OpenAI wire a role:"tool"
    // message whose assistant tool_calls was dropped, which strict gateways
    // reject wholesale.
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    sys_blocks[0] = .{ .text = try alloc.dupe(u8, "sys") };
    try history.append(alloc, .{ .role = .system, .content = sys_blocks, .timestamp = 0 });

    // 4 full exchanges: user → assistant(tool_use) → user(tool_result).
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const q = try alloc.alloc(llm.ContentBlock, 1);
        q[0] = .{ .text = try alloc.dupe(u8, "question") };
        try history.append(alloc, .{ .role = .user, .content = q, .timestamp = 0 });

        const id = try std.fmt.allocPrint(alloc, "call_{d}", .{i});
        const tu = try alloc.alloc(llm.ContentBlock, 1);
        tu[0] = .{ .tool_use = .{ .id = id, .name = try alloc.dupe(u8, "Bash"), .input = .null } };
        try history.append(alloc, .{ .role = .assistant, .content = tu, .timestamp = 0 });

        const tr = try alloc.alloc(llm.ContentBlock, 1);
        tr[0] = .{ .tool_result = .{
            .tool_use_id = try alloc.dupe(u8, id),
            .content = try alloc.dupe(u8, "ok"),
        } };
        try history.append(alloc, .{ .role = .user, .content = tr, .timestamp = 0 });
        // `id` ownership moved into the tool_use block — history frees it.
    }
    try std.testing.expectEqual(@as(usize, 13), history.items.len);

    if (compactHistoryImpl(&history, alloc, null)) |nf| std.testing.allocator.free(nf);

    // Head must not be an orphan tool-result message; tail must not be a
    // dangling assistant tool_use.
    try std.testing.expect(!isPureToolResultMessage(history.items[1]));
    const last = history.items[history.items.len - 1];
    try std.testing.expect(!(last.role == .assistant and messageHasToolUse(last)));

    clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
}

test "undoLastExchange strips a stranded assistant tool_use" {
    // [sys, user, assistant(tool_use), user(tool_results), assistant(final)]
    // — undo drops the last two, which used to strand the tool_use: the next
    // request carried tool_calls with no tool responses (a 400 on strict
    // gateways).
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    sys_blocks[0] = .{ .text = try alloc.dupe(u8, "sys") };
    try history.append(alloc, .{ .role = .system, .content = sys_blocks, .timestamp = 0 });

    const q = try alloc.alloc(llm.ContentBlock, 1);
    q[0] = .{ .text = try alloc.dupe(u8, "run ls") };
    try history.append(alloc, .{ .role = .user, .content = q, .timestamp = 0 });

    const tu = try alloc.alloc(llm.ContentBlock, 1);
    tu[0] = .{ .tool_use = .{ .id = try alloc.dupe(u8, "call_1"), .name = try alloc.dupe(u8, "Bash"), .input = .null } };
    try history.append(alloc, .{ .role = .assistant, .content = tu, .timestamp = 0 });

    const tr = try alloc.alloc(llm.ContentBlock, 1);
    tr[0] = .{ .tool_result = .{
        .tool_use_id = try alloc.dupe(u8, "call_1"),
        .content = try alloc.dupe(u8, "file_a"),
    } };
    try history.append(alloc, .{ .role = .user, .content = tr, .timestamp = 0 });

    const fin = try alloc.alloc(llm.ContentBlock, 1);
    fin[0] = .{ .text = try alloc.dupe(u8, "done") };
    try history.append(alloc, .{ .role = .assistant, .content = fin, .timestamp = 0 });

    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    _ = try undoLastExchange(&history, alloc, &w);

    // The tool_use message must be gone too — history ends at the prompt.
    try std.testing.expectEqual(@as(usize, 2), history.items.len);
    try std.testing.expect(history.items[1].role == .user);

    clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
}

test "toolArgSummary picks the informative field and caps length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cmd = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":\"ls -la /tmp\"}", .{});
    try std.testing.expectEqualStrings("(ls -la /tmp)", toolArgSummary(a, "Bash", cmd));

    const path = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"/etc/hosts\"}", .{});
    try std.testing.expectEqualStrings("(/etc/hosts)", toolArgSummary(a, "FileRead", path));

    // Empty object: nothing to show.
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{});
    try std.testing.expectEqualStrings("", toolArgSummary(a, "ToolSearch", empty));

    // Long command gets the ellipsis cap.
    const longv = try std.json.parseFromSliceLeaky(std.json.Value, a,
        "{\"command\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}", .{});
    const out = toolArgSummary(a, "Bash", longv);
    try std.testing.expect(std.mem.endsWith(u8, out, "…)"));
}

test "reflectLlmWithTimeout abandons a hung gateway" {
    const alloc = std.testing.allocator;
    const Fake = struct {
        fn complete(_: *anyopaque, _: []const llm.provider.Message, _: llm.provider.CompleteOptions) anyerror!llm.provider.CompleteResponse {
            var req: std.c.timespec = .{ .sec = 10, .nsec = 0 }; // "hang"
            _ = std.c.nanosleep(&req, null);
            return error.Hung;
        }
        fn stream(_: *anyopaque, _: []const llm.provider.Message, _: llm.provider.CompleteOptions, _: ?*anyopaque, _: *const llm.provider.StreamCallback) anyerror!void {}
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn noop(_: *anyopaque) void {}
    };
    const vt = llm.provider.ProviderVTable{
        .complete_fn = Fake.complete,
        .stream_fn = Fake.stream,
        .count_tokens_fn = null,
        .supports_tool_use_fn = Fake.yes,
        .supports_streaming_fn = Fake.yes,
        .deinit_fn = Fake.noop,
    };
    const fake = llm.Provider{ .ptr = @ptrFromInt(16), .vtable = &vt };
    const queries = [_][]const u8{"hung-gateway-probe"};
    const t0 = util_time.nowMillis();
    // page_allocator: the detached hung worker's prompt allocations are
    // intentionally abandoned — the leak-checking allocator would flag them.
    _ = alloc;
    const res = reflectLlmWithTimeout(fake, &queries, std.heap.page_allocator, 300);
    const elapsed = util_time.nowMillis() - t0;
    try std.testing.expect(res == null);
    // Returned at the 300 ms deadline (± scheduling slack), not after 60 s.
    try std.testing.expect(elapsed < 2500);
}

test "writeMarginLines keeps the margin across chunk splits" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    // Response-style: first line indented too (at_line_start starts true).
    var ls = true;
    try writeMarginLines(w, "hello\nwor", " ", &ls);
    try writeMarginLines(w, "ld\nlast", " ", &ls);
    try std.testing.expectEqualStrings(" hello\n world\n last", aw.written());

    // Preview-style: first line already positioned, only continuations.
    aw.writer.end = 0;
    var ls2 = false;
    try writeMarginLines(w, "file_a\nfile_b\n", "  ", &ls2);
    try std.testing.expectEqualStrings("file_a\n  file_b\n", aw.written());

    // Trailing newline does not leave a dangling indent.
    aw.writer.end = 0;
    var ls3 = false;
    try writeMarginLines(w, "x\n", "  ", &ls3);
    try std.testing.expectEqualStrings("x\n", aw.written());
}

test "plan summary, append and remove system blocks (T8)" {
    const alloc = std.testing.allocator;
    const raw = "# 计划：完成迁移\n\n- [x] 分析旧表\n- [ ] 写迁移脚本\n";
    const summary = planSummaryText(alloc, raw).?;
    defer alloc.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Active plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "分析旧表") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "写迁移脚本") != null);

    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        alloc.free(@constCast(history.items[0].content));
        history.deinit(alloc);
    }
    const blocks = try alloc.alloc(llm.ContentBlock, 1);
    blocks[0] = .{ .text = "SYSTEM" };
    try history.append(alloc, .{ .role = .system, .content = blocks, .timestamp = 0 });

    try std.testing.expect(appendSystemBlock(&history, alloc, summary));
    try std.testing.expectEqual(@as(usize, 2), history.items[0].content.len);
    try std.testing.expectEqualStrings(summary, history.items[0].content[1].text);
    try std.testing.expect(removeSystemBlockByText(&history, alloc, summary));
    try std.testing.expectEqual(@as(usize, 1), history.items[0].content.len);
    try std.testing.expectEqualStrings("SYSTEM", history.items[0].content[0].text);
    try std.testing.expect(!removeSystemBlockByText(&history, alloc, summary)); // gone: no-op
}

test "key facts survive repeated phi compaction (T4.2)" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeContentBlocks(alloc, m.content);
        history.deinit(alloc);
    }
    const appendTurn = struct {
        fn f(a: std.mem.Allocator, h: *std.ArrayList(llm.Message), text: []const u8) !void {
            const b = try a.alloc(llm.ContentBlock, 1);
            b[0] = .{ .text = try a.dupe(u8, text) }; // HEAP: blocks free their text
            try h.append(a, .{ .role = .user, .content = b, .timestamp = 0 });
        }
    }.f;

    // Index 0 is always kept as the system prompt — the DECISION must sit
    // at index 1 so phi actually drops it (that's the point of the test).
    try appendTurn(alloc, &history, "SYSTEM-PROMPT");
    try appendTurn(alloc, &history, "我们决定使用 sqlite WAL 模式，数据库文件是 data/app.db，不要改成 delete 模式");
    // Filler turns so phi actually drops the head.
    for (0..40) |i| {
        var tb: [64]u8 = undefined;
        const t = try std.fmt.bufPrint(&tb, "regular exchange number {d} nothing worth keeping", .{i});
        try appendTurn(alloc, &history, t);
    }
    // NOTE: the facts block lives in history[0]'s blocks — its text is
    // freed by the message cleanup below, so NO separate facts defer.
    var facts: ?[]u8 = null;

    var rounds: usize = 0;
    while (rounds < 3) : (rounds += 1) {
        // replenish filler so each round actually compacts again
        for (0..20) |i| {
            var tb: [64]u8 = undefined;
            const t = try std.fmt.bufPrint(&tb, "later padding {d} for the round", .{i});
            try appendTurn(alloc, &history, t);
        }
        applyFactsUpdate(&history, &facts, alloc, compactHistoryImpl(&history, alloc, facts));
    }
    const f = facts orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, f, "sqlite WAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, f, "data/app.db") != null);
    // And the block is anchored in history[0].
    var anchored = false;
    for (history.items[0].content) |b| switch (b) {
        .text => |t| if (std.mem.indexOf(u8, t, "sqlite WAL") != null) {
            anchored = true;
        },
        else => {},
    };
    try std.testing.expect(anchored);
}

test "isLowSignal and near-duplicate gates (T2.3)" {
    try std.testing.expect(isLowSignal("。。。！！！？？"));
    try std.testing.expect(isLowSignal(""));
    try std.testing.expect(!isLowSignal("user prefers zig for agents"));
    try std.testing.expect(!isLowSignal("用户偏好中文回复")); // CJK is signal
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), jaccardTokens("deploy with docker compose", "deploy with docker compose"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), jaccardTokens("alpha beta", "xray yankee"), 1e-9);
    var accepted = [_]extraction_mod.ExtractedFact{.{ .content = "deploy the service with docker compose up", .fact_type = .project_context, .importance = 1 }};
    // One filler word apart (>0.8 overlap) = re-extracted variant → dup.
    try std.testing.expect(isNearDuplicate(&accepted, "please deploy the service with docker compose up"));
    // A changed MEANINGFUL word (0.71 overlap) stays a distinct fact.
    try std.testing.expect(!isNearDuplicate(&accepted, "deploy the service with docker compose down"));
    try std.testing.expect(!isNearDuplicate(&accepted, "user prefers zig language for builds"));
}

test "shouldReanchor: phi gate on topic drift (T1.3)" {
    const alloc = std.testing.allocator;
    // Same text → cosine 1 → no re-anchor.
    const a = try embedding_mod.embed(alloc, "deploy the payment service with docker");
    defer alloc.free(a);
    const a2 = try embedding_mod.embed(alloc, "deploy the payment service with docker");
    defer alloc.free(a2);
    try std.testing.expect(!shouldReanchor(a, a2));
    // Disjoint token sets → cosine 0 < 0.618 → re-anchor.
    const b = try embedding_mod.embed(alloc, "xray yankee zulu whiskey tango");
    defer alloc.free(b);
    try std.testing.expect(shouldReanchor(a, b));
}

test "topicVectorOfLastUserTurns means last 3 user turns, ignores others" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| alloc.free(@constCast(m.content));
        history.deinit(alloc);
    }
    const mkMsg = struct {
        fn f(a: std.mem.Allocator, h: *std.ArrayList(llm.Message), role: @TypeOf(h.items[0].role), text: []const u8) !void {
            const blocks = try a.alloc(llm.ContentBlock, 1);
            blocks[0] = .{ .text = text };
            try h.append(a, .{ .role = role, .content = blocks, .timestamp = 0 });
        }
    }.f;
    try mkMsg(alloc, &history, .user, "alpha bravo charlie");
    try mkMsg(alloc, &history, .assistant, "irrelevant assistant text");
    try mkMsg(alloc, &history, .user, "delta echo foxtrot");
    const v = topicVectorOfLastUserTurns(&history, alloc).?;
    defer alloc.free(v);
    try std.testing.expectEqual(embedding_mod.DIMS, v.len);
    // Assistant-only history → null.
    var h2: std.ArrayList(llm.Message) = .empty;
    defer {
        for (h2.items) |m| alloc.free(@constCast(m.content));
        h2.deinit(alloc);
    }
    try mkMsg(alloc, &h2, .assistant, "only assistant");
    try std.testing.expect(topicVectorOfLastUserTurns(&h2, alloc) == null);
}

test "swapMemoryBlockText replaces by identity, preserves siblings" {
    const alloc = std.testing.allocator;
    // swapMemoryBlockText TAKES OWNERSHIP of the old content slice — no
    // defer-free here; the swap frees it and installs a new one that the
    // history teardown below releases.
    const blocks = try alloc.alloc(llm.ContentBlock, 3);
    blocks[0] = .{ .text = "SYSTEM" };
    blocks[1] = .{ .text = "OLD-MEMORY" };
    blocks[2] = .{ .text = "SKILLS" };
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        alloc.free(@constCast(history.items[0].content));
        history.deinit(alloc);
    }
    try history.append(alloc, .{ .role = .system, .content = blocks, .timestamp = 0 });

    const new_text = try alloc.dupe(u8, "NEW-MEMORY");
    defer alloc.free(new_text);
    try std.testing.expect(swapMemoryBlockText(&history, alloc, "OLD-MEMORY", new_text));
    const cur = history.items[0].content;
    try std.testing.expectEqual(@as(usize, 3), cur.len);
    try std.testing.expectEqualStrings("SYSTEM", cur[0].text);
    try std.testing.expectEqualStrings("NEW-MEMORY", cur[1].text);
    try std.testing.expectEqualStrings("SKILLS", cur[2].text);
    // Stale pointer → no match, history untouched (and the candidate not
    // consumed — caller keeps ownership).
    try std.testing.expect(!swapMemoryBlockText(&history, alloc, "OLD-MEMORY", new_text));
    try std.testing.expectEqualStrings("NEW-MEMORY", history.items[0].content[1].text);
}

test "mergeInputHistory unions concurrent windows and caps the tail" {
    const alloc = std.testing.allocator;
    // Window B wrote entries after our startup snapshot of [a, b].
    const file = [_][]const u8{ "a", "b", "B1", "B2" };
    const session = [_][]const u8{ "a", "b", "mine" };
    const merged = try mergeInputHistory(alloc, &file, &session);
    defer alloc.free(merged);
    // Their new entries survive, ours appended, no duplicates.
    try std.testing.expectEqual(@as(usize, 5), merged.len);
    try std.testing.expectEqualStrings("B1", merged[2]);
    try std.testing.expectEqualStrings("B2", merged[3]);
    try std.testing.expectEqualStrings("mine", merged[4]);

    // Re-typed old command (final session line) moves to the TAIL — the
    // global-skip used to strand it mid-file, regressing single-window
    // recall order.
    const f2 = [_][]const u8{ "a", "b", "c" };
    const s2 = [_][]const u8{ "a", "b", "c", "a" };
    const m3 = try mergeInputHistory(alloc, &f2, &s2);
    defer alloc.free(m3);
    try std.testing.expectEqual(@as(usize, 3), m3.len);
    try std.testing.expectEqualStrings("a", m3[2]); // moved to tail

    // Consecutive duplicates collapse.
    const f3 = [_][]const u8{"x"};
    const m4 = try mergeInputHistory(alloc, &f3, &f3);
    defer alloc.free(m4);
    try std.testing.expectEqual(@as(usize, 1), m4.len);

    // Tail cap: 10 file + 495 fresh session entries → exactly 500, oldest dropped.
    var big_file: [10][]const u8 = undefined;
    for (&big_file, 0..) |*e, i| e.* = if (i % 2 == 0) "old-even" else "old-odd";
    var names: [495][]const u8 = undefined;
    var name_bufs: [495][16]u8 = undefined;
    var big_sess: std.ArrayList([]const u8) = .empty;
    defer big_sess.deinit(alloc);
    var n: usize = 0;
    while (n < 495) : (n += 1) {
        names[n] = try std.fmt.bufPrint(&name_bufs[n], "fresh{d}", .{n});
        try big_sess.append(alloc, names[n]);
    }
    const m5 = try mergeInputHistory(alloc, &big_file, big_sess.items);
    defer alloc.free(m5);
    try std.testing.expectEqual(@as(usize, 500), m5.len);
    try std.testing.expectEqualStrings("old-odd", m5[0]); // 5 oldest file lines dropped
    try std.testing.expectEqualStrings("fresh494", m5[499]);
}
