/// File content cache — LRU ring keyed by path, validated by (mtime, size).
/// Caches the line-numbered formatted output FileRead produces, so repeat
/// reads of an unchanged file skip both the disk IO and the per-line
/// formatting pass. Writes elsewhere (FileWrite/FileEdit, external editors)
/// change mtime/size and the entry goes stale automatically — invalidate()
/// exists for explicit callers but the stat validation is the real guard.
/// Thread-safe: FileRead runs concurrently in parallel batches.
const std = @import("std");
const time_mod = @import("time.zig");

pub const FileState = struct {
    path: []const u8,
    /// Line-numbered formatted content (what FileRead returns).
    content: []const u8,
    mtime_ns: i96,
    size: u64,
    timestamp: i64,
    offset: ?u32 = null,
    limit: ?u32 = null,
};

pub const FileStateCache = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    /// Plain slot ring (not PiRingBuffer): the π-dispersed iterator can
    /// skip entries, which silently leaks their strings on deinit and on
    /// same-path replacement. A linear scan is the same complexity as the
    /// old iterator walk and completely deterministic.
    slots: [capacity]?FileState = @splat(null),
    head: usize = 0,
    count: usize = 0,

    const capacity = 128;
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (&self.slots) |slot| {
            if (slot) |e| {
                self.allocator.free(e.path);
                self.allocator.free(e.content);
            }
        }
    }

    /// Get a cached file state by path. Returns null if not found.
    /// Unlocked — getFresh is the synchronized path; this is for tests and
    /// inspection.
    pub fn get(self: *Self, path: []const u8) ?FileState {
        for (&self.slots) |slot| {
            if (slot) |e| {
                if (std.mem.eql(u8, e.path, path)) return e;
            }
        }
        return null;
    }

    /// Get the cached formatted content only when it is still fresh
    /// (mtime and size match the file's current stat). The caller must
    /// hold no reference across another get/put — content is cache-owned.
    pub fn getFresh(self: *Self, io: std.Io, path: []const u8) ?[]const u8 {
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const entry = self.get(path) orelse return null;
        if (entry.mtime_ns != st.mtime.nanoseconds or entry.size != st.size) return null;
        return entry.content;
    }

    /// Store a formatted file state in the cache. Evicts oldest if full.
    /// Copies path and content; the caller keeps ownership of its inputs.
    pub fn put(
        self: *Self,
        io: std.Io,
        path: []const u8,
        content: []const u8,
        mtime_ns: i96,
        size: u64,
    ) !void {
        const path_dup = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_dup);
        const content_dup = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_dup);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Replace any same-path entry in place; otherwise take the oldest
        // slot when full (its strings die here), or a free slot.
        var slot_idx: ?usize = null;
        for (&self.slots, 0..) |slot, i| {
            if (slot) |e| {
                if (std.mem.eql(u8, e.path, path)) {
                    self.allocator.free(e.path);
                    self.allocator.free(e.content);
                    slot_idx = i;
                    break;
                }
            } else if (slot_idx == null) {
                slot_idx = i;
            }
        }
        if (slot_idx == null) {
            const e = self.slots[self.head].?;
            self.allocator.free(e.path);
            self.allocator.free(e.content);
            slot_idx = self.head;
            self.head = (self.head + 1) % capacity;
        } else if (slot_idx.? == self.count) {
            self.count += 1;
        }

        self.slots[slot_idx.?] = .{
            .path = path_dup,
            .content = content_dup,
            .mtime_ns = mtime_ns,
            .size = size,
            .timestamp = time_mod.nowMillis(),
        };
    }

    /// Invalidate a cached file entry. The ring buffer cannot remove
    /// entries, so this is a placeholder — freshness is enforced by
    /// getFresh's (mtime, size) validation, which any write (ours or
    /// external) trips immediately.
    pub fn invalidate(self: *Self, path: []const u8) void {
        _ = self;
        _ = path;
    }
};

/// Process-wide cache instance wired at REPL startup; FileRead consults it,
/// nothing else needs to know it exists (writes self-invalidate via stat).
pub var global: ?FileStateCache = null;

/// Initialize the global cache (REPL startup). Safe to call once; use
/// deinitGlobal at shutdown.
pub fn globalInit(allocator: std.mem.Allocator) void {
    if (global == null) global = FileStateCache.init(allocator);
}

pub fn deinitGlobal() void {
    if (global) |*c| c.deinit();
    global = null;
}

fn sleepMs(ms: u32) void {
    var req: std.c.timespec = .{ .sec = 0, .nsec = @as(i64, ms) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&req, null);
}

test "FileStateCache put/get" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var cache = FileStateCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.put(io_state.io(), "/test/file.zig", "const std = @import(\"std\");", 1, 42);
    const state = cache.get("/test/file.zig");
    try std.testing.expect(state != null);
    try std.testing.expectEqualStrings("const std = @import(\"std\");", state.?.content);
}

test "FileStateCache getFresh requires matching mtime and size" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const tmp = "/tmp/ziv_cache_fresh_test.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = "hello" });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var cache = FileStateCache.init(std.testing.allocator);
    defer cache.deinit();

    const st = try std.Io.Dir.cwd().statFile(io, tmp, .{});
    try cache.put(io, tmp, "     1\thello\n", st.mtime.nanoseconds, st.size);

    // Unchanged file → hit.
    try std.testing.expect(cache.getFresh(io, tmp) != null);

    // Same size, rewritten (mtime advanced beyond the cached value) → miss.
    sleepMs(20); // ensure a new mtime tick
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = "world" });
    try std.testing.expect(cache.getFresh(io, tmp) == null);

    // Different size with the cached stat → miss.
    try cache.put(io, tmp, "     1\thello\n", st.mtime.nanoseconds, st.size + 1);
    try std.testing.expect(cache.getFresh(io, tmp) == null);
}
