//! Session memory operations — the reflection/extraction cluster carved
//! out of repl.zig (P1 step 5, pure move): session-fact extraction (LLM
//! primary + keyword fallback), periodic reflection with background
//! dispatch and inbox drain, memory decay / health cron tasks, /memory
//! /research /diagnose command bodies. Turn-loop wiring stays in repl.zig.

const std = @import("std");
const llm = @import("../llm/mod.zig");
const compaction = @import("../llm/compaction.zig");
const memory_mod = @import("../memory/mod.zig");
const injection_mod = @import("../memory/injection.zig");
const extraction_mod = @import("../memory/extraction.zig");
const reflection_mod = @import("../memory/reflection.zig");
const knowledge_graph = @import("../knowledge/graph.zig");
const task_mod = @import("../task/mod.zig");
const util_time = @import("../util/time.zig");
const logger = @import("../util/log.zig");
const math_mod = @import("../math/mod.zig");
const env = @import("../util/env.zig");
const self_diagnostic = @import("../runtime/self_diagnostic.zig");
const decision_trace = @import("../runtime/decision_trace.zig");
const runtime_monitor = @import("../runtime/monitor.zig");
const runtime_rules = @import("../runtime/rules.zig");
const agent_dispatch = @import("../tools/agent_dispatch.zig");
const knowledge_search = @import("../knowledge/search.zig");
const researcher_mod = @import("../research/optimization_researcher.zig");
const database_mod = @import("../storage/database.zig");
const fs_ops = @import("../util/fs_ops.zig");
const repl_mod = @import("../repl.zig");

const ModelSwitcher = repl_mod.ModelSwitcher;
const allocator = std.heap.smp_allocator; // test-path only; same stateless global as repl.zig

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

/// LLM-extracted session payload (facts + real entity/relation graph).
/// All strings owned by the list allocator; deinit frees everything.
const LlmExtraction = struct {
    facts: std.ArrayList(extraction_mod.ExtractedFact) = .empty,
    entities: std.ArrayList(ExtractedEntity) = .empty,
    relations: std.ArrayList(ExtractedRelation) = .empty,

    fn deinit(self: *LlmExtraction, alloc: std.mem.Allocator) void {
        for (self.facts.items) |f| alloc.free(f.content);
        self.facts.deinit(alloc);
        for (self.entities.items) |e| alloc.free(e.name);
        self.entities.deinit(alloc);
        for (self.relations.items) |r| {
            alloc.free(r.from);
            alloc.free(r.to);
            alloc.free(r.relation);
        }
        self.relations.deinit(alloc);
    }
};

const ExtractedEntity = struct {
    name: []u8,
    etype: knowledge_graph.EntityType,
};

const ExtractedRelation = struct {
    from: []u8,
    to: []u8,
    relation: []u8,
};

/// One aux LLM call distilling a whole session into structured knowledge —
/// the primary extraction path. The keyword heuristics in
/// extractSessionMemories remain as the fallback (gateway down at exit,
/// unparseable reply, no provider). All strings allocated with `alloc`.
fn llmExtractSession(alloc: std.mem.Allocator, prov: llm.Provider, messages: []const llm.Message, aux_cap: u32) !LlmExtraction {
    const transcript = compaction.renderTranscript(alloc, messages) catch return error.ExtractTranscriptFailed;
    defer alloc.free(transcript);
    if (transcript.len == 0) return error.ExtractEmptyTranscript;
    const tr = transcript[0..@min(transcript.len, 24_000)]; // bound the aux call

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(alloc);
    try prompt.appendSlice(alloc,
        \\Extract durable knowledge from this coding-agent conversation for long-term memory.
        \\Respond with ONLY a JSON object (no markdown fences, no commentary), exactly this schema:
        \\{"facts":[{"type":"user_preference|project_context|technical_fact|error_solution|pattern_observed","content":"..."}],"entities":[{"name":"...","type":"technology|person|concept|organization|code_pattern|api_endpoint"}],"relations":[{"from":"entity name","to":"entity name","relation":"short verb phrase"}]}
        \\Rules: each fact is ONE standalone statement, max 300 chars, in the conversation's dominant language; skip small talk, raw code dumps and transient state; at most 12 facts. Entities are the concrete technologies, files, tools, commands and projects involved (max 15). Relations (max 20) only between listed entities.
        \\
    );
    try prompt.appendSlice(alloc, tr);

    var blocks = try alloc.alloc(llm.ContentBlock, 1);
    defer alloc.free(blocks);
    blocks[0] = .{ .text = try alloc.dupe(u8, prompt.items) };
    defer alloc.free(blocks[0].text);
    const msgs = [_]llm.Message{
        .{ .role = .user, .content = blocks, .timestamp = util_time.nowMillis() },
    };
    var resp = try prov.complete(&msgs, .{
        .max_tokens = @min(aux_cap, 2048),
        .temperature = 0.2,
    });
    // Pull the text out before the response DOM arena is freed.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    for (resp.content) |b| {
        if (b == .text) text.appendSlice(alloc, b.text) catch break;
    }
    resp.free(alloc);
    if (text.items.len == 0) return error.ExtractEmptyReply;
    return parseExtractionReply(alloc, text.items);
}

