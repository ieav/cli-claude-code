/// Tool orchestration — partition tool calls into concurrency-safe/unsafe batches.
/// Safe tools execute in parallel, unsafe tools execute serially.
const std = @import("std");
const registry = @import("registry.zig");
const math = @import("../math/mod.zig");

pub const ToolCall = struct {
    tool_name: []const u8,
    input: std.json.Value,
    tool_use_id: []const u8,
};

pub const ToolCallBatch = struct {
    is_concurrency_safe: bool,
    calls: []const ToolCall,
};

pub const BatchResult = struct {
    tool_use_id: []const u8,
    result: registry.ToolResult,
};

/// Partition tool calls into batches based on concurrency safety.
/// Adjacent safe calls are grouped together; unsafe calls stand alone.
pub fn partitionToolCalls(
    calls: []const ToolCall,
    tools_def: []const registry.ToolDefinition,
    allocator: std.mem.Allocator,
) ![]ToolCallBatch {
    var batches = std.ArrayList(ToolCallBatch).empty;
    defer batches.deinit(allocator);

    var safe_batch = std.ArrayList(ToolCall).empty;
    defer safe_batch.deinit(allocator);

    for (calls) |call| {
        const tool = findTool(tools_def, call.tool_name);
        const is_safe = if (tool) |t| t.isConcurrencySafe(call.input) else false;

        if (is_safe) {
            try safe_batch.append(allocator, call);
        } else {
            // Flush accumulated safe batch
            if (safe_batch.items.len > 0) {
                try batches.append(allocator, .{
                    .is_concurrency_safe = true,
                    .calls = try safe_batch.toOwnedSlice(allocator),
                });
            }
            // Unsafe call stands alone
            try batches.append(allocator, .{
                .is_concurrency_safe = false,
                .calls = try allocator.dupe(ToolCall, &[_]ToolCall{call}),
            });
        }
    }

    // Flush remaining safe batch
    if (safe_batch.items.len > 0) {
        try batches.append(allocator, .{
            .is_concurrency_safe = true,
            .calls = try safe_batch.toOwnedSlice(allocator),
        });
    }

    return batches.toOwnedSlice(allocator);
}

/// Execute batches — safe batches run in parallel, unsafe batches serially.
///
/// Parallelism model: one thread per call, spawned in waves bounded by the
/// e-based concurrency function (effectiveConcurrency(0, hw)). This replaces
/// the old per-batch ThreadPool, which — for every batch — initialized a
/// pool, spawned hw/2 idle-polling workers, and joined/destroyed them, even
/// for two-call batches. Threads now exist only while there is work, in the
/// amount there is work for; join() replaces both the worker nanosleep
/// polling and the submitter's 1ms spin-wait. A spawn failure degrades that
/// single call to serial — semantics never depend on the pool existing.
pub fn executeBatches(
    batches: []const ToolCallBatch,
    allocator: std.mem.Allocator,
    io: std.Io,
    tools_def: []const registry.ToolDefinition,
) ![]BatchResult {
    var results = std.ArrayList(BatchResult).empty;
    defer results.deinit(allocator);

    const hw = std.Thread.getCpuCount() catch 4;
    const cap = @max(math.effectiveConcurrency(0, hw), 1);

    for (batches) |batch| {
        if (batch.is_concurrency_safe and batch.calls.len > 1) {
            const ctxs = try allocator.alloc(ParallelCall, batch.calls.len);
            defer allocator.free(ctxs);
            const threads = try allocator.alloc(?std.Thread, batch.calls.len);
            defer allocator.free(threads);

            // Wave execution: at most `cap` calls in flight at once.
            var start: usize = 0;
            while (start < batch.calls.len) {
                const wave_end = @min(start + cap, batch.calls.len);
                for (batch.calls[start..wave_end], start..) |call, i| {
                    ctxs[i] = .{ .call = call, .allocator = allocator, .io = io, .tools_def = tools_def };
                    threads[i] = std.Thread.spawn(.{}, parallelCallThread, .{&ctxs[i]}) catch null;
                    if (threads[i] == null) {
                        // Spawn failed — run this call on the current thread.
                        parallelCallThread(&ctxs[i]);
                    }
                }
                // Blocking join replaces the old spin-wait; result writes
                // happen-before join returns.
                for (batch.calls[start..wave_end], start..) |_, i| {
                    if (threads[i]) |t| t.join();
                }
                start = wave_end;
            }

            for (ctxs) |*c| {
                try results.append(allocator, .{ .tool_use_id = c.call.tool_use_id, .result = c.result });
            }
        } else {
            // Serial execution for unsafe tools (and single-call batches)
            for (batch.calls) |call| {
                const result = executeToolCall(call, allocator, io, tools_def);
                try results.append(allocator, .{ .tool_use_id = call.tool_use_id, .result = result });
            }
        }
    }

    return results.toOwnedSlice(allocator);
}

fn findTool(tools_def: []const registry.ToolDefinition, name: []const u8) ?*const registry.ToolDefinition {
    for (tools_def) |*tool| {
        if (tool.matchesName(name)) return tool;
    }
    return null;
}

/// Per-call context handed to worker threads.
const ParallelCall = struct {
    call: ToolCall,
    allocator: std.mem.Allocator,
    io: std.Io,
    tools_def: []const registry.ToolDefinition,
    result: registry.ToolResult = .{ .output = "not run", .is_error = true },
};

