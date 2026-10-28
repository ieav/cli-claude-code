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
    /// Conversation length (history.items.len) at the moment this op was
    /// recorded — the EXACT rewind boundary for /rewind's dialogue part.
    /// Millisecond timestamps cannot split messages inside one fast turn;
    /// an index can. 0 = "not a conversation checkpoint" (records that are
    /// never rollback points, or tests).
    history_len: usize = 0,
    /// Conversation epoch when recorded. /compact, /clear and /undo REWRITE
    /// the history, so an old point's history_len then indexes unrelated
    /// messages — rewinding to it would delete innocent new dialogue. Those
    /// operations bump the epoch; points from a stale epoch rewind FILES
    /// ONLY.
    epoch: u64 = 0,
};

pub const OperationLog = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(OperationRecord),
    current_position: u32,
    /// Bumped whenever the conversation is rewritten (compact/clear/undo);
    /// see OperationRecord.epoch.
    epoch: u64 = 0,

    const Self = @This();

    /// Invalidate every recorded conversation checkpoint: the history they
    /// indexed has been rewritten. File rollback for old points stays
    /// available — only the dialogue truncation is disabled.
    pub fn bumpEpoch(self: *Self) void {
        self.epoch += 1;
    }

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
        history_len: usize,
    ) ![16]u8 {
        // uuid, not timestamp-spice: two ops in the same millisecond used
        // to collide on op_id (uuid was imported but never used).
        var id: [16]u8 = undefined;
        uuid.randomBytes(&id);

        try self.records.append(self.allocator, .{
            .op_id = id,
            .timestamp = time_mod.nowMillis(),
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .input = try self.allocator.dupe(u8, input),
            .output = try self.allocator.dupe(u8, output),
            .snapshot_id = snapshot_id,
            .rollback_safe = rollback_safe,
            .history_len = history_len,
            .epoch = self.epoch,
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
