const std = @import("std");

pub const math = @import("math/mod.zig");
pub const llm_mod = @import("llm/mod.zig");
pub const decision_trace = @import("runtime/decision_trace.zig");
pub const tools = @import("tools/mod.zig");
pub const task_mod = @import("task/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const memory_mod = @import("memory/mod.zig");
pub const knowledge = @import("knowledge/mod.zig");
pub const research = @import("research/optimization_researcher.zig");
pub const util = @import("util/mod.zig");
pub const checkpoint = @import("checkpoint/mod.zig");
pub const integration_tests = @import("tests/integration.zig");

// Collect every module's tests into the test build. The `pub const` imports
// above are lazily analyzed (nothing references them in test mode), so
// without this block `zig build test` silently runs zero tests. Files are
// listed individually: `_ = @import("x/mod.zig")` does NOT transitively
// collect tests from x's submodules (pub consts stay lazily analyzed).
test {
    _ = @import("knowledge/graph.zig");
    _ = @import("knowledge/search.zig");
    _ = @import("llm/claude.zig");
    _ = @import("llm/compaction.zig");
    _ = @import("llm/message.zig");
    _ = @import("llm/mod.zig");
    _ = @import("llm/ollama.zig");
    _ = @import("llm/openai.zig");
    _ = @import("llm/streaming.zig");
    _ = @import("math/constants.zig");
    _ = @import("math/e_growth.zig");
    _ = @import("math/phi_condense.zig");
    _ = @import("math/pi_ring.zig");
    _ = @import("memory/episodic.zig");
    _ = @import("memory/extraction.zig");
    _ = @import("memory/injection.zig");
    _ = @import("memory/memory.zig");
    _ = @import("memory/reflection.zig");
    _ = @import("memory/working.zig");
    _ = @import("research/optimization_researcher.zig");
    _ = @import("repl.zig");
    _ = @import("runtime/builtin_rules.zig");
    _ = @import("runtime/error_handler.zig");
    _ = @import("runtime/monitor.zig");
    _ = @import("runtime/self_diagnostic.zig");
    _ = @import("storage/database.zig");
    _ = @import("storage/vector.zig");
    _ = @import("task/cron.zig");
    _ = @import("task/event_bus.zig");
    _ = @import("task/mpsc_queue.zig");
    _ = @import("task/thread_pool.zig");
    _ = @import("tests/integration.zig");
    _ = @import("tools/auth_mode.zig");
    _ = @import("tools/classifier.zig");
    _ = @import("tools/denial_tracker.zig");
    _ = @import("tools/orchestration.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/rule_parser.zig");
    _ = @import("tools/task_store.zig");
    _ = @import("util/embedding.zig");
    _ = @import("util/menu.zig");
    _ = @import("util/binary_check.zig");
    _ = @import("util/cancel.zig");
    _ = @import("util/diff.zig");
    _ = @import("util/env.zig");
    _ = @import("util/file_cache.zig");
    _ = @import("util/find_executable.zig");
    _ = @import("util/format.zig");
    _ = @import("util/fs_ops.zig");
    _ = @import("util/glob_match.zig");
    _ = @import("util/hash.zig");
    _ = @import("util/json_helpers.zig");
    _ = @import("util/lockfile.zig");
    _ = @import("util/memoize.zig");
    _ = @import("util/path.zig");
    _ = @import("util/platform.zig");
    _ = @import("util/sanitization.zig");
    _ = @import("util/semver.zig");
    _ = @import("util/shell_quote.zig");
    _ = @import("util/string_utils.zig");
    _ = @import("util/system_dirs.zig");
    _ = @import("util/tempfile.zig");
    _ = @import("util/time.zig");
    _ = @import("util/tokens.zig");
    _ = @import("util/uuid.zig");
}

pub fn main() !void {
    // Create I/O context (Zig 0.16 Threaded Io)
    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io: std.Io = io_state.io();

    const stdout_file = std.Io.File.stdout();
    const stdin_file = std.Io.File.stdin();

    // Create buffered writer
    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(stdout_file, io, &write_buf);
    const w = &file_writer.interface;

    try std.Io.Writer.writeAll(w,
        \\╔══════════════════════════════════════╗
        \\║  Ziv — Zig 自学习 Agent v0.4.0      ║
        \\║  pi 圆融 · e 增长 · phi 浓缩         ║
        \\╚══════════════════════════════════════╝
        \\
    );
    try std.Io.Writer.print(w, "  pi  = {d:.10}\n", .{math.constants.PI});
    try std.Io.Writer.print(w, "  e   = {d:.10}\n", .{math.constants.E});
    try std.Io.Writer.print(w, "  phi = {d:.10}\n\n", .{math.constants.PHI});
    try std.Io.File.Writer.flush(&file_writer);

    // Self-test
    try std.Io.Writer.writeAll(w, "Running self-tests...\n");
    const result = runTests();
    switch (result) {
        .ok => try std.Io.Writer.writeAll(w, "  ok - All tests passed\n\n"),
        .fail => |err| try std.Io.Writer.print(w, "  FAIL: {}\n\n", .{err}),
    }
    try std.Io.File.Writer.flush(&file_writer);

    // Start REPL
    const repl = @import("repl.zig");
    try repl.run(io, stdin_file, stdout_file);
}

const TestResult = union(enum) {
    ok,
    fail: anyerror,
};

fn runTests() TestResult {
    const s0 = math.sigmoid(0);
    if (@abs(s0 - 0.5) > 1e-10) return .{ .fail = error.TestFailed };

    const c = math.condensationTarget(1000);
    if (c != 618) return .{ .fail = error.TestFailed };

    // Verify φ hash distribution
    const h1 = math.fibonacciHash(1, 4);
    const h2 = math.fibonacciHash(2, 4);
    if (h1 == h2) return .{ .fail = error.TestFailed };

    // Verify e decay
    const d = math.expDecay(1.0, std.math.ln2, 1.0);
    if (@abs(d - 0.5) > 1e-8) return .{ .fail = error.TestFailed };

    return .ok;
}
