/// Agent-dispatch E2E (T6.4 default-on re-validation) — real HTTP against
/// a mock gateway on 127.0.0.1, exercising the exact machinery behind the
/// 2026-10-30 intermittent hang (TODO P38): worker threads, per-worker
/// private providers + Io, watchdog-armed requests, fail-fast retry, and
/// the merge report. Two scenarios:
///
///   1. happy — two tasks fan out concurrently, each subagent completes in
///      one round trip, the merge contains both reports, bounded time;
///   2. stall — the gateway accepts the request and NEVER answers (the P38
///      failure mode). The per-request watchdog — shortened via
///      ZIV_LLM_TIMEOUT_MS for the test, restored afterwards — kills the
///      socket, the subagent fails, the fail-fast retry fails, and the
///      dispatch STILL returns merged output in bounded time. An agent-tool
///      turn can no longer hang the session.
///
/// Dispatch allocations use smp_allocator (production shape): the
/// subagent loop intentionally never frees response DOMs inside the loop
/// (bounded by max_turns, same accepted trade as the reflection worker),
/// which the testing allocator would flag as a leak.
const std = @import("std");
const runtime_registry = @import("../tools/runtime_registry.zig");
const registry = @import("../tools/registry.zig");
const agent_dispatch = @import("../tools/agent_dispatch.zig");
const time_mod = @import("../util/time.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// ── mock gateway ─────────────────────────────────────────────────────

const MockMode = enum { happy, stall, gate_yes, gate_no };

const MockServer = struct {
    mode: MockMode,
    /// 0 until the accept thread has bound a listener; the test spins on it.
    port: u16 = 0,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    served: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Fixed port window with probing — std.Io.net has no getsockname helper
/// for a bound port, so we walk a small window until one listens.
fn listenOnSomePort(io: std.Io, base: u16) !struct { server: std.Io.net.Server, port: u16 } {
    var port: u16 = base;
    while (port < base + 16) : (port += 1) {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        if (addr.listen(io, .{ .reuse_address = true })) |s| {
            return .{ .server = s, .port = port };
        } else |e| switch (e) {
            error.AddressInUse => continue,
            else => return e,
        }
    }
    return error.AddressInUse;
}

/// Non-streaming chat completion body the ziv openai provider parses.
const happy_body =
    \\{"id":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"MOCK_SUBAGENT_OK"},"finish_reason":"stop"}],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}
;

/// Serve connections until `running` flips. The request is always READ
/// inline under the accept thread's own Io (never shared cross-thread —
/// see agent_dispatch.ProviderStorage for why); happy responses are also
/// written inline (each subagent blocks on its own response, the kernel
/// backlog holds the rest). Stall connections are handed to a DETACHED
/// parker thread so the accept loop stays free for the retry's second
/// connection (parking inline dead-balls the backlog and the test's
/// served-count).
fn mockServe(server: *MockServer) void {
    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();
    var listener = listenOnSomePort(io, 18810) catch return;
    server.port = listener.port; // published before the accept loop starts
    while (server.running.load(.acquire)) {
        const stream = listener.server.accept(io) catch break; // listener closed → exit
        if (!readRequest(stream, io)) {
            stream.close(io);
            continue;
        }
        _ = server.served.fetchAdd(1, .monotonic);
        switch (server.mode) {
            .happy, .gate_yes, .gate_no => {
                writeResponse(stream, io, server.mode);
                stream.close(io);
            },
            .stall => {
                const t = std.Thread.spawn(.{}, stallParker, .{ server, stream }) catch {
                    stream.close(io);
                    continue;
                };
                t.detach();
            },
        }
    }
    listener.server.deinit(io);
}

/// P38 shape: the request was consumed, the connection now stays ALIVE but
/// SILENT — never a byte back. The client-side watchdog shutdown(2)s its
/// end; we park on the running flag so the thread exits (and the fd
/// closes) promptly at test teardown, under the parker's OWN Io.
fn stallParker(server: *MockServer, stream: std.Io.net.Stream) void {
    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    const io = io_state.io();
    defer {
        stream.close(io);
        io_state.deinit();
    }
    while (server.running.load(.acquire)) {
        time_mod.sleepMs(100);
    }
}

