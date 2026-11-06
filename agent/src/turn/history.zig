/// History management (P1 extraction from repl.zig — pure move):
/// token estimation, φ/auto compaction, key-fact preservation, tool-pair
/// repair, content-block deep copy, clear/undo primitives.
const std = @import("std");
const llm = @import("../llm/mod.zig");
const compaction = @import("../llm/compaction.zig");
const op_log = @import("../checkpoint/op_log.zig");
const logger = @import("../util/log.zig");
const tokens_mod = @import("../util/tokens.zig");
const json_tree = @import("../util/json_tree.zig");
const util_time = @import("../util/time.zig");
const registry = @import("../tools/registry.zig");
const config_mod = @import("../config.zig");
const repl_mod = @import("../repl.zig");
const ModelSwitcher = repl_mod.ModelSwitcher;
const swapMemoryBlockText = repl_mod.swapMemoryBlockText;
const appendSystemBlock = repl_mod.appendSystemBlock;

/// Deep-copy content blocks so history owns every string and JSON tree.
pub fn cloneContentBlocks(alloc: std.mem.Allocator, blocks: []const llm.ContentBlock) ![]llm.ContentBlock {
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
                .input = try json_tree.dupeJsonValue(alloc, tu.input),
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

pub fn freeContentBlocks(alloc: std.mem.Allocator, blocks: []const llm.ContentBlock) void {
    for (blocks) |b| {
        switch (b) {
            .text => |t| alloc.free(t),
            .thinking => |t| alloc.free(t),
            .tool_use => |tu| {
                alloc.free(tu.id);
                alloc.free(tu.name);
                json_tree.freeJsonValue(alloc, tu.input);
            },
            .tool_result => |tr| {
                alloc.free(tr.tool_use_id);
                alloc.free(tr.content);
            },
        }
    }
    alloc.free(@constCast(blocks));
}

/// Estimate total tokens across all history messages.
pub fn estimateHistoryTokens(history: []const llm.Message) u32 {
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
pub fn estimateTextTokens(text: []const u8) u32 {
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
pub fn maybeCompact(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer, file_writer: *std.Io.File.Writer, log: *op_log.OperationLog, facts: *?[]u8, model: []const u8, backend: llm.BackendType) u32 {
    const current_tokens = estimateHistoryTokens(history.items);
    // T4.1: the ceiling follows the ACTIVE model's context estimate, not
    // the old hardcoded 128K — an 8K local model now compacts at ~5K
    // instead of overflowing first.
    const ceiling = llm.provider.contextEstimate(model, backend);
    if (!compaction.needsCompaction(current_tokens, ceiling)) return current_tokens;

    applyFactsUpdate(history, facts, alloc, compactHistoryImpl(history, alloc, facts.*));
    log.bumpEpoch();
    // Auto-compact fires MID-TURN (region up) as often as between turns —
    // the region-aware `w` callers pass handles both without overwriting
    // the input row (verbatim when the region is down).
    std.Io.Writer.print(w, "  [Context auto-compacted: {d} messages remaining]\n", .{history.items.len}) catch {};
    std.Io.File.Writer.flush(file_writer) catch {};
    return estimateHistoryTokens(history.items);
}

/// Force compact history via LLM summary (used by /compact) — Claude-style:
/// the current provider summarizes the conversation and the summary replaces
/// the history, so earlier context is condensed instead of dropped. On any
/// failure the history is left untouched and the user is pointed at
/// /compact phi (truncation) rather than silently losing context.
pub fn compactHistory(
    history: *std.ArrayList(llm.Message),
    switcher: *ModelSwitcher,
    log: *op_log.OperationLog,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    total_in: *u64,
    total_out: *u64,
    /// Optional user focus instructions appended to the summary prompt
    /// ("/compact focus on X" — Claude-Code parity).
    focus: []const u8,
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
    // v0.7.7: keep the most recent messages VERBATIM — only the older
    // conversation is summarized (Claude-Code parity; the old version
    // replaced everything, losing the live exchange you just had).
    const KEEP_RECENT: usize = 4;
    const summarize_to = if (before_msgs > KEEP_RECENT + 2) before_msgs - KEEP_RECENT else before_msgs;
    try std.Io.Writer.print(w, "  Compacting: summarizing {d} messages, keeping the last {d} verbatim (~{d} tokens total)…\n", .{ summarize_to - 1, before_msgs - summarize_to, before_tokens });
    std.Io.File.Writer.flush(file_writer) catch {};

    const transcript = compaction.renderTranscript(alloc, history.items[1..summarize_to]) catch |err| {
        try std.Io.Writer.print(w, "  Compaction failed: {}\n  History untouched — try /compact phi.\n\n", .{err});
        return;
    };
    defer alloc.free(transcript);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    defer alloc.free(sys_blocks);
    if (focus.len > 0) {
        sys_blocks[0] = .{ .text = try alloc.print("{s}\n\nThe user additionally asks to prioritize:\n{s}", .{ compaction.SUMMARY_INSTRUCTION, focus }) };
    } else {
        sys_blocks[0] = .{ .text = compaction.SUMMARY_INSTRUCTION };
    }
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

    // Move the kept-recent tail out (clearHistory frees everything),
    // then rebuild: system + summary + recent tail.
    {
        var tail: std.ArrayList(llm.Message) = .empty;
        defer {
            // On success the messages moved into history; on the error
            // paths below they are freed here.
            for (tail.items) |m| freeMessage(m, alloc);
            tail.deinit(alloc);
        }
        for (history.items[summarize_to..]) |m| {
            const dupe = dupeMessage(alloc, m) catch {
                try std.Io.Writer.writeAll(w, "  Compaction failed (copy recent turns).\n  History untouched — try /compact phi.\n\n");
                return;
            };
            tail.append(alloc, dupe) catch {
                freeMessage(dupe, alloc);
                try std.Io.Writer.writeAll(w, "  Compaction failed (copy recent turns).\n  History untouched — try /compact phi.\n\n");
                return;
            };
        }
        try replaceHistoryWithSummary(history, alloc, summary.items);
        for (tail.items) |m| {
            try history.append(alloc, m);
        }
        // Ownership moved into history: neutralize the defer's cleanup.
        tail.clearRetainingCapacity();
    }
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
pub fn compactHistoryPhi(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer, log: *op_log.OperationLog, facts: *?[]u8) !void {
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
pub fn applyFactsUpdate(history: *std.ArrayList(llm.Message), facts: *?[]u8, alloc: std.mem.Allocator, new_facts: ?[]u8) void {
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
    "决定",
    "改用",
    "换成",
    "选定",
    "decision",
    "switch to",
    "instead",
    "let's",
    "we'll",
    "use ",
    "必须",
    "不要",
    "禁止",
    "不能",
    "must",
    "never",
    "always",
    "require",
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
pub fn compactHistoryImpl(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, existing_facts: ?[]const u8) ?[]u8 {
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
/// Deep-copy one message (blocks + their strings) — used by /compact's
/// keep-recent-tail path.
fn dupeMessage(alloc: std.mem.Allocator, msg: llm.Message) !llm.Message {
    const blocks = try cloneContentBlocks(alloc, msg.content);
    return .{ .role = msg.role, .content = blocks, .timestamp = msg.timestamp };
}

pub fn freeMessage(msg: llm.Message, alloc: std.mem.Allocator) void {
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
pub fn repairToolPairing(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) void {
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

pub fn clearHistory(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) void {
    while (history.items.len > 1) {
        const msg = history.orderedRemove(1);
        freeMessage(msg, alloc);
    }
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