/// Lenient JSON recovery + field extraction from a model's extraction
/// reply. Models fence or preface despite instructions — slice to the
/// outermost braces and parse what's between. All strings duped onto
/// `alloc`; parse scratch lives in a per-call arena.
fn parseExtractionReply(alloc: std.mem.Allocator, reply: []const u8) !LlmExtraction {
    const lbrace = std.mem.indexOfScalar(u8, reply, '{') orelse return error.ExtractNoJson;
    const rbrace = std.mem.lastIndexOfScalar(u8, reply, '}') orelse return error.ExtractNoJson;
    if (rbrace <= lbrace) return error.ExtractNoJson;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), reply[lbrace .. rbrace + 1], .{});
    if (parsed != .object) return error.ExtractBadShape;

    var out = LlmExtraction{};
    errdefer out.deinit(alloc);
    if (parsed.object.get("facts")) |fv| {
        if (fv == .array) {
            for (fv.array.items[0..@min(fv.array.items.len, 12)]) |item| {
                if (item != .object) continue;
                const content_v = item.object.get("content") orelse continue;
                const type_v = item.object.get("type") orelse continue;
                if (content_v != .string or type_v != .string) continue;
                if (content_v.string.len < 8 or content_v.string.len > 600) continue;
                const ftype = std.meta.stringToEnum(extraction_mod.FactType, type_v.string) orelse .pattern_observed;
                try out.facts.append(alloc, .{
                    .content = try alloc.dupe(u8, content_v.string),
                    .fact_type = ftype,
                    .importance = 0.85,
                });
            }
        }
    }
    if (parsed.object.get("entities")) |ev| {
        if (ev == .array) {
            for (ev.array.items[0..@min(ev.array.items.len, 15)]) |item| {
                if (item != .object) continue;
                const name_v = item.object.get("name") orelse continue;
                const type_v = item.object.get("type") orelse continue;
                if (name_v != .string or type_v != .string) continue;
                if (name_v.string.len < 1 or name_v.string.len > 96) continue;
                try out.entities.append(alloc, .{
                    .name = try alloc.dupe(u8, name_v.string),
                    .etype = std.meta.stringToEnum(knowledge_graph.EntityType, type_v.string) orelse .concept,
                });
            }
        }
    }
    if (parsed.object.get("relations")) |rv| {
        if (rv == .array) {
            for (rv.array.items[0..@min(rv.array.items.len, 20)]) |item| {
                if (item != .object) continue;
                const from_v = item.object.get("from") orelse continue;
                const to_v = item.object.get("to") orelse continue;
                const rel_v = item.object.get("relation") orelse continue;
                if (from_v != .string or to_v != .string or rel_v != .string) continue;
                try out.relations.append(alloc, .{
                    .from = try alloc.dupe(u8, from_v.string),
                    .to = try alloc.dupe(u8, to_v.string),
                    .relation = try alloc.dupe(u8, rel_v.string),
                });
            }
        }
    }
    return out;
}

/// Store an LLM extraction (facts + graph). Split out so the bounded
/// exit path can run the LLM call off-thread and apply on the main thread
/// (sqlite is THREADSAFE=0 — DB writes never leave main).
fn applyLlmExtraction(mem: *memory_mod.MemorySystem, kg: ?*knowledge_graph.KnowledgeGraph, bus: ?*task_mod.EventBus, w: *std.Io.Writer, out_in: LlmExtraction) !void {
    {
        var out = out_in; // mutable copy: deinit needs *Self
        defer out.deinit(mem.allocator);
        logger.info("llm extraction parsed: {d} facts, {d} entities, {d} relations", .{ out.facts.items.len, out.entities.items.len, out.relations.items.len });
        var stored: usize = 0;
            for (out.facts.items) |f| {
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
            }
            if (kg) |g| {
                for (out.entities.items) |e| {
                    _ = g.addNode(e.name, e.etype, "llm") catch {};
                }
                for (out.relations.items) |r| {
                    const fid = g.findNodeId(r.from) orelse continue;
                    const tid = g.findNodeId(r.to) orelse continue;
                    g.addEdge(fid, tid, r.relation, 1.0) catch {};
                }
            }
        if (stored > 0) {
            try w.print("  Saved {d} memories (LLM extraction; {d} entities, {d} relations).\n", .{ stored, out.entities.items.len, out.relations.items.len });
            if (bus) |b| b.emit(.{ .memory_updated = .{ .stored = @intCast(@min(stored, 255)) } });
        }
    }
}