/// Consume headers + Content-Length body (std.http always sends CL for a
/// complete body; chunked would hang this loop — not our client's shape).
fn readRequest(stream: std.Io.net.Stream, io: std.Io) bool {
    var rbuf: [8192]u8 = undefined;
    var fr = stream.reader(io, &rbuf);
    const r = &fr.interface;
    var buf: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    var header_end: usize = 0;
    while (len < buf.len) {
        const chunk = r.peekGreedy(1) catch return false; // EOF / error
        if (chunk.len == 0) return false;
        const n = @min(chunk.len, buf.len - len);
        @memcpy(buf[len..][0..n], chunk[0..n]);
        len += n;
        r.toss(n);
        if (header_end == 0) {
            if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |he| {
                header_end = he + 4;
            } else continue;
        }
        const cl = parseContentLength(buf[0..header_end]) orelse return false;
        if (len >= header_end + cl) return true;
    }
    return false;
}

fn writeResponse(stream: std.Io.net.Stream, io: std.Io, mode: MockMode) void {
    const body: []const u8 = switch (mode) {
        .gate_yes => "{\"id\":\"mock\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"yes\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,\"total_tokens\":4}}",
        .gate_no => "{\"id\":\"mock\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"no\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,\"total_tokens\":4}}",
        else => happy_body,
    };
    var rsp: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&rsp, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
    writeAll(stream, io, head);
    writeAll(stream, io, body);
}

fn writeAll(stream: std.Io.net.Stream, io: std.Io, bytes: []const u8) void {
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    std.Io.Writer.writeAll(&w.interface, bytes) catch return;
    std.Io.Writer.flush(&w.interface) catch return;
}

fn parseContentLength(headers: []const u8) ?usize {
    const want = "content-length:";
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len <= want.len) continue;
        var match = true;
        for (want, 0..) |c, i| {
            if (std.ascii.toLower(line[i]) != c) {
                match = false;
                break;
            }
        }
        if (match) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[want.len..], " \t"), 10) catch null;
        }
    }
    return null;
}

// ── shared dispatch scaffolding ──────────────────────────────────────

fn runDispatch(
    port: u16,
    concurrency: u32,
    tasks: []const []const u8,
) !registry.ToolResult {
    const alloc = std.heap.smp_allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();

    var reg = runtime_registry.RuntimeRegistry.init(alloc);
    defer reg.deinit();

    const base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/v1", .{port});
    defer alloc.free(base_url);
    var conc = concurrency;
    var ctx = agent_dispatch.DispatchCtx{
        .alloc = alloc,
        .io = io_state.io(),
        .tools = &reg,
        .backend = .openai,
        .model = "mock-model",
        .api_key = "test-key",
        .base_url = base_url,
        .ollama_host = "",
        .concurrency = &conc,
        .bus = null,
    };

    // Input {"tasks":[…]} on an arena — the strings must outlive the call.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var arr = std.json.Array.init(a); // managed: append takes only the value
    for (tasks) |t| try arr.append(.{ .string = t });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "tasks", .{ .array = arr });

    return agent_dispatch.executeWithCtx(@ptrCast(&ctx), alloc, .{ .object = obj }, io_state.io());
}

/// Spin until the server thread has bound a port (or bail after 5s).
fn waitReady(server: *MockServer) !u16 {
    const t0 = time_mod.nowMillis();
    while (time_mod.nowMillis() - t0 < 5_000) {
        if (server.port != 0) return server.port;
        time_mod.sleepMs(10);
    }
    return error.MockServerNotReady;
}

// ── tests ────────────────────────────────────────────────────────────

test "agent dispatch E2E happy path: 2 tasks, mock gateway, no hang" {
    const alloc = std.heap.smp_allocator;
    var server = MockServer{ .mode = .happy };
    const th = try std.Thread.spawn(.{}, mockServe, .{&server});
    th.detach();
    const port = try waitReady(&server);
    defer server.running.store(false, .release);

    const t0 = time_mod.nowMillis();
    const result = try runDispatch(port, 2, &.{ "count the zig files", "check the grep tool" });
    const elapsed = time_mod.nowMillis() - t0;

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## 子任务 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## 子任务 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MOCK_SUBAGENT_OK") != null);
    try std.testing.expectEqual(@as(u32, 2), server.served.load(.monotonic));
    // Bounded: two local round trips are sub-second; generous CI slack.
    try std.testing.expect(elapsed < 30_000);
    alloc.free(result.output);
}

