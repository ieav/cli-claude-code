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
const stream_mod = @import("turn/stream.zig");
const turn_ask = @import("turn/ask.zig");
const turn_tools = @import("turn/tools.zig");
const turn_history = @import("turn/history.zig");
const memory_ops = @import("session/memory_ops.zig");
const config_menu = @import("commands/config_menu.zig");
const model_switcher = @import("session/model_switcher.zig");
pub const ModelSwitcher = model_switcher.ModelSwitcher; // re-export: memory_ops/config_menu alias via repl_mod
const json_tree = @import("util/json_tree.zig");
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
const mpsc_queue = @import("task/mpsc_queue.zig");
const task_mod = @import("task/mod.zig");
const agent_dispatch = @import("tools/agent_dispatch.zig");

const knowledge_search = @import("knowledge/search.zig");
const knowledge_graph = @import("knowledge/graph.zig");
const researcher_mod = @import("research/optimization_researcher.zig");
const env = @import("util/env.zig");
const turn_clock = @import("util/turn_clock.zig");
const task_store = @import("tools/task_store.zig");
const format_mod = @import("util/format.zig");
const diff_util = @import("util/diff.zig");
const cancel_mod = @import("util/cancel.zig");
const llm_watchdog = @import("util/llm_watchdog.zig");
const self_diagnostic = @import("runtime/self_diagnostic.zig");
const decision_trace = @import("runtime/decision_trace.zig");
const runtime_monitor = @import("runtime/monitor.zig");
const runtime_rules = @import("runtime/rules.zig");
const error_handler = @import("runtime/error_handler.zig");
const allocator = std.heap.smp_allocator;

/// The REPL's cron scheduler, for mid-turn UI slices (same pattern as
/// lineinput.setSessionGuard): drainDue used to run ONLY at the loop
/// top, so a marathon turn starved health checks and memory decay for
/// its entire duration. Both turn-phase UI loops (streaming + tools)
/// now drain due tasks on their quiet 100ms slices.
var cron_ptr: ?*task_mod.CronScheduler = null;

// Agent-loop cap lives in settings.agent_loop_limit (default 50, clamp
// 1..200) — see the turn loop's max_agent_iters.
const MAX_CONTEXT_TOKENS: u32 = 128_000;

/// Code-change diff preview (TUI) — see renderCodeDiff. Cap one edit's
/// block at 15 rows × 110 display columns so a big rewrite can't flood
/// the screen; oversized files skip the preview instead of diffing them.
/// v0.7.5 (user call): show the WHOLE diff — no folding. The cap only
/// guards pathological sizes (a 1000-line generated blob would flood the
/// screen past any usefulness).
const DIFF_READ_CAP: usize = 1024 * 1024; // diff-size consts moved to turn/tools.zig

/// Baseline fingerprint of all settings files, refreshed by (a) startup,
/// (b) every own-save (autoSaveSettings, /mode, model picker). When a prompt
/// observes a different fingerprint, the file was edited externally → reload.
pub var settings_fp_baseline: u64 = 0;