pub fn extractSessionMemories(mem: *memory_mod.MemorySystem, kg: ?*knowledge_graph.KnowledgeGraph, history: *std.ArrayList(llm.Message), bus: ?*task_mod.EventBus, w: *std.Io.Writer, prov: ?llm.Provider, aux_cap: u32) !void {
    // ── Primary path: one aux LLM call for structured facts + graph. ──
    if (prov) |p| {
        if (llmExtractSession(mem.allocator, p, history.items, aux_cap)) |out_captured| {
            return applyLlmExtraction(mem, kg, bus, w, out_captured);
        } else |_| {
            logger.info("llm extraction unavailable; falling back to keyword heuristics", .{});
        }
    }

    // ── Fallback path: keyword heuristics (no provider / LLM failed). ──
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
        if (bus) |b| b.emit(.{ .memory_updated = .{ .stored = @intCast(@min(stored, 255)) } });
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
pub fn writeMarginLines(w: *std.Io.Writer, s: []const u8, indent: []const u8, at_line_start: *bool) !void {
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
/// Snapshot of everything a background LLM worker needs to build its OWN
/// provider — values copied at dispatch time so settings hot-reloads and
/// model switches cannot dangle under a running worker.
const BackgroundLlmConfig = struct {
    backend: llm.BackendType,
    model: []u8, // alloc-owned copy
    api_key: ?[]u8 = null,
    base_url: ?[]u8 = null,
    ollama_host: []u8,

    fn deinit(self: BackgroundLlmConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.model);
        if (self.api_key) |k| alloc.free(k);
        if (self.base_url) |b| alloc.free(b);
        alloc.free(self.ollama_host);
    }
};

/// Snapshot the current provider config for a background worker.
pub fn backgroundLlmConfig(alloc: std.mem.Allocator, switcher: *ModelSwitcher) ?BackgroundLlmConfig {
    const model = alloc.dupe(u8, switcher.modelName()) catch return null;
    errdefer alloc.free(model);
    const oh = alloc.dupe(u8, switcher.settings.api_keys.ollama_host) catch {
        alloc.free(model);
        return null;
    };
    return switch (switcher.backend) {
        .openai => BackgroundLlmConfig{
            .backend = .openai,
            .model = model,
            .api_key = if (switcher.settings.api_keys.openai) |k| (alloc.dupe(u8, k) catch null) else null,
            .base_url = if (switcher.settings.api_keys.openai_base_url) |b| (alloc.dupe(u8, b) catch null) else null,
            .ollama_host = oh,
        },
        .claude => BackgroundLlmConfig{
            .backend = .claude,
            .model = model,
            .api_key = if (switcher.settings.api_keys.anthropic) |k| (alloc.dupe(u8, k) catch null) else null,
            .base_url = if (switcher.settings.api_keys.anthropic_base_url) |b| (alloc.dupe(u8, b) catch null) else null,
            .ollama_host = oh,
        },
        .ollama => BackgroundLlmConfig{
            .backend = .ollama,
            .model = model,
            .ollama_host = oh,
        },
    };
}

/// Dispatch the background reflection (fire-and-forget; results arrive in
/// the inbox and are drained at the next prompt).
fn dispatchBackgroundReflection(
    alloc: std.mem.Allocator,
    queries: []const []const u8,
    cfg: BackgroundLlmConfig,
    trigger_name: []const u8,
    quality: f64,
) void {
    const t0 = util_time.nowMillis();
    // deep-copy queries (the window resets as soon as we return)
    const qs = alloc.alloc([:0]u8, queries.len) catch {
        cfg.deinit(alloc);
        return;
    };
    var filled: usize = 0;
    for (queries) |q| {
        // 0.17 has no dupeZ, and dupe(..)[0..len:0] PANICS at runtime —
        // the sentinel check reads past the slice (crashed the 10th-turn
        // reflection dispatch). Allocate len+1, copy, NUL-terminate.
        const buf = alloc.alloc(u8, q.len + 1) catch break;
        @memcpy(buf[0..q.len], q);
        buf[q.len] = 0;
        qs[filled] = buf[0..q.len :0];
        filled += 1;
    }
    if (filled < queries.len) {
        for (qs[0..filled]) |d| alloc.free(d);
        alloc.free(qs);
        cfg.deinit(alloc);
        return;
    }
    reflect_inflight = true;
    const t = std.Thread.spawn(.{}, reflectWorkerOwned, .{ alloc, qs, cfg, trigger_name, quality, t0 }) catch {
        reflect_inflight = false;
        for (qs) |d| alloc.free(d);
        alloc.free(qs);
        cfg.deinit(alloc);
        return;
    };
    t.detach(); // single-flight flag is cleared by the worker itself
}

/// Thin adapter: owns the config snapshot alongside reflectWorker.
fn reflectWorkerOwned(alloc: std.mem.Allocator, queries: [][:0]u8, cfg: BackgroundLlmConfig, trigger_name: []const u8, quality: f64, t0: i64) void {
    defer cfg.deinit(alloc);
    reflectWorker(alloc, queries, cfg.backend, cfg.model, cfg.api_key, cfg.base_url, cfg.ollama_host, trigger_name, quality, t0);
}

/// Drain finished background reflections on the MAIN thread: store as
/// .feedback memory (SQLite stays main-thread) and print the arrival.
pub fn drainReflectionInbox(alloc: std.mem.Allocator, mem: ?*memory_mod.MemorySystem, bus: ?*task_mod.EventBus, w: *std.Io.Writer) void {
    if (!reflect_inbox_init) return;
    while (reflect_inbox.pop()) |out| {
        defer {
            alloc.free(out.insights);
            alloc.destroy(out);
        }
        if (mem == null) continue;
        if (reflectionIsDuplicate(mem.?, out.insights)) {
            logger.info("reflection: background llm insight near-duplicate — store skipped", .{});
            std.Io.Writer.print(w, "  [Reflection+ {d}ms] {s}\n", .{ out.elapsed_ms, out.insights }) catch {};
            continue;
        }
        const name = "reflection (background llm)";
        const now = util_time.nowMillis();
        mem.?.store(.{
            .id = injection_mod.memoryId(out.insights, "reflection"),
            .mem_type = .feedback,
            .name = name,
            .description = out.trigger_name,
            .content = out.insights,
            .access_count = 0,
            .created_at = now,
            .updated_at = now,
        }) catch {};
        logger.info("reflection: background llm insight stored ({d}ms)", .{out.elapsed_ms});
        if (bus) |b| b.emit(.{ .reflection_produced = .{ .quality = @floatCast(out.quality), .background = true } });
        std.Io.Writer.print(w, "  [Reflection+ {d}ms] {s}\n", .{ out.elapsed_ms, out.insights }) catch {};
    }
}

pub const MemoryDecayCtx = struct { mem: ?*memory_mod.MemorySystem };

/// P3 cron task: e-decay + φ condensation sweep. Ranks the recent window
/// by e^(-age/30d) × (access+1), prunes the bottom 38.2% — but ONLY
/// entries untouched for 30+ days (fresh entries ride). Runs on the MAIN
/// thread via cron.drainDue (SQLite rule).
pub fn memoryDecayTask(opaque_ctx: ?*anyopaque) anyerror!void {
    const dc: *MemoryDecayCtx = @ptrCast(@alignCast(opaque_ctx orelse return));
    const ms = dc.mem orelse return;
    const entries = try ms.episodic_mem.retrieveRecent(200);
    defer ms.episodic_mem.freeEntries(entries);
    const now = util_time.nowMillis();
    const month_ms: i64 = 30 * 24 * 3600 * 1000;
    var ids_buf: [200][16]u8 = undefined;
    var scores: [200]f64 = undefined;
    var n_cand: usize = 0;
    for (entries) |e| {
        if (now - e.updated_at < month_ms) continue;
        const age_days = @as(f64, @floatFromInt(now - e.updated_at)) / 86_400_000.0;
        scores[n_cand] = std.math.exp(-age_days / 30.0) * @as(f64, @floatFromInt(e.access_count + 1));
        ids_buf[n_cand] = e.id;
        n_cand += 1;
    }
    if (n_cand < 4) return; // nothing meaningful to condense
    const prune_n = @min(n_cand - 1, n_cand * 382 / 1000); // keep φ ≈ 61.8%
    if (prune_n == 0) return;
    // lowest-score selection (n ≤ 200, runs every ~81.5min — naive is fine)
    var used: [200]bool = @splat(false);
    var prune: [200][16]u8 = undefined;
    var prune_len: usize = 0;
    while (prune_len < prune_n) {
        var lowest: ?usize = null;
        for (scores[0..n_cand], 0..) |s, i| {
            if (used[i]) continue;
            if (lowest == null or s < scores[lowest.?]) lowest = i;
        }
        used[lowest.?] = true;
        prune[prune_len] = ids_buf[lowest.?];
        prune_len += 1;
    }
    const deleted = ms.episodic_mem.deleteByIds(prune[0..prune_len]);
    if (deleted > 0) {
        logger.info("memory: φ sweep pruned {d}/{d} stale entries (>30d untouched)", .{ deleted, n_cand });
        // NOTE: deliberately no memory_updated emit — that event marks
        // additions; a sweep log line is enough signal.
    }
}

/// P5 π 图谱扫描：孤立节点/断边检测，结果缓存给 /knowledge。跑在
/// cron 主线程契约下（与衰减/健康任务同）。
pub var last_graph_scan: ?knowledge_graph.KnowledgeGraph.GraphHealth = null;
pub var last_graph_scan_at: i64 = 0;

pub fn runGraphScan(kg: ?*knowledge_graph.KnowledgeGraph) void {
    const g = kg orelse return;
    if (last_graph_scan) |*h| h.deinit(allocator);
    last_graph_scan = g.scanHealth(allocator);
    last_graph_scan_at = util_time.nowMillis();
    const h = last_graph_scan.?;
    logger.info("graph scan: {d} nodes / {d} edges / {d} orphans / {d} broken", .{
        h.total_nodes, h.total_edges, h.orphan_nodes, h.broken_edges,
    });
}

pub const GraphScanCtx = struct { kg: ?*knowledge_graph.KnowledgeGraph };

pub fn graphScanTask(opaque_ctx: ?*anyopaque) anyerror!void {
    const c: *GraphScanCtx = @ptrCast(@alignCast(opaque_ctx orelse return));
    runGraphScan(c.kg);
}

pub const HealthCtx = struct {
    monitor: *runtime_monitor.RuntimeMonitor,
    bus: *task_mod.EventBus,
    w: *std.Io.Writer,
    /// Region-aware transcript writer + the flushable File.Writer: the
    /// monitor line must print ABOVE the live region when the check
    /// drains mid-turn (2026-11-06 — cron now drains in the turn's UI
    /// slices too, so the old bare-`w` print would smear the input row).
    ow: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    /// Live model context (window re-estimated at check time — the model
    /// can switch mid-session). The first wiring compared against
    /// settings.max_tokens — the RESPONSE cap (4096!) — so every active
    /// session read "context window near limit" as a false positive.
    switcher: *ModelSwitcher,
    llm_calls: *std.atomic.Value(u32),
    llm_429s: *std.atomic.Value(u32),
    est_tokens: *std.atomic.Value(u32),
    /// Dedup: print only when the failing-rule signature CHANGES — the
    /// same warning every 60s used to stack into noise walls.
    last_warn_count: usize = std.math.maxInt(usize),
    last_warn_first: []const u8 = "",
};

/// P3 cron task: runtime monitor checks on the main thread. The api-rate
/// signal is the LLM-call delta since the previous check (~1/min at the
/// default 60s interval). Failures print one compact line + a
/// resource_warning event; suggested fixes stay in the report below it.
pub fn healthCheckTask(opaque_ctx: ?*anyopaque) anyerror!void {
    const hc: *HealthCtx = @ptrCast(@alignCast(opaque_ctx orelse return));
    const calls = hc.llm_calls.swap(0, .monotonic);
    hc.monitor.updateContext(.{
        .memory_used_bytes = 0, // RSS not cheaply readable; rule idles
        .memory_limit_bytes = 100 * 1024 * 1024,
        .memory_entry_count = 0,
        .api_calls_last_minute = calls,
        .api_rate_limit = 60,
        .api_rate_limited_count = hc.llm_429s.swap(0, .monotonic),
        .db_integrity_ok = true,
        .current_tokens = hc.est_tokens.load(.monotonic),
        // The real context WINDOW for the live model (e.g. glm-5.3 →
        // 131072), not the response cap.
        .max_tokens = llm.provider.contextEstimate(hc.switcher.modelName(), hc.switcher.backend),
        .task_failed_count = 0,
        .task_total_count = 0,
        .network_timeout_count = 0,
        .active_tasks = 0,
        .max_concurrent_tasks = 4,
    });
    var failures: std.ArrayList(runtime_rules.FailedCheck) = .empty;
    defer failures.deinit(allocator);
    try hc.monitor.runChecks(&failures);
    if (failures.items.len > 0) {
        const changed = failures.items.len != hc.last_warn_count or
            !std.mem.eql(u8, failures.items[0].rule_id, hc.last_warn_first);
        if (changed) {
            hc.last_warn_count = failures.items.len;
            hc.last_warn_first = failures.items[0].rule_id;
            // Through the RegionWriter: lands ABOVE the live region when
            // the check drains mid-turn (line-atomic), verbatim at the
            // prompt — a bare write here smeared the persistent input
            // row whenever the drain raced an active turn.
            std.Io.Writer.print(hc.ow, "\x1b[2m  [monitor] {d} runtime warning(s) — {s}\x1b[0m\n", .{ failures.items.len, failures.items[0].message }) catch {};
            std.Io.File.Writer.flush(hc.file_writer) catch {};
        }
        // Events flow regardless (π ring feeds reflection) — only the
        // print is deduped.
        hc.bus.emit(.{ .resource_warning = .{ .failed_checks = @intCast(failures.items.len) } });
    } else {
        hc.last_warn_count = 0;
        hc.last_warn_first = "";
    }
}

/// Reflection-store near-duplicate gate (mirrors the extraction T2.3
/// gate): jaccard > 0.8 against any recent stored memory rejects the
/// store. The extraction path always had this gate; the reflection paths
/// didn't, so repeated LLM insights about similar patterns piled up
/// unbounded. Side benefit: an identical canned text no longer refreshes
/// its own updated_at, so the e-decay actually gets to age it.
fn reflectionIsDuplicate(mem: *memory_mod.MemorySystem, insight: []const u8) bool {
    const entries = mem.episodic_mem.retrieveRecent(20) catch return false;
    defer mem.episodic_mem.freeEntries(entries);
    for (entries) |e| {
        if (jaccardTokens(e.content, insight) > 0.8) return true;
    }
    return false;
}

/// T3.2 (as-designed): background reflection result, handed from the
/// worker to the main thread via a bounded MPSC — the main thread owns
/// all SQLite writes (THREADSAFE=0) and all printing.
/// P5 洞察质量门：启发式洞察（罐头文案）入库前的最后一道校验——
/// provider 可达时问一次 LLM「真经验还是误诊」，只认 yes/no。
/// 返回 null = 无法判定（网关错误/答非所问）→ fail-open 照常入库；
/// 关闭路径与 flash 档不付这个往返（调用方门控）。
fn parseInsightVerdict(reply: []const u8) ?bool {
    var lower_buf: [64]u8 = undefined;
    const n = @min(reply.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..n], reply[0..n]);
    const yes = std.mem.indexOf(u8, lower, "yes");
    const no = std.mem.indexOf(u8, lower, "no");
    if (yes == null and no == null) return null;
    if (yes != null and no != null) return yes.? < no.?;
    return yes != null;
}