test "agent dispatch E2E stall: watchdog kills, retry fails, dispatch still returns" {
    const alloc = std.heap.smp_allocator;
    // Shorten the request watchdog for this test only. Save/restore so a
    // user-set value survives and no other test sees ours (the watchdog
    // reads env per request, deliberately uncached; tests run sequentially).
    const saved: ?[:0]u8 = if (std.c.getenv("ZIV_LLM_TIMEOUT_MS")) |v| blk: {
        const old = std.mem.sliceTo(v, 0);
        const buf = std.heap.smp_allocator.allocSentinel(u8, old.len, 0) catch break :blk null;
        @memcpy(buf[0..old.len], old);
        break :blk buf;
    } else null;
    _ = setenv("ZIV_LLM_TIMEOUT_MS", "1500", 1);
    defer {
        if (saved) |s| {
            _ = setenv("ZIV_LLM_TIMEOUT_MS", s.ptr, 1);
            std.heap.smp_allocator.free(s);
        } else {
            _ = unsetenv("ZIV_LLM_TIMEOUT_MS");
        }
    }

    var server = MockServer{ .mode = .stall };
    const th = try std.Thread.spawn(.{}, mockServe, .{&server});
    th.detach();
    const port = try waitReady(&server);
    defer server.running.store(false, .release);

    const t0 = time_mod.nowMillis();
    const result = try runDispatch(port, 1, &.{"probe the dead gateway"});
    const elapsed = time_mod.nowMillis() - t0;

    // The dispatch RETURNS (this is the P38 regression lock): the job
    // failed, the fail-fast retry failed, the merge reports it — no hang.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "## 子任务 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(子代理执行失败)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "取消") == null); // not a cancel path
    // Two stalls: initial attempt + the one fail-fast retry (~1.5s each,
    // plus the 1s backoff). Far under the 180s default watchdog.
    try std.testing.expectEqual(@as(u32, 2), server.served.load(.monotonic));
    try std.testing.expect(elapsed < 30_000);
    alloc.free(result.output);
}

// ── P2 hybrid compaction E2E ─────────────────────────────────────────

