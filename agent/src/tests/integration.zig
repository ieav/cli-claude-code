/// Integration tests for modules that lack test coverage.
/// Tests use real SQLite databases and exercise full code paths.
const std = @import("std");
const time_mod = @import("../util/time.zig");
const fs_ops = @import("../util/fs_ops.zig");
const database = @import("../storage/database.zig");
const episodic = @import("../memory/episodic.zig");
const types = @import("../memory/types.zig");
const knowledge = @import("../knowledge/graph.zig");
const decision = @import("../runtime/decision_trace.zig");
const op_log = @import("../checkpoint/op_log.zig");
const mpsc = @import("../task/mpsc_queue.zig");
const streaming = @import("../llm/streaming.zig");

// ──── Database quoteString ────

test "quoteString escapes single quotes" {
    const q = try database.Database.quoteString(std.testing.allocator, "it's a test");
    defer std.testing.allocator.free(q);
    try std.testing.expectEqualStrings("'it''s a test'", q);
}

test "quoteString handles empty string" {
    const q = try database.Database.quoteString(std.testing.allocator, "");
    defer std.testing.allocator.free(q);
    try std.testing.expectEqualStrings("''", q);
}

test "quoteString handles multiple quotes" {
    const q = try database.Database.quoteString(std.testing.allocator, "a'b'c");
    defer std.testing.allocator.free(q);
    try std.testing.expectEqualStrings("'a''b''c'", q);
}

test "quoteString no quotes passthrough" {
    const q = try database.Database.quoteString(std.testing.allocator, "hello");
    defer std.testing.allocator.free(q);
    try std.testing.expectEqualStrings("'hello'", q);
}

test "quoteString SQL injection attempt" {
    const q = try database.Database.quoteString(std.testing.allocator, "'; DROP TABLE users; --");
    defer std.testing.allocator.free(q);
    try std.testing.expectEqualStrings("'''; DROP TABLE users; --'", q);
}

// ──── Episodic Memory Store ────

test "EpisodicStore store and touch" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_episodic_test_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var store = episodic.EpisodicStore.init(std.testing.allocator, &db);

    var id: [16]u8 = undefined;
    for (&id, 0..) |*byte, i| byte.* = @intCast(i);

    const entry = types.MemoryEntry{
        .id = id,
        .mem_type = .user,
        .name = "test memory",
        .description = "a test entry with 'quotes'",
        .content = "content with 'SQL injection'; DROP TABLE memories;--",
        .access_count = 0,
        .created_at = time_mod.nowMillis(),
        .updated_at = time_mod.nowMillis(),
    };

    try store.store(entry);

    // Touch should update access count without error
    store.touch(id);
    store.touch(id);
}

test "EpisodicStore store with special characters" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_episodic_special_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var store = episodic.EpisodicStore.init(std.testing.allocator, &db);

    var id: [16]u8 = undefined;
    for (&id, 0..) |*byte, i| byte.* = @intCast(i + 100);

    // Store entry with characters that would break unescaped SQL
    const entry = types.MemoryEntry{
        .id = id,
        .mem_type = .feedback,
        .name = "O'Brien's rule",
        .description = "it's fine; isn't it?",
        .content = "value'; INSERT INTO memories VALUES(0); --",
        .access_count = 0,
        .created_at = time_mod.nowMillis(),
        .updated_at = time_mod.nowMillis(),
    };

    try store.store(entry);

    // Verify DB integrity after injection attempt
    try std.testing.expect(try db.checkIntegrity());
}

// ──── Knowledge Graph ────

test "KnowledgeGraph addNode returns valid row ID" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_kg_rowid_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var kg = knowledge.KnowledgeGraph.init(std.testing.allocator, &db);

    const id1 = try kg.addNode("Zig", .technology, "test");
    const id2 = try kg.addNode("Rust", .technology, "test");
    try std.testing.expect(id1 >= 0);
    try std.testing.expect(id2 > id1);
}

