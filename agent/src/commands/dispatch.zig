//! Slash-command dispatcher — the /-command if/else tree carved out of
//! run()'s loop body and struct-ified (P1 ⑦): ReplCtx pointer-links the
//! run() session state (single storage, no copy drift), dispatchSlash
//! returns an outcome that drives the prompt loop. Heavy command bodies
//! live beside their domains (memory_ops / config_menu / history_cmds /
//! turn_*); this module is the routing.

const std = @import("std");
const llm = @import("../llm/mod.zig");
const auth = @import("../tools/auth_mode.zig");
const config_mod = @import("../config.zig");
const lineinput = @import("../util/lineinput.zig");
const util_time = @import("../util/time.zig");
const logger = @import("../util/log.zig");
const env = @import("../util/env.zig");
const version_mod = @import("../util/version.zig");
const fs_ops = @import("../util/fs_ops.zig");
const slash_cmds = @import("../util/slash_commands.zig");
const mcp_mod = @import("../mcp/mod.zig");
const system_prompt_mod = @import("../system_prompt.zig");
const skills_mod = @import("../skills/mod.zig");
const memory_ops = @import("../session/memory_ops.zig");
const config_menu = @import("config_menu.zig");
const history_cmds = @import("history_cmds.zig");
const turn_ask = @import("../turn/ask.zig");
const turn_history = @import("../turn/history.zig");
const session_store_mod = @import("../session/session_store.zig");
const menu = @import("../util/menu.zig");
const turn_tools = @import("../turn/tools.zig");
const registry = @import("../tools/registry.zig");
const op_log = @import("../checkpoint/op_log.zig");
const file_history = @import("../checkpoint/file_history.zig");
const turn_clock = @import("../util/turn_clock.zig");
const rollback_mod = @import("../checkpoint/rollback.zig");
const task_store = @import("../tools/task_store.zig");
const task_mod = @import("../task/mod.zig");
const memory_mod = @import("../memory/mod.zig");
const decision_trace = @import("../runtime/decision_trace.zig");
const runtime_registry = @import("../tools/runtime_registry.zig");
const knowledge_graph = @import("../knowledge/graph.zig");
const reflection_mod = @import("../memory/reflection.zig");
const denial_tracker_mod = @import("../tools/denial_tracker.zig");
const repl_mod = @import("../repl.zig");
const ModelSwitcher = repl_mod.ModelSwitcher;
const allocator = std.heap.smp_allocator; // same stateless global as repl.zig

/// One slash-command dispatch — carved out of run()'s loop body (P1 ⑦).
/// Outcome drives the loop: .handled re-prompts, .quit ends the session,
/// .message/.skill fall through to the agent turn (skill = its body is
/// already appended as the user message).
pub const DispatchOutcome = enum { message, skill, handled, quit };

/// REPL session state shared by the prompt loop and the dispatcher — the
/// run() setup both touch, pointer-linked to run's locals so each value
/// has exactly one storage (no copy drift). Built fresh each prompt.
pub const ReplCtx = struct {
    w: *std.Io.Writer,
    ow: *std.Io.Writer,
    r: *std.Io.Reader,
    io: std.Io,
    file_writer: *std.Io.File.Writer,
    history: *std.ArrayList(llm.Message),
    switcher: *ModelSwitcher,
    current_mode: *auth.PermissionMode,
    log: *op_log.OperationLog,
    fhist: *file_history.FileHistoryState,
    rollback_engine: *rollback_mod.RollbackEngine,
    message_count: *usize,
    injected_count: *usize,
    evbus: *task_mod.EventBus,
    mem_sys: *?memory_mod.MemorySystem,
    kgraph: *?knowledge_graph.KnowledgeGraph,
    mcp_cfg: *mcp_mod.config.McpConfig,
    mcp_sessions: *std.ArrayList(*mcp_mod.session.McpSession),
    skill_loader: *skills_mod.loader.SkillLoader,
    skill_manifest: ?[]u8,
    sys_prompt: *[]const u8,
    sys_prompt_owned: *?[]u8,
    applied_prompt_setting: *?[]const u8,
    memory_block: *?[]u8,
    facts_block: *?[]u8,
    plan_block: *?[]u8,
    plan_raw_last: *?[]u8,
    total_input_tokens: *u64,
    total_output_tokens: *u64,
    live_trace: *?decision_trace.DecisionTrace,
    reflector: *reflection_mod.ReflectionEngine,
    reg: *runtime_registry.RuntimeRegistry,
    denial_state: *denial_tracker_mod.DenialTracker,
    window_queries: *std.ArrayList([]u8),
    window_tools: *u32,
    sessions: ?*session_store_mod.SessionStore,
    window_errors: *u32,
    prompt: []const u8,
};