pub fn insightPassesGate(alloc: std.mem.Allocator, prov: llm.Provider, insight: []const u8) ?bool {
    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(alloc);
    prompt.appendSlice(alloc,
        \\Judge this session insight: is it a genuine, durable lesson — or a misdiagnosis of normal/deliberate activity (e.g. planned timeouts, user-driven retries)? Answer ONLY "yes" (keep) or "no" (reject).
        \\Insight:
    ) catch return null;
    prompt.appendSlice(alloc, insight) catch return null;

    const sys_blocks = alloc.alloc(llm.ContentBlock, 1) catch return null;
    defer alloc.free(sys_blocks);
    sys_blocks[0] = .{ .text = "You are a strict memory curator. One word answers only." };
    const user_blocks = alloc.alloc(llm.ContentBlock, 1) catch return null;
    defer alloc.free(user_blocks);
    user_blocks[0] = .{ .text = prompt.items };
    const msgs = [_]llm.Message{
        .{ .role = .system, .content = sys_blocks, .timestamp = util_time.nowMillis() },
        .{ .role = .user, .content = user_blocks, .timestamp = util_time.nowMillis() },
    };
    var resp = prov.complete(&msgs, .{ .max_tokens = 8, .temperature = 0.0 }) catch return null;
    defer resp.free(alloc);
    for (resp.content) |b| {
        if (b != .text) continue;
        return parseInsightVerdict(b.text);
    }
    return null;
}

