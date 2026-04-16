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
        \\║  Ziv — Zig 自学习 Agent v0.1.0      ║
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