fn parallelCallThread(ctx: *ParallelCall) void {
    ctx.result = executeToolCall(ctx.call, ctx.allocator, ctx.io, ctx.tools_def);
}

fn executeToolCall(
    call: ToolCall,
    allocator: std.mem.Allocator,
    io: std.Io,
    tools_def: []const registry.ToolDefinition,
) registry.ToolResult {
    const tool = findTool(tools_def, call.tool_name) orelse
        return .{ .output = "Tool not found", .is_error = true };

    return tool.execute(allocator, call.input, io) catch
        .{ .output = "Tool execution error", .is_error = true };
}

test "partitionToolCalls" {
    const alloc = std.testing.allocator;
    const tools_list = registry.default_tools;

    const calls = [_]ToolCall{
        .{ .tool_name = "FileRead", .input = .null, .tool_use_id = "1" },
        .{ .tool_name = "FileRead", .input = .null, .tool_use_id = "2" },
        .{ .tool_name = "FileWrite", .input = .null, .tool_use_id = "3" },
        .{ .tool_name = "FileRead", .input = .null, .tool_use_id = "4" },
    };

    const batches = try partitionToolCalls(&calls, tools_list, alloc);
    defer {
        for (batches) |b| alloc.free(b.calls);
        alloc.free(batches);
    }

    // Should have 3 batches: [safe: 1,2] [unsafe: 3] [safe: 4]
    try std.testing.expectEqual(@as(usize, 3), batches.len);
    try std.testing.expect(batches[0].is_concurrency_safe);
    try std.testing.expectEqual(@as(usize, 2), batches[0].calls.len);
    try std.testing.expect(!batches[1].is_concurrency_safe);
    try std.testing.expect(batches[2].is_concurrency_safe);
}

test "executeBatches runs safe batch in parallel with ordered results" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    // Prepare a temp file for the concurrent FileReads.
    const tmp_path = "/tmp/ziv_orch_parallel_test.txt";
    {
        var io2_state = std.Io.Threaded.init(alloc, .{});
        defer io2_state.deinit();
        try std.Io.Dir.cwd().writeFile(io2_state.io(), .{ .sub_path = tmp_path, .data = "PARALLEL_OK" });
    }
    defer {
        var io3_state = std.Io.Threaded.init(alloc, .{});
        defer io3_state.deinit();
        std.Io.Dir.cwd().deleteFile(io3_state.io(), tmp_path) catch {};
    }

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(alloc);
    try obj.put(alloc, "path", .{ .string = tmp_path });

    const calls = [_]ToolCall{
        .{ .tool_name = "FileRead", .input = .{ .object = obj }, .tool_use_id = "t1" },
        .{ .tool_name = "FileRead", .input = .{ .object = obj }, .tool_use_id = "t2" },
        .{ .tool_name = "FileRead", .input = .{ .object = obj }, .tool_use_id = "t3" },
        .{ .tool_name = "FileRead", .input = .{ .object = obj }, .tool_use_id = "t4" },
    };

    const batches = try partitionToolCalls(&calls, registry.default_tools, alloc);
    defer {
        for (batches) |b| alloc.free(b.calls);
        alloc.free(batches);
    }

    const results = try executeBatches(batches, alloc, io, registry.default_tools);
    defer alloc.free(results);

    try std.testing.expectEqual(@as(usize, 4), results.len);
    // Results come back in the original call order.
    const expected_ids = [_][]const u8{ "t1", "t2", "t3", "t4" };
    for (results, expected_ids) |r, want| {
        try std.testing.expectEqualStrings(want, r.tool_use_id);
        try std.testing.expect(!r.result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.result.output, "PARALLEL_OK") != null);
        alloc.free(r.result.output);
    }
}

test "executeBatches preserves order across many calls (wave looping)" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    // 16 calls — more than typical e-based caps, forcing multi-wave execution.
    const tmp_path = "/tmp/ziv_orch_waves_test.txt";
    {
        var io2_state = std.Io.Threaded.init(alloc, .{});
        defer io2_state.deinit();
        try std.Io.Dir.cwd().writeFile(io2_state.io(), .{ .sub_path = tmp_path, .data = "WAVE_OK" });
    }
    defer {
        var io3_state = std.Io.Threaded.init(alloc, .{});
        defer io3_state.deinit();
        std.Io.Dir.cwd().deleteFile(io3_state.io(), tmp_path) catch {};
    }

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(alloc);
    try obj.put(alloc, "path", .{ .string = tmp_path });

    var calls: [16]ToolCall = undefined;
    for (&calls, 0..) |*c, i| {
        c.* = .{ .tool_name = "FileRead", .input = .{ .object = obj }, .tool_use_id = "w1" };
        c.tool_use_id = switch (i % 3) {
            0 => "a",
            1 => "b",
            else => "c",
        };
    }

    const batches = try partitionToolCalls(&calls, registry.default_tools, alloc);
    defer {
        for (batches) |b| alloc.free(b.calls);
        alloc.free(batches);
    }
    const results = try executeBatches(batches, alloc, io, registry.default_tools);
    defer {
        for (results) |r| alloc.free(r.result.output);
        alloc.free(results);
    }

    try std.testing.expectEqual(@as(usize, 16), results.len);
    for (results) |r| {
        try std.testing.expect(!r.result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.result.output, "WAVE_OK") != null);
    }
}