/// 退出期提取的兜底时限：网关慢是常态（实测 29.6s 一次），/quit 不能
/// 无界等 LLM。超时 → 关键词启发式兜底（毫秒级），LLM 线程被放弃
/// （随进程消亡——与后台反思同一放弃契约：泄漏优于悬垂释放）。
pub const EXIT_EXTRACT_DEADLINE_MS: i64 = 20_000;

const ExitExtractSlot = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0), // 0=running 1=done 2=failed
    cfg: ?BackgroundLlmConfig = null,
    history: []const llm.Message = &.{},
    out: ?LlmExtraction = null,
    alloc: std.mem.Allocator,
    aux_cap: u32 = 0,
};

/// LLM 提取跑在分离线程：自建 io + 自建 provider（被放弃的线程绝不碰
/// 活对象——同 reflectWorker 的生命周期契约），结果字符串由 slot.alloc
/// 单独持有，与 provider/io 生命周期无关，主线程可安全接手。
fn exitExtractWorker(slot: *ExitExtractSlot) void {
    var io_state = std.Io.Threaded.init(slot.alloc, .{});
    defer io_state.deinit();
    var storage: BgProviderStorage = undefined;
    const c = slot.cfg.?;
    const prov = makeBackgroundProviderInto(slot.alloc, io_state.io(), c.backend, c.model, c.api_key, c.base_url, c.ollama_host, &storage) orelse {
        slot.state.store(2, .release);
        return;
    };
    defer prov.deinit();
    if (llmExtractSession(slot.alloc, prov, slot.history, slot.aux_cap)) |out| {
        slot.out = out;
        slot.state.store(1, .release);
    } else |_| {
        slot.state.store(2, .release);
    }
}

