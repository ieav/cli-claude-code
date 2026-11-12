/// Enhanced REPL for Ziv — reads user input, dispatches commands and queries.
/// Supports multi-model switching, tool execution, permission modes, operation history,
/// conversation management (compact/clear/context/undo/rewind), and interactive config.
/// Adapted for Zig 0.16 I/O API.
const std = @import("std");
const termio = @import("util/termio.zig");
const wincompat = @import("util/wincompat.zig");
const tools_mod = @import("tools/mod.zig");
const orchestration_mod = @import("tools/orchestration.zig");
const auth = @import("tools/auth_mode.zig");
const classifier_mod = @import("tools/classifier.zig");
const menu = @import("util/menu.zig");
const zivroot = @import("util/zivroot.zig");

fn env_flag_off(name: []const u8) bool {
    const v = @import("util/env.zig").get(name) orelse return false;
    return std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false");
}
const lineinput = @import("util/lineinput.zig");
const stream_mod = @import("turn/stream.zig");
const turn_ask = @import("turn/ask.zig");
const turn_tools = @import("turn/tools.zig");
const turn_history = @import("turn/history.zig");
pub const rules_mod = @import("rules/ziv_md.zig");
const memory_ops = @import("session/memory_ops.zig");
const config_menu = @import("commands/config_menu.zig");
const history_cmds = @import("commands/history_cmds.zig");
const dispatch_mod = @import("commands/dispatch.zig");
const input_history_mod = @import("session/input_history.zig");
const session_store = @import("session/session_store.zig");
const code_index = @import("knowledge/code_index.zig");
const error_recovery = @import("turn/error_recovery.zig");
const model_switcher = @import("session/model_switcher.zig");
pub const ModelSwitcher = model_switcher.ModelSwitcher; // re-export: memory_ops/config_menu alias via repl_mod
const json_tree = @import("util/json_tree.zig");
const slash_cmds = @import("util/slash_commands.zig");
const runtime_registry = @import("tools/runtime_registry.zig");
const skills_mod = @import("skills/mod.zig");
const hooks_mod = @import("hooks/hooks.zig");
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
pub const MAX_CONTEXT_TOKENS: u32 = 128_000;

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

/// Ctrl+T 输出风格 toggle 的接线上下文：on_style_toggle 是无参回调
/// （与 on_verbose_toggle 同形），只能经模块级取 run() 的常驻局部。
/// 主循环开始前赋值；回调仅在按键时解引用，彼时必然已就绪。
const StyleToggleCtx = struct {
    switcher: *ModelSwitcher,
    applied_prompt_setting: *?[]const u8,
    applied_output_style: *[]const u8,
    sys_prompt_owned: *?[]u8,
    sys_prompt: *[]const u8,
    history: *std.ArrayList(llm.Message),
    io: std.Io,
};
var style_toggle_ctx: ?StyleToggleCtx = null;


/// ziv.md hot reload: refresh both layers and swap/append/remove the
/// rules block in history[0]. Returns true when anything changed. The
/// swap can legitimately fail (e.g. /clear rebuilt the system message and
/// dropped the block) — that path degrades to append, self-healing.
pub fn reloadRulesBlock(
    history: *std.ArrayList(llm.Message),
    rules_state: *rules_mod.RulesState,
    rules_text: *?[]u8,
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
) bool {
    rules_mod.freeRulesState(alloc, rules_state);
    rules_state.* = rules_mod.loadStartup(alloc, io, false); // never generates on reload
    const fresh = rules_mod.buildBlockText(alloc, rules_state);
    if (fresh) |nt| {
        if (rules_text.*) |ot| {
            if (turn_history.swapMemoryBlockText(history, alloc, ot, nt)) {
                alloc.free(ot);
                rules_text.* = nt;
            } else if (turn_history.appendSystemBlock(history, alloc, nt)) {
                alloc.free(ot);
                rules_text.* = nt;
            } else {
                alloc.free(nt); // block update failed; old text stays for the next tick
            }
        } else if (turn_history.appendSystemBlock(history, alloc, nt)) {
            rules_text.* = nt;
        } else {
            alloc.free(nt);
        }
        if (rules_text.* != null and rules_text.*.?.ptr == nt.ptr) {
            std.Io.Writer.print(w, "  [ziv.md 已重载 · ~{d} tokens]\n", .{tokens_mod.estimateTokens(nt)}) catch {};
            std.Io.File.Writer.flush(file_writer) catch {};
            return true;
        }
        return false;
    }
    // New content empty: drop the block if one exists.
    if (rules_text.*) |ot| {
        _ = turn_history.removeSystemBlockByText(history, alloc, ot);
        alloc.free(ot);
        rules_text.* = null;
        std.Io.Writer.print(w, "  [ziv.md 已移除（内容为空/文件删除）]\n", .{}) catch {};
        std.Io.File.Writer.flush(file_writer) catch {};
        return true;
    }
    return false;
}