pub fn dispatchSlash(ctx: *ReplCtx, input: []const u8) !DispatchOutcome {
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
            if (ctx.mem_sys.*) |*ms| {
                const ext_t0 = util_time.nowMillis();
                memory_ops.extractSessionMemories(ms, if (ctx.kgraph.*) |*g| g else null, ctx.history, ctx.evbus, ctx.w, ctx.switcher.getProvider() catch null, ctx.switcher.settings.max_tokens) catch {};
                logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
            }
            if (ctx.mem_sys.* != null and ctx.window_queries.items.len > 0) {
                memory_ops.runReflection(ctx.reflector, &ctx.mem_sys.*.?, ctx.window_queries, ctx.window_tools, ctx.window_errors, allocator, ctx.w, null, .full, null, null); // exit path: heuristic-only, no background dispatch
                // Best-effort drain: an insight that already landed in the
                // inbox is stored now; one still in flight dies with the
                // process (the heuristic reflection was stored synchronously
                // above — nothing of value blocks on a detached thread).
                memory_ops.drainReflectionInbox(allocator, if (ctx.mem_sys.*) |*ms| ms else null, ctx.evbus, ctx.w);
            }
            // Visibility: queued-but-unsent messages die with the
            // session — say so instead of dropping silently.
            if (lineinput.queuedHas()) {
                try std.Io.Writer.print(ctx.w, "\x1b[2m  [{d} 条排队消息未发送，已丢弃]\x1b[0m\n", .{lineinput.queuedCount()});
            }
            if (ctx.sessions) |st| {
                st.flush(ctx.history.items);
                st.markExit(true);
            }
            try std.Io.Writer.writeAll(ctx.w, "Goodbye!\n");
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .quit;
        } else if (std.mem.eql(u8, input, "/help") or std.mem.eql(u8, input, "/h")) {
            try repl_mod.printHelp(ctx.w);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.startsWith(u8, input, "/mcp")) {
            const rest_mcp = std.mem.trim(u8, input[4..], " \t");
            if (rest_mcp.len == 0 or std.mem.eql(u8, rest_mcp, "list")) {
                if (ctx.mcp_cfg.servers.items.len == 0) {
                    try std.Io.Writer.writeAll(ctx.w, "  No MCP servers configured. /mcp install <name> | /mcp add <name> <command>\n\n");
                } else {
                    try std.Io.Writer.writeAll(ctx.w, "  MCP servers:\n");
                    for (ctx.mcp_cfg.servers.items) |srv| {
                        const sess = repl_mod.findMcpSession(ctx.mcp_sessions.items, srv.name);
                        const state = if (sess) |ss| (if (ss.connected) "connected" else "down") else "off";
                        try std.Io.Writer.print(ctx.w, "    {s} [{s}] — {s}\n", .{ srv.name, state, if (srv.url) |u| u else srv.command });
                    }
                    try std.Io.Writer.writeAll(ctx.w, "\n");
                }
            } else if (std.mem.startsWith(u8, rest_mcp, "install ")) {
                const want = std.mem.trim(u8, rest_mcp[8..], " \t");
                var found = false;
                for (mcp_mod.config.McpConfig.known_servers) |ks| {
                    if (std.mem.eql(u8, ks.name, want)) {
                        try ctx.mcp_cfg.upsert(ks.name, ks.command);
                        try std.Io.Writer.print(ctx.w, "  Installed {s} -> {s}\n  Connect with: /mcp connect {s}\n\n", .{ ks.name, ks.command, ks.name });
                        found = true;
                        break;
                    }
                }
                if (!found) try std.Io.Writer.print(ctx.w, "  Unknown package '{s}'. Known: playwright, filesystem, memory, fetch, sequential-thinking\n\n", .{want});
            } else if (std.mem.startsWith(u8, rest_mcp, "add ")) {
                const args_str = std.mem.trim(u8, rest_mcp[4..], " \t");
                const sp = std.mem.indexOfScalar(u8, args_str, ' ') orelse {
                    try std.Io.Writer.writeAll(ctx.w, "  Usage: /mcp add <name> <command...>\n\n");
                    try std.Io.File.Writer.flush(ctx.file_writer);
                    return .handled;
                };
                const val = std.mem.trim(u8, args_str[sp + 1 ..], " \t");
                if (std.mem.startsWith(u8, val, "http://") or std.mem.startsWith(u8, val, "https://")) {
                    try ctx.mcp_cfg.upsertUrl(args_str[0..sp], val);
                } else {
                    try ctx.mcp_cfg.upsert(args_str[0..sp], val);
                }
                try std.Io.Writer.print(ctx.w, "  Added. Connect with: /mcp connect {s}\n\n", .{args_str[0..sp]});
            } else if (std.mem.startsWith(u8, rest_mcp, "remove ")) {
                const want = std.mem.trim(u8, rest_mcp[7..], " \t");
                if (repl_mod.findMcpSession(ctx.mcp_sessions.items, want)) |sess| {
                    mcp_mod.session.unbridgeSessionTools(sess, ctx.reg);
                    sess.disconnect(ctx.io);
                }
                if (ctx.mcp_cfg.remove(want)) {
                    try std.Io.Writer.print(ctx.w, "  Removed {s}\n\n", .{want});
                } else {
                    try std.Io.Writer.print(ctx.w, "  No such server: {s}\n\n", .{want});
                }
            } else if (std.mem.startsWith(u8, rest_mcp, "connect ")) {
                const want = std.mem.trim(u8, rest_mcp[8..], " \t");
                const entry = ctx.mcp_cfg.find(want) orelse {
                    try std.Io.Writer.print(ctx.w, "  No such server: {s} (see /mcp list)\n\n", .{want});
                    try std.Io.File.Writer.flush(ctx.file_writer);
                    return .handled;
                };
                try repl_mod.connectMcpServer(entry, ctx.mcp_sessions, ctx.reg, allocator, ctx.io, ctx.w, ctx.file_writer);
            } else if (std.mem.startsWith(u8, rest_mcp, "disconnect ")) {
                const want = std.mem.trim(u8, rest_mcp[11..], " \t");
                if (repl_mod.findMcpSession(ctx.mcp_sessions.items, want)) |sess| {
                    mcp_mod.session.unbridgeSessionTools(sess, ctx.reg);
                    sess.disconnect(ctx.io);
                    try std.Io.Writer.print(ctx.w, "  {s} disconnected\n\n", .{want});
                } else {
                    try std.Io.Writer.print(ctx.w, "  {s} was not connected\n\n", .{want});
                }
            } else {
                try std.Io.Writer.writeAll(ctx.w, "  Usage: /mcp [list|install|add|remove|connect|disconnect] ...\n\n");
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/skills")) {
            if (ctx.skill_loader.skills.items.len == 0) {
                try std.Io.Writer.writeAll(ctx.w, "  No skills found. Add SKILL.md packs under ~/.config/ziv/skills/<name>/ or .ziv/skills/<name>/\n\n");
            } else {
                try std.Io.Writer.writeAll(ctx.w, "  Skills (invoke with /<name>):\n");
                for (ctx.skill_loader.skills.items) |skill| {
                    try std.Io.Writer.print(ctx.w, "    /{s} — {s} [{s}]\n", .{ skill.name, skill.description, @tagName(skill.source) });
                }
                try std.Io.Writer.writeAll(ctx.w, "\n");
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/tools")) {
            try std.Io.Writer.writeAll(ctx.w, "Registered tools:\n");
            for (ctx.reg.definitions()) |tool| {
                const safety = if (tool.is_concurrency_safe_fn != null) "safe" else "serial";
                try std.Io.Writer.print(ctx.w, "  {s} - {s} [{s}|{s}]\n", .{
                    tool.name,
                    tool.description,
                    if (tool.is_read_only) "read" else "write",
                    safety,
                });
            }
            try std.Io.Writer.print(ctx.w, "\n  Total: {d} tools\n\n", .{ctx.reg.count()});
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.startsWith(u8, input, "/run ")) {
            const rest = input[5..];
            const space_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse {
                try std.Io.Writer.writeAll(ctx.w, "Usage: /run <ToolName> <json-input>\n\n");
                try std.Io.File.Writer.flush(ctx.file_writer);
                return .handled;
            };
            const tool_name = rest[0..space_idx];
            const json_str = rest[space_idx + 1 ..];

            // Per-command arena: the DOM (and every string the tool
            // pulled out of it) dies at the end of the /run arm.
            var run_arena = std.heap.ArenaAllocator.init(allocator);
            defer run_arena.deinit();
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, run_arena.allocator(), json_str, .{}) catch {
                try std.Io.Writer.writeAll(ctx.w, "Invalid JSON input\n\n");
                try std.Io.File.Writer.flush(ctx.file_writer);
                return .handled;
            };

            try std.Io.Writer.print(ctx.w, "  Running {s}...\n", .{tool_name});
            try std.Io.File.Writer.flush(ctx.file_writer);
            logger.info("Tool /run: {s}", .{tool_name});

            // Permission gate — /run goes through the same pipeline as
            // agent-loop tool calls (previously it bypassed the mode
            // entirely, letting Plan mode perform writes).
            const run_tool = ctx.reg.findByName(tool_name) orelse {
                try std.Io.Writer.print(ctx.w, "  Unknown tool: {s}\n\n", .{tool_name});
                try std.Io.File.Writer.flush(ctx.file_writer);
                return .handled;
            };
            if (!try turn_ask.permissionGate(run_tool, parsed, ctx.current_mode.*, ctx.switcher, allocator, ctx.r, ctx.w, ctx.ow, ctx.file_writer, ctx.denial_state)) return .handled;

            // Backup file before modification (for /run commands)
            var run_snap_id: ?[16]u8 = null;
            if (turn_tools.isFileModifyingTool(tool_name)) {
                if (registry.getStringField(parsed, "path")) |fp| {
                    var sid: [16]u8 = undefined;
                    const ts = util_time.nowMillis();
                    for (&sid, 0..) |*byte, i| {
                        byte.* = @truncate(@as(u64, @bitCast(ts)) +% @as(u64, i) *% 0x9e3779b97f4a7c15);
                    }
                    if (ctx.switcher.settings.checkpointing_enabled) {
                        ctx.fhist.trackEdit(fp, sid, ctx.io) catch {};
                        run_snap_id = sid;
                    }
                }
            }

            const result = run_tool.execute(allocator, parsed, ctx.io) catch |err| {
                logger.err("Tool /run failed: {s} error={}", .{ tool_name, err });
                try std.Io.Writer.print(ctx.w, "  Tool error: {}\n\n", .{err});
                _ = ctx.log.record(tool_name, "execution", "error", run_snap_id, false, ctx.history.items.len) catch {};
                try std.Io.File.Writer.flush(ctx.file_writer);
                return .handled;
            };

            // Same /last ring as agent-loop calls (finishToolCall) —
            // the expansion valve must cover manual /run too.
            turn_tools.LastTools.push(tool_name, result.output);

            if (result.is_error) {
                try std.Io.Writer.print(ctx.w, "  ERROR: {s}\n\n", .{result.output});
            } else {
                try std.Io.Writer.print(ctx.w, "  {s}\n\n", .{result.output});
            }
            _ = ctx.log.record(tool_name, "executed", result.output, run_snap_id, run_snap_id != null, ctx.history.items.len) catch {};
            allocator.free(result.output);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/mode")) {
            // Cycle permission mode
            ctx.current_mode.* = auth.nextMode(ctx.current_mode.*);
            // Persist the mode choice — it was runtime-only before, so
            // every restart silently fell back to the configured mode.
            ctx.switcher.settings.permission_mode = ctx.current_mode.*;
            config_mod.saveSettings(&ctx.switcher.settings, allocator, ctx.io) catch {};
            repl_mod.settings_fp_baseline = config_mod.settingsFingerprint(allocator, ctx.io);
            try std.Io.Writer.print(ctx.w, "  Permission mode: {s} (已保存)\n\n", .{auth.modeLabel(ctx.current_mode.*)});
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/model") or std.mem.eql(u8, input, "/models")) {
            // Interactive model picker (arrow keys + Enter); q shows the
            // plain text listing instead.
            try config_menu.runModelPicker(ctx.w, ctx.r, ctx.file_writer, ctx.switcher, ctx.io);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.startsWith(u8, input, "/model ")) {
            // Switch model: /model <name>
            const new_model = input[7..];
            ctx.switcher.switchModel(new_model) catch |err| {
                if (err == error.MissingApiKey) {
                    // Report the backend that VALIDATED the key
                    // (effectiveBackend honors default_backend) — the
                    // name-prefix detector could point at Ollama
                    // (keyless) while the gateway backend rejected us.
                    try std.Io.Writer.print(ctx.w, "  Error: API key not configured for {s} backend.\n", .{ctx.switcher.effectiveBackend(new_model).label()});
                    try std.Io.Writer.writeAll(ctx.w, "  Use /config to set API keys, or add to ~/.config/ziv/settings.json.\n\n");
                } else {
                    try std.Io.Writer.print(ctx.w, "  Error switching model: {}\n\n", .{err});
                }
                try std.Io.File.Writer.flush(ctx.file_writer);
                return .handled;
            };
            try std.Io.Writer.print(ctx.w, "  Switched to {s} ({s})\n\n", .{ ctx.switcher.modelName(), ctx.switcher.backendLabel() });
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/config")) {
            try config_menu.runConfigMenu(ctx.w, ctx.r, ctx.file_writer, ctx.switcher, allocator, ctx.io);
            // The live permission gate reads `current_mode`, which the
            // menu never touched — without this resync a mode picked in
            // /config never reached the gate until restart.
            ctx.current_mode.* = ctx.switcher.settings.permission_mode;
            // A changed system prompt must reach the baked history[0]
            // this session, not after the next restart.
            repl_mod.reapplySystemPromptIfNeeded(ctx.applied_prompt_setting, ctx.sys_prompt_owned, ctx.sys_prompt, ctx.history, allocator, ctx.switcher.settings.system_prompt);
            return .handled;
        } else if (std.mem.eql(u8, input, "/compact") or std.mem.startsWith(u8, input, "/compact ")) {
            // Claude-style: LLM summarizes the OLDER conversation; the
            // summary replaces it and the most recent messages are kept
            // verbatim (v0.7.7 — the old version summarized everything,
            // including what you just said). Optional free text after
            // the command steers the summary:
            //   /compact 重点保留数据库迁移的决策
            const focus = std.mem.trim(u8, input["/compact".len..], " \t");
            if (std.mem.eql(u8, focus, "phi")) return .handled; // handled below
            try turn_history.compactHistory(ctx.history, ctx.switcher, ctx.log, allocator, ctx.w, ctx.file_writer, ctx.total_input_tokens, ctx.total_output_tokens, focus);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/compact phi")) {
            // Original φ truncation strategy, kept as an explicit option
            // (also what auto-compaction runs).
            try turn_history.compactHistoryPhi(ctx.history, allocator, ctx.w, ctx.log, ctx.facts_block);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/clear") or std.mem.eql(u8, input, "/reset") or std.mem.eql(u8, input, "/new")) {
            // P3: /clear starts a FRESH session row — the old conversation
            // stays resumable instead of being overwritten by the new one.
            if (ctx.sessions) |st| st.rotate(".", ctx.switcher.modelName(), ctx.current_mode.*);
            // Reflect BEFORE the window is orphaned: /quit and Ctrl-D
            // both reflect first; /clear used to skip it, leaking the
            // cleared conversation's queries into the next one's
            // reflection window.
            // Extract memories FIRST (valuable, durable, ms) — reflection
            // is best-effort behind it; killing the window mid-exit
            // used to lose the whole session's learnings.
            if (ctx.mem_sys.*) |*ms| {
                const ext_t0 = util_time.nowMillis();
                memory_ops.extractSessionMemories(ms, if (ctx.kgraph.*) |*g| g else null, ctx.history, ctx.evbus, ctx.w, ctx.switcher.getProvider() catch null, ctx.switcher.settings.max_tokens) catch {};
                logger.info("session extraction: {d}ms", .{util_time.nowMillis() - ext_t0});
            }
            if (ctx.mem_sys.* != null and ctx.window_queries.items.len > 0) {
                memory_ops.runReflection(ctx.reflector, &ctx.mem_sys.*.?, ctx.window_queries, ctx.window_tools, ctx.window_errors, allocator, ctx.w, null, .full, null, null); // exit path: heuristic-only, no background dispatch
                // Best-effort drain: an insight that already landed in the
                // inbox is stored now; one still in flight dies with the
                // process (the heuristic reflection was stored synchronously
                // above — nothing of value blocks on a detached thread).
                memory_ops.drainReflectionInbox(allocator, if (ctx.mem_sys.*) |*ms| ms else null, ctx.evbus, ctx.w);
            }
            turn_history.clearHistory(ctx.history, allocator);
            ctx.log.bumpEpoch();
            // Drop the stale memory-injection block from the surviving
            // system message so the fresh conversation isn't primed
            // with the cleared one's memories.
            if (ctx.memory_block.*) |mb| {
                allocator.free(mb);
                // Rebuild the prompt so the embedded date/time is fresh —
                // a session crossing midnight must not keep answering
                // date questions with yesterday. (defer frees whatever
                // sys_prompt_owned holds at scope exit, so swapping here
                // stays single-ownership.)
                if (ctx.sys_prompt_owned.*) |sp| allocator.free(sp);
                ctx.sys_prompt_owned.* = system_prompt_mod.buildSystemPrompt(allocator, ctx.switcher.settings.system_prompt) catch null;
                ctx.sys_prompt.* = ctx.sys_prompt_owned.* orelse system_prompt_mod.default_system_prompt;
                const fresh_count: usize = 1 + @as(usize, @intFromBool(ctx.skill_manifest != null));
                const fresh_blocks = try allocator.alloc(llm.ContentBlock, fresh_count);
                fresh_blocks[0] = .{ .text = ctx.sys_prompt.* };
                // The skill manifest must survive /clear — rebuilding a
                // single-block message dropped it, leaving the model
                // blind to every /<skill> until restart (the manifest
                // string stays owned by the outer defer).
                if (ctx.skill_manifest) |sm| fresh_blocks[1] = .{ .text = sm };
                allocator.free(ctx.history.items[0].content);
                ctx.history.items[0].content = fresh_blocks;
                ctx.memory_block.* = null; // the end-of-session defer must not double-free
                ctx.injected_count.* = 0;
            }
            ctx.message_count.* = 0;
            ctx.total_input_tokens.* = 0;
            ctx.total_output_tokens.* = 0;
            _ = ctx.log.record("ClearHistory", "/", "/", null, false, 0) catch {};
            try std.Io.Writer.writeAll(ctx.w, "  Conversation cleared. Starting fresh.\n\n");
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/context")) {
            try history_cmds.showContext(ctx.history, ctx.total_input_tokens.*, ctx.total_output_tokens.*, ctx.w);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/trace")) {
            // P2: per-step timing of the last turn, read straight from
            // the .ziv/traces/*.jsonl the turn-end telemetry wrote —
            // the data has existed since 2026-11-05, this is its
            // in-TUI window.
            if (turn_clock.tracePath().len == 0) {
                try std.Io.Writer.print(ctx.w, "  本会话尚无 trace（任一回合结束后生成；ZIV_TRACE=0 可关闭落盘）\n\n", .{});
            } else {
                const tpath = turn_clock.tracePath();
                var fbuf: [131072]u8 = undefined;
                if (std.Io.Dir.cwd().readFile(ctx.io, tpath, &fbuf)) |data| {
                    var lines_it = std.mem.splitScalar(u8, data, '\n');
                    const header = lines_it.next() orelse "";
                    var qb: [96]u8 = undefined;
                    const qtxt = repl_mod.traceHeaderSummary(header, &qb) catch "（表头解析失败）";
                    try std.Io.Writer.print(ctx.w, "  ⏱ 上一回合 {s}\n", .{qtxt});
                    var step_no: usize = 0;
                    while (lines_it.next()) |ln| {
                        if (ln.len == 0) continue;
                        step_no += 1;
                        if (step_no > 80) break;
                        var sb: [96]u8 = undefined;
                        if (repl_mod.traceStepSummary(ln, &sb)) |s| {
                            try std.Io.Writer.print(ctx.w, "    {d:>3}. {s}\n", .{ step_no, s });
                        }
                    }
                    if (step_no > 80) try std.Io.Writer.print(ctx.w, "    …（超 80 步截断；全量见文件）\n", .{});
                    try std.Io.Writer.print(ctx.w, "  文件: {s}\n\n", .{tpath});
                } else |_| {
                    try std.Io.Writer.print(ctx.w, "  读取 trace 失败（文件可能已被移动）: {s}\n\n", .{tpath});
                }
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/tasks")) {
            // ②: the task system (TaskCreate/TaskUpdate) had a full
            // store + render() but no TUI surface at all.
            const ts = task_store.global();
            if (ts.count() == 0) {
                try std.Io.Writer.print(ctx.w, "  任务列表为空（模型用 TaskCreate 建任务后在此查看进度）\n\n", .{});
            } else {
                const rendered = ts.render(allocator) catch {
                    try std.Io.Writer.print(ctx.w, "  任务列表渲染失败\n\n", .{});
                    try std.Io.File.Writer.flush(ctx.file_writer);
                    return .handled;
                };
                defer allocator.free(rendered);
                try std.Io.Writer.print(ctx.w, "{s}\n", .{rendered});
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
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
                try std.Io.Writer.print(ctx.w, "  ── {s}（最近第 {d} 条，{d} 字节）──\n", .{ e.name, n, e.output.len });
                var at_ls = false;
                try memory_ops.writeMarginLines(ctx.w, e.output, "  ", &at_ls);
                if (!at_ls) try std.Io.Writer.writeAll(ctx.w, "\n");
                try std.Io.Writer.writeAll(ctx.w, "\n");
            } else {
                try std.Io.Writer.print(ctx.w, "  无记录（/last=最近一条，/last N=第 N 近，最多保留 {d} 条）\n\n", .{turn_tools.LastTools.N});
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/memory")) {
            try memory_ops.printMemoryStatus(if (ctx.mem_sys.*) |*ms| ms else null, ctx.injected_count.*, ctx.w);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.startsWith(u8, input, "/research ")) {
            const topic = std.mem.trim(u8, input["/research ".len..], " \t");
            if (topic.len == 0) {
                try std.Io.Writer.writeAll(ctx.w, "  Usage: /research <topic>\n\n");
            } else {
                try memory_ops.runResearch(topic, allocator, ctx.io, ctx.w, ctx.switcher.settings.api_keys.brave_api_key, if (ctx.mem_sys.*) |*ms| ms else null, if (ctx.kgraph.*) |*g| g else null);
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/knowledge")) {
            try repl_mod.printKnowledge(if (ctx.kgraph.*) |*g| g else null, ctx.w);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.startsWith(u8, input, "/diagnose")) {
            const rest = if (input.len > "/diagnose".len) input["/diagnose".len..] else "";
            const concern = std.mem.trim(u8, rest, " \t");
            if (concern.len == 0) {
                try std.Io.Writer.writeAll(ctx.w, "  Usage: /diagnose <your concern about the last answer>\n\n");
            } else {
                try memory_ops.runDiagnose(if (ctx.live_trace.*) |*t| t else null, concern, ctx.injected_count.*, ctx.window_tools.*, ctx.window_errors.*, if (ctx.mem_sys.*) |*ms| ms else null, allocator, ctx.w);
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/undo")) {
            // Only invalidate older rewind points when something was
            // actually removed — a no-op undo must not rewrite history.
            if (try history_cmds.undoLastExchange(ctx.history, allocator, ctx.w) > 0) {
                ctx.log.bumpEpoch();
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/history")) {
            if (ctx.log.records.items.len == 0) {
                try std.Io.Writer.writeAll(ctx.w, "  No operations recorded yet.\n\n");
            } else {
                try std.Io.Writer.print(ctx.w, "  Operation history ({d} operations):\n", .{ctx.log.records.items.len});
                for (ctx.log.records.items, 0..) |rec, i| {
                    try std.Io.Writer.print(ctx.w, "    [{d}] {s}\n", .{ i + 1, rec.tool_name });
                }
                try std.Io.Writer.writeAll(ctx.w, "\n");
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/rewind")) {
            try history_cmds.rewindOperation(ctx.rollback_engine, ctx.history, ctx.w, ctx.r, ctx.file_writer, allocator, ctx.io);
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/plan") or std.mem.startsWith(u8, input, "/plan ")) {
            const plan_arg = std.mem.trim(u8, input[5..], " \t");
            if (std.mem.eql(u8, plan_arg, "off")) {
                std.Io.Dir.cwd().deleteFile(ctx.io, ".ziv/plan.md") catch {};
                turn_history.refreshPlanAnchor(ctx.history, ctx.plan_block, ctx.plan_raw_last, allocator, ctx.io);
                try std.Io.Writer.writeAll(ctx.w, "  计划已停用（.ziv/plan.md 已删除，system 锚点已移除）\n\n");
            } else if (plan_arg.len == 0) {
                if (ctx.plan_raw_last.*) |pr| {
                    try std.Io.Writer.print(ctx.w, "  当前计划（.ziv/plan.md）：\n{s}\n\n", .{pr});
                } else {
                    try std.Io.Writer.writeAll(ctx.w, "  当前无计划。用法：/plan <目标> 创建 ｜ /plan off 停用\n\n");
                }
            } else {
                std.Io.Dir.cwd().createDirPath(ctx.io, ".ziv") catch {};
                var tp: [4096]u8 = undefined;
                const template = std.fmt.bufPrint(&tp, "# 计划：{s}\n\n- [ ] （补充步骤；勾选为 [x] 后，system 注入的摘要自动更新）\n", .{plan_arg}) catch "";
                if (template.len > 0) {
                    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ".ziv/plan.md", .data = template }) catch {
                        try std.Io.Writer.writeAll(ctx.w, "  写入 .ziv/plan.md 失败\n\n");
                        try std.Io.File.Writer.flush(ctx.file_writer);
                        return .handled;
                    };
                    turn_history.refreshPlanAnchor(ctx.history, ctx.plan_block, ctx.plan_raw_last, allocator, ctx.io);
                    try std.Io.Writer.writeAll(ctx.w, "  计划已创建并锚定到 system prompt（每轮自动同步勾选进度）\n\n");
                }
            }
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/stats")) {
            const est_tokens = turn_history.estimateHistoryTokens(ctx.history.items);
            try std.Io.Writer.print(ctx.w, "  Messages: {d} | History tokens: ~{d} | Operations: {d}\n", .{
                ctx.message_count.*,
                est_tokens,
                ctx.log.records.items.len,
            });
            try std.Io.Writer.print(ctx.w, "  Mode: {s} | Model: {s} ({s}) | Tier: {s}\n", .{
                auth.modeLabel(ctx.current_mode.*),
                ctx.switcher.modelName(),
                ctx.switcher.backendLabel(),
                @tagName(llm.provider.capabilityTier(ctx.switcher.modelName(), ctx.switcher.backend)),
            });
            try std.Io.Writer.print(ctx.w, "  Total: {d} in / {d} out tokens\n\n", .{
                ctx.total_input_tokens.*,
                ctx.total_output_tokens.*,
            });
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/terminal-setup")) {
            // Claude-Code-style Shift+Enter enabler: ziv understands the
            // sequences; this tells the TERMINAL to actually send one.
            const term = env.get("TERM_PROGRAM") orelse "";
            try std.Io.Writer.writeAll(ctx.w,
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
                try std.Io.Writer.writeAll(ctx.w,
                    \\
                    \\  ─ VS Code 集成终端 ────────────────────────────
                    \\    Settings → Keyboard Shortcuts → Terminal: Run Recent Command?
                    \\    简单做法：keybindings.json 加一条
                    \\      { "key": "shift+enter", "command": "workbench.action.terminal.sendSequence",
                    \\        "args": { "text": "\n" }, "when": "terminalFocus" }
                    \\
                );
            } else if (std.mem.eql(u8, term, "iTerm.app")) {
                try std.Io.Writer.writeAll(ctx.w,
                    \\
                    \\  ─ iTerm2 ──────────────────────────────────────
                    \\    Settings → Profiles → Keys → Key Mappings → +:
                    \\      Shortcut: Shift+Enter  Action: Send Escape Sequence
                    \\      Esc+ 输入: \r    （ziv 识别 ESC+CR 为换行）
                    \\
                );
            } else if (std.mem.eql(u8, term, "WezTerm")) {
                try std.Io.Writer.writeAll(ctx.w,
                    \\
                    \\  ─ WezTerm ─────────────────────────────────────
                    \\    wezterm.lua:
                    \\      keys = { { key="Enter", mods="SHIFT", action=wezterm.action{SendString="\n"} } }
                    \\
                );
            } else {
                try std.Io.Writer.writeAll(ctx.w,
                    \\
                    \\  ─ 其他终端（含 Apple Terminal）─────────────────
                    \\    Apple Terminal 不支持 kitty 协议，也不支持单键改映射，
                    \\    推荐用 `\`+Enter 或 Ctrl+J。
                    \\
                );
            }
            try std.Io.Writer.writeAll(ctx.w, "\n");
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/resume") or std.mem.startsWith(u8, input, "/resume ")) {
            const st = ctx.sessions orelse {
                try std.Io.Writer.writeAll(ctx.w, "  Session store unavailable (.ziv/sessions.db not writable).\n\n");
                try std.Io.File.Writer.flush(ctx.file_writer);
                return .handled;
            };
            var pick: ?i64 = null;
            const arg = std.mem.trim(u8, input["/resume".len..], " \t");
            if (arg.len > 0) {
                pick = std.fmt.parseInt(i64, arg, 10) catch null;
                if (pick == null) {
                    try std.Io.Writer.writeAll(ctx.w, "  Usage: /resume [会话编号]\n\n");
                    try std.Io.File.Writer.flush(ctx.file_writer);
                    return .handled;
                }
            }
            const list = session_store_mod.listRecent(allocator, &st.db, 8) catch &[_]session_store_mod.SessionInfo{};
            {
                defer for (list) |*s2| session_store_mod.freeInfo(allocator, s2.*);
                if (pick == null) {
                    if (list.len == 0) {
                        try std.Io.Writer.writeAll(ctx.w, "  还没有可恢复的会话。\n\n");
                        try std.Io.File.Writer.flush(ctx.file_writer);
                        return .handled;
                    }
                    var labels: std.ArrayList([]const u8) = .empty;
                    defer labels.deinit(allocator);
                    for (list) |s2| {
                        const when = util_time.formatIso(allocator, s2.started_at) catch " ?";
                        const line = std.fmt.allocPrint(allocator, "#{d} · {s} · {d} 轮 · {s}{s}", .{
                            s2.id,
                            when,
                            s2.rounds,
                            s2.first_line orelse "(无消息)",
                            if (s2.ended_at == null) " · 未正常退出" else "",
                        }) catch continue;
                        allocator.free(when);
                        labels.append(allocator, line) catch allocator.free(line);
                    }
                    const sel = (menu.select(ctx.w, ctx.r, ctx.file_writer, "恢复会话（当前对话将被替换；q 取消）:", labels.items, 0) catch null) orelse {
                        for (labels.items) |l| allocator.free(@constCast(l));
                        return .handled;
                    };
                    for (labels.items) |l| allocator.free(@constCast(l));
                    pick = list[sel].id;
                }
            }
            const id = pick.?;
            const meta = session_store_mod.metaOf(allocator, &st.db, id) catch {
                try std.Io.Writer.print(ctx.w, "  会话 #{d} 不存在。/resume 查看列表。\n\n", .{id});
                try std.Io.File.Writer.flush(ctx.file_writer);
                return .handled;
            };
            defer {
                allocator.free(meta.model);
                allocator.free(meta.permission_mode);
            }
            const msgs = session_store_mod.loadMessages(allocator, &st.db, id) catch {
                try std.Io.Writer.writeAll(ctx.w, "  读取会话消息失败。\n\n");
                try std.Io.File.Writer.flush(ctx.file_writer);
                return .handled;
            };
            // Replace the live conversation: clear frees the current one,
            // then the loaded heap-owned messages move in.
            turn_history.clearHistory(ctx.history, allocator);
            var moved: usize = 0;
            for (msgs) |m| {
                ctx.history.append(allocator, m) catch {
                    session_store_mod.freeMessage(m, allocator);
                    continue;
                };
                moved += 1;
            }
            allocator.free(msgs);
            ctx.switcher.switchModel(meta.model) catch {
                std.Io.Writer.print(ctx.w, "  (模型 {s} 切换失败，保持当前模型)\n", .{meta.model}) catch {};
            };
            if (std.meta.stringToEnum(auth.PermissionMode, meta.permission_mode)) |m2| {
                ctx.current_mode.* = m2;
            }
            st.adopt(id, moved);
            const est = turn_history.estimateHistoryTokens(ctx.history.items);
            try std.Io.Writer.print(ctx.w, "  已恢复会话 #{d}：{d} 条消息（~{d} tokens · 模型 {s} · 模式 {s}）。继续对话即可。\n\n", .{
                id, moved, est, meta.model, meta.permission_mode,
            });
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (std.mem.eql(u8, input, "/version")) {
            try std.Io.Writer.writeAll(ctx.w, "  Ziv v" ++ version_mod.version ++ " (Zig " ++ @import("builtin").zig_version_string ++ ")\n\n");
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        } else if (input.len > 1 and ctx.skill_loader.findByName(if (std.mem.indexOfScalar(u8, input[1..], ' ')) |sp| input[1 .. 1 + sp] else input[1..]) != null) {
            // /<skill-name> [task...]: known skill -> inject its body as
            // the user message (v1: prompt-only skills) and fall through
            // to the normal agent path.
            const rest = input[1..];
            const sp_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            const skill = ctx.skill_loader.findByName(rest[0..sp_end]).?;
            const task = std.mem.trim(u8, rest[sp_end..], " \t");
            const body = ctx.skill_loader.readBody(skill, allocator) catch "";
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
                try std.Io.Writer.writeAll(ctx.w, prev);
                try std.Io.File.Writer.flush(ctx.file_writer);
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
            }) catch return .handled;
            var skill_blocks = try allocator.alloc(llm.ContentBlock, 1);
            skill_blocks[0] = .{ .text = msg };
            try ctx.history.append(allocator, .{
                .role = .user,
                .content = skill_blocks,
                .timestamp = util_time.nowMillis(),
            });
            return .skill;
        } else {
            try std.Io.Writer.print(ctx.w, "Unknown command: {s}", .{input});
            // Typo hints from the canonical command table.
            if (slash_cmds.suggestMatching(allocator, input) catch null) |hits| {
                defer allocator.free(hits);
                if (hits.len > 0) {
                    try std.Io.Writer.writeAll(ctx.w, "\nDid you mean:");
                    for (hits[0..@min(hits.len, 5)]) |h| {
                        try std.Io.Writer.print(ctx.w, " {s}", .{h});
                    }
                }
            }
            try std.Io.Writer.writeAll(ctx.w, "\nType /help for available commands.\n\n");
            try std.Io.File.Writer.flush(ctx.file_writer);
            return .handled;
        }
    }
    return .message;
}