/// 有界退出提取：主线程等 ≤ deadline——LLM 完成 → 主线程落库（sqlite
/// THREADSAFE=0，DB 写永不出主线程）；超时/失败 → 关键词启发式兜底。
/// cfg 所有权移入 slot：成功/失败由主线程 deinit，超时随进程泄漏。
pub fn extractSessionMemoriesBounded(
    mem: *memory_mod.MemorySystem,
    kg: ?*knowledge_graph.KnowledgeGraph,
    history: *std.ArrayList(llm.Message),
    bus: ?*task_mod.EventBus,
    w: *std.Io.Writer,
    file_writer: ?*std.Io.File.Writer,
    alloc: std.mem.Allocator,
    cfg: ?BackgroundLlmConfig,
    aux_cap: u32,
    deadline_ms: i64,
) void {
    const c = cfg orelse {
        extractSessionMemories(mem, kg, history, bus, w, null, aux_cap) catch {};
        return;
    };
    // No api key in the snapshot → the LLM attempt is doomed to a network
    // timeout (hermetic suites, unconfigured backends). Skip straight to
    // heuristics: exit stays fast where LLM extraction cannot succeed.
    if (c.api_key == null and c.backend != .ollama) {
        var cc = c;
        cc.deinit(alloc);
        extractSessionMemories(mem, kg, history, bus, w, null, aux_cap) catch {};
        return;
    }
    std.Io.Writer.print(w, "  [正在提取本会话记忆…（≤{d}s，网关慢时自动降级为关键词提取）]\n", .{@divTrunc(deadline_ms, 1000)}) catch {};
    if (file_writer) |fw| std.Io.File.Writer.flush(fw) catch {};

    const slot = alloc.create(ExitExtractSlot) catch {
        var cc = c;
        cc.deinit(alloc);
        extractSessionMemories(mem, kg, history, bus, w, null, aux_cap) catch {};
        return;
    };
    slot.* = .{ .cfg = c, .history = history.items, .alloc = alloc, .aux_cap = aux_cap };
    const th = std.Thread.spawn(.{}, exitExtractWorker, .{slot}) catch {
        // 罕见（OOM）：不等了，启发式兜底；slot.cfg 由本线程收尾。
        if (slot.cfg) |cc| {
            var c2 = cc;
            c2.deinit(alloc);
        }
        alloc.destroy(slot);
        extractSessionMemories(mem, kg, history, bus, w, null, aux_cap) catch {};
        return;
    };
    th.detach();

    const t0 = util_time.nowMillis();
    while (util_time.nowMillis() - t0 < deadline_ms) {
        const s = slot.state.load(.acquire);
        if (s != 0) {
            // 线程已收尾自己的 provider/io；结果字符串独立可接手。
            if (s == 1) {
                applyLlmExtraction(mem, kg, bus, w, slot.out.?) catch {};
            } else {
                extractSessionMemories(mem, kg, history, bus, w, null, aux_cap) catch {};
            }
            if (slot.cfg) |cc| {
                var c2 = cc;
                c2.deinit(alloc);
            }
            alloc.destroy(slot);
            return;
        }
        util_time.sleepMs(100);
    }
    // 超时：放弃线程（cfg/slot 随进程泄漏——进程即将退出，释放反而悬垂）。
    std.Io.Writer.print(w, "  [提取超时 — 已降级为关键词启发式，慢网关的部分放弃]\n", .{}) catch {};
    if (file_writer) |fw| std.Io.File.Writer.flush(fw) catch {};
    extractSessionMemories(mem, kg, history, bus, w, null, aux_cap) catch {};
}

const ReflectOutcome = struct {
    insights: []u8, // alloc-owned; freed by the drainer
    trigger_name: []const u8, // enum tag string (static)
    quality: f64,
    elapsed_ms: i64,
};

pub var reflect_inbox: task_mod.BoundedMPSC(*ReflectOutcome, 4) = undefined;
pub var reflect_inbox_init = false;
var reflect_inflight = false; // single-flight: one background reflection at a time

/// Background worker (B-pattern from the io probe): private Threaded io
/// created AND destroyed on this same thread + a private provider — the
/// only combination measured stable (shared-io concurrent use asserts in
/// std.http.Client.deinit; multiple live instances deadlock teardown).
fn reflectWorker(
    alloc: std.mem.Allocator,
    queries: [][:0]u8,
    backend: llm.BackendType,
    model: []const u8,
    api_key: ?[]const u8,
    base_url: ?[]const u8,
    ollama_host: []const u8,
    trigger_name: []const u8,
    quality: f64,
    t0: i64,
) void {
    defer {
        for (queries) |q| alloc.free(q);
        alloc.free(queries);
    }
    // Lifetime order (probe-verified): provider dies BEFORE its io, and
    // the io is destroyed on THIS thread (its creator). defers run LIFO:
    // io deinit registered first → runs last.
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const wio = io_state.io();
    var bg_storage: BgProviderStorage = undefined;
    const provider: ?llm.Provider = makeBackgroundProviderInto(alloc, wio, backend, model, api_key, base_url, ollama_host, &bg_storage);
    defer if (provider) |p| p.deinit();

    // Prompt wording kept identical to the retired timeout worker so
    // insight style stays continuous across the rework.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const pw = &aw.writer;
    pw.writeAll("Recent queries in this session:\n") catch {
        reflect_inflight = false;
        return;
    };
    for (queries) |q| pw.print("- {s}\n", .{q}) catch break;
    pw.writeAll("Summarize the ONE most actionable insight for future sessions (1-3 sentences, specific).") catch {};
    const prompt = alloc.dupe(u8, aw.written()) catch {
        reflect_inflight = false;
        return;
    };
    defer alloc.free(prompt);
    const blocks = [_]llm.ContentBlock{.{ .text = prompt }};
    const msgs = [_]llm.Message{.{ .role = .user, .content = &blocks, .timestamp = 0 }};
    var resp = provider.?.complete(&msgs, .{ .max_tokens = 512, .temperature = 0.3 }) catch {
        reflect_inflight = false;
        return;
    };
    defer resp.free(alloc);
    var text: []const u8 = "";
    for (resp.content) |b| switch (b) {
        .text => |t| if (t.len > 0) {
            text = t;
            break;
        },
        else => {},
    };
    const owned = alloc.dupe(u8, text) catch {
        reflect_inflight = false;
        return;
    };
    const out = alloc.create(ReflectOutcome) catch {
        alloc.free(owned);
        reflect_inflight = false;
        return;
    };
    out.* = .{
        .insights = owned,
        .trigger_name = trigger_name,
        .quality = quality,
        .elapsed_ms = util_time.nowMillis() - t0,
    };
    if (!reflect_inbox.push(out)) {
        alloc.free(owned);
        alloc.destroy(out);
    }
    reflect_inflight = false;
}

/// Provider storage for the background reflection worker (see
/// agent_dispatch.ProviderStorage — providers must outlive their maker's
/// frame or toProvider() dangles).
const BgProviderStorage = union(llm.BackendType) {
    openai: llm.OpenAIProvider,
    claude: llm.ClaudeProvider,
    ollama: llm.OllamaProvider,

    fn provider(self: *BgProviderStorage) llm.Provider {
        return switch (self.*) {
            inline else => |*p| p.toProvider(),
        };
    }
};