test "KnowledgeGraph addNode with SQL-special characters" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_kg_sql_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var kg = knowledge.KnowledgeGraph.init(std.testing.allocator, &db);

    const id = try kg.addNode("O'Brien's Framework", .concept, "source; DROP TABLE--;--");
    try std.testing.expect(id >= 0);

    // Add edge with special relation
    const id2 = try kg.addNode("test", .technology, null);
    try kg.addEdge(id, id2, "uses it's features", 0.85);

    try std.testing.expect(try db.checkIntegrity());
}

test "KnowledgeGraph pruneWeakEdges" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_kg_prune_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var kg = knowledge.KnowledgeGraph.init(std.testing.allocator, &db);

    const a = try kg.addNode("A", .concept, null);
    const b = try kg.addNode("B", .concept, null);
    const c = try kg.addNode("C", .concept, null);

    try kg.addEdge(a, b, "strong", 0.9);
    try kg.addEdge(a, c, "weak", 0.1);

    // φ-based pruning: edges below φ × max_weight (0.618 × 0.9 ≈ 0.556) are removed
    _ = try kg.pruneWeakEdges(0.9);
    try std.testing.expect(try db.checkIntegrity());
}

// ──── Decision Trace ────

test "DecisionTrace addStep and getSteps" {
    const allocator = std.testing.allocator;
    const query = try allocator.dupe(u8, "test query");

    var trace = decision.DecisionTrace.init(allocator, query);
    defer trace.deinit();

    const input = try allocator.dupe(u8, "input");
    const output = try allocator.dupe(u8, "output");
    const reasoning = try allocator.dupe(u8, "because");

    try trace.addStep(.{
        .step_id = 1,
        .phase = .memory_retrieval,
        .timestamp = time_mod.nowMillis(),
        .input = input,
        .output = output,
        .reasoning = reasoning,
        .confidence = 0.9,
        .duration_ms = 10,
        .alternatives = &.{},
        .dependencies = &.{},
    });

    try std.testing.expectEqual(@as(usize, 1), trace.getSteps().len);
}

test "DecisionTrace findWeakSteps filters by threshold" {
    const allocator = std.testing.allocator;
    const query = try allocator.dupe(u8, "test");

    var trace = decision.DecisionTrace.init(allocator, query);
    defer trace.deinit();

    // Add a strong step (confidence 0.9)
    const strong_input = try allocator.dupe(u8, "s_in");
    const strong_output = try allocator.dupe(u8, "s_out");
    const strong_reason = try allocator.dupe(u8, "s_reason");

    try trace.addStep(.{
        .step_id = 1,
        .phase = .tool_selection,
        .timestamp = time_mod.nowMillis(),
        .input = strong_input,
        .output = strong_output,
        .reasoning = strong_reason,
        .confidence = 0.9,
        .duration_ms = 5,
        .alternatives = &.{},
        .dependencies = &.{},
    });

    // Add a weak step (confidence 0.3)
    const weak_input = try allocator.dupe(u8, "w_in");
    const weak_output = try allocator.dupe(u8, "w_out");
    const weak_reason = try allocator.dupe(u8, "w_reason");

    try trace.addStep(.{
        .step_id = 2,
        .phase = .tool_execution,
        .timestamp = time_mod.nowMillis(),
        .input = weak_input,
        .output = weak_output,
        .reasoning = weak_reason,
        .confidence = 0.3,
        .duration_ms = 100,
        .alternatives = &.{},
        .dependencies = &.{},
    });

    // φ threshold ~0.618: only the weak step should be found
    const weak = trace.findWeakSteps(0.618);
    defer std.testing.allocator.free(weak);
    try std.testing.expectEqual(@as(usize, 1), weak.len);
    // Indices into the step list; the weak step is step #2.
    try std.testing.expectEqual(@as(usize, 1), weak[0]);
    try std.testing.expectEqual(@as(u32, 2), trace.getSteps()[weak[0]].step_id);
}

test "DecisionTrace totalDurationMs" {
    const allocator = std.testing.allocator;
    const query = try allocator.dupe(u8, "test");

    var trace = decision.DecisionTrace.init(allocator, query);
    defer trace.deinit();

    const dur = trace.totalDurationMs();
    try std.testing.expect(dur >= 0);

    trace.complete();
    const dur2 = trace.totalDurationMs();
    try std.testing.expect(dur2 >= dur);
}

