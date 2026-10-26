/// Rollback engine — restore files to a previous checkpoint.
const std = @import("std");
const file_history = @import("file_history.zig");
const op_log = @import("op_log.zig");

pub const RollbackPoint = struct {
    op_id: [16]u8,
    tool_name: []const u8,
    timestamp: i64,
    files_affected: usize,
};

pub const RollbackResult = struct {
    restored_files: []const []const u8,
    deleted_files: []const []const u8,
    errors: []const RollbackError,
};

pub const RollbackError = struct {
    file_path: []const u8,
    message: []const u8,
};

pub const RollbackPreview = struct {
    files_to_restore: usize,
    files_to_delete: usize,
    operations_to_undo: usize,
};

/// Sentinel op_id meaning "roll back everything (session start state)".
pub const session_start_op_id: [16]u8 = @splat(0);

pub const RollbackEngine = struct {
    history: *file_history.FileHistoryState,
    op_log: *op_log.OperationLog,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, history: *file_history.FileHistoryState, log: *op_log.OperationLog) Self {
        return .{
            .allocator = allocator,
            .history = history,
            .op_log = log,
        };
    }

    /// List all rollback points (operations that have snapshots and are rollback-safe).
    pub fn listRollbackPoints(self: *Self) ![]RollbackPoint {
        var points = std.ArrayList(RollbackPoint).empty;
        defer points.deinit(self.allocator);

        for (self.op_log.records.items) |rec| {
            if (rec.rollback_safe and rec.snapshot_id != null) {
                // Count files in the snapshot for this operation
                var files_affected: usize = 0;
                if (self.history.findSnapshotForMessage(rec.snapshot_id.?)) |snap_idx| {
                    var iter = self.history.snapshots.items[snap_idx].backups.iterator();
                    while (iter.next()) |_| {
                        files_affected += 1;
                    }
                }
                try points.append(self.allocator, .{
                    .op_id = rec.op_id,
                    .tool_name = rec.tool_name,
                    .timestamp = rec.timestamp,
                    .files_affected = files_affected,
                });
            }
        }

        return points.toOwnedSlice(self.allocator);
    }

    /// Preview what a rollback would do without executing it.
    pub fn previewRollback(self: *Self, target_op_id: [16]u8) !RollbackPreview {
        var preview = RollbackPreview{
            .files_to_restore = 0,
            .files_to_delete = 0,
            .operations_to_undo = 0,
        };

        // Find target operation index. The all-zero sentinel means
        // "undo everything back to the session start state".
        var target_idx: ?usize = null;
        if (std.mem.eql(u8, &target_op_id, &session_start_op_id)) {
            target_idx = std.math.maxInt(usize);
        }
        if (target_idx == null) {
            for (self.op_log.records.items, 0..) |rec, i| {
                if (std.mem.eql(u8, &rec.op_id, &target_op_id)) {
                    target_idx = i;
                    break;
                }
            }
        }
        if (target_idx == null) return error.OperationNotFound;

        // Count operations and files from target+1 to end
        const start_idx: usize = if (target_idx.? == std.math.maxInt(usize)) 0 else target_idx.? + 1;
        var i: usize = start_idx;
        while (i < self.op_log.records.items.len) : (i += 1) {
            const rec = self.op_log.records.items[i];
            preview.operations_to_undo += 1;

            if (rec.snapshot_id) |sid| {
                if (self.history.findSnapshotForMessage(sid)) |snap_idx| {
                    var iter = self.history.snapshots.items[snap_idx].backups.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.backup_path != null) {
                            preview.files_to_restore += 1;
                        } else {
                            preview.files_to_delete += 1;
                        }
                    }
                }
            }
        }

        return preview;
    }

    /// Execute a rollback to the given operation point.
    /// Restores all files modified by operations after the target.
    /// Removes the undone operations from the log.
    pub fn rollbackTo(self: *Self, target_op_id: [16]u8, io: std.Io) !RollbackResult {
        var restored_list = std.ArrayList([]const u8).empty;
        defer restored_list.deinit(self.allocator);
        var deleted_list = std.ArrayList([]const u8).empty;
        defer deleted_list.deinit(self.allocator);
        var error_list = std.ArrayList(RollbackError).empty;
        defer error_list.deinit(self.allocator);

        // Find target operation. The all-zero sentinel means
        // "undo everything back to the session start state".
        var target_idx: ?usize = null;
        if (std.mem.eql(u8, &target_op_id, &session_start_op_id)) {
            target_idx = std.math.maxInt(usize);
        }
        if (target_idx == null) {
            for (self.op_log.records.items, 0..) |rec, i| {
                if (std.mem.eql(u8, &rec.op_id, &target_op_id)) {
                    target_idx = i;
                    break;
                }
            }
        }
        if (target_idx == null) return error.OperationNotFound;

        // Restore snapshots in reverse order (latest first)
        const start_idx: usize = if (target_idx.? == std.math.maxInt(usize)) 0 else target_idx.? + 1;
        var ri: usize = self.op_log.records.items.len;
        while (ri > start_idx) {
            ri -= 1;
            const rec = self.op_log.records.items[ri];

            if (rec.snapshot_id) |sid| {
                if (self.history.findSnapshotForMessage(sid)) |snap_idx| {
                    const result = self.history.restoreSnapshot(snap_idx, io) catch |err| {
                        try error_list.append(self.allocator, .{
                            .file_path = "(snapshot)",
                            .message = @errorName(err),
                        });
                        continue;
                    };

                    for (result.restored) |fp| {
                        try restored_list.append(self.allocator, fp);
                    }
                    for (result.deleted) |fp| {
                        try deleted_list.append(self.allocator, fp);
                    }
                    self.allocator.free(result.restored);
                    self.allocator.free(result.deleted);
                }
            }
        }

        // Remove undone operations from log. For the session-start sentinel
        // (maxInt) everything is undone; compute the keep-count without the
        // maxInt+1 overflow.
        const keep_count: usize = if (target_idx.? == std.math.maxInt(usize)) 0 else target_idx.? + 1;
        while (self.op_log.records.items.len > keep_count) {
            const removed = self.op_log.records.pop() orelse break;
            self.allocator.free(removed.tool_name);
            self.allocator.free(removed.input);
            self.allocator.free(removed.output);
        }

        return .{
            .restored_files = try restored_list.toOwnedSlice(self.allocator),
            .deleted_files = try deleted_list.toOwnedSlice(self.allocator),
            .errors = try error_list.toOwnedSlice(self.allocator),
        };
    }

    /// Free a RollbackResult's allocated slices.
    pub fn freeResult(self: *Self, result: RollbackResult) void {
        for (result.restored_files) |fp| self.allocator.free(fp);
        self.allocator.free(result.restored_files);
        for (result.deleted_files) |fp| self.allocator.free(fp);
        self.allocator.free(result.deleted_files);
        self.allocator.free(result.errors);
    }
};