fn makeBackgroundProviderInto(alloc: std.mem.Allocator, io: std.Io, backend: llm.BackendType, model: []const u8, api_key: ?[]const u8, base_url: ?[]const u8, ollama_host: []const u8, storage: *BgProviderStorage) ?llm.Provider {
    switch (backend) {
        .openai => storage.* = .{ .openai = llm.OpenAIProvider.init(alloc, io, .{
            .api_key = api_key orelse return null,
            .model = model,
            .base_url = base_url orelse "https://api.openai.com/v1",
        }) },
        .claude => storage.* = .{ .claude = llm.ClaudeProvider.init(alloc, io, .{
            .api_key = api_key orelse return null,
            .model = model,
            .base_url = base_url orelse "https://api.anthropic.com",
        }) },
        .ollama => storage.* = .{ .ollama = llm.OllamaProvider.init(alloc, io, .{
            .model = model,
            .base_url = ollama_host,
        }) },
    }
    return storage.provider();
}

pub fn runReflection(
    reflector: *reflection_mod.ReflectionEngine,
    mem: *memory_mod.MemorySystem,
    window_queries: *std.ArrayList([]u8),
    window_tools: *u32,
    window_errors: *u32,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    provider: ?llm.Provider,
    tier: llm.provider.CapabilityTier,
    bg_cfg: ?BackgroundLlmConfig,
    bus: ?*task_mod.EventBus,
) void {
    const reflect_t0 = util_time.nowMillis();
    // P5 经验回放：窗口 >20 条时 π-均匀采样——反思看见会话全史（早期
    // 决策重回视野），而非只盯最近 20 条。
    var sampled: ?[]const []const u8 = null;
    defer if (sampled) |s| alloc.free(@constCast(s));
    const reflect_window: []const []const u8 = blk: {
        if (window_queries.items.len > 20) {
            if (reflection_mod.piSample(alloc, window_queries.items, 20)) |s| {
                sampled = s;
                break :blk s;
            } else |_| {}
        }
        break :blk window_queries.items;
    };
    const reflection = reflector.reflect(reflect_window, window_tools.*, window_errors.*, .on_query_complete) catch return orelse return;

    // Gate: only ACTIONABLE windows pay the LLM round trip (and the print
    // and the stored row). A clean session is routine — it used to be
    // billed 1-3 s at exit plus a junk "良好" memory entry every session.
    if (!reflection.actionable) {
        resetReflectionWindow(window_queries, window_tools, window_errors, alloc);
        return;
    }

    // T3.2 (as designed): full-quality LLM augmentation runs IN THE
    // BACKGROUND — the turn never waits for it. The heuristic result is
    // stored immediately (0-blocking, complete on its own); the LLM
    // insight lands as a second .feedback memory when the drainer picks
    // it up next prompt. Single-flight: a still-running reflection means
    // this window's LLM pass is skipped (heuristics already stored).
    // T2.2 gate stays: flash/local tiers never pay an LLM round trip.
    // P3: π-sampled earlier-session events ride along as one extra line —
    // the window only sees recent queries, the event ring covers the whole
    // session, so the reflection gets past the recency horizon.
    if (provider != null and tier == .full and bg_cfg != null and
        window_queries.items.len >= 3 and !reflect_inflight)
    {
        var events_blurb: ?[]u8 = null;
        defer if (events_blurb) |eb| alloc.free(eb);
        if (bus) |b| {
            if (b.eventCount() >= 3) {
                var eaw: std.Io.Writer.Allocating = .init(alloc);
                defer eaw.deinit();
                const evs = b.getRecentEvents(8);
                defer b.freeEvents(evs);
                for (evs) |ev| {
                    var dbuf: [160]u8 = undefined;
                    eaw.writer.print("[earlier] {s}\n", .{task_mod.event_bus.EventBus.describe(ev, &dbuf)}) catch break;
                }
                var elist = eaw.toArrayList();
                events_blurb = elist.toOwnedSlice(alloc) catch null;
            }
        }
        var qs_extra: [16][]const u8 = undefined;
        var n_extra: usize = 0;
        // Fill from the TAIL: the π sample is oldest→newest, and the LLM
        // reflection prompt must keep the NEWEST turns — taking the head
        // of a full-history sample would hand it the early session and
        // drop everything recent (P5② review fix).
        {
            var qi = reflect_window.len;
            while (qi > 0 and n_extra < 15) {
                qi -= 1;
                qs_extra[n_extra] = reflect_window[qi];
                n_extra += 1;
            }
        }
        if (events_blurb) |eb| {
            qs_extra[n_extra] = eb;
            n_extra += 1;
        }
        dispatchBackgroundReflection(
            alloc,
            qs_extra[0..n_extra],
            bg_cfg.?,
            @tagName(reflection.trigger),
            reflection.quality_score,
        );
    } else if (bg_cfg) |c| {
        c.deinit(alloc); // gated out: nobody owns the snapshot anymore
    }
    const insights: []const u8 = reflection.insights;

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "reflection q={d} tools={d}", .{ window_queries.items.len, window_tools.* }) catch "reflection";
    if (reflectionIsDuplicate(mem, insights)) {
        // Keep the print + the LLM dispatch (both already happened above);
        // only the STORE is gated — repeated identical windows must not
        // refresh the same row forever.
        logger.info("reflection: heuristic insight near-duplicate — store skipped", .{});
    } else {
        // P5 质量门：启发式罐头洞察在入库前经一次 LLM 校验（provider
        // 可达且 full 档才付这个往返；网关错误 fail-open 照常入库）。
        // expected_stop 治标（计数剔除）之外的治本：误诊进不了库。
        var store_insight = true;
        if (provider != null and tier == .full) {
            if (insightPassesGate(alloc, provider.?, insights)) |keep| {
                store_insight = keep;
                if (!keep) {
                    logger.info("reflection: insight REJECTED by quality gate — misdiagnosis", .{});
                    w.print("  \x1b[2m[洞察被质量门驳回（判定为误诊，未入库）]\x1b[0m\n", .{}) catch {};
                }
            }
        }
        if (store_insight) {
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
        }
    }
    logger.info("reflection: quality={d:.2} heuristic insights stored (llm dispatched in background)", .{reflection.quality_score});
    if (bus) |b| b.emit(.{ .reflection_produced = .{ .quality = @floatCast(reflection.quality_score), .background = false } });
    w.print("  [Reflection {d}ms] {s}\n", .{ util_time.nowMillis() - reflect_t0, insights }) catch {};

    resetReflectionWindow(window_queries, window_tools, window_errors, alloc);
}