test "DecisionTrace getStepByPhase" {
    const allocator = std.testing.allocator;
    const query = try allocator.dupe(u8, "test");

    var trace = decision.DecisionTrace.init(allocator, query);
    defer trace.deinit();

    const inp = try allocator.dupe(u8, "in");
    const out = try allocator.dupe(u8, "out");
    const reason = try allocator.dupe(u8, "r");

    try trace.addStep(.{
        .step_id = 1,
        .phase = .llm_generation,
        .timestamp = time_mod.nowMillis(),
        .input = inp,
        .output = out,
        .reasoning = reason,
        .confidence = 0.95,
        .duration_ms = 50,
        .alternatives = &.{},
        .dependencies = &.{},
    });

    const step = trace.getStepByPhase(.llm_generation);
    try std.testing.expect(step != null);
    try std.testing.expectEqual(@as(u32, 1), step.?.step_id);

    try std.testing.expect(trace.getStepByPhase(.reflection_trigger) == null);
}

// ──── Operation Log ────

test "OperationLog record and canRollbackTo" {
    var log = op_log.OperationLog.init(std.testing.allocator);
    defer log.deinit();

    var snap_id: [16]u8 = undefined;
    for (&snap_id, 0..) |*byte, i| byte.* = @intCast(i);

    const op_id = try log.record("FileEdit", "path:/tmp/test.txt", "ok", snap_id, true);
    try std.testing.expect(log.canRollbackTo(op_id));
    try std.testing.expect(!log.canRollbackTo(snap_id)); // not an op_id
}

test "OperationLog non-rollback-safe operation" {
    var log = op_log.OperationLog.init(std.testing.allocator);
    defer log.deinit();

    const op_id = try log.record("Bash", "rm -rf /", "error", null, false);
    try std.testing.expect(!log.canRollbackTo(op_id));
}

test "OperationLog getOperationsSince" {
    var log = op_log.OperationLog.init(std.testing.allocator);
    defer log.deinit();

    var snap1: [16]u8 = undefined;
    for (&snap1, 0..) |*byte, i| byte.* = @intCast(i);
    var snap2: [16]u8 = undefined;
    for (&snap2, 0..) |*byte, i| byte.* = @intCast(i + 100);

    _ = try log.record("FileRead", "path:a.txt", "ok", snap1, true);
    _ = try log.record("FileEdit", "path:b.txt", "ok", snap2, true);
    _ = try log.record("Grep", "pattern:test", "ok", null, false);

    const ops = log.getOperationsSince(snap1);
    try std.testing.expectEqual(@as(usize, 3), ops.len);

    const ops2 = log.getOperationsSince(snap2);
    try std.testing.expectEqual(@as(usize, 2), ops2.len);
}

test "OperationLog rollbackPoints" {
    var log = op_log.OperationLog.init(std.testing.allocator);
    defer log.deinit();

    var snap: [16]u8 = undefined;
    for (&snap, 0..) |*byte, i| byte.* = @intCast(i);

    _ = try log.record("FileEdit", "path:a", "ok", snap, true);
    _ = try log.record("Bash", "cmd:ls", "ok", null, false);
    _ = try log.record("FileWrite", "path:b", "ok", snap, true);

    var points = log.rollbackPoints();
    defer points.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), points.items.len);
}

// ──── Unbounded MPSCQueue ────

test "MPSCQueue init push pop deinit" {
    var queue = try mpsc.MPSCQueue(u32).init(std.testing.allocator);
    defer queue.deinit();

    try queue.push(42);
    try queue.push(99);
    try queue.push(7);

    const v1 = queue.pop();
    try std.testing.expect(v1 != null);
    try std.testing.expectEqual(@as(u32, 42), v1.?);

    const v2 = queue.pop();
    try std.testing.expect(v2 != null);
    try std.testing.expectEqual(@as(u32, 99), v2.?);

    const v3 = queue.pop();
    try std.testing.expect(v3 != null);
    try std.testing.expectEqual(@as(u32, 7), v3.?);

    try std.testing.expect(queue.pop() == null);
}