test "hybrid compact E2E: mock gateway summarizes, layout is three-tier" {
    const alloc = std.heap.smp_allocator;
    var server = MockServer{ .mode = .happy };
    const th = try std.Thread.spawn(.{}, mockServe, .{&server});
    th.detach();
    const port = try waitReady(&server);
    defer server.running.store(false, .release);

    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const turn_history = @import("../turn/history.zig");
    const model_switcher = @import("../session/model_switcher.zig");
    const config_mod = @import("../config.zig");
    const op_log = @import("../checkpoint/op_log.zig");

    var settings = config_mod.Settings{};
    settings.default_model = "gpt-mock-e2e"; // gpt- prefix → openai backend
    settings.api_keys.openai = "test-key";
    settings.api_keys.openai_base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/v1", .{port});
    var switcher = model_switcher.ModelSwitcher.init(settings, io);
    defer switcher.deinit();

    // [system] + 12 × ([user] [assistant] [user tool_result 5 KiB]).
    const llm = @import("../llm/mod.zig");
    var history: std.ArrayList(llm.Message) = .empty;
    {
        const sb = try alloc.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = sb, .timestamp = 0 });
        var round: usize = 0;
        while (round < 12) : (round += 1) {
            var ub: [64]u8 = undefined;
            const ut = try std.fmt.bufPrint(&ub, "user question round {d}", .{round});
            const ubb = try alloc.alloc(llm.ContentBlock, 1);
            ubb[0] = .{ .text = try alloc.dupe(u8, ut) };
            try history.append(alloc, .{ .role = .user, .content = ubb, .timestamp = 0 });
            const abb = try alloc.alloc(llm.ContentBlock, 1);
            abb[0] = .{ .text = try alloc.dupe(u8, "assistant answer") };
            try history.append(alloc, .{ .role = .assistant, .content = abb, .timestamp = 0 });
            const fat = try alloc.alloc(u8, 5 * 1024);
            @memset(fat, 'x');
            const trb = try alloc.alloc(llm.ContentBlock, 1);
            trb[0] = .{ .tool_result = .{ .tool_use_id = try alloc.dupe(u8, "t0"), .content = fat } };
            try history.append(alloc, .{ .role = .user, .content = trb, .timestamp = 0 });
        }
    }
    defer {
        for (history.items) |m| turn_history.freeMessage(m, alloc);
        history.deinit(alloc);
    }
    const before_tokens = turn_history.estimateHistoryTokens(history.items);

    var log = op_log.OperationLog.init(alloc);
    defer log.deinit();
    const null_file = try std.Io.Dir.cwd().openFile(io, "/dev/null", .{ .mode = .write_only });
    defer null_file.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = std.Io.File.Writer.initStreaming(null_file, io, &wbuf);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var total_in: u64 = 0;
    var total_out: u64 = 0;

    try turn_history.compactHistory(&history, &switcher, &log, alloc, &aw.writer, &fw, &total_in, &total_out, "");

    // Exactly one summary call hit the mock gateway.
    try std.testing.expectEqual(@as(u32, 1), server.served.load(.monotonic));
    // Three-tier layout: system kept, summary present, last 5 rounds verbatim.
    try std.testing.expect(history.items[0].role == .system);
    var has_summary = false;
    for (history.items) |m| for (m.content) |b| {
        if (b == .text and std.mem.indexOf(u8, b.text, "Here is a summary") != null) has_summary = true;
    };
    try std.testing.expect(has_summary);
    var kept_rounds: usize = 0;
    for (history.items) |m| for (m.content) |b| {
        if (b == .text and std.mem.indexOf(u8, b.text, "user question round") != null) kept_rounds += 1;
    };
    try std.testing.expectEqual(@as(usize, 5), kept_rounds);
    // Tier 3: kept tool results carry the slim marker; tokens dropped hard.
    var slim_markers: usize = 0;
    for (history.items) |m| for (m.content) |b| {
        if (b == .tool_result and std.mem.indexOf(u8, b.tool_result.content, "字节") != null) slim_markers += 1;
    };
    try std.testing.expectEqual(@as(usize, 5), slim_markers);
    const after_tokens = turn_history.estimateHistoryTokens(history.items);
    try std.testing.expect(after_tokens * 10 < before_tokens * 4);
    try std.testing.expect(total_in + total_out > 0); // usage accounted
    alloc.free(settings.api_keys.openai_base_url.?);
}

// ── P5 insight quality gate E2E ──────────────────────────────────────

fn runReflectionWithMockGate(
    comptime mode: MockMode,
    comptime expect_stored: bool,
) !void {
    const alloc = std.heap.smp_allocator;
    var server = MockServer{ .mode = mode };
    const th = try std.Thread.spawn(.{}, mockServe, .{&server});
    th.detach();
    const port = try waitReady(&server);
    defer server.running.store(false, .release);

    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const memory_ops = @import("../session/memory_ops.zig");
    const reflection_mod = @import("../memory/reflection.zig");
    const memory_mod = @import("../memory/mod.zig");
    const model_switcher = @import("../session/model_switcher.zig");
    const config_mod = @import("../config.zig");
    const fs_ops = @import("../util/fs_ops.zig");
    const database_mod = @import("../storage/database.zig");
    const time_mod2 = @import("../util/time.zig");

    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&pbuf, "/tmp/ziv_gate_{d}.db", .{time_mod2.nowMillis()});
    defer _ = fs_ops.deleteFile(db_path);
    var db = try database_mod.Database.init(alloc, db_path);
    defer db.deinit();
    try db.runMigrations();
    var mem = memory_mod.MemorySystem.init(alloc, &db);
    defer mem.deinit();

    var settings = config_mod.Settings{};
    settings.default_model = "gpt-mock-e2e";
    settings.api_keys.openai = "test-key";
    settings.api_keys.openai_base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/v1", .{port});
    var switcher = model_switcher.ModelSwitcher.init(settings, io);
    defer switcher.deinit();
    const prov = try switcher.getProvider();
    defer alloc.free(settings.api_keys.openai_base_url.?);

    var reflector = reflection_mod.ReflectionEngine.init(alloc);
    defer reflector.deinit();
    // Actionable window: error rate 1/2 > 38.2% → heuristic insight fires.
    var window: std.ArrayList([]u8) = .empty;
    defer {
        for (window.items) |q| alloc.free(q);
        window.deinit(alloc);
    }
    try window.append(alloc, try alloc.dupe(u8, "query one"));
    try window.append(alloc, try alloc.dupe(u8, "query two"));
    var tools: u32 = 0;
    var errors: u32 = 1;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    memory_ops.runReflection(&reflector, &mem, &window, &tools, &errors, alloc, &aw.writer, prov, .full, null, null, true);

    // Exactly one gate round trip.
    try std.testing.expectEqual(@as(u32, 1), server.served.load(.monotonic));
    const ents = try mem.episodic_mem.retrieveRecent(10);
    defer mem.episodic_mem.freeEntries(ents);
    if (expect_stored) {
        try std.testing.expectEqual(@as(usize, 1), ents.len);
        try std.testing.expect(std.mem.indexOf(u8, ents[0].content, "失败率") != null);
    } else {
        try std.testing.expectEqual(@as(usize, 0), ents.len);
    }
}