/// M4: /memory — show what was injected this session and what is stored.
pub fn printMemoryStatus(mem_sys: ?*memory_mod.MemorySystem, injected_count: usize, w: *std.Io.Writer) !void {
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
pub fn runResearch(topic: []const u8, alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, configured_brave_key: ?[]const u8, mem: ?*memory_mod.MemorySystem, kg: ?*knowledge_graph.KnowledgeGraph) !void {
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
pub fn runDiagnose(
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


test "parseExtractionReply recovers fenced JSON from a prosy reply" {
    const alloc = std.testing.allocator;
    const reply =
        \\Here is the requested knowledge extraction:
        \\
        \\```json
        \\{"facts":[
        \\  {"type":"user_preference","content":"用户偏好使用中文交流，代码注释保持中文"},
        \\  {"type":"project_context","content":"ziv 的记忆提取已改为 LLM 主路径，关键词启发式仅作回退"},
        \\  {"type":"technical_fact","content":"E2E 验证通过 mock 网关在 8792 端口完成"}
        \\],
        \\ "entities":[
        \\  {"name":"ziv","type":"technology"},
        \\  {"name":"memory-extraction","type":"concept"}
        \\ ],
        \\ "relations":[
        \\  {"from":"ziv","to":"memory-extraction","relation":"implements"}
        \\ ]}
        \\```
        \\
        \\Hope this helps!
    ;
    var out = try parseExtractionReply(alloc, reply);
    defer out.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), out.facts.items.len);
    try std.testing.expectEqual(@as(usize, 2), out.entities.items.len);
    try std.testing.expectEqual(@as(usize, 1), out.relations.items.len);
    try std.testing.expectEqual(extraction_mod.FactType.user_preference, out.facts.items[0].fact_type);
    try std.testing.expectEqual(knowledge_graph.EntityType.technology, out.entities.items[0].etype);
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


test "reflection inbox drains, prints, and empties (T3.2 wiring)" {
    // v0.6.0 shipped the inbox uninit and drain uncalled — every
    // background insight was generated then silently discarded. This pins
    // the full last mile: push → drain stores a .feedback row, prints the
    // arrival, and a second drain is a no-op.
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_reflect_drain_{d}.db", .{util_time.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);
    var db = try database_mod.Database.init(allocator, path);
    defer db.deinit();
    try db.runMigrations();
    var mem = memory_mod.MemorySystem.init(allocator, &db);
    defer mem.deinit();

    reflect_inbox = .init();
    reflect_inbox_init = true;
    defer reflect_inbox_init = false;
    const owned = try allocator.dupe(u8, "insight text from the background llm");
    const out = try allocator.create(ReflectOutcome);
    out.* = .{ .insights = owned, .trigger_name = "on_query_complete", .quality = 0.5, .elapsed_ms = 42 };
    try std.testing.expect(reflect_inbox.push(out));
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    drainReflectionInbox(allocator, &mem, null, &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "insight text from the background llm") != null);
    const len_after_first = aw.written().len;
    drainReflectionInbox(allocator, &mem, null, &aw.writer);
    try std.testing.expectEqual(len_after_first, aw.written().len); // drained dry

    // P6 near-duplicate gate: the SAME insight again must NOT add a row
    // (and still prints — the print is not gated).
    const dup = try allocator.dupe(u8, "insight text from the background llm");
    const out2 = try allocator.create(ReflectOutcome);
    out2.* = .{ .insights = dup, .trigger_name = "on_query_complete", .quality = 0.5, .elapsed_ms = 10 };
    try std.testing.expect(reflect_inbox.push(out2));
    drainReflectionInbox(allocator, &mem, null, &aw.writer);
    {
        const ents = try mem.episodic_mem.retrieveRecent(10);
        defer mem.episodic_mem.freeEntries(ents);
        try std.testing.expectEqual(@as(usize, 1), ents.len);
    }
    // A genuinely different insight still stores.
    const other = try allocator.dupe(u8, "completely different insight about caching strategy tradeoffs");
    const out3 = try allocator.create(ReflectOutcome);
    out3.* = .{ .insights = other, .trigger_name = "on_query_complete", .quality = 0.5, .elapsed_ms = 10 };
    try std.testing.expect(reflect_inbox.push(out3));
    drainReflectionInbox(allocator, &mem, null, &aw.writer);
    {
        const ents = try mem.episodic_mem.retrieveRecent(10);
        defer mem.episodic_mem.freeEntries(ents);
        try std.testing.expectEqual(@as(usize, 2), ents.len);
    }
}

test "insight verdict parser: yes/no/garbage matrix" {
    try std.testing.expect(parseInsightVerdict("yes") == true);
    try std.testing.expect(parseInsightVerdict("Yes.") == true);
    try std.testing.expect(parseInsightVerdict("  no") == false);
    try std.testing.expect(parseInsightVerdict("NO") == false);
    // Both present → the FIRST one wins (strict curator answers one word).
    try std.testing.expect(parseInsightVerdict("yes, but no") == true);
    try std.testing.expect(parseInsightVerdict("no — not yes") == false);
    // Neither → null (fail-open at the caller).
    try std.testing.expect(parseInsightVerdict("perhaps") == null);
    try std.testing.expect(parseInsightVerdict("") == null);
}
