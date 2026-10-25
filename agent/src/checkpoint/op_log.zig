/// Operation log — record every tool invocation for auditing and rollback.
const std = @import("std");
const uuid = @import("../util/uuid.zig");
const time_mod = @import("../util/time.zig");

pub const OperationRecord = struct {
    op_id: [16]u8,
    timestamp: i64,
    tool_name: []const u8,
    input: []const u8,
    output: []const u8,
    snapshot_id: ?[16]u8,
    rollback_safe: bool,
};

pub const OperationLog = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(OperationRecord),
    current_position: u32,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .allocator = alloc,
            .records = std.ArrayList(OperationRecord).empty,
            .current_position = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.records.items) |rec| {
            self.allocator.free(rec.tool_name);
            self.allocator.free(rec.input);
            self.allocator.free(rec.output);
        }
        self.records.deinit(self.allocator);
    }

    /// Record a new operation.
    pub fn record(
        self: *Self,
        tool_name: []const u8,
        input: []const u8,
        output: []const u8,
        snapshot_id: ?[16]u8,
        rollback_safe: bool,
    ) ![16]u8 {
        var id: [16]u8 = undefined;
        const ts = time_mod.nowMillis();
        for (&id, 0..) |*byte, i| {
            byte.* = @truncate(@as(u64, @bitCast(ts)) +% @as(u64, i) *% 0x9e3779b97f4a7c15);
        }

        try self.records.append(self.allocator, .{
            .op_id = id,
            .timestamp = time_mod.nowMillis(),
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .input = try self.allocator.dupe(u8, input),
            .output = try self.allocator.dupe(u8, output),
            .snapshot_id = snapshot_id,
            .rollback_safe = rollback_safe,
        });
        self.current_position = @intCast(self.records.items.len);
        return id;
    }

    /// Get operations since a given snapshot.
    pub fn getOperationsSince(self: *Self, snapshot_id: [16]u8) []const OperationRecord {
        for (self.records.items, 0..) |rec, i| {
            if (rec.snapshot_id) |sid| {
                if (std.mem.eql(u8, &sid, &snapshot_id)) {
                    return self.records.items[i..];
                }
            }
        }
        return self.records.items;
    }

    /// Check if we can rollback to a given operation.
    pub fn canRollbackTo(self: *Self, op_id: [16]u8) bool {
        for (self.records.items) |rec| {
            if (std.mem.eql(u8, &rec.op_id, &op_id)) {
                return rec.rollback_safe;
            }
        }
        return false;
    }

    /// Get all rollback-safe operation IDs.
    pub fn rollbackPoints(self: *Self) std.ArrayList([16]u8) {
        var points = std.ArrayList([16]u8).empty;
        for (self.records.items) |rec| {
            if (rec.rollback_safe and rec.snapshot_id != null) {
                points.append(self.allocator, rec.op_id) catch {};
            }
        }
        return points;
    }
};