test "MPSCQueue empty pop returns null" {
    var queue = try mpsc.MPSCQueue(u32).init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(queue.pop() == null);
}

test "MPSCQueue deinit drains remaining" {
    var queue = try mpsc.MPSCQueue(u32).init(std.testing.allocator);
    try queue.push(1);
    try queue.push(2);
    try queue.push(3);
    // deinit should free all nodes including stub without leaks
    queue.deinit();
}

// ──── SSE Streaming Parser ────

test "SSEParser multi-event" {
    var parser = streaming.SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const input = "event: message\ndata: hello\n\nevent: message\ndata: world\n\n";
    const count = try parser.feed(input);
    try std.testing.expectEqual(@as(usize, 2), count);

    const events = parser.drain();
    defer std.testing.allocator.free(events);
    defer {
        for (events) |ev| {
            if (ev.event) |s| std.testing.allocator.free(s);
            if (ev.data) |s| std.testing.allocator.free(s);
            if (ev.id) |s| std.testing.allocator.free(s);
        }
    }
    try std.testing.expectEqualStrings("hello", events[0].data.?);
    try std.testing.expectEqualStrings("world", events[1].data.?);
}

test "SSEParser partial chunk then complete" {
    var parser = streaming.SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    // Feed partial event
    const count1 = try parser.feed("event: message\nda");
    try std.testing.expectEqual(@as(usize, 0), count1);

    // Feed remaining
    const count2 = try parser.feed("ta: hello\n\n");
    try std.testing.expectEqual(@as(usize, 1), count2);
}

test "SSEParser ignores comments" {
    var parser = streaming.SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const input = ": this is a comment\nevent: ping\ndata: pong\n\n";
    const count = try parser.feed(input);
    try std.testing.expectEqual(@as(usize, 1), count);

    const events = parser.drain();
    defer std.testing.allocator.free(events);
    defer {
        for (events) |ev| {
            if (ev.event) |s| std.testing.allocator.free(s);
            if (ev.data) |s| std.testing.allocator.free(s);
            if (ev.id) |s| std.testing.allocator.free(s);
        }
    }
    try std.testing.expectEqualStrings("pong", events[0].data.?);
}

test "SSEParser handles CRLF line endings" {
    var parser = streaming.SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const input = "event: msg\r\ndata: crlf\r\n\r\n";
    const count = try parser.feed(input);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "SSEParser event without data is ignored" {
    var parser = streaming.SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const input = "event: ping\nid: 42\n\n";
    const count = try parser.feed(input);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "SSEParser retry field" {
    var parser = streaming.SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const input = "retry: 5000\ndata: test\n\n";
    const count = try parser.feed(input);
    try std.testing.expectEqual(@as(usize, 1), count);

    const events = parser.drain();
    defer std.testing.allocator.free(events);
    defer {
        for (events) |ev| {
            if (ev.event) |s| std.testing.allocator.free(s);
            if (ev.data) |s| std.testing.allocator.free(s);
            if (ev.id) |s| std.testing.allocator.free(s);
        }
    }
    try std.testing.expect(events[0].retry != null);
    try std.testing.expectEqual(@as(u32, 5000), events[0].retry.?);
}

// ──── Database integrity ────

test "Database full migration round-trip" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_full_migration_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    // Verify all tables exist by inserting into each
    try db.exec("INSERT INTO conversations (id, started_at, model, provider) VALUES (X'00', 1, 'gpt-4o', 'openai')");
    try db.exec("INSERT INTO messages (conversation_id, role, content, timestamp) VALUES (X'00', 'user', 'hello', 1)");
    try db.exec("INSERT INTO embeddings (entity_type, entity_id, embedding, model, dimensions, created_at) VALUES ('test', '1', X'00', 'test', 1, 1)");

    try std.testing.expect(try db.checkIntegrity());
}
