/// Tool orchestration — partition tool calls into concurrency-safe/unsafe batches.
/// Safe tools execute in parallel, unsafe tools execute serially.
const std = @import("std");
const registry = @import("registry.zig");

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
    var batches = std.ArrayList(ToolCallBatch).init(allocator);
    defer batches.deinit();

    var safe_batch = std.ArrayList(ToolCall).init(allocator);
    defer safe_batch.deinit();

    for (calls) |call| {
        const tool = findTool(tools_def, call.tool_name);
        const is_safe = if (tool) |t| t.isConcurrencySafe(call.input) else false;

        if (is_safe) {
            try safe_batch.append(call);
        } else {
            // Flush accumulated safe batch
            if (safe_batch.items.len > 0) {
                try batches.append(.{
                    .is_concurrency_safe = true,
                    .calls = try safe_batch.toOwnedSlice(allocator),
                });
            }
            // Unsafe call stands alone
            try batches.append(.{
                .is_concurrency_safe = false,
                .calls = try allocator.dupe(ToolCall, &[_]ToolCall{call}),
            });
        }
    }

    // Flush remaining safe batch
    if (safe_batch.items.len > 0) {
        try batches.append(.{
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
    var results = std.ArrayList(BatchResult).init(allocator);
    defer results.deinit();

    for (batches) |batch| {
        if (batch.is_concurrency_safe and batch.calls.len > 1) {
            // Parallel execution using threads
            // TODO: Use thread pool for true parallelism
            // For now, execute sequentially (safe tools don't interfere)
            for (batch.calls) |call| {
                const result = executeToolCall(call, allocator, io, tools_def);
                try results.append(.{
                    .tool_use_id = call.tool_use_id,
                    .result = result,
                });
            }
        } else {
            // Serial execution for unsafe tools
            for (batch.calls) |call| {
                const result = executeToolCall(call, allocator, io, tools_def);
                try results.append(.{
                    .tool_use_id = call.tool_use_id,
                    .result = result,
                });
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
        .{ .tool_name = "FileRead", .input = .{}, .tool_use_id = "1" },
        .{ .tool_name = "FileRead", .input = .{}, .tool_use_id = "2" },
        .{ .tool_name = "FileWrite", .input = .{}, .tool_use_id = "3" },
        .{ .tool_name = "FileRead", .input = .{}, .tool_use_id = "4" },
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