pub fn run(io: std.Io, stdin_file: std.Io.File, stdout_file: std.Io.File) !void {
    // Terminal-write serialization needs the Io instance (std.Io.Mutex
    // lock/unlock take it) — inject before any region call below.
    lineinput.setIo(io);
    // SESSION-scoped raw mode (2026-11-06): raw used to be entered per
    // readLine call, so the tty sat in cooked+echo for every entire TURN —
    // the line discipline echoed mid-turn keystrokes as ^[[C/^R garbage
    // and line-buffered input away from the editor. One guard for the
    // whole session; every exit path restores via defer, crashes via the
    // guard's INT/TERM signal restore. Mid-turn y/N gates temporarily go
    // cooked (menu.CookedGuard) around their reads.
    var tty_guard = menu.RawGuard{};
    tty_guard.enterNoSig();
    defer tty_guard.restore();
    lineinput.setSessionGuard(&tty_guard); // Ctrl-Z manual suspend needs it
    // Writer setup
    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(stdout_file, io, &write_buf);
    const w = &file_writer.interface;
    // Turn-body transcript writer (P0-b mechanism): funnels every business
    // print through the live-region protocol — line-atomic ABOVE the
    // region while it is up, verbatim passthrough while it is down. A
    // direct write over the persistent input row (the diff-preview bug
    // class) becomes impossible; the region MECHANICS calls
    // (regionBegin/End/Freeze/Status, editorLiveKey) keep using `w`.
    var region_wr = lineinput.RegionWriter{ .real = w, .table_alloc = allocator };
    const ow = &region_wr.interface;

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
    // Persistent diagnostics: the interactive-stderr mute hides every log
    // line in TUI mode, so gateway failures used to leave no trail at all.
    logger.setLogFile(io, ".ziv/logs");
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
    defer if (kgraph) |*g| g.deinit(); // finalize cached stmts before db close

    // ──── P3: runtime layer — typed event bus + cron (main-thread exec) ────
    // Threading contract: the bus emits ONLY on the main thread; the cron
    // scheduler thread never runs task code, it just queues due indices
    // which the loop-top drain executes here (SQLite THREADSAFE=0 rule).
    var evbus = task_mod.EventBus.init(allocator);
    defer evbus.deinit();
    var monitor = runtime_monitor.RuntimeMonitor.init(allocator);
    defer monitor.deinit();
    monitor.setEventBus(&evbus);
    // Live stats the health check reads (updated in the main loop below).
    var live_llm_calls = std.atomic.Value(u32).init(0);
    var live_llm_429s = std.atomic.Value(u32).init(0); // real 429s → monitor rule
    var live_est_tokens = std.atomic.Value(u32).init(0);
    // Test hook: ZIV_CRON_SCALE=60 compresses the timeline (81.5min → ~82s)
    // so scheduled maintenance is observable in a smoke run.
    var cron_scale: u64 = 1;
    if (env.get("ZIV_CRON_SCALE")) |v| {
        if (std.fmt.parseInt(u64, v, 10)) |s| {
            if (s >= 1) cron_scale = s;
        } else |_| {}
    }
    var decay_ctx = memory_ops.MemoryDecayCtx{ .mem = if (mem_sys) |*ms| ms else null };
    var health_ctx = memory_ops.HealthCtx{
        .monitor = &monitor,
        .bus = &evbus,
        .w = w,
        .ow = ow,
        .file_writer = &file_writer,
        .switcher = &switcher,
        .llm_calls = &live_llm_calls,
        .llm_429s = &live_llm_429s,
        .est_tokens = &live_est_tokens,
    };
    var cron = task_mod.CronScheduler.init(allocator);
    defer cron.deinit();
    cron_ptr = &cron;
    defer cron_ptr = null;
    if (mem_db != null) {
        cron.addTask(.{
            .name = "memory_decay",
            .interval_ms = task_mod.cron.CronScheduler.MEMORY_DECAY_INTERVAL / cron_scale,
            .last_run = std.atomic.Value(i64).init(0),
            .enabled = std.atomic.Value(bool).init(true),
            .task_fn = memory_ops.memoryDecayTask,
            .ctx = @ptrCast(&decay_ctx),
        }) catch {};
    }
    cron.addTask(.{
        .name = "health_check",
        .interval_ms = task_mod.cron.CronScheduler.HEALTH_CHECK_INTERVAL / cron_scale,
        .last_run = std.atomic.Value(i64).init(0),
        .enabled = std.atomic.Value(bool).init(true),
        .task_fn = memory_ops.healthCheckTask,
        .ctx = @ptrCast(&health_ctx),
    }) catch {};
    cron.start() catch logger.warning("cron: scheduler unavailable", .{});

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

    if (mem_sys) |*ms| {
        // Candidate pool of 200, not 20: the e-decay + cosine ranking only
        // reorders what SQL already returned — with LIMIT 20, older
        // high-value memories were evicted before ranking ever saw them.
        // Arena-owned rows: ~3000 per-row dupes collapse into one reset.
        var rows_arena = std.heap.ArenaAllocator.init(allocator);
        defer rows_arena.deinit();
        if (ms.episodic_mem.retrieveRecentArena(rows_arena.allocator(), 1000) catch null) |entries| {
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
    // T3.2 wiring: arm the insight inbox — background workers push here,
    // the main loop drains it before each prompt. v0.6.0 shipped with
    // this init (and the drain call) missing, so every background insight
    // was silently discarded: the LLM round trip ran, the store never did.
    memory_ops.reflect_inbox = .init();
    memory_ops.reflect_inbox_init = true;
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
    var ask_ctx = turn_ask.AskUserCtx{ .r = r, .w = w, .ow = ow, .file_writer = &file_writer };
    for (reg.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.def.name, "AskUserQuestion")) {
            entry.def.execute_ctx_fn = turn_ask.askUserExecute;
            entry.def.execute_ctx = @ptrCast(&ask_ctx);
        }
    }

    // T6.3: register the parallel-subagent dispatch tool. ctx borrows
    // stable references (model_name_buf updates in place on hot switches;
    // retired settings slices are never freed, so key snapshots stay
    // readable) — workers build their OWN provider per job from these.
    var dispatch_ctx = agent_dispatch.DispatchCtx{
        .alloc = allocator,
        .io = io,
        .tools = &reg,
        .concurrency = &switcher.settings.subagent_concurrency,
        .bus = &evbus,
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
    // T6.4 status: the subagent dispatch tool is ENABLED by default
    // (2026-11-04). The old "intermittent hang after an agent-tool turn"
    // was root-caused on 2026-10-30 (TODO P38): the gateway occasionally
    // accepts a request and then never answers, and the provider layer had
    // no timeout — the dynamic-tool path itself was exonerated. Every LLM
    // request is now guarded by the stall watchdog (util/llm_watchdog.zig,
    // default 180s idle — pushed forward by every received byte since
    // 2026-11-05, ZIV_LLM_TIMEOUT_MS), and the default-on E2E
    // re-validation ran both shapes against a real mock gateway
    // (tests/agent_e2e.zig): happy fan-out AND the P38 stall (gateway
    // accepts, never answers → watchdog kills → fail-fast retry fails →
    // dispatch still returns merged output, bounded). Opt OUT with
    // ZIV_AGENT_TOOL=0 / false.
    const agent_tool_enabled = blk: {
        const v = env.get("ZIV_AGENT_TOOL") orelse break :blk true;
        break :blk !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
    };
    if (agent_tool_enabled) reg.registerDynamic(
        "agent",
        "Run 1-3 focused read-only subagents in parallel. Each gets its own context and the read-only tools, then reports back. Use for independent research or verification subtasks (e.g. 'check X in the codebase', 'verify the failing paths'), NOT for sequential work.",
        "{\"type\":\"object\",\"properties\":{\"tasks\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"1-3 self-contained task descriptions\"}},\"required\":[\"tasks\"]}",
        agent_dispatch.executeWithCtx,
        @ptrCast(&dispatch_ctx),
        false,
    ) catch |e| logger.warning("agent tool registration failed: {}", .{e});

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

    // P4: a message queued during generation (Enter pressed mid-stream)
    // that never hit a tool-round injection point auto-sends as the next
    // turn — the main loop consumes it instead of calling readLine.
    var auto_submit: ?[]u8 = null;

    while (true) {
        // Hot-reload: a settings file changed on disk since the last prompt
        // (external edit) → reload everything and resync the live permission
        // mode. Own saves refresh the baseline, so this never fires for them.
        const settings_fp = config_mod.settingsFingerprint(allocator, io);
        if (settings_fp != settings_fp_baseline) {
            settings_fp_baseline = settings_fp;
            if (config_mod.loadSettings(allocator, io)) |fresh| {
                const old_model = switcher.modelName();
                model_switcher.applyReloadedSettings(&switcher, fresh);
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

        // T3.2: land any background-reflection insights that completed
        // since the last prompt (SQLite writes and printing stay on this
        // thread — the worker only pushed into the inbox).
        memory_ops.drainReflectionInbox(allocator, if (mem_sys) |*ms| ms else null, &evbus, w);
        // P3: run cron tasks that came due (same main-thread contract).
        cron.drainDue();

        // Prompt with mode indicator + model + context usage
        const mode_str = switch (current_mode) {
            .default => "ziv",
            .accept_edits => "ziv[edit]",
            .plan => "ziv[plan]",
            .bypass => "ziv[bypass]",
            .dont_ask => "ziv[dontask]",
            .auto => "ziv[auto]",
        };
        var est_ctx = turn_history.estimateHistoryTokens(history.items);
        live_est_tokens.store(@intCast(@min(est_ctx, std.math.maxInt(u32))), .monotonic); // P3: health-check context signal
        // Parity: the prompt % uses the SAME adaptive ceiling as maybeCompact
        // (contextEstimate of the active model) — display and decision must
        // not diverge on small-context models.
        const ctx_ceiling = llm.provider.contextEstimate(switcher.modelName(), switcher.backend);
        const ctx_pct = @as(u32, @intFromFloat(@as(f64, @floatFromInt(est_ctx)) / @as(f64, @floatFromInt(ctx_ceiling)) * 100.0));
        var prompt_buf: [160]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "{s} ({s}) [{d}%] > ", .{ mode_str, switcher.modelName(), ctx_pct }) catch "> ";
        // The turn-scoped live region's input row renders with this SAME
        // prefix — one input area identity across turn and prompt.
        lineinput.regionPromptSet(prompt);

        // Read line via the raw-mode editor: arrows move the cursor,
        // up/down walk history (or move between lines on multi-line input),
        // Backspace/Delete/Home/End work, pasted multi-line text arrives as
        // ONE input. The returned slice is allocator-owned and may exceed
        // 4 KiB after a big paste — freed at the end of this iteration.
        var from_auto_queue = false;
        var maybe_line: ?[]u8 = null;
        if (auto_submit) |a| {
            from_auto_queue = true;
            auto_submit = null;
            maybe_line = a;
            lineinput.regionEnd(w);
            // The auto-sent message gets the committed echo UNLESS the
            // queue-time echo already showed it (with its ↳ 已排队 marker).
            if (!lineinput.last_take_echoed) lineinput.echoCommittedDirect(w, a);
            std.Io.File.Writer.flush(&file_writer) catch {};
        } else {
            maybe_line = lineinput.readLine(w, r, &file_writer, prompt, &input_history, allocator) catch |err| {
                std.debug.print("Error reading input: {}\n", .{err});
                return;
            };
        }
        const line = maybe_line orelse {
            // Ctrl-D on an empty line (EOF): same session-end cleanup as
            // /quit — this path used to skip reflection + memory extraction,
            // silently losing the session's learnings on a common exit habit.
            // Extract first, reflect last — see the /quit path note.
            if (mem_sys) |*ms| {
                const ext_t0 = util_time.nowMillis();
                memory_ops.extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, &evbus, w, switcher.getProvider() catch null, switcher.settings.max_tokens) catch {};
                logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
            }
            if (mem_sys != null and window_queries.items.len > 0) {
                memory_ops.runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, null, .full, null, null); // exit path: heuristic-only, no background dispatch
                // Best-effort drain: an insight that already landed in the
                // inbox is stored now; one still in flight dies with the
                // process (the heuristic reflection was stored synchronously
                // above — nothing of value blocks on a detached thread).
                memory_ops.drainReflectionInbox(allocator, if (mem_sys) |*ms| ms else null, &evbus, w);
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
        if (!from_auto_queue) saveInputHistory(allocator, &input_history);

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
                    memory_ops.extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, &evbus, w, switcher.getProvider() catch null, switcher.settings.max_tokens) catch {};
                    logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
                }
                if (mem_sys != null and window_queries.items.len > 0) {
                    memory_ops.runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, null, .full, null, null); // exit path: heuristic-only, no background dispatch
                    // Best-effort drain: an insight that already landed in the
                    // inbox is stored now; one still in flight dies with the
                    // process (the heuristic reflection was stored synchronously
                    // above — nothing of value blocks on a detached thread).
                    memory_ops.drainReflectionInbox(allocator, if (mem_sys) |*ms| ms else null, &evbus, w);
                }
                // Visibility: queued-but-unsent messages die with the
                // session — say so instead of dropping silently.
                if (lineinput.queuedHas()) {
                    try std.Io.Writer.print(w, "\x1b[2m  [{d} 条排队消息未发送，已丢弃]\x1b[0m\n", .{lineinput.queuedCount()});
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
                if (!try turn_ask.permissionGate(run_tool, parsed, current_mode, &switcher, allocator, r, w, ow, &file_writer, &denial_state)) continue;

                // Backup file before modification (for /run commands)
                var run_snap_id: ?[16]u8 = null;
                if (turn_tools.isFileModifyingTool(tool_name)) {
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

                // Same /last ring as agent-loop calls (finishToolCall) —
                // the expansion valve must cover manual /run too.
                turn_tools.LastTools.push(tool_name, result.output);

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
                try config_menu.runModelPicker(w, r, &file_writer, &switcher, io);
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
                try config_menu.runConfigMenu(w, r, &file_writer, &switcher, allocator, io);
                // The live permission gate reads `current_mode`, which the
                // menu never touched — without this resync a mode picked in
                // /config never reached the gate until restart.
                current_mode = switcher.settings.permission_mode;
                // A changed system prompt must reach the baked history[0]
                // this session, not after the next restart.
                reapplySystemPromptIfNeeded(&applied_prompt_setting, &sys_prompt_owned, &sys_prompt, &history, allocator, switcher.settings.system_prompt);
                continue;
            } else if (std.mem.eql(u8, input, "/compact") or std.mem.startsWith(u8, input, "/compact ")) {
                // Claude-style: LLM summarizes the OLDER conversation; the
                // summary replaces it and the most recent messages are kept
                // verbatim (v0.7.7 — the old version summarized everything,
                // including what you just said). Optional free text after
                // the command steers the summary:
                //   /compact 重点保留数据库迁移的决策
                const focus = std.mem.trim(u8, input["/compact".len..], " \t");
                if (std.mem.eql(u8, focus, "phi")) continue; // handled below
                try turn_history.compactHistory(&history, &switcher, &log, allocator, w, &file_writer, &total_input_tokens, &total_output_tokens, focus);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/compact phi")) {
                // Original φ truncation strategy, kept as an explicit option
                // (also what auto-compaction runs).
                try turn_history.compactHistoryPhi(&history, allocator, w, &log, &facts_block);
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
                    memory_ops.extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, &evbus, w, switcher.getProvider() catch null, switcher.settings.max_tokens) catch {};
                    logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
                }
                if (mem_sys != null and window_queries.items.len > 0) {
                    memory_ops.runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, null, .full, null, null); // exit path: heuristic-only, no background dispatch
                    // Best-effort drain: an insight that already landed in the
                    // inbox is stored now; one still in flight dies with the
                    // process (the heuristic reflection was stored synchronously
                    // above — nothing of value blocks on a detached thread).
                    memory_ops.drainReflectionInbox(allocator, if (mem_sys) |*ms| ms else null, &evbus, w);
                }
                turn_history.clearHistory(&history, allocator);
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
            } else if (std.mem.eql(u8, input, "/trace")) {
                // P2: per-step timing of the last turn, read straight from
                // the .ziv/traces/*.jsonl the turn-end telemetry wrote —
                // the data has existed since 2026-11-05, this is its
                // in-TUI window.
                if (turn_clock.tracePath().len == 0) {
                    try std.Io.Writer.print(w, "  本会话尚无 trace（任一回合结束后生成；ZIV_TRACE=0 可关闭落盘）\n\n", .{});
                } else {
                    const tpath = turn_clock.tracePath();
                    var fbuf: [131072]u8 = undefined;
                    if (std.Io.Dir.cwd().readFile(io, tpath, &fbuf)) |data| {
                        var lines_it = std.mem.splitScalar(u8, data, '\n');
                        const header = lines_it.next() orelse "";
                        var qb: [96]u8 = undefined;
                        const qtxt = traceHeaderSummary(header, &qb) catch "（表头解析失败）";
                        try std.Io.Writer.print(w, "  ⏱ 上一回合 {s}\n", .{qtxt});
                        var step_no: usize = 0;
                        while (lines_it.next()) |ln| {
                            if (ln.len == 0) continue;
                            step_no += 1;
                            if (step_no > 80) break;
                            var sb: [96]u8 = undefined;
                            if (traceStepSummary(ln, &sb)) |s| {
                                try std.Io.Writer.print(w, "    {d:>3}. {s}\n", .{ step_no, s });
                            }
                        }
                        if (step_no > 80) try std.Io.Writer.print(w, "    …（超 80 步截断；全量见文件）\n", .{});
                        try std.Io.Writer.print(w, "  文件: {s}\n\n", .{tpath});
                    } else |_| {
                        try std.Io.Writer.print(w, "  读取 trace 失败（文件可能已被移动）: {s}\n\n", .{tpath});
                    }
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/tasks")) {
                // ②: the task system (TaskCreate/TaskUpdate) had a full
                // store + render() but no TUI surface at all.
                const ts = task_store.global();
                if (ts.count() == 0) {
                    try std.Io.Writer.print(w, "  任务列表为空（模型用 TaskCreate 建任务后在此查看进度）\n\n", .{});
                } else {
                    const rendered = ts.render(allocator) catch {
                        try std.Io.Writer.print(w, "  任务列表渲染失败\n\n", .{});
                        try std.Io.File.Writer.flush(&file_writer);
                        continue;
                    };
                    defer allocator.free(rendered);
                    try std.Io.Writer.print(w, "{s}\n", .{rendered});
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/last") or std.mem.startsWith(u8, input, "/last ")) {
                // ③: full output of a recent tool — the one-line preview in
                // the transcript deliberately truncates; this is the
                // expansion valve (/last = newest, /last 3 = third newest).
                var n: usize = 1;
                if (std.mem.startsWith(u8, input, "/last ")) {
                    const arg = std.mem.trim(u8, input["/last ".len..], " \t");
                    n = std.fmt.parseInt(usize, arg, 10) catch 1;
                }
                if (turn_tools.LastTools.get(n)) |e| {
                    try std.Io.Writer.print(w, "  ── {s}（最近第 {d} 条，{d} 字节）──\n", .{ e.name, n, e.output.len });
                    var at_ls = false;
                    try memory_ops.writeMarginLines(w, e.output, "  ", &at_ls);
                    if (!at_ls) try std.Io.Writer.writeAll(w, "\n");
                    try std.Io.Writer.writeAll(w, "\n");
                } else {
                    try std.Io.Writer.print(w, "  无记录（/last=最近一条，/last N=第 N 近，最多保留 {d} 条）\n\n", .{turn_tools.LastTools.N});
                }
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/memory")) {
                try memory_ops.printMemoryStatus(if (mem_sys) |*ms| ms else null, injected_count, w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.startsWith(u8, input, "/research ")) {
                const topic = std.mem.trim(u8, input["/research ".len..], " \t");
                if (topic.len == 0) {
                    try std.Io.Writer.writeAll(w, "  Usage: /research <topic>\n\n");
                } else {
                    try memory_ops.runResearch(topic, allocator, io, w, switcher.settings.api_keys.brave_api_key, if (mem_sys) |*ms| ms else null, if (kgraph) |*g| g else null);
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
                    try memory_ops.runDiagnose(if (live_trace) |*t| t else null, concern, injected_count, window_tools, window_errors, if (mem_sys) |*ms| ms else null, allocator, w);
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
                const est_tokens = turn_history.estimateHistoryTokens(history.items);
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
            evbus.emit(.{ .user_query_start = {} }); // P3 event record
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
        // TTFT auto-retries left this turn: a gateway that accepted the
        // request but sent no first byte gets killed at the TTFT deadline
        // (provider-side) and transparently retried — "发了消息模型一直
        // 没响应" self-heals instead of idling on the 180s watchdog.
        var ttft_retries: u8 = 0;
        var result_blocks = std.ArrayList(llm.ContentBlock).empty;
        defer result_blocks.deinit(allocator);
        // One emergency compaction per turn on ContextOverflow — a second
        // overflow after compacting falls through to the manual hint.
        var overflow_compacted = false;
        // ① Turn summary: tokens accumulate across the turn's generations
        // and surface ONCE — in the status row the region FREEZES at turn
        // end — instead of a stat line after every generation.
        const turn_t0 = util_time.nowMillis();
        var turn_in: u64 = 0;
        var turn_out: u64 = 0;
        // ① Turn timing — same clock (util_time.nowMillis) and same
        // boundaries everywhere downstream: LLM = per generation
        // (llm_t0 → accepted response), tools = per batch (batch_t0 →
        // all results collected), turn = turn_t0 → teardown. Surfaced in
        // the frozen turn-end status row + ziv.log + .ziv/traces/*.jsonl.
        var turn_llm_ms: i64 = 0;
        var turn_llm_calls: u32 = 0;
        var turn_tool_ms: i64 = 0;
        var turn_tool_calls: u32 = 0;

        // The live region (status row + prompt-identical input row) now
        // spans the WHOLE turn: begun once here, ended once after the
        // loop. Generations and tool rounds only swap the STATUS text —
        // the input row never disappears mid-turn (the old per-phase
        // begin/end flickered the bottom two rows on every iteration).
        // Transcript prints inside the loop go through `ow` (region-aware);
        // only the region lifecycle calls below keep `w`.
        turn_clock.turnStart(turn_t0);
        lineinput.regionBegin(w, "⏳ 本轮 0.0s · 累计 0.0s · Esc 中断 · Enter 排队");
        // v0.7.7: context low-water WARNING (Claude-Code parity) — one dim
        // transcript line at >=80% of the model's ceiling, before the φ
        // auto-compaction ever fires, so the squeeze is never a surprise.
        var ctx_warned = false;

        // Per-turn read (hot-reloadable): settings.json agent_loop_limit,
        // clamped at parse. The hard 50 cut mid-investigation on a
        // debugging marathon (53 tools / 29 min) motivated the knob +
        // the 「继续」 prefill below.
        const max_agent_iters: usize = @max(1, switcher.settings.agent_loop_limit);

        while (agent_iterations < max_agent_iters) : (agent_iterations += 1) {
            // Compaction check + context estimate in one pass. (v0.7.6:
            // the old per-turn WRITE cap (15) is gone — the Claude-Code/
            // Codex model gates on CONTEXT PRESSURE, not write counts:
            // compaction runs first, and only when the estimate stays
            // above the guard AFTER compacting does the turn end. Long
            // multi-file tasks now run to completion inside one turn.)
            est_ctx = turn_history.maybeCompact(&history, allocator, ow, &file_writer, &log, &facts_block, switcher.modelName(), switcher.backend);
            {
                const ceiling = llm.provider.contextEstimate(switcher.modelName(), switcher.backend);
                const warn_pct = @as(f64, @floatFromInt(est_ctx)) / @as(f64, @floatFromInt(ceiling));
                if (!ctx_warned and warn_pct >= 0.80) {
                    ctx_warned = true;
                    std.Io.Writer.print(ow, "\x1b[2m  [上下文已用 {d}% — 接近自动压缩水位。/compact 可手动提前压缩]\x1b[0m\n", .{@as(u32, @intFromFloat(warn_pct * 100.0))}) catch {};
                    try std.Io.File.Writer.flush(&file_writer);
                }
                const pct = @as(f64, @floatFromInt(est_ctx)) / @as(f64, @floatFromInt(ceiling));
                if (pct > 0.92) {
                    const pct100: u32 = @intFromFloat(pct * 100.0);
                    std.Io.Writer.print(ow, "\x1b[2m  [上下文压力 {d}% — 自动压缩后仍接近上限，本回合到此为止。发送新消息继续；/clear 可立即释放]\x1b[0m\n", .{pct100}) catch {};
                    try std.Io.File.Writer.flush(&file_writer);
                    break;
                }
            }

            // Get provider
            const prov = switcher.getProvider() catch |err| {
                lineinput.regionEnd(w);
                if (err == error.MissingApiKey) {
                    try std.Io.Writer.print(ow, "  [No API key for {s} — use /config to set it]\n\n", .{switcher.backendLabel()});
                } else {
                    try std.Io.Writer.print(ow, "  [Provider error: {}]\n\n", .{err});
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
            var had_thinking = false;
            const first_resp = stream_mod.streamComplete(prov, cron_ptr, history.items, .{
                .max_tokens = switcher.settings.max_tokens,
                .temperature = 0.7,
                // Declare the tools so the model can actually call them.
                .tools = reg.toolSpecs(),
                // Interactive stream: the UI loop's cancel flag (P2) —
                // Esc/Ctrl-C fails the pump's idle wait cross-thread.
                .cancel_flag = null, // set by streamComplete's StreamJob
            }, r, w, ow, &file_writer, allocator, &had_thinking) catch |err| {
                // The region stays up through streamComplete's error
                // returns — turn-ENDING paths drop it before printing,
                // turn-CONTINUING paths print above it.
                if (err == error.EscCancelled) {
                    // Esc: abort this exchange and pull the input back into
                    // the editor (history keeps the user message; no
                    // assistant reply was appended).
                    lineinput.regionEnd(w);
                    try std.Io.Writer.print(ow, "\n  [Esc — 已中断，输入已撤回，可直接编辑重发]\n\n", .{});
                    lineinput.recall_text = last_sent;
                    lineinput.recall_prefill = true;
                    try std.Io.File.Writer.flush(&file_writer);
                    break;
                }
                if (err == error.FirstByteTimeout) {
                    // Gateway accepted the request but produced nothing
                    // within the TTFT budget. Nothing was shown or stored
                    // yet, so a retry is invisible-safe: re-run this
                    // generation from the same history.
                    if (ttft_retries < 2) {
                        ttft_retries += 1;
                        std.Io.Writer.print(ow, "\x1b[2m  [网关 {d}s 无响应 — 自动重试 {d}/2…]\x1b[0m\n", .{ @divTrunc(llm_watchdog.currentTtftMs(), 1000), ttft_retries }) catch {};
                        try std.Io.File.Writer.flush(&file_writer);
                        continue;
                    }
                    lineinput.regionEnd(w);
                    try std.Io.Writer.print(ow, "\x1b[2m  [网关连续 3 次无首字节响应 — 放弃本回合]\x1b[0m\n", .{});
                    // P3 recoverable give-up: prefill 「继续」 — one Enter
                    // resumes the task as a fresh turn (proven 2026-11-05:
                    // a "继续" turn picked the task up cleanly and history
                    // pairs stay legal — see trace 1793893733712).
                    try std.Io.Writer.print(ow, "\x1b[2m  [输入区已预填「继续」：网关恢复后 Enter 即接续任务；也可直接改成其他输入]\x1b[0m\n\n", .{});
                    lineinput.recall_text = "继续";
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
                    turn_history.applyFactsUpdate(&history, &facts_block, allocator, turn_history.compactHistoryImpl(&history, allocator, facts_block));
                    log.bumpEpoch();
                    std.Io.Writer.print(ow, "  [Context overflow — history auto-compacted, retrying]\n", .{}) catch {};
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                }
                lineinput.regionEnd(w);
                if (err == error.RateLimit) _ = live_llm_429s.fetchAdd(1, .monotonic); // monitor: real-429 evidence
                try std.Io.Writer.print(ow, "  [LLM error: {}]\n", .{err});
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
                        try std.Io.Writer.print(ow, "  {s}\n", .{report.analysis});
                        for (report.fixes) |f| {
                            try std.Io.Writer.print(ow, "    [{d}] {s}{s}\n", .{ f.index, f.description, if (f.is_recommended) " ★" else "" });
                        }
                    } else |_| {}
                }
                if (err == error.ContextOverflow) {
                    try std.Io.Writer.print(ow, "  [Still too long after compaction — try /compact phi or /clear]\n", .{});
                }
                // The gateway's own reason, surfaced through the provider's
                // structured error-detail channel (no more "see the [ERR]
                // log line above" — the reason belongs IN the interface).
                if (llm.provider.lastErrorDetail().len > 0) {
                    var db: [520]u8 = undefined;
                    const dline = std.fmt.bufPrint(&db, "  \x1b[2m[网关返回: {s}]\x1b[0m\n", .{llm.provider.lastErrorDetail()}) catch "";
                    try std.Io.Writer.writeAll(ow, dline);
                }
                // Point at the persistent trail — the TUI mutes stderr, so
                // without this hint a session's diagnostics are invisible.
                if (logger.logFilePath().len > 0) {
                    var lb: [300]u8 = undefined;
                    const lline = std.fmt.bufPrint(&lb, "  \x1b[2m[详细日志: {s}，上一会话在同目录 ziv.log.prev]\x1b[0m\n", .{logger.logFilePath()}) catch "";
                    try std.Io.Writer.writeAll(ow, lline);
                }
                try std.Io.Writer.writeAll(ow, "\n");
                try std.Io.File.Writer.flush(&file_writer);
                break;
            };

            // Reasoning-budget escalation: a thinking model can spend the
            // ENTIRE output cap on reasoning_content — zero visible text,
            // out == max_tokens. Resending at the same cap reproduces the
            // failure (the old "[…如非预期可重发]" advice was a trap), so
            // escalate the budget level by level instead.
            var response = first_resp;
            var eff_cap = switcher.settings.max_tokens;
            if (response.content.len == 0 and eff_cap < stream_mod.MAX_OUTPUT_BUDGET and
                stream_mod.outputBudgetExhausted(response.stop_reason, response.usage.output_tokens, eff_cap))
            {
                var esc_after_retry = false;
                while (eff_cap < stream_mod.MAX_OUTPUT_BUDGET) {
                    const prev_cap = eff_cap;
                    eff_cap = @min(eff_cap * 2, stream_mod.MAX_OUTPUT_BUDGET);
                    logger.info("budget escalation: out={d} == cap {d} with 0 content blocks, retrying at max_tokens={d}", .{ response.usage.output_tokens, prev_cap, eff_cap });
                    std.Io.Writer.print(ow, "\x1b[2m  [思考耗尽输出预算（out={d} = 上限 {d}，正文 0）— 以 {d} tokens 预算重试…]\x1b[0m\n", .{
                        response.usage.output_tokens, prev_cap, eff_cap,
                    }) catch {};
                    try std.Io.File.Writer.flush(&file_writer);
                    const next = stream_mod.streamComplete(prov, cron_ptr, history.items, .{
                        .max_tokens = eff_cap,
                        .temperature = 0.7,
                        .tools = reg.toolSpecs(),
                        .cancel_flag = null,
                    }, r, w, ow, &file_writer, allocator, &had_thinking) catch |err2| {
                        if (err2 == error.EscCancelled) {
                            esc_after_retry = true; // the Esc recall below owns the messaging
                        } else {
                            logger.info("budget escalation retry failed: {s}", .{@errorName(err2)});
                            std.Io.Writer.print(ow, "  \x1b[2m[预算重试失败：{s} — 见下方诊断]\x1b[0m\n", .{@errorName(err2)}) catch {};
                        }
                        break;
                    };
                    // The discarded attempt's tokens were really spent —
                    // count them before it falls out of the totals.
                    total_input_tokens += response.usage.input_tokens;
                    total_output_tokens += response.usage.output_tokens;
                    turn_in += response.usage.input_tokens;
                    turn_out += response.usage.output_tokens;
                    response = next;
                    if (response.content.len > 0) break; // recovered
                    if (!stream_mod.outputBudgetExhausted(response.stop_reason, response.usage.output_tokens, eff_cap)) break; // empty but not capped — escalating won't help
                }
                if (esc_after_retry) {
                    // Same recall path as the main Esc branch above.
                    lineinput.regionEnd(w);
                    try std.Io.Writer.print(ow, "\n  [Esc — 已中断，输入已撤回，可直接编辑重发]\n\n", .{});
                    lineinput.recall_text = last_sent;
                    lineinput.recall_prefill = true;
                    try std.Io.File.Writer.flush(&file_writer);
                    break;
                }
            }

            logger.info("LLM response: stop={s} tokens_in={d} tokens_out={d} blocks={d}", .{
                @tagName(response.stop_reason),
                response.usage.input_tokens,
                response.usage.output_tokens,
                response.content.len,
            });

            // Track token usage — session totals plus the ① turn summary
            // (surfaced once, in the frozen turn-end status row).
            total_input_tokens += response.usage.input_tokens;
            total_output_tokens += response.usage.output_tokens;
            turn_in += response.usage.input_tokens;
            turn_out += response.usage.output_tokens;
            // Timing 口径: one window per generation, llm_t0 → accepted
            // response. The rare budget-escalation retry keeps the same
            // llm_t0, folding the discarded attempt into this window — a
            // bounded overcount, simpler than threading a second t0
            // through the escalation loop.
            turn_llm_calls += 1;
            turn_clock.roundDone(turn_llm_calls); // StreamJob ticker mirror
            turn_llm_ms += util_time.nowMillis() - llm_t0;

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
                        try std.Io.Writer.print(ow, "  [tool {s}: ", .{label});
                        var at_ls = false;
                        try memory_ops.writeMarginLines(ow, tr.content, "  ", &at_ls);
                        try std.Io.Writer.writeAll(ow, "]\n");
                    },
                    else => {},
                }
            }
            _ = live_llm_calls.fetchAdd(1, .monotonic); // P3: health-check api-rate signal
            // ① The per-generation stat line is gone: in/out surfaces once,
            // in the turn-end status row the region freezes below.
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
                // Empty with zero fanfare is the most confusing variant:
                // name the actual flavor instead of a blanket "resend".
                // ① budget exhausted (thinking burned the cap — escalation
                //    already tried up to stream_mod.MAX_OUTPUT_BUDGET);
                // ② reasoning-only output (no cap hit, still no text);
                // ③ plain empty (rare).
                if (stream_mod.outputBudgetExhausted(stop_reason, response.usage.output_tokens, eff_cap)) {
                    std.Io.Writer.print(ow, "  \x1b[2m[输出预算耗尽：模型生成 {d} tokens（达上限 {d}）但正文为空 — 思考型模型建议 /config 将「最大 tokens」调大（当前 {d}）后重发]\x1b[0m\n", .{
                        response.usage.output_tokens, eff_cap, switcher.settings.max_tokens,
                    }) catch {};
                } else if (had_thinking) {
                    std.Io.Writer.print(ow, "  \x1b[2m[模型只输出了思考过程（reasoning），未产出正文 — 重发通常可得到正文]\x1b[0m\n", .{}) catch {};
                } else {
                    std.Io.Writer.print(ow, "  \x1b[2m[模型返回空响应（0 内容块，stop={s}）— 如非预期可重发]\x1b[0m\n", .{@tagName(stop_reason)}) catch {};
                }
                try std.Io.File.Writer.flush(&file_writer);
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
            // Esc-cancel / worker-failure markers, hoisted to iteration
            // scope: the turn-break after the tool-result history append
            // (below) reads them from outside the `prepared` block.
            // batch_aborted = end the turn after this batch (Esc OR worker
            // failure); worker_failed = additionally skip finishToolCall
            // (no results exist — manual failure results were appended).
            // A user Esc does NOT skip finishToolCall: the cancelled batch
            // still yields one result per tool_use id, and those results
            // are exactly what the model must see on the next turn.
            var batch_aborted = false;
            var user_cancelled = false;
            var worker_failed = false;
            // Phase 1 (serial): permission gate + pre-execution backup for
            // every tool_use; approved calls are collected for phase 2.
            var prepared = std.ArrayList(turn_tools.PreparedCall).empty;
            var total_calls: u32 = 0;
            defer {
                for (prepared.items) |pc| {
                    if (pc.old_content) |oc| allocator.free(oc);
                }
                prepared.deinit(allocator);
            }

            // Iterate the owned copy in history — the response was freed above.
            const last_assistant = history.items[history.items.len - 1].content;
            for (last_assistant) |block| {
                if (block == .tool_use) {
                    has_tool_use = true;
                    total_calls += 1;
                    const tc = block.tool_use;

                    // Find tool definition
                    const tool_def = reg.findByName(tc.name) orelse {
                        std.Io.Writer.print(ow, "  [Unknown tool: {s}]\n", .{tc.name}) catch {};
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
                    if (turn_tools.isFileModifyingTool(tc.name)) {
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
                    const approved = try turn_ask.permissionGate(tool_def, tc.input, current_mode, &switcher, allocator, r, w, ow, &file_writer, &denial_state);
                    if (!approved) {
                        try result_blocks.append(allocator, .{ .tool_result = .{
                            .tool_use_id = try allocator.dupe(u8, tc.id),
                            .content = try allocator.dupe(u8, "denied by permission gate"),
                            .is_error = true,
                        } });
                        continue;
                    }

                    // Capture pre-write bytes for the diff preview.
                    // renderCodeDiff runs post-execution (finishToolCall),
                    // when the old content is already gone.
                    var old_content: ?[]u8 = null;
                    var old_unavailable = false;
                    if (turn_tools.isFileModifyingTool(tc.name) and
                        registry.getStringField(tc.input, "old_string") == null and
                        registry.getStringField(tc.input, "content") != null)
                    {
                        if (registry.getStringField(tc.input, "path")) |fp| {
                            if (std.Io.Dir.cwd().statFile(io, fp, .{})) |st| {
                                if (st.size > DIFF_READ_CAP) {
                                    old_unavailable = true;
                                } else if (std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, fp, allocator, std.Io.Limit.limited(DIFF_READ_CAP))) |oc| {
                                    old_content = oc;
                                } else |read_err| {
                                    // FileNotFound → genuinely new file (all-green);
                                    // anything else → skip the preview rather than
                                    // mislabel the overwrite as a new file.
                                    if (read_err != error.FileNotFound) old_unavailable = true;
                                }
                            } else |stat_err| {
                                if (stat_err != error.FileNotFound) old_unavailable = true;
                            }
                        }
                    }
                    errdefer if (old_content) |oc| allocator.free(oc);

                    try prepared.append(allocator, .{
                        .call = .{ .tool_name = tc.name, .input = tc.input, .tool_use_id = tc.id },
                        .snap_id = snap_id,
                        .old_content = old_content,
                        .old_unavailable = old_unavailable,
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
                // P4: tool batches run on a WORKER thread; the UI loop
                // stays alive underneath — full editing during a long
                // Bash run, and the status row carries a LIVE clock (the
                // old static status could not tick because the main
                // thread WAS the executor). Esc has no effect here (tools
                // are not cancellable); it is consumed by the editor
                // pump, never leaked into the next prompt.
                const batch_t0 = util_time.nowMillis();
                const ToolJob = struct {
                    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                    err: ?anyerror = null,
                    results: ?[]orchestration_mod.BatchResult = null,
                    fn run(
                        self: *@This(),
                        bts: []const orchestration_mod.ToolCallBatch,
                        al: std.mem.Allocator,
                        i_o: std.Io,
                        defs: []const registry.ToolDefinition,
                    ) void {
                        executeBatches(self, bts, al, i_o, defs);
                    }
                    fn executeBatches(
                        self: *@This(),
                        bts: []const orchestration_mod.ToolCallBatch,
                        al: std.mem.Allocator,
                        i_o: std.Io,
                        defs: []const registry.ToolDefinition,
                    ) void {
                        const res = orchestration_mod.executeBatches(bts, al, i_o, defs) catch |e| {
                            self.err = e;
                            self.done.store(true, .release);
                            return;
                        };
                        self.results = res;
                        self.done.store(true, .release);
                    }
                    /// Status text with the LIVE turn clock (UI loop side).
                    fn statusText(t0: i64, llm_rounds: u32, n_calls: usize, first_tool: []const u8, buf: []u8) []const u8 {
                        const tsum = @as(f64, @floatFromInt(util_time.nowMillis() - t0)) / 1000.0;
                        // Task progress (②: the task system existed but the
                        // TUI never surfaced it — "长任务进行到哪" answered
                        // at a glance). Empty store → segment omitted.
                        const ts = task_store.global();
                        var task_seg: [40]u8 = undefined;
                        const tseg: []const u8 = if (ts.count() > 0)
                            std.fmt.bufPrint(&task_seg, " · 任务 {d}/{d}", .{ ts.completedCount(), ts.count() }) catch ""
                        else
                            "";
                        return if (n_calls == 1)
                            std.fmt.bufPrint(buf, "⚙ 工具 {s}{s} · LLM {d}轮 · 回合 {d:.1}s", .{ first_tool, tseg, llm_rounds, tsum }) catch "⚙ 执行工具"
                        else
                            std.fmt.bufPrint(buf, "⚙ 执行 {d} 个工具（{s}…）{s} · LLM {d}轮 · 回合 {d:.1}s", .{ n_calls, first_tool, tseg, llm_rounds, tsum }) catch "⚙ 执行工具";
                    }
                };
                var tool_job = ToolJob{};
                var tool_results: []orchestration_mod.BatchResult = undefined;
                // batch_aborted/user_cancelled live at iteration scope (see
                // their declaration above); set by the UI loop (Esc) or the
                // worker-failure path below. Tool results are still appended
                // to history so every tool_use id keeps a tool_result.
                // Interactive tools (AskUserQuestion) read stdin COOKED on
                // the calling thread — running them inside the worker would
                // race the UI loop for fd 0. Any batch containing one runs
                // synchronously (the pre-P4 shape; the y/N permission gate
                // already behaves this way).
                var has_interactive = false;
                for (prepared.items) |p| {
                    if (std.mem.eql(u8, p.call.tool_name, "AskUserQuestion")) has_interactive = true;
                }
                // Fresh cancel slot per batch — a stale `true` from a
                // previous Esc would silently no-op every tool in this one.
                cancel_mod.toolBatchReset();
                const th = if (has_interactive) null else std.Thread.spawn(.{}, ToolJob.run, .{ &tool_job, batches, allocator, io, reg.definitions() }) catch null;
                {
                    if (th) |t| {
                        t.detach();
                        // UI loop while the tools run: editor + live clock.
                        var last_status: i64 = 0;
                        while (!tool_job.done.load(.acquire)) {
                            var pfd = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
                            const n = std.c.poll(&pfd, 1, 100);
                            if (n == 1 and (pfd[0].revents & std.c.POLL.IN) != 0) {
                                if (lineinput.editorLiveKey(r, w) and !user_cancelled) {
                                    // Esc/Ctrl-C during tools: cancel the
                                    // batch. An in-flight Bash is group-
                                    // killed by its watchdog (this is the
                                    // only escape from `timeout: 0`); not-
                                    // yet-started calls short-circuit to
                                    // "cancelled (not run)". The batch still
                                    // yields one result per tool_use id.
                                    user_cancelled = true;
                                    batch_aborted = true;
                                    cancel_mod.toolBatchCancel();
                                    lineinput.regionStatus(w, "⏳ 正在取消工具批次…");
                                    std.Io.File.Writer.flush(&file_writer) catch {};
                                }
                            } else if (n == 0 and !user_cancelled) {
                                // Quiet slice: drain due cron tasks (health
                                // check / memory decay) so a long batch no
                                // longer starves them for the whole turn.
                                if (cron_ptr) |cp| cp.drainDue();
                                const now = util_time.nowMillis();
                                if (now - last_status >= 500) {
                                    last_status = now;
                                    var sb: [96]u8 = undefined;
                                    lineinput.regionStatus(w, ToolJob.statusText(turn_t0, turn_llm_calls, prepared.items.len, prepared.items[0].call.tool_name, &sb));
                                    std.Io.File.Writer.flush(&file_writer) catch {};
                                }
                            }
                        }
                        // The slot must not leak a `true` into later batches
                        // (subagent tool runs its own inner batches).
                        cancel_mod.toolBatchReset();
                        if (tool_job.results) |res| {
                            tool_results = res;
                        } else {
                            // The worker failed (alloc etc.). Returning here
                            // would strand every tool_use id without a
                            // tool_result — invalid history for strict APIs
                            // on the next request. Record failure results
                            // and end the turn gracefully instead.
                            // tool_results stays undefined — every use below
                            // is guarded by !worker_failed.
                            if (tool_job.err) |e| logger.err("tool batch worker failed: {}", .{e});
                            batch_aborted = true;
                            worker_failed = true;
                            for (prepared.items) |p| {
                                try result_blocks.append(allocator, .{ .tool_result = .{
                                    .tool_use_id = try allocator.dupe(u8, p.call.tool_use_id),
                                    .content = try allocator.dupe(u8, "tool batch failed (internal error); not executed"),
                                    .is_error = true,
                                } });
                            }
                            std.Io.Writer.print(ow, "  [工具批次内部错误 — 本回合结束，结果已按失败记录]\n", .{}) catch {};
                            try std.Io.File.Writer.flush(&file_writer);
                        }
                    } else {
                        // No thread: synchronous fallback (pre-P4 shape).
                        tool_results = try orchestration_mod.executeBatches(batches, allocator, io, reg.definitions());
                    }
                }

                // Worker failure is the ONLY path that skips finishToolCall
                // (results don't exist). A user cancel runs it normally —
                // the cancelled/partial results must land in history.
                if (!worker_failed) {
                    const results = tool_results;
                    defer allocator.free(results);

                    var batch_errors: u32 = 0;
                    for (prepared.items, 0..) |p, i| {
                        window_tools += 1;
                        const errored = try turn_tools.finishToolCall(p, results[i].result, allocator, &log, &result_blocks, w, ow, &file_writer, history.items.len, util_time.nowMillis() - batch_t0);
                        if (errored) {
                            batch_errors += 1;
                            // expected_stop (timeout kill / user cancel / declined
                            // question) is deliberate control flow — feeding it to
                            // the reflection window's error rate diagnosed a
                            // timeout-driven debugging marathon as "unstable
                            // environment" and stored that as a cross-session
                            // "insight" (2026-11-06).
                            if (!results[i].result.expected_stop) {
                                window_errors += 1;
                                evbus.emit(.{ .error_detected = .{ .errors = 1 } }); // P3 event record
                            }
                        }
                    }

                    // Timing 口径: one window per batch, dispatch
                    // (batch_t0) → all results collected; tools counted
                    // per call — a parallel batch folds each tool's time
                    // into the batch window (wall time, not exclusive).
                    turn_tool_ms += util_time.nowMillis() - batch_t0;
                    turn_tool_calls += @intCast(prepared.items.len);
                    // Live decision trace: execution step for this batch.
                    if (live_trace) |*t| {
                        const conf = 1.0 - @as(f64, @floatFromInt(batch_errors)) / @as(f64, @floatFromInt(prepared.items.len));
                        var step_buf: [96]u8 = undefined;
                        const out_desc = std.fmt.bufPrint(&step_buf, "tools={d} errors={d}", .{ prepared.items.len, batch_errors }) catch "batch";
                        traceAddStep(t, .tool_execution, conf, "approved batch", out_desc, "permission gate + thread pool", @intCast(util_time.nowMillis() - batch_t0), allocator) catch {};
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

            // Esc-cancelled or internally-failed batch: the turn stops
            // HERE, with valid history — the tool results (cancelled /
            // partial / failure) are already appended, so the model sees
            // exactly what happened when the conversation resumes.
            if (batch_aborted) {
                lineinput.regionEnd(w);
                if (user_cancelled) {
                    std.Io.Writer.print(ow, "\n  [Esc — 工具批次已取消，回合结束。取消/部分结果已记录，可直接继续对话]\n\n", .{}) catch {};
                }
                try std.Io.File.Writer.flush(&file_writer);
                break;
            }

            // P4 mid-turn injection: messages the user typed + Enter'd
            // while the model was generating enter the conversation HERE —
            // the next iteration's request includes them, so supplements
            // land one tool-round later without interrupting anything.
            while (lineinput.queuedTake()) |qm| {
                const q = try allocator.dupe(u8, qm); // slot shifts on next take
                const qb = try allocator.alloc(llm.ContentBlock, 1);
                qb[0] = .{ .text = q };
                try history.append(allocator, .{
                    .role = .user,
                    .content = qb,
                    .timestamp = util_time.nowMillis(),
                });
                // Same bookkeeping as a regular query: reflection window +
                // event record. The window owns its OWN copy — history
                // frees qb's text on compact/clear and the window's defer
                // frees its items; one shared pointer double-freed.
                if (allocator.dupe(u8, q)) |wq| {
                    window_queries.append(allocator, wq) catch allocator.free(wq);
                } else |_| {}
                evbus.emit(.{ .user_query_start = {} });
                // Committed-style echo — ONLY when the queue-time echo
                // didn't already show it (null-w drain queues skip that).
                if (!lineinput.last_take_echoed) lineinput.regionEchoCommitted(w, q);
                std.Io.File.Writer.flush(&file_writer) catch {};
            }

            try std.Io.File.Writer.flush(&file_writer);
        }

        // Turn over: the live region comes down HERE — one teardown for
        // every exit path (completion, error break, Esc). Paths that
        // already ended it before their own message printing arrive with
        // it down. A still-up region (normal completion) FREEZES: the ①
        // turn summary becomes the status row's final text, that row
        // stays as the transcript tail, and the next prompt renders
        // exactly where the input row was. Zero-usage turns (nothing was
        // generated) keep the plain regionEnd + spacer.
        if (lineinput.regionUp()) {
            region_wr.flushTableBlock();
            if (turn_in + turn_out > 0) {
                const turn_s = @as(f64, @floatFromInt(util_time.nowMillis() - turn_t0)) / 1000.0;
                var sb: [160]u8 = undefined;
                // Non-empty fallback: regionStatus("") would erase the
                // region rows instead of freezing a summary.
                const summary = std.fmt.bufPrint(&sb, "✓ 完成 · in {d} → out {d} · LLM {d}次 {d:.1}s · 工具 {d}个 {d:.1}s · 总 {d:.1}s", .{ turn_in, turn_out, turn_llm_calls, @as(f64, @floatFromInt(turn_llm_ms)) / 1000.0, turn_tool_calls, @as(f64, @floatFromInt(turn_tool_ms)) / 1000.0, turn_s }) catch "✓ 完成";
                lineinput.regionStatus(w, summary);
                lineinput.regionFreeze(w);
                // Same numbers into the persistent log — the frozen row
                // scrolls away; ziv.log is where post-mortems read.
                logger.info("turn: llm {d} calls {d}ms · tools {d} calls {d}ms · total {d}ms", .{ turn_llm_calls, turn_llm_ms, turn_tool_calls, turn_tool_ms, util_time.nowMillis() - turn_t0 });
            } else {
                lineinput.regionEnd(w);
                // Aborted/failed exits (Esc, TTFT give-up, transport error)
                // arrive with the region already down — the frozen-row
                // summary above never runs, so the turn's cost was silent
                // (2026-11-05 23:51 incident: 157.9s spent, TUI showed
                // nothing). Same breakdown, as a transcript line instead.
                if (turn_llm_calls > 0 or turn_tool_calls > 0) {
                    const abort_s = @as(f64, @floatFromInt(util_time.nowMillis() - turn_t0)) / 1000.0;
                    const ts = task_store.global();
                    var tseg_b: [48]u8 = undefined;
                    const undone = ts.count() -| ts.completedCount();
                    const tseg: []const u8 = if (undone > 0)
                        std.fmt.bufPrint(&tseg_b, " · 未完任务 {d}（/tasks 查看）", .{undone}) catch ""
                    else
                        "";
                    std.Io.Writer.print(ow, "  \x1b[2m⏱ 中断 · LLM {d}次 {d:.1}s · 工具 {d}个 {d:.1}s · 已进行 {d:.1}s{s} · 逐步耗时见 .ziv/traces/（/trace 直读）\x1b[0m\n", .{ turn_llm_calls, @as(f64, @floatFromInt(turn_llm_ms)) / 1000.0, turn_tool_calls, @as(f64, @floatFromInt(turn_tool_ms)) / 1000.0, abort_s, tseg }) catch {};
                    logger.info("turn(aborted): llm {d} calls {d}ms · tools {d} calls {d}ms · total {d}ms", .{ turn_llm_calls, turn_llm_ms, turn_tool_calls, turn_tool_ms, util_time.nowMillis() - turn_t0 });
                }
                try std.Io.Writer.writeAll(w, "\n");
            }
            try std.Io.File.Writer.flush(&file_writer);
        }

        // ③ Turn telemetry: persist the decision trace (per-step
        // durations, JSONL) before the next query re-inits it. Default
        // ON; ZIV_TRACE=0/false opts out. A failed write is a warning —
        // telemetry must never break a turn.
        if (live_trace) |*t| {
            const trace_off = blk: {
                const v = env.get("ZIV_TRACE") orelse break :blk false;
                break :blk std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false");
            };
            if (!trace_off and t.getSteps().len > 0) {
                t.complete();
                if (t.writeJsonlFile(io, ".ziv/traces", allocator)) {
                    // /trace reads this path back — record it on success only.
                    var path_b: [160]u8 = undefined;
                    if (std.fmt.bufPrint(&path_b, ".ziv/traces/{d}.jsonl", .{t.started_at})) |p| {
                        turn_clock.setTracePath(p);
                    } else |_| {}
                } else |e| {
                    logger.warning("trace persist failed: {}", .{e});
                }
            }
        }

        if (agent_iterations >= max_agent_iters) {
            try std.Io.Writer.print(w, "\x1b[2m  [Agent loop limit ({d}) reached — 输入区已预填「继续」：Enter 接着跑，也可改发其他指令；上限经 settings.json 的 agent_loop_limit 调整]\x1b[0m\n", .{max_agent_iters});
            // Same recoverable-giveup shape as the TTFT triple-failure
            // path: history stays legal, one Enter resumes as a fresh
            // turn — the marathon's findings are never lost to a stop.
            lineinput.recall_text = "继续";
            lineinput.recall_prefill = true;
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
                            var rows_arena = std.heap.ArenaAllocator.init(allocator);
                            defer rows_arena.deinit();
                            if (ms.episodic_mem.retrieveRecentArena(rows_arena.allocator(), 1000) catch null) |entries| {
                                const ents = entries;
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
        evbus.emit(.{ .user_query_end = .{ .tools = window_tools, .errors = window_errors } }); // P3 event record
        if (mem_sys != null and reflector.shouldReflect()) {
            memory_ops.runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, switcher.getProvider() catch null, llm.provider.capabilityTier(switcher.modelName(), switcher.backend), memory_ops.backgroundLlmConfig(allocator, &switcher), &evbus);
            if (live_trace) |*t| {
                traceAddStep(t, .reflection_trigger, 0.9, "query window", "insights stored", "phi/e heuristics", 0, allocator) catch {};
            }
        }

        // P4: queue survivors (queued during the FINAL stream, after the
        // last tool round) auto-send as the next turn. ALL of them —
        // joined with '\n' as one multi-line message (mid-turn injection
        // at the tool rounds drains them as separate messages; here the
        // single auto_submit slot is the only vehicle). The old take-one
        // silently dropped every survivor past the first.
        if (lineinput.queuedHas()) {
            var joined: std.ArrayList(u8) = .empty;
            while (lineinput.queuedTake()) |qm| {
                if (joined.items.len > 0) joined.append(allocator, '\n') catch break;
                joined.appendSlice(allocator, qm) catch break;
            }
            if (joined.items.len > 0) {
                auto_submit = joined.toOwnedSlice(allocator) catch blk: {
                    joined.deinit(allocator);
                    break :blk null;
                };
            }
        }

        try std.Io.Writer.writeAll(w, "\n");
        try std.Io.File.Writer.flush(&file_writer);
    }
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
/// One compact row from a trace JSONL step line: "phase  Nms". Header
/// lines (query/total — no "phase" key) return null. Field scanning, not
/// JSON parsing: /trace stays light and the field order is fixed by
/// decision_trace.toJsonl.
fn traceStepSummary(line: []const u8, buf: []u8) ?[]const u8 {
    const phase_key = "\"phase\":\"";
    const p0 = std.mem.indexOf(u8, line, phase_key) orelse return null;
    const p1 = p0 + phase_key.len;
    const p2 = std.mem.indexOfScalarPos(u8, line, p1, '"') orelse return null;
    const ms_key = "\"ms\":";
    const m0 = std.mem.indexOf(u8, line, ms_key) orelse return null;
    const m1 = m0 + ms_key.len;
    const m2 = std.mem.indexOfScalarPos(u8, line, m1, ',') orelse line.len;
    return std.fmt.bufPrint(buf, "{s:<18} {s}ms", .{ line[p1..p2], line[m1..m2] }) catch null;
}

/// Header row of a trace file: "「query」 · N 步 · 总 X.Ys".
fn traceHeaderSummary(header: []const u8, buf: []u8) ![]const u8 {
    const qk = "\"query\":\"";
    const q0 = std.mem.indexOf(u8, header, qk) orelse return error.BadHeader;
    const q1 = q0 + qk.len;
    var q_end = std.mem.indexOf(u8, header, "\",\"steps\":") orelse header.len;
    if (q_end < q1) q_end = header.len;
    var query = header[q1..q_end];
    if (query.len > 24) {
        query = query[0..24];
        // Back off to a UTF-8 boundary — a mid-CJK cut would mojibake.
        while (query.len > 0 and (query[query.len - 1] & 0xC0) == 0x80) query = query[0 .. query.len - 1];
        if (query.len > 0) query = query[0 .. query.len - 1];
    }
    const tk = "\"total_ms\":";
    const t0 = std.mem.indexOf(u8, header, tk) orelse return error.BadHeader;
    const t1 = t0 + tk.len;
    const t2 = std.mem.indexOfScalarPos(u8, header, t1, ',') orelse header.len;
    const total_ms = std.fmt.parseInt(i64, header[t1..t2], 10) catch 0;
    const sk = "\"steps\":";
    const s0 = std.mem.indexOf(u8, header, sk) orelse return error.BadHeader;
    const s1 = s0 + sk.len;
    const s2 = std.mem.indexOfScalarPos(u8, header, s1, ',') orelse header.len;
    return std.fmt.bufPrint(buf, "「{s}」 · {s} 步 · 总 {d}.{d}s", .{ query, header[s1..s2], @divTrunc(total_ms, 1000), @divTrunc(@mod(total_ms, 1000), 100) });
}

test "trace line summary: step rows parsed, header skipped" {
    var buf: [96]u8 = undefined;
    const step_line = "{\"step\":3,\"phase\":\"llm_generation\",\"ts\":1793893800607,\"ms\":66895,\"conf\":0.90,\"in\":\"history + system prompt\",\"out\":\"content blocks\",\"why\":\"tool_use\"}";
    const s = traceStepSummary(step_line, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, s, "llm_generation") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "66895ms") != null);
    // Header rows carry no "phase" key — they must yield null, not garbage.
    const header_line = "{\"query\":\"继续\",\"steps\":9,\"total_ms\":157941,\"started_at\":1793893733712}";
    try std.testing.expect(traceStepSummary(header_line, &buf) == null);
}

test "trace header summary: query, steps, total seconds" {
    var buf: [96]u8 = undefined;
    const header = "{\"query\":\"继续任务\",\"steps\":9,\"total_ms\":157941,\"started_at\":1793893733712}";
    const s = try traceHeaderSummary(header, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "继续任务") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "157.9s") != null);
    // Long CJK queries truncate on a UTF-8 boundary (no mojibake tail).
    const long_header = "{\"query\":\"一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十\",\"steps\":2,\"total_ms\":1000,\"started_at\":1}";
    const s2 = try traceHeaderSummary(long_header, &buf);
    try std.testing.expect(s2.len <= buf.len);
}

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
/// Turn start (P1): the stream tick's status row shows BOTH the current
/// round's elapsed time and the CUMULATIVE turn time — the old per-
/// generation timer reset to 0.0s on every round, hiding what the
/// previous rounds cost. Main-thread only: set by run() right before
/// regionBegin, read by streamCb's tick on the same thread.
// Turn timing/round/trace-path state lives in util/turn_clock.zig (R2:
// three loose globals → one atomic namespaced object, single writer).


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

/// Show current context usage.
fn showContext(history: *std.ArrayList(llm.Message), total_in: u64, total_out: u64, w: *std.Io.Writer) !void {
    const est = turn_history.estimateHistoryTokens(history.items);
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
            turn_history.freeMessage(msg, alloc);
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
                turn_history.freeMessage(msg, alloc);
                removed += 1;
            }
        }
    }

    // Remove trailing user message (the original prompt)
    if (history.items.len > 1) {
        const last = history.items[history.items.len - 1];
        if (last.role == .user) {
            const msg = history.pop().?;
            turn_history.freeMessage(msg, alloc);
            removed += 1;
        }
    }

    // Removing the results message above can strand the assistant tool_use
    // it answered — a dangling tool_calls gets the next request 400'd.
    const len_before_repair = history.items.len;
    turn_history.repairToolPairing(history, alloc);
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

    // Cooked-with-echo (session raw otherwise — same as the confirm below).
    var cooked_sel = menu.CookedGuard{};
    cooked_sel.enter();
    defer cooked_sel.restore();
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

    // Cooked-with-echo for the confirm read (session raw otherwise).
    var cooked = menu.CookedGuard{};
    cooked.enter();
    defer cooked.restore();
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
        turn_history.freeMessage(msg, alloc);
        dropped += 1;
    }
    // The recorded history_len can fall between a tool_use and its results —
    // trim the stranded pair end so the next request stays wire-valid.
    const len_before_repair = history.items.len;
    turn_history.repairToolPairing(history, alloc);
    dropped += len_before_repair - history.items.len;

    try std.Io.Writer.print(w, "  ({d} restored, {d} deleted, {d} errors, {d} messages rewound)\n\n", .{
        result.restored_files.len,
        result.deleted_files.len,
        result.errors.len,
        dropped,
    });

    engine.freeResult(result);
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
pub fn swapMemoryBlockText(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, old_text: []const u8, new_text: []const u8) bool {
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
pub fn appendSystemBlock(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, text: []const u8) bool {
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



fn printHelp(w: *std.Io.Writer) !void {
    try std.Io.Writer.writeAll(w,
        \\Available commands:
        \\  /help, /h         Show this help
        \\  /quit, /q         Exit ziv
        \\  /version          Show version
        \\  /stats            Show session statistics and token usage
        \\  /tools            List registered tools (12 tools)
        \\  /run <t> <json>   Execute a tool directly
        \\  /terminal-setup   Show Shift+Enter setup guide for this terminal
        \\
        \\Model & Config:
        \\  /model, /models   Show current model and available models
        \\  /model <name>     Switch to a different model
        \\  /mode             Cycle permission mode
        \\  /config           Interactive configuration menu
        \\
        \\Conversation:
        \\  /compact          Summarize the conversation (LLM) to free tokens
        \\  /compact phi      Truncate history to the recent 61.8% (no LLM call)
        \\  /clear            Clear conversation, start fresh (alias: /reset, /new)
        \\  /context          Show current context/token usage
        \\  /trace            Show the last turn's per-step timing
        \\  /tasks            Show the task list and progress
        \\  /last [N]         Show a recent tool's full output (N=1 newest)
        \\  /undo             Undo last exchange
        \\  /history          Show operation history
        \\  /rewind           Rewind files AND conversation to a checkpoint
        \\  /plan <goal>      Create a plan file anchored into the system
        \\                    prompt; /plan shows it, /plan off ends it
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

    turn_history.clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
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
        for (history.items) |m| turn_history.freeContentBlocks(alloc, m.content);
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
        turn_history.applyFactsUpdate(&history, &facts, alloc, turn_history.compactHistoryImpl(&history, alloc, facts));
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
