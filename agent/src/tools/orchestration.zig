/// Tool orchestration — partition tool calls into concurrency-safe/unsafe batches.
/// Safe tools execute in parallel, unsafe tools execute serially.
const std = @import("std");
const registry = @import("registry.zig");
const thread_pool = @import("../task/thread_pool.zig");

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

/// Execute batches — safe batches via thread pool, unsafe batches serially.
pub fn executeBatches(
    batches: []const ToolCallBatch,
    allocator: std.mem.Allocator,
    io: std.Io,
    tools_def: []const registry.ToolDefinition,
) ![]BatchResult {
    var results = std.ArrayList(BatchResult).empty;
    defer results.deinit(allocator);

    for (batches) |batch| {
        if (batch.is_concurrency_safe and batch.calls.len > 1) {
            // True parallelism: submit to the e-bounded thread pool, wait for
            // all workers, then collect results in the original call order.
            var pool = thread_pool.ThreadPool.init(allocator) catch {
                // Pool unavailable — degrade to serial, semantics unchanged.
                for (batch.calls) |call| {
                    const result = executeToolCall(call, allocator, io, tools_def);
                    try results.append(allocator, .{ .tool_use_id = call.tool_use_id, .result = result });
                }
                continue;
            };
            try pool.start();
            // Defer order is LIFO: register the pool join FIRST so it runs
            // LAST — workers may still write task.status after done is set,
            // so tasks/ctxs must outlive the join.
            defer pool.deinit();

            const ctxs = try allocator.alloc(ParallelCall, batch.calls.len);
            defer allocator.free(ctxs);
            const tasks = try allocator.alloc(thread_pool.Task, batch.calls.len);
            defer allocator.free(tasks);

            for (batch.calls, 0..) |call, i| {
                ctxs[i] = .{ .call = call, .allocator = allocator, .io = io, .tools_def = tools_def };
                tasks[i] = .{
                    .id = i,
                    .name = "tool_call",
                    .priority = .normal,
                    .status = std.atomic.Value(thread_pool.TaskStatus).init(.pending),
                    .progress = std.atomic.Value(f64).init(0),
                    .execute_fn = parallelCallTask,
                    .ctx = &ctxs[i],
                    .cancel_token = std.atomic.Value(bool).init(false),
                    .error_message = null,
                    .retry_count = 0,
                    .max_retries = 0,
                };
                try pool.submit(&tasks[i]);
            }

            // Wait for all workers to report done.
            while (true) {
                var all_done = true;
                for (ctxs) |*c| {
                    if (!c.done.load(.acquire)) {
                        all_done = false;
                        break;
                    }
                }
                if (all_done) break;
                var req: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = std.c.nanosleep(&req, null);
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

/// Per-call context handed to pool workers.
const ParallelCall = struct {
    call: ToolCall,
    allocator: std.mem.Allocator,
    io: std.Io,
    tools_def: []const registry.ToolDefinition,
    result: registry.ToolResult = .{ .output = "not run", .is_error = true },
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn parallelCallTask(_: *std.mem.Allocator, ctx_opaque: ?*anyopaque) anyerror!void {
    const ctx: *ParallelCall = @ptrCast(@alignCast(ctx_opaque.?));
    ctx.result = executeToolCall(ctx.call, ctx.allocator, ctx.io, ctx.tools_def);
    ctx.done.store(true, .release);
}

fn executeToolCall(
    call: ToolCall,
    allocator: std.mem.Allocator,
    io: std.Io,
    tools_def: []const registry.ToolDefinition,
) registry.ToolResult {
    const tool = findTool(tools_def, call.tool_name) orelse
        return .{ .output = "Tool not found", .is_error = true };

    return tool.execute_fn(allocator, call.input, io) catch
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