pub fn run(io: std.Io, stdin_file: std.Io.File, stdout_file: std.Io.File) !void {
    // Windows one-shot: VT output + UTF-8 console CP (posix no-op).
    termio.init();
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
    lineinput.setSessionGuard(&tty_guard);
    // SESSION-scoped keyboard protocols (2026-11-12): bracketed paste +
    // kitty disambiguate + xterm modifyOtherKeys level 1. Pushed for the
    // WHOLE session (not per-readLine — that left every mid-turn keystroke
    // without them: Shift+Enter degraded to Enter = queue, pastes lost
    // their 200~ wrapper = no folding). modifyOtherKeys L1 is what makes
    // Shift+Enter/Ctrl+Enter arrive as CSI 13;2u/13;5u on xterm-family
    // terminals (VS Code, Windows Terminal, VTE) — level 1 on purpose:
    // it only re-encodes MODIFIED well-known keys, never plain letters,
    // so Alt+letter etc. keep their legacy encodings. macOS Terminal.app
    // honors none of these — the \`+Enter / Ctrl+J / Option+Enter
    // fallbacks remain. Popped on every normal exit path (defer); a hard
    // crash leaks the modes like mouse mode did — cosmetic, terminal
    // reset clears it.
    if (tty_guard.active) {
        termio.writeProtocol(true); // push bracketed paste + kitty + modifyOtherKeys
    }
    defer if (tty_guard.active) {
        termio.writeProtocol(false); // pop: terminal left as found
    };
    // P3c: Ctrl+O toggles tool-output verbosity (prompt AND mid-turn).
    lineinput.on_verbose_toggle = struct {
        fn cb() []const u8 {
            const next = !turn_tools.verbose_output.load(.monotonic);
            turn_tools.verbose_output.store(next, .monotonic);
            return if (next)
                "\x1b[2m[工具输出: 详细（Ctrl+O 切简要）]\x1b[0m"
            else
                "\x1b[2m[工具输出: 简要——长输出只出前 3 行（Ctrl+O 切详细）]\x1b[0m";
        }
    }.cb; // Ctrl-Z manual suspend needs it
    // Ctrl+T toggles output style (default ↔ concise), prompt AND
    // mid-turn — mirror of Ctrl+O's wiring above. Style settings live in
    // the ModelSwitcher the ctx points at; ctx lands before the main
    // loop (vars must exist first), and the callback only fires on a
    // keypress inside readLine — never before.
    lineinput.on_style_toggle = struct {
        fn cb() []const u8 {
            const c = style_toggle_ctx orelse return "\x1b[2m[风格切换未就绪]\x1b[0m";
            const next: []const u8 = if (std.mem.eql(u8, c.switcher.settings.output_style, system_prompt_mod.STYLE_CONCISE))
                system_prompt_mod.STYLE_DEFAULT
            else
                system_prompt_mod.STYLE_CONCISE;
            dispatch_mod.applyOutputStyle(c.switcher, c.applied_prompt_setting, c.applied_output_style, c.sys_prompt_owned, c.sys_prompt, c.history, allocator, c.io, next) catch |e| {
                logger.warning("style toggle failed: {}", .{e});
                return "\x1b[2m[风格切换失败（详见日志）]\x1b[0m";
            };
            return if (std.mem.eql(u8, next, system_prompt_mod.STYLE_CONCISE))
                "\x1b[2m[输出风格: concise——结果优先，省略开场白/过程/复述（Ctrl+T 切回）]\x1b[0m"
            else
                "\x1b[2m[输出风格: default——完整叙述（Ctrl+T 切 concise）]\x1b[0m";
        }
    }.cb;
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
    // 项目根锚定：main.zig 已在横幅处初始化（含继承提示）；此处幂等兜底
    // （直接单测调用 repl.run 的形态）。
    if (zivroot.rootLen() == 0) zivroot.init(io);
    var fhist_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fhist = file_history.FileHistoryState.init(allocator, try allocator.dupe(u8, zivroot.sub(&fhist_buf, "checkpoints")));
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
    var dotziv_buf: [std.fs.max_path_bytes]u8 = undefined;
    std.Io.Dir.cwd().createDirPath(io, zivroot.sub(&dotziv_buf, ".")) catch {};
    // Persistent diagnostics: the interactive-stderr mute hides every log
    // line in TUI mode, so gateway failures used to leave no trail at all.
    var logs_buf: [std.fs.max_path_bytes]u8 = undefined;
    logger.setLogFile(io, zivroot.sub(&logs_buf, "logs"));
    var mem_db: ?database_mod.Database = blk: {
        var memdb_buf: [std.fs.max_path_bytes]u8 = undefined;
        var db = database_mod.Database.init(allocator, zivroot.sub(&memdb_buf, "memory.db")) catch break :blk null;
        db.runMigrations() catch {
            logger.warning("memory: migrations failed, memory disabled", .{});
            db.deinit();
            break :blk null;
        };
        break :blk db;
    };
    defer if (mem_db) |*db| db.deinit();
    // P3 session persistence: every turn boundary flushes new history into
    // .ziv/sessions.db; /resume brings a past conversation (blocks, model,
    // mode) back. Best-effort — the REPL runs fine without it.
    const sess_store: ?*session_store.SessionStore = blk: {
        var sessdb_buf: [std.fs.max_path_bytes]u8 = undefined;
        const store = session_store.SessionStore.open(allocator, zivroot.sub(&sessdb_buf, "sessions.db"), ".", switcher.modelName(), current_mode) orelse break :blk null;
        break :blk store;
    };
    defer if (sess_store) |st| {
        st.flush(history.items);
        st.markExit(false); // no-op when /quit/EOF already marked clean
        st.close();
    };
    // Crash recovery hint: a session row with no exit mark means the last
    // process died mid-conversation — surface it before the first prompt.
    if (sess_store) |st| {
        if (session_store.lastUncleanSession(allocator, &st.db, st.session_id) catch null) |unc| {
            defer {
                allocator.free(unc.model);
                allocator.free(unc.permission_mode);
                if (unc.first_line) |f| allocator.free(f);
            }
            if (unc.id != st.session_id) {
                std.Io.Writer.print(w, "  [检测到未正常退出的会话 #{d}（{s}…）— /resume 可恢复]\n\n", .{
                    unc.id, unc.first_line orelse "(无消息)",
                }) catch {};
                std.Io.File.Writer.flush(&file_writer) catch {};
            }
        }
    }
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

    // 延迟提取（2026-11-10）：上次退出存档的会话转录在后台补提（LLM），
    // 结果经 .reply 文件交接，提示符循环顶落库——启动零延迟。
    if (mem_db != null) {
        if (memory_ops.backgroundLlmConfig(allocator, &switcher)) |cfg| {
            memory_ops.spawnPendingExtraction(cfg, allocator, io);
        }
    }

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
    monitor.setLiveStats(&live_llm_calls, &live_llm_429s, &live_est_tokens);
    // Test hook: ZIV_CRON_SCALE=60 compresses the timeline (81.5min → ~82s)
    // so scheduled maintenance is observable in a smoke run.
    var cron_scale: u64 = 1;
    // π hours ≈ 3.14h — the roadmap's π-period graph scan cadence.
    const graph_scan_interval_ms: i64 = @intFromFloat(math_mod.constants.PI * 60.0 * 60.0 * 1000.0);
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
    // P5 π 周期图谱扫描：启动即扫一次（/knowledge 立即有数据），此后
    // 每 π 小时刷新孤立节点/断边报告。
    var graph_scan_ctx = memory_ops.GraphScanCtx{ .kg = if (kgraph) |*g| g else null };
    memory_ops.runGraphScan(if (kgraph) |*g| g else null);
    cron.addTask(.{
        .name = "graph_scan",
        .interval_ms = graph_scan_interval_ms,
        .last_run = std.atomic.Value(i64).init(0),
        .enabled = std.atomic.Value(bool).init(true),
        .task_fn = memory_ops.graphScanTask,
        .ctx = @ptrCast(&graph_scan_ctx),
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
    var sys_prompt_owned = system_prompt_mod.buildSystemPrompt(allocator, switcher.settings.system_prompt, switcher.settings.output_style) catch null;
    defer if (sys_prompt_owned) |sp| allocator.free(sp);
    var sys_prompt: []const u8 = sys_prompt_owned orelse system_prompt_mod.default_system_prompt;
    // What the baked history[0] prompt was built from — /config and the
    // settings hot reload compare against it to know when to rebuild.
    var applied_prompt_setting: ?[]const u8 = switcher.settings.system_prompt;
    var applied_output_style: []const u8 = switcher.settings.output_style;
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
    // P6-③: per-question code context block (index-backed). Swapped only
    // when the new question's block differs byte-wise — prompt-cache warm
    // while the topic holds (same philosophy as the memory re-anchor).
    var code_block: ?[]u8 = null;
    defer if (code_block) |cb| allocator.free(cb);
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
    // Project rules (ziv.md single source — global + project layers, each
    // with its own budget; generated on demand from AGENTS.md/CLAUDE.md,
    // see rules/ziv_md.zig). Loaded AFTER the manifest so the block order
    // matches what appendSystemBlock produces on hot reload.
    var rules_state = rules_mod.loadStartup(allocator, io, true);
    defer rules_mod.freeRulesState(allocator, &rules_state);
    if (rules_state.generated_path) |gp| {
        try std.Io.Writer.print(w, "  [已生成 {s} —— 整合自外来规则文件（AGENTS.md/CLAUDE.md），此后以 ziv.md 为准；/agents 查看管理]\n", .{gp});
        try std.Io.File.Writer.flush(&file_writer);
    }
    var rules_text: ?[]u8 = rules_mod.buildBlockText(allocator, &rules_state);
    defer if (rules_text) |rt| allocator.free(rt);
    var rules_fp_last = rules_mod.fingerprint(io);
    if (rules_text) |rt| {
        logger.info("rules: injected ~{d} tokens (global={s} project={s})", .{
            tokens_mod.estimateTokens(rt),
            if (rules_state.global != null) "y" else "n",
            if (rules_state.project != null) "y" else "n",
        });
    }
    const sys_block_count: usize = 1 + @as(usize, @intFromBool(memory_block != null)) + @as(usize, @intFromBool(skill_manifest != null)) + @as(usize, @intFromBool(rules_text != null));
    var sys_blocks = try allocator.alloc(llm.ContentBlock, sys_block_count);
    sys_blocks[0] = .{ .text = sys_prompt };
    var sys_i: usize = 1;
    if (memory_block) |mb| {
        sys_blocks[sys_i] = .{ .text = mb };
        sys_i += 1;
    }
    if (skill_manifest) |sm| {
        sys_blocks[sys_i] = .{ .text = sm };
        sys_i += 1;
    }
    if (rules_text) |rt| sys_blocks[sys_i] = .{ .text = rt };
    try history.append(allocator, .{
        .role = .system,
        .content = sys_blocks,
        .timestamp = util_time.nowMillis(),
    });

    // Session token tracking
    var total_input_tokens: u64 = 0;
    var total_cached_tokens: u64 = 0; // M3.1：网关前缀缓存命中累计（/stats）
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
        .history = &history, // M4 fork：只读借用（dispatch 期间主线程阻塞在此）
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
        // 子代理输出预算与主会话同源（思考型模型的思考 token 计入
        // 输出预算——见 subagent.zig response_budget 注释）。
        .response_budget = switcher.settings.max_tokens,
        // 全能力素材（write:true 用）：模式指针热切换实时生效；规则切片
        // 指向 settings（retired 不释放，生命周期安全）。auto 由 dispatch
        // 侧降级为 default（无头不做 LLM 分类审批）。
        .perm_mode = &current_mode,
        .allow_rules = switcher.settings.allow_rules,
        .deny_rules = switcher.settings.deny_rules,
        .ask_rules = switcher.settings.ask_rules,
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
        "Run 1-10 focused subagents in parallel and get their merged reports. Default is READ-ONLY (research/verification fan-out). Set 'write':true to grant FULL permissions through the user's real rules (writes/Bash allowed; anything that would ASK is still denied — headless; write dispatches run serially). Each subagent has its own context. Optional: 'tools' narrows what each subagent may use; 'fork' makes them inherit the recent conversation tail (~16K tokens); 'max_turns' caps turns (1-10).",
        "{\"type\":\"object\",\"properties\":{\"tasks\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"1-10 self-contained task descriptions\"},\"tools\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Optional tool-name whitelist for every subagent (narrows only)\"},\"fork\":{\"type\":\"boolean\",\"description\":\"Inherit the recent conversation tail (~16K tokens) instead of starting fresh\"},\"write\":{\"type\":\"boolean\",\"description\":\"Full permissions via the user's real rules (writes allowed, ask-tier denied; forces serial execution). Default false = read-only\"},\"max_turns\":{\"type\":\"integer\",\"description\":\"Per-subagent turn cap (1-10, default 10)\"}},\"required\":[\"tasks\"]}",
        agent_dispatch.executeWithCtx,
        @ptrCast(&dispatch_ctx),
        false,
    ) catch |e| logger.warning("agent tool registration failed: {}", .{e});
    // MCP 自动连接（2026-11-10）：配置了就连——不该让人再敲 /mcp connect。
    // ZIV_MCP_AUTOSTART=0 或 settings.mcp_autostart=false 关闭。失败只记
    // 日志不打断启动（网关类工具离线是常态）。握手走短预算（默认 3s，
    // ZIV_MCP_AUTOSTART_TIMEOUT_MS 可调）：这里拖住的是每次冷启动，一个
    // 挂起的 server 不配罚全体用户 20s（实测修复前 20.7s 才出提示符）。
    if (switcher.settings.mcp_autostart and env_flag_off("ZIV_MCP_AUTOSTART") == false) {
        const autostart_timeout: u32 = blk: {
            const v = env.get("ZIV_MCP_AUTOSTART_TIMEOUT_MS") orelse break :blk 3000;
            break :blk std.fmt.parseInt(u32, v, 10) catch 3000;
        };
        for (mcp_cfg.servers.items) |*entry| {
            if (!entry.enabled) continue;
            connectMcpServer(entry, &mcp_sessions, &reg, allocator, io, w, &file_writer, autostart_timeout) catch |err| {
                logger.warning("mcp autostart {s}: {}", .{ entry.name, err });
            };
        }
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
    input_history_mod.loadInputHistory(allocator, io, &input_history);

    try std.Io.Writer.writeAll(w,
        \\Type your message (or /help for commands):
        \\
    );
    try std.Io.File.Writer.flush(&file_writer);

    // P4: a message queued during generation (Enter pressed mid-stream)
    // that never hit a tool-round injection point auto-sends as the next
    // turn — the main loop consumes it instead of calling readLine.
    var auto_submit: ?[]u8 = null;

    // Ctrl+T style toggle goes live once every var it touches exists.
    style_toggle_ctx = .{
        .switcher = &switcher,
        .applied_prompt_setting = &applied_prompt_setting,
        .applied_output_style = &applied_output_style,
        .sys_prompt_owned = &sys_prompt_owned,
        .sys_prompt = &sys_prompt,
        .history = &history,
        .io = io,
    };

    while (true) {
        // Turn boundary: persist whatever the finished turn appended (one
        // transaction per turn — roadmap P3 "每轮结束原子追加").
        if (sess_store) |st| st.flush(history.items);

        // 延迟提取回收（2026-11-10）：上次会话的后台补提结果在此落库
        // （主线程 DB 写；一次一份，小步走）。
        if (mem_sys) |*ms| {
            memory_ops.collectPendingExtraction(ms, if (kgraph) |*g| g else null, &evbus, w, allocator, io);
        }

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
                reapplySystemPromptIfNeeded(&applied_prompt_setting, &applied_output_style, &sys_prompt_owned, &sys_prompt, &history, allocator, switcher.settings.system_prompt, switcher.settings.output_style);
                logger.info("settings reloaded: mode={s}", .{@tagName(current_mode)});
                try std.Io.Writer.print(w, "  [settings reloaded | mode: {s}]\n\n", .{auth.modeLabel(current_mode)});
                try std.Io.File.Writer.flush(&file_writer);
            } else |_| {}
        }

        // M6 Hooks：回合边界换装（与热重载同点——外部改 hooks 立即生效；
        // 执行线程只在回合内读，无并发换装窗口，skills gate 同款纪律）。
        hooks_mod.setConfig(.{
            .pre = switcher.settings.hooks_pre,
            .post = switcher.settings.hooks_post,
        });

        // T8: sync the plan anchor with .ziv/plan.md (fingerprint-gated;
        // also covers the very first prompt — the file may predate us).
        turn_history.refreshPlanAnchor(&history, &plan_block, &plan_raw_last, allocator, io);
        // ziv.md hot reload: mtime+size per layer (cheap; content hashing
        // buys nothing at this cadence). Same tick as the settings reload
        // and plan refresh — one prompt-boundary sweep.
        const rfp = rules_mod.fingerprint(io);
        if (!rules_mod.sameFingerprint(rfp, rules_fp_last)) {
            rules_fp_last = rfp;
            _ = reloadRulesBlock(&history, &rules_state, &rules_text, allocator, io, w, &file_writer);
        }

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
                if (memory_ops.exitExtractDeadlineMs() > 0) {
                    memory_ops.extractSessionMemoriesBounded(ms, if (kgraph) |*g| g else null, &history, &evbus, w, &file_writer, allocator, memory_ops.backgroundLlmConfig(allocator, &switcher), switcher.settings.max_tokens, memory_ops.exitExtractDeadlineMs());
                } else {
                    // 2026-11-10 默认：退出零 LLM 等待（启发式毫秒级 +
                    // 转录存档，LLM 提取下次启动后台补）。
                    memory_ops.extractSessionMemories(ms, if (kgraph) |*g| g else null, &history, &evbus, w, null, switcher.settings.max_tokens) catch {};
                    _ = memory_ops.deferSessionExtraction(allocator, io, history.items, w);
                }
                logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
            }
            if (mem_sys != null and window_queries.items.len > 0) {
                memory_ops.runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, null, .full, null, null, false); // exit: 不入库（无质量门防污染）
                // Best-effort drain: an insight that already landed in the
                // inbox is stored now; one still in flight dies with the
                // process (the heuristic reflection was stored synchronously
                // above — nothing of value blocks on a detached thread).
                memory_ops.drainReflectionInbox(allocator, if (mem_sys) |*ms| ms else null, &evbus, w);
            }
            if (sess_store) |st| {
                st.flush(history.items);
                st.markExit(true);
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
        if (!from_auto_queue) input_history_mod.saveInputHistory(allocator, &input_history);

        var ctx = dispatch_mod.ReplCtx{
        .w = w,
        .ow = ow,
        .r = r,
        .io = io,
        .file_writer = &file_writer,
        .history = &history,
        .switcher = &switcher,
        .current_mode = &current_mode,
        .log = &log,
        .fhist = &fhist,
        .rollback_engine = &rollback_engine,
        .message_count = &message_count,
        .injected_count = &injected_count,
        .evbus = &evbus,
        .mem_sys = &mem_sys,
        .kgraph = &kgraph,
        .mcp_cfg = &mcp_cfg,
        .mcp_sessions = &mcp_sessions,
        .skill_loader = &skill_loader,
        .skill_manifest = skill_manifest,
        .skill_manifest_slot = &skill_manifest,
        .rules_state = &rules_state,
        .rules_text = rules_text,
        .rules_text_slot = &rules_text,
        .rules_fp = &rules_fp_last,
        .sys_prompt = &sys_prompt,
        .sys_prompt_owned = &sys_prompt_owned,
        .applied_prompt_setting = &applied_prompt_setting,
        .applied_output_style = &applied_output_style,
        .memory_block = &memory_block,
        .facts_block = &facts_block,
        .plan_block = &plan_block,
        .plan_raw_last = &plan_raw_last,
        .total_input_tokens = &total_input_tokens,
        .total_output_tokens = &total_output_tokens,
        .total_cached_tokens = &total_cached_tokens,
        .monitor = &monitor,
        .live_llm_calls = &live_llm_calls,
        .live_llm_429s = &live_llm_429s,
        .live_est_tokens = &live_est_tokens,
        .live_trace = &live_trace,
        .reflector = &reflector,
        .reg = &reg,
        .denial_state = &denial_state,
        .window_queries = &window_queries,
        .window_tools = &window_tools,
        .sessions = sess_store,
        .window_errors = &window_errors,
        .prompt = prompt,
        };
        const dres = try dispatch_mod.dispatchSlash(&ctx, input);
        if (dres == .quit) break;
        if (dres == .handled) continue;
        if (dres == .message) {
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
            if (window_queries.items.len > 256) {
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

        // P6-③: refresh the code context block from the index for THIS
        // question. Skip the swap when byte-identical (cache); drop the
        // block when the index has nothing fresh to offer.
        {
            const nb = code_index.buildContextBlock(allocator, io, input, 8);
            if (nb) |new_text| {
                var swap_needed = true;
                if (code_block) |cb| {
                    if (std.mem.eql(u8, cb, new_text)) swap_needed = false;
                }
                if (swap_needed) {
                    if (code_block) |cb| {
                        if (turn_history.swapMemoryBlockText(&history, allocator, cb, new_text)) {
                            allocator.free(cb);
                            code_block = new_text;
                        } else if (turn_history.appendSystemBlock(&history, allocator, new_text)) {
                            allocator.free(cb);
                            code_block = new_text;
                        } else {
                            allocator.free(new_text); // keep old block
                        }
                    } else if (turn_history.appendSystemBlock(&history, allocator, new_text)) {
                        code_block = new_text;
                    } else {
                        allocator.free(new_text);
                    }
                } else {
                    allocator.free(new_text);
                }
            } else if (code_block) |cb| {
                // No fresh hits for this question — stale code context
                // misleads; remove the block entirely.
                if (turn_history.removeSystemBlockByText(&history, allocator, cb)) {
                    allocator.free(cb);
                    code_block = null;
                }
            }
        }

        // Agent loop
        var agent_iterations: usize = 0;
        // TTFT auto-retries left this turn: a gateway that accepted the
        // request but sent no first byte gets killed at the TTFT deadline
        // (provider-side) and transparently retried — "发了消息模型一直
        // 没响应" self-heals instead of idling on the 180s watchdog.
        var ttft_retries: u8 = 0;
        // P4 auto-fix ladder budget: transient-error backoff retries this
        // turn (429 / network class; TTFT has its own counter above).
        var auto_fix_retries: u8 = 0;
        // P2.5 提炼优先梯子预算：每回合最多 2 次 LLM 深压，防压缩→膨胀
        // →再压缩循环烧钱；预算尽或 LLM 不可用 → φ 截断兜底。
        var deep_compacts: u8 = 0;
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
            // P2.5 提炼优先压力梯子（2026-11-07 定纲：信息先提炼存续，
            // 截断只兜底，回合尽量不断——"任务能一直往下执行，信息能一直
            // 压缩"）。收敛性由 turn/history.zig 的滚动压缩不变量测试锁定。
            //   ≤61.8%   不动
            //   >61.8%   LLM 深压（摘要+近5轮原文+瘦身）——信息以摘要滚动存续
            //   不可用    φ 截断 + 瘦身（maybeCompact 旧路径，有损兜底）
            //   仍 >92%  收窄保留窗（keep=2）再深压；再不行 φ 硬砍
            //   仍 >92%  病态（单条消息/系统提示自身超窗）——唯一断点
            {
                const ceiling = llm.provider.contextEstimate(switcher.modelName(), switcher.backend);
                const level = turn_history.pressureLadder(est_ctx, ceiling);

                // 提炼可用性：开关开 + provider 可达 + full 档（flash/本地
                // 档不付摘要往返）+ 预算未尽 + 历史够长（hybrid 无从下刀
                // 的短史走 φ）。
                const prov_ok = switcher.getProvider() catch null;
                const deep_ok = switcher.settings.auto_deep_compact and prov_ok != null and
                    llm.provider.capabilityTier(switcher.modelName(), switcher.backend) == .full and
                    deep_compacts < 2 and history.items.len > 8;

                if (level != .ok) {
                    if (deep_ok and level == .extract) {
                        deep_compacts += 1;
                        const before_pct = est_ctx * 100 / ceiling;
                        std.Io.Writer.print(ow, "\x1b[2m  [上下文 {d}% — 自动提炼压缩（LLM 摘要 + 近5轮原文）…]\x1b[0m\n", .{before_pct}) catch {};
                        try std.Io.File.Writer.flush(&file_writer);
                        turn_history.compactHistoryKeep(&history, &switcher, &log, allocator, ow, &file_writer, &total_input_tokens, &total_output_tokens, "", turn_history.HYBRID_KEEP) catch {};
                        est_ctx = turn_history.estimateHistoryTokens(history.items);
                        if (live_trace) |*t| {
                            var tb: [96]u8 = undefined;
                            const desc = std.fmt.bufPrint(&tb, "deep ~{d}% -> ~{d}%", .{ before_pct, est_ctx * 100 / ceiling }) catch "deep compact";
                            traceAddStep(t, .context_assembly, 0.85, "context pressure", desc, "llm extraction", 0, allocator) catch {};
                        }
                    } else if (deep_ok and level == .emergency) {
                        // 收窄保留窗再提炼：keep=2 是信息保全的最后一级。
                        deep_compacts += 1;
                        const before_pct = est_ctx * 100 / ceiling;
                        std.Io.Writer.print(ow, "\x1b[2m  [上下文 {d}% — 紧急提炼（摘要 + 近2轮原文）…]\x1b[0m\n", .{before_pct}) catch {};
                        try std.Io.File.Writer.flush(&file_writer);
                        turn_history.compactHistoryKeep(&history, &switcher, &log, allocator, ow, &file_writer, &total_input_tokens, &total_output_tokens, "", 2) catch {};
                        est_ctx = turn_history.estimateHistoryTokens(history.items);
                        if (live_trace) |*t| {
                            var tb: [96]u8 = undefined;
                            const desc = std.fmt.bufPrint(&tb, "emergency keep=2 ~{d}% -> ~{d}%", .{ before_pct, est_ctx * 100 / ceiling }) catch "emergency compact";
                            traceAddStep(t, .context_assembly, 0.9, "context pressure", desc, "llm extraction (narrow)", 0, allocator) catch {};
                        }
                    }

                    // 压后目标（2026-11-08）：压完要真的小——首轮深压后仍
                    // >45% 且预算未尽，收窄保留窗再压一轮（回合内工具结果
                    // 折叠由 applyHybridLayout 统一处理）。原先 <75% 即停。
                    if (deep_compacts == 1 and level == .extract) {
                        const pct_now = @as(f64, @floatFromInt(est_ctx)) / @as(f64, @floatFromInt(ceiling));
                        const prov2 = switcher.getProvider() catch null;
                        if (pct_now > turn_history.POST_COMPACT_TARGET and prov2 != null and
                            switcher.settings.auto_deep_compact and
                            llm.provider.capabilityTier(switcher.modelName(), switcher.backend) == .full and
                            history.items.len > 8)
                        {
                            deep_compacts += 1;
                            const before_pct = est_ctx * 100 / ceiling;
                            std.Io.Writer.print(ow, "\x1b[2m  [压后仍 {d}%（目标 ≤45%）— 收窄再提炼（摘要 + 近2轮原文）…]\x1b[0m\n", .{before_pct}) catch {};
                            try std.Io.File.Writer.flush(&file_writer);
                            turn_history.compactHistoryKeep(&history, &switcher, &log, allocator, ow, &file_writer, &total_input_tokens, &total_output_tokens, "", 2) catch {};
                            est_ctx = turn_history.estimateHistoryTokens(history.items);
                        }
                    }

                    // 提炼不可用/没压够 → φ 截断 + 瘦身（有损兜底）。
                    if (turn_history.pressureLadder(est_ctx, ceiling) != .ok) {
                        const cmp_ev = turn_history.maybeCompact(&history, allocator, ow, &file_writer, &log, &facts_block, switcher.modelName(), switcher.backend);
                        est_ctx = cmp_ev.tokens;
                        if (cmp_ev.compacted) {
                            if (live_trace) |*t| {
                                var tb: [96]u8 = undefined;
                                const desc = std.fmt.bufPrint(&tb, "phi+slim ~{d} -> ~{d} tok", .{ cmp_ev.before_tokens, cmp_ev.tokens }) catch "phi+slim";
                                traceAddStep(t, .context_assembly, 0.8, "context pressure", desc, "auto-compaction", 0, allocator) catch {};
                            }
                        }
                    }

                    // 唯一断点：一切手段后仍 >92% —— 病态情形（单条消息或
                    // 系统提示自身超窗，压缩无从下手）。
                    const pct_final = @as(f64, @floatFromInt(est_ctx)) / @as(f64, @floatFromInt(ceiling));
                    if (pct_final > 0.92) {
                        const pct100: u32 = @intFromFloat(pct_final * 100.0);
                        std.Io.Writer.print(ow, "\x1b[2m  [上下文 {d}% — 提炼与截断均已用尽仍超窗（单条消息/系统提示过大？）。本回合到此为止，发送新消息继续；/clear 可立即释放]\x1b[0m\n", .{pct100}) catch {};
                        try std.Io.File.Writer.flush(&file_writer);
                        break;
                    }
                    if (!ctx_warned) {
                        ctx_warned = true;
                        std.Io.Writer.print(ow, "\x1b[2m  [上下文已压缩至 {d}% — 继续本回合]\x1b[0m\n", .{est_ctx * 100 / ceiling}) catch {};
                        try std.Io.File.Writer.flush(&file_writer);
                    }
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
                    // within the (body-scaled) TTFT budget. Nothing was
                    // shown or stored yet, so a retry is invisible-safe:
                    // re-run this generation from the same history.
                    if (ttft_retries < 2) {
                        ttft_retries += 1;
                        // 2026-11-07: back off between TTFT retries (1s/2s)
                        // — an instant retry hammers a gateway that is
                        // already struggling, and each re-send re-bills the
                        // full input.
                        const backoff_s: u32 = @intCast(ttft_retries);
                        std.Io.Writer.print(ow, "\x1b[2m  [网关 {d}s 无响应 — 退避 {d}s 后自动重试 {d}/2…]\x1b[0m\n", .{ @divTrunc(llm_watchdog.currentTtftMs(), 1000), backoff_s, ttft_retries }) catch {};
                        try std.Io.File.Writer.flush(&file_writer);
                        util_time.sleepMs(backoff_s * 1000);
                        continue;
                    }
                    lineinput.regionEnd(w);
                    // 2026-11-07: three dead first-bytes = sustained outage,
                    // not a blip — fall into the SHARED error path below
                    // (classified report + P4 selector: 换模型 is exactly
                    // what a dead gateway needs; ignore keeps the 「继续」
                    // prefill semantics).
                    try std.Io.Writer.print(ow, "\x1b[2m  [网关连续 3 次无首字节响应]\x1b[0m\n", .{});
                    try std.Io.File.Writer.flush(&file_writer);
                }
                logger.err("LLM call failed: {}", .{err});
                // Context overflow: compact once and retry instead of
                // stranding the session — every retry would otherwise send
                // the same oversized history and fail identically.
                if (err == error.ContextOverflow and !overflow_compacted) {
                    overflow_compacted = true;
                    turn_history.applyFactsUpdate(&history, &facts_block, allocator, turn_history.compactHistoryImpl(&history, allocator, facts_block));
                    // P2: a history of FEW messages with FAT tool results
                    // has nothing for φ to cut — the retry would send the
                    // same oversized payload and fail identically. Tier-3
                    // slimming is the only lever that bites there.
                    const ov_slim = turn_history.slimToolResults(history.items, allocator);
                    log.bumpEpoch();
                    if (ov_slim.slimmed > 0) {
                        std.Io.Writer.print(ow, "  [Context overflow — history auto-compacted, {d} tool outputs slimmed, retrying]\n", .{ov_slim.slimmed}) catch {};
                    } else {
                        std.Io.Writer.print(ow, "  [Context overflow — history auto-compacted, retrying]\n", .{}) catch {};
                    }
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                }
                // P4 auto-fix ladder (unified): transient errors back off
                // and retry on their own before anything user-facing.
                if (error_recovery.backoffPlan(err, switcher.settings.auto_fix, auto_fix_retries)) |plan| {
                    auto_fix_retries += 1;
                    if (err == error.RateLimit) _ = live_llm_429s.fetchAdd(1, .monotonic);
                    std.Io.Writer.print(ow, "\x1b[2m  [{s} — 退避 {d}s 后自动重试 {d}/{d}…]\x1b[0m\n", .{ plan.reason, plan.ms / 1000, auto_fix_retries, error_recovery.MAX_AUTO_RETRIES }) catch {};
                    try std.Io.File.Writer.flush(&file_writer);
                    util_time.sleepMs(plan.ms);
                    continue;
                }
                lineinput.regionEnd(w);
                if (err == error.RateLimit) _ = live_llm_429s.fetchAdd(1, .monotonic); // monitor: real-429 evidence
                try std.Io.Writer.print(ow, "  \x1b[31m[LLM error: {}]\x1b[0m\n", .{err});
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
                // P4 (design §五): the numbered suggestions above become
                // actionable — one arrow-key pick, no retyping. Esc = ignore.
                if (error_recovery.selectorEligible(err)) {
                    // 模态生命周期必须走裸 w（TUI v2）：RegionWriter 行原子缓冲会吞掉
                    // modalEnter/Exit 的无换行转义舞步（S9 开发中实证——标题被吃）。
                    if (error_recovery.offerMenu(w, r, &file_writer)) |choice| switch (choice) {
                        .retry => {
                            try std.Io.Writer.writeAll(ow, "  [重试本回合…]\n");
                            try std.Io.File.Writer.flush(&file_writer);
                            continue;
                        },
                        .compact_retry => {
                            turn_history.applyFactsUpdate(&history, &facts_block, allocator, turn_history.compactHistoryImpl(&history, allocator, facts_block));
                            _ = turn_history.slimToolResults(history.items, allocator);
                            log.bumpEpoch();
                            try std.Io.Writer.print(ow, "  [已压缩（φ+瘦身）— {d} 条消息，重试本回合…]\n", .{history.items.len});
                            try std.Io.File.Writer.flush(&file_writer);
                            continue;
                        },
                        .switch_model => {
                            try config_menu.runModelPicker(w, r, &file_writer, &switcher, io);
                            try std.Io.Writer.print(ow, "  [模型: {s} — 重试本回合…]\n", .{switcher.modelName()});
                            try std.Io.File.Writer.flush(&file_writer);
                            continue;
                        },
                        .ignore => {},
                    };
                    // ignore / Esc: prefill 「继续」 so one Enter resumes
                    // once the user has fixed the environment.
                    lineinput.recall_text = "继续";
                    lineinput.recall_prefill = true;
                }
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
                    total_cached_tokens += response.usage.cached_tokens;
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
            total_cached_tokens += response.usage.cached_tokens; // M3.1：前缀缓存命中
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
            _ = log.record("LLMResponse", input, "response", null, false, 0, "") catch {};
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
                            const n = termio.pollInput(100);
                            if (n == 1) {
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
                                    // 子代理 dispatch 进行中 → 状态行换实时
                                    // 进度（agent 2/5：#1 ✓ · #2 t4 · …），
                                    // 其余工具维持泛化状态行。
                                    var asb: [128]u8 = undefined;
                                    if (agent_dispatch.liveSummary(&asb)) |live| {
                                        lineinput.regionStatus(w, live);
                                    } else {
                                        var sb: [96]u8 = undefined;
                                        lineinput.regionStatus(w, ToolJob.statusText(turn_t0, turn_llm_calls, prepared.items.len, prepared.items[0].call.tool_name, &sb));
                                    }
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
                    // Fixed for the whole turn: the prompt every op in this
                    // batch belongs to — /rewind shows it beside each point.
                    const turn_label = turn_history.turnLabelAt(history.items, history.items.len);
                    for (prepared.items, 0..) |p, i| {
                        window_tools += 1;
                        const errored = try turn_tools.finishToolCall(p, results[i].result, allocator, &log, &result_blocks, w, ow, &file_writer, history.items.len, util_time.nowMillis() - batch_t0, turn_label);
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
                var traces_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (t.writeJsonlFile(io, zivroot.sub(&traces_buf, "traces"), allocator)) {
                    // /trace reads this path back — record it on success only.
                    var path_b: [160]u8 = undefined;
                    var tr2: [std.fs.max_path_bytes]u8 = undefined;
                    if (std.fmt.bufPrint(&path_b, "{s}/{d}.jsonl", .{ zivroot.sub(&tr2, "traces"), t.started_at })) |p| {
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

        // Skill 工具门解除（2026-11-10 C 项）：门只管 skill 生效的那一个
        // 回合——回合一结束恢复全量（下一个 /skill 重新武装）。
        skills_mod.gate.disarm();

        // T1.3: topic-drift re-anchor — checked after EVERY completed turn
        // (cheap: ≤3 hash embeddings + one cosine), fires at most once.
        if (!mem_block_rebuilt and memory_block != null) {
            if (mem_sys) |*ms| {
                if (turn_history.topicVectorOfLastUserTurns(&history, allocator)) |cur| {
                    if (mem_topic_baseline) |base| {
                        if (turn_history.shouldReanchor(base, cur)) {
                            const ctx_est = llm.provider.contextEstimate(switcher.modelName(), switcher.backend);
                            const eff_budget = injection_mod.effectiveBudget(switcher.settings.memory_budget_tokens, ctx_est);
                            var rows_arena = std.heap.ArenaAllocator.init(allocator);
                            defer rows_arena.deinit();
                            if (ms.episodic_mem.retrieveRecentArena(rows_arena.allocator(), 1000) catch null) |entries| {
                                const ents = entries;
                                if (injection_mod.buildMemoryBlockAnchored(allocator, ents, eff_budget, cur) catch null) |nb| {
                                    if (turn_history.swapMemoryBlockText(&history, allocator, memory_block.?, nb.text)) {
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
            memory_ops.runReflection(&reflector, &mem_sys.?, &window_queries, &window_tools, &window_errors, allocator, w, switcher.getProvider() catch null, llm.provider.capabilityTier(switcher.modelName(), switcher.backend), memory_ops.backgroundLlmConfig(allocator, &switcher), &evbus, true);
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
pub fn printKnowledge(kg: ?*knowledge_graph.KnowledgeGraph, w: *std.Io.Writer) !void {
    if (kg == null) {
        try std.Io.Writer.writeAll(w, "  Knowledge graph unavailable (database disabled).\n\n");
        return;
    }
    const g: *knowledge_graph.KnowledgeGraph = kg.?;
    // P5: π 图谱扫描报告（孤立节点/断边）。
    if (memory_ops.last_graph_scan) |h| {
        if (h.orphan_nodes > 0 or h.broken_edges > 0) {
            try std.Io.Writer.print(w, "  \x1b[2m[图谱扫描: {d} 孤立节点 / {d} 断边 — 提取链路自查]\x1b[0m\n", .{ h.orphan_nodes, h.broken_edges });
        } else {
            try std.Io.Writer.print(w, "  \x1b[2m[图谱扫描: 健康（{d} 节点 / {d} 边全连通）]\x1b[0m\n", .{ h.total_nodes, h.total_edges });
        }
    }
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
pub fn traceStepSummary(line: []const u8, buf: []u8) ?[]const u8 {
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
pub fn traceHeaderSummary(header: []const u8, buf: []u8) ![]const u8 {
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


pub fn findMcpSession(sessions: []*mcp_mod.session.McpSession, name: []const u8) ?*mcp_mod.session.McpSession {
    for (sessions) |sess| {
        if (std.mem.eql(u8, sess.name, name)) return sess;
    }
    return null;
}

/// Spawn + handshake + bridge one server's tools into the runtime registry.
pub fn connectMcpServer(
    entry: *mcp_mod.config.ServerEntry,
    sessions: *std.ArrayList(*mcp_mod.session.McpSession),
    reg: *runtime_registry.RuntimeRegistry,
    alloc: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    /// 0 = 默认 20s（手动 /mcp connect，人在主动等）。启动自动连接传
    /// 短预算：挂起的 server 拖住的是每一次冷启动（实测 20.7s 才出
    /// 提示符），3s 是「等一个正常 server 起来」的合理上限。
    handshake_timeout_ms: u32,
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
    if (handshake_timeout_ms > 0) cfg.handshake_timeout_ms = handshake_timeout_ms;
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
pub fn reapplySystemPromptIfNeeded(
    applied: *?[]const u8,
    applied_style: *[]const u8,
    owned: *?[]u8,
    prompt: *[]const u8,
    history: *std.ArrayList(llm.Message),
    alloc: std.mem.Allocator,
    setting: ?[]const u8,
    style: []const u8,
) void {
    // 双键对比：system_prompt 与 output_style 任一变化都要重建提示
    // （T4 坑：漏 style 键则 /style 切换不生效——开发计划风险表 #2）。
    if (sameOptSlice(applied.*, setting) and std.mem.eql(u8, applied_style.*, style)) return;
    applied.* = setting;
    applied_style.* = style;
    if (owned.*) |sp| alloc.free(sp);
    owned.* = system_prompt_mod.buildSystemPrompt(alloc, setting, style) catch null;
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

pub fn printHelp(w: *std.Io.Writer) !void {
    try std.Io.Writer.writeAll(w,
        \\Available commands:
        \\  /help, /h         Show this help
        \\  /quit, /q         Exit ziv
        \\  /version          Show version
        \\  /stats            Show session statistics and token usage
        \\  /tools            List registered tools (built-in + MCP/agent dynamic)
        \\  /run <t> <json>   Execute a tool directly
        \\  /terminal-setup   Show Shift+Enter setup guide for this terminal
        \\
        \\Model & Config:
        \\  /model, /models   Show current model and available models
        \\  /model <name>     Switch to a different model
        \\  /mode             Cycle permission mode
        \\  /config           Interactive configuration menu
        \\  /style [name]     Output style: default | concise (results-first)
        \\
        \\Conversation:
        \\  /compact          Summarize the conversation (LLM) to free tokens
        \\  /compact phi      Truncate history to the recent 61.8% (no LLM call)
        \\  /clear            Clear conversation, start fresh (alias: /reset, /new)
        \\  /resume [id]      Resume a past session (picker when no id)
        \\  /context          Show current context/token usage
        \\  /trace            Show the last turn's per-step timing
        \\  /tasks            Show the task list and progress
        \\  /bg               Background tasks panel (status/output/stop)
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
        \\  /skill new|show|remove|reload   Manage skills (reload rescans
        \\                     both roots — new packs take effect at once)
        \\  /mcp               MCP servers: list/connect/disconnect
        \\  /agents            Project rules (ziv.md): status/init/sync/reload
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
        \\Keys:
        \\  Enter 发送 · Shift+Enter / Ctrl+Enter 换行（需终端支持 kitty/
        \\  modifyOtherKeys 协议，否则用 `\`+Enter / Ctrl+J / Option+Enter）
        \\  多行/超长粘贴自动折叠为一条消息（提交时展开） · Ctrl+R 历史搜索
        \\  行编辑（提示符与回合中同样生效）：
        \\    Ctrl-A/E 行首/行尾 · Ctrl-B/F 左右移 · Ctrl-U/K 删至行首/行尾
        \\    Ctrl-W 删前一个词 · Ctrl-D 向前删 · Home/End/←→/↑↓ 历史
        \\  Esc / Ctrl-C 中断生成或撤回刚发的消息 · Ctrl-C 快速连按两次退出
        \\  Ctrl+O 工具输出 详细/简要 切换（提示符与回合中都可切）
        \\  Ctrl+T 输出风格 default/concise 互切（同 /style）
        \\
        \\Example:
        \\  /config                       Open configuration menu
        \\  /model claude-sonnet-4-6      Switch to Claude Sonnet
        \\  /compact                      Summarize the conversation (LLM)
        \\  /run Bash {"command":"ls"}
        \\
    );
}