test "P5 quality gate: mock curator says no → misdiagnosis never stored" {
    try runReflectionWithMockGate(.gate_no, false);
}

test "P5 quality gate: mock curator says yes → insight stored" {
    try runReflectionWithMockGate(.gate_yes, true);
}

// ── P2.6 bounded exit extraction E2E ─────────────────────────────────

test "bounded exit extraction: stalled gateway falls back within deadline" {
    const alloc = std.heap.smp_allocator;
    var server = MockServer{ .mode = .stall };
    const th = try std.Thread.spawn(.{}, mockServe, .{&server});
    th.detach();
    const port = try waitReady(&server);
    defer server.running.store(false, .release);

    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const memory_ops = @import("../session/memory_ops.zig");
    const memory_mod = @import("../memory/mod.zig");
    const model_switcher = @import("../session/model_switcher.zig");
    const config_mod = @import("../config.zig");
    const llm = @import("../llm/mod.zig");
    const fs_ops = @import("../util/fs_ops.zig");
    const database_mod = @import("../storage/database.zig");
    const time_mod2 = @import("../util/time.zig");

    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&pbuf, "/tmp/ziv_bex_{d}.db", .{time_mod2.nowMillis()});
    defer _ = fs_ops.deleteFile(db_path);
    var db = try database_mod.Database.init(alloc, db_path);
    defer db.deinit();
    try db.runMigrations();
    var mem = memory_mod.MemorySystem.init(alloc, &db);
    defer mem.deinit();

    var settings = config_mod.Settings{};
    settings.default_model = "gpt-mock-e2e";
    settings.api_keys.openai = "test-key";
    settings.api_keys.openai_base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/v1", .{port});
    var switcher = model_switcher.ModelSwitcher.init(settings, io);
    defer switcher.deinit();

    // Keyword-rich history: the heuristic fallback must find the 决定-line.
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| {
            for (m.content) |b| switch (b) {
                .text => |t| alloc.free(t),
                else => {},
            };
            alloc.free(@constCast(m.content));
        }
        history.deinit(alloc);
    }
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = b, .timestamp = 0 });
        const b2 = try alloc.alloc(llm.ContentBlock, 1);
        b2[0] = .{ .text = try alloc.dupe(u8, "我们决定使用 sqlite WAL 模式，数据库文件是 /data/app.db，不要改成 delete 模式") };
        try history.append(alloc, .{ .role = .user, .content = b2, .timestamp = 1 });
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const cfg = memory_ops.backgroundLlmConfig(alloc, &switcher);
    const t0 = time_mod2.nowMillis();
    memory_ops.extractSessionMemoriesBounded(&mem, null, &history, null, &aw.writer, null, alloc, cfg, 16384, 1500);
    const elapsed = time_mod2.nowMillis() - t0;

    // The whole call must land just past the 1.5s deadline (+heuristic run),
    // nowhere near the stalled gateway's forever.
    try std.testing.expect(elapsed < 5_000);
    try std.testing.expect(elapsed >= 1_400);
    // Heuristic fallback stored the decision fact.
    const ents = try mem.episodic_mem.retrieveRecent(5);
    defer mem.episodic_mem.freeEntries(ents);
    try std.testing.expect(ents.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, ents[0].content, "WAL") != null or std.mem.indexOf(u8, ents[0].content, "决定") != null);
    // The user-visible notice landed.
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "正在提取本会话记忆") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "降级") != null);
    alloc.free(settings.api_keys.openai_base_url.?);
}
