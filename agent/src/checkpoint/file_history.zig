/// File history — snapshot-based file backup and restore system.
/// Tracks file changes and enables rollback to any checkpoint.
const std = @import("std");
const hash_mod = @import("../util/hash.zig");
const time_mod = @import("../util/time.zig");
const logger = @import("../util/log.zig");

pub const FileBackup = struct {
    backup_path: ?[]const u8,
    version: u32,
    content_hash: [16]u8,
    backup_time: i64,
};

pub const Snapshot = struct {
    message_id: [16]u8,
    backups: std.StringHashMap(FileBackup),
    timestamp: i64,
};

pub const FileHistoryState = struct {
    allocator: std.mem.Allocator,
    snapshots: std.ArrayList(Snapshot),
    tracked_files: std.StringHashMap(void),
    sequence: u32,
    max_snapshots: u32,
    checkpoint_dir: []const u8,
    dir_ensured: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, checkpoint_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .snapshots = std.ArrayList(Snapshot).empty,
            .tracked_files = std.StringHashMap(void).init(allocator),
            .sequence = 0,
            .max_snapshots = 100,
            .checkpoint_dir = checkpoint_dir,
        };
    }

    fn freeSnapshotBackups(self: *Self, snap_in: Snapshot) void {
        var snap = snap_in;
        var iter = snap.backups.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.backup_path) |bp| {
                self.allocator.free(bp);
            }
            self.allocator.free(entry.key_ptr.*);
        }
        snap.backups.deinit();
    }

    pub fn deinit(self: *Self) void {
        // Clean up snapshots
        for (self.snapshots.items) |snap| {
            self.freeSnapshotBackups(snap);
        }
        self.snapshots.deinit(self.allocator);

        // Clean up tracked files
        var iter = self.tracked_files.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tracked_files.deinit();
        self.allocator.free(self.checkpoint_dir);
    }

    /// Track a file edit — create backup before modification.
    /// If the file exists, its content is backed up to the checkpoint directory.
    /// If the file doesn't exist yet, it's recorded as "new" (rollback will delete it).
    pub fn trackEdit(self: *Self, file_path: []const u8, message_id: [16]u8, io: std.Io) !void {
        // Ensure checkpoint directory exists (idempotent, runs once)
        if (!self.dir_ensured) {
            std.Io.Dir.cwd().createDirPath(io, self.checkpoint_dir) catch {};
            self.dir_ensured = true;
        }

        // Register file as tracked (idempotent)
        const gop = try self.tracked_files.getOrPut(file_path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, file_path);
        }

        // Find or create snapshot for this message
        var snap_idx: ?usize = null;
        for (self.snapshots.items, 0..) |snap, i| {
            if (std.mem.eql(u8, &snap.message_id, &message_id)) {
                snap_idx = i;
                break;
            }
        }
        if (snap_idx == null) {
            try self.makeSnapshot(message_id);
            snap_idx = self.snapshots.items.len - 1;
        }
        const snap = &self.snapshots.items[snap_idx.?];

        // Try to read current file content. A read FAILURE is not "file
        // doesn't exist": a >100 MB or unreadable (EACCES) existing file
        // used to fall into the "new file" branch below, and rollback would
        // then DELETE it — data loss beyond the edit being undone. Only
        // FileNotFound means new; any other failure leaves the file out of
        // rollback coverage (same policy as a failed backup write).
        const cwd = std.Io.Dir.cwd();
        const content: ?[]u8 = std.Io.Dir.readFileAlloc(cwd, io, file_path, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| blk: {
            if (err != error.FileNotFound) {
                logger.warning("Backup read failed ({s}) — {s} left out of rollback coverage", .{ @errorName(err), file_path });
                return;
            }
            break :blk null;
        };

        if (content) |data| {
            defer self.allocator.free(data);

            // Compute hash (first 16 bytes of SHA-256)
            const full_hash = hash_mod.sha256(data);
            var content_hash: [16]u8 = undefined;
            @memcpy(&content_hash, full_hash[0..16]);

            // Skip if unchanged since last backup
            if (snap.backups.get(file_path)) |existing| {
                if (std.mem.eql(u8, &existing.content_hash, &content_hash)) return;
            }

            // Write the new backup file FIRST — only after it exists on disk
            // do we replace the old entry, so a failed write leaves the
            // snapshot with its previous valid backup instead of silently
            // dropping the file from rollback coverage.
            self.sequence += 1;
            const basename_start = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse 0;
            const basename = if (basename_start > 0) file_path[basename_start + 1 ..] else file_path;
            const backup_path = self.allocator.print("{s}/{d}_{s}", .{
                self.checkpoint_dir,
                self.sequence,
                basename,
            }) catch return;

            cwd.writeFile(io, .{ .sub_path = backup_path, .data = data }) catch {
                logger.warning("Backup write failed: {s}", .{backup_path});
                self.allocator.free(backup_path);
                return;
            };

            if (snap.backups.fetchRemove(file_path)) |old| {
                if (old.value.backup_path) |bp| self.allocator.free(bp);
                self.allocator.free(old.key);
            }

            const path_key = try self.allocator.dupe(u8, file_path);
            try snap.backups.put(path_key, .{
                .backup_path = backup_path,
                .version = self.sequence,
                .content_hash = content_hash,
                .backup_time = time_mod.nowMillis(),
            });
        } else {
            // File doesn't exist yet — record as "new file" (backup_path = null)
            // Rollback will delete it
            if (snap.backups.get(file_path) == null) {
                const path_key = try self.allocator.dupe(u8, file_path);
                try snap.backups.put(path_key, .{
                    .backup_path = null,
                    .version = self.sequence,
                    .content_hash = @splat(0),
                    .backup_time = time_mod.nowMillis(),
                });
            }
        }
    }

    /// Create a snapshot of all tracked files.
    pub fn makeSnapshot(self: *Self, message_id: [16]u8) !void {
        self.sequence += 1;
        const snap = Snapshot{
            .message_id = message_id,
            .backups = std.StringHashMap(FileBackup).init(self.allocator),
            .timestamp = time_mod.nowMillis(),
        };
        try self.snapshots.append(self.allocator, snap);

        // Evict oldest if over limit
        if (self.snapshots.items.len > self.max_snapshots) {
            const old = self.snapshots.orderedRemove(0);
            self.freeSnapshotBackups(old);
        }
    }

    /// Get diff stats for a snapshot.
    pub fn getDiffStats(_: *Self, _: [16]u8) DiffStats {
        return .{ .additions = 0, .deletions = 0, .files_changed = 0 };
    }

    /// Restore all files from a snapshot by index.
    /// Returns lists of restored (from backup) and deleted (were new) file paths.
    /// Caller owns the returned slices.
    pub const RestoreResult = struct {
        restored: []const []const u8,
        deleted: []const []const u8,
        /// Files whose restore attempt failed (backup unreadable, target
        /// unwritable, delete failed) — surfaced instead of silently
        /// skipped, so "Rollback complete" can no longer report success
        /// over unrestored files.
        failed: []const []const u8,
    };

    pub fn restoreSnapshot(self: *Self, snapshot_idx: usize, io: std.Io) !RestoreResult {
        if (snapshot_idx >= self.snapshots.items.len) return error.InvalidSnapshot;

        logger.info("Restoring snapshot {d} ({d} files)", .{ snapshot_idx, self.snapshots.items[snapshot_idx].backups.count() });

        var restored = std.ArrayList([]const u8).empty;
        defer restored.deinit(self.allocator);
        var deleted = std.ArrayList([]const u8).empty;
        defer deleted.deinit(self.allocator);
        var failed = std.ArrayList([]const u8).empty;
        defer failed.deinit(self.allocator);

        const cwd = std.Io.Dir.cwd();
        const snap = &self.snapshots.items[snapshot_idx];
        var iter = snap.backups.iterator();
        while (iter.next()) |entry| {
            const fp = entry.key_ptr.*;
            const bkp = entry.value_ptr.*;

            if (bkp.backup_path) |bp| {
                // Restore from backup file
                const data = (std.Io.Dir.readFileAlloc(cwd, io, bp, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch {
                    try failed.append(self.allocator, try self.allocator.dupe(u8, fp));
                    continue;
                });
                defer self.allocator.free(data);
                cwd.writeFile(io, .{ .sub_path = fp, .data = data }) catch {
                    logger.warning("Restore write failed: {s}", .{fp});
                    try failed.append(self.allocator, try self.allocator.dupe(u8, fp));
                    continue;
                };
                try restored.append(self.allocator, try self.allocator.dupe(u8, fp));
            } else {
                // File was newly created — delete on rollback
                cwd.deleteFile(io, fp) catch {
                    logger.warning("Restore delete failed: {s}", .{fp});
                    try failed.append(self.allocator, try self.allocator.dupe(u8, fp));
                    continue;
                };
                try deleted.append(self.allocator, try self.allocator.dupe(u8, fp));
            }
        }

        return .{
            .restored = try restored.toOwnedSlice(self.allocator),
            .deleted = try deleted.toOwnedSlice(self.allocator),
            .failed = try failed.toOwnedSlice(self.allocator),
        };
    }

    /// Find snapshot index for a given message_id.
    pub fn findSnapshotForMessage(self: *Self, message_id: [16]u8) ?usize {
        for (self.snapshots.items, 0..) |snap, i| {
            if (std.mem.eql(u8, &snap.message_id, &message_id)) return i;
        }
        return null;
    }
};

pub const DiffStats = struct {
    additions: usize,
    deletions: usize,
    files_changed: usize,
};
