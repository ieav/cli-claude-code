//! Cross-session input history for the line editor — `.ziv/input_history`
//! in the working directory, newest last, capped at INPUT_HISTORY_MAX
//! entries. Whole-file rewrite under a flock'd mutex (tmp+rename swap);
//! merged across concurrent ziv windows. Carved out of repl.zig
//! (P1 step 7c, pure move).

const std = @import("std");
const fs_ops = @import("../util/fs_ops.zig");
const logger = @import("../util/log.zig");

/// Cross-session input history for the line editor: `.ziv/input_history` in
/// the working directory, newest last, capped at INPUT_HISTORY_MAX entries.
/// Whole-file rewrite on every commit (≤ ~50 KB) — no append mode needed and
/// rotation comes for free.
const INPUT_HISTORY_FILE = ".ziv/input_history";
/// Cross-process mutex for history saves. Locked via createFile's atomic
/// flock (blocking); its inode never changes — locking the history file
/// itself would be voided by the tmp+rename swap that replaces it.
const INPUT_HISTORY_LOCK = ".ziv/input_history.lock";
const INPUT_HISTORY_MAX: usize = 500;

pub fn loadInputHistory(alloc: std.mem.Allocator, io: std.Io, history: *std.ArrayList([]u8)) void {
    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, INPUT_HISTORY_FILE, alloc, std.Io.Limit.limited(256 * 1024)) catch return;
    defer alloc.free(contents);
    // Collect first, keep the TAIL: breaking early on an oversized file would
    // recall the OLDEST entries and silently drop the newest ones.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines.append(alloc, line) catch return;
    }
    const start = if (lines.items.len > INPUT_HISTORY_MAX) lines.items.len - INPUT_HISTORY_MAX else 0;
    for (lines.items[start..]) |line| {
        if (history.items.len > 0 and std.mem.eql(u8, history.items[history.items.len - 1], line)) continue;
        const owned = alloc.dupe(u8, line) catch return;
        history.append(alloc, owned) catch {
            alloc.free(owned);
            return;
        };
    }
}

/// Merge this session's entries with whatever another concurrent window has
/// written since our startup snapshot. Pure function over line lists
/// (borrowed slices); returns the tail-capped merge, caller owns the result.
pub fn mergeInputHistory(alloc: std.mem.Allocator, file_lines: []const []const u8, session: []const []const u8) ![]const []const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    errdefer merged.deinit(alloc);
    try merged.appendSlice(alloc, file_lines);
    for (session, 0..) |line, i| {
        // Consecutive duplicates collapse (matches the pre-concurrency
        // save behavior).
        if (merged.items.len > 0 and std.mem.eql(u8, merged.items[merged.items.len - 1], line)) continue;
        // Present elsewhere: a startup-loaded echo — skip. The FINAL session
        // line is the just-typed command: move it to the tail so a re-typed
        // old command recalls last, exactly like the single-window behavior
        // this merge replaced (a global skip used to strand it mid-file).
        const is_final = i + 1 == session.len;
        var found: ?usize = null;
        for (merged.items, 0..) |m, mi| {
            if (std.mem.eql(u8, m, line)) {
                found = mi;
                break;
            }
        }
        if (found) |mi| {
            if (is_final) {
                const moved = merged.orderedRemove(mi);
                try merged.append(alloc, moved);
            }
            continue;
        }
        try merged.append(alloc, line);
    }
    const start = if (merged.items.len > INPUT_HISTORY_MAX) merged.items.len - INPUT_HISTORY_MAX else 0;
    const tail = try alloc.dupe([]const u8, merged.items[start..]);
    merged.deinit(alloc);
    return tail;
}

/// Persist the in-memory input history (the line editor already appended the
/// just-committed line, with consecutive-duplicate suppression). Concurrent
/// windows in the same directory MERGE instead of last-writer-wins, and the
/// write is tmp+rename atomic so a parallel reader never sees a half file.
pub fn saveInputHistory(alloc: std.mem.Allocator, history: *std.ArrayList([]u8)) void {
    if (history.items.len == 0) return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // Session tail (single-line entries only — the file is one entry per
    // line; multi-line pastes stay session-only, up-arrow recall works).
    var session: std.ArrayList([]const u8) = .empty;
    defer session.deinit(alloc);
    const start = if (history.items.len > INPUT_HISTORY_MAX) history.items.len - INPUT_HISTORY_MAX else 0;
    for (history.items[start..]) |line| {
        if (std.mem.indexOfScalar(u8, line, '\n') != null) continue;
        session.append(alloc, line) catch return;
    }

    // What's on disk right now (another window may have written since our
    // startup snapshot): merge, keeping their entries and ours. The whole
    // read-merge-write runs under a cross-process flock — two windows
    // committing in the same millisecond used to last-writer-wins anyway.
    // flock goes through libc directly (blocking), NOT via the Io vtable:
    // createFile's embedded .lock under std.Io.Threaded failed silently and
    // the losing window skipped its save entirely.
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    var lock_file = std.Io.Dir.cwd().createFile(io_state.io(), INPUT_HISTORY_LOCK, .{
        .read = true,
        .truncate = false,
    }) catch blk: {
        // No lock file, no lock — but the history still deserves a save.
        break :blk null;
    };
    defer if (lock_file) |*lf| lf.close(io_state.io());
    var contents_owned: ?[]u8 = null;
    defer if (contents_owned) |c| alloc.free(c);
    var history_locked = false;
    defer if (history_locked) {
        _ = std.c.flock(lock_file.?.handle, std.posix.LOCK.UN);
    };
    if (lock_file != null) {
        // Bounded acquisition: a suspended (Ctrl-Z'd) holder never releases,
        // and a blocking LOCK.EX on the Enter path would freeze this prompt
        // forever. Retry briefly, then degrade to a lockless save — same
        // semantics as the no-lock-file fallback.
        var tries: usize = 0;
        while (tries < 5) : (tries += 1) {
            if (std.c.flock(lock_file.?.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) == 0) {
                history_locked = true;
                break;
            }
            var req: std.c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&req, null);
        }
        if (!history_locked) {
            logger.warning("input history lock busy — saving without lock", .{});
            lock_file.?.close(io_state.io());
            lock_file = null;
        }
    }
    var file_lines: std.ArrayList([]const u8) = .empty;
    defer file_lines.deinit(alloc);
    if (std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io_state.io(), INPUT_HISTORY_FILE, alloc, std.Io.Limit.limited(256 * 1024))) |contents| {
        // OWNERSHIP: file_lines borrows slices into `contents`, so it must
        // outlive the if-block — a defer inside the block freed it on block
        // exit and merge then read freed memory (0xAA garbage entries).
        contents_owned = contents;
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            file_lines.append(alloc, line) catch break;
        }
    } else |_| {}

    const merged = mergeInputHistory(alloc, file_lines.items, session.items) catch return;
    defer alloc.free(merged);
    for (merged) |line| {
        buf.appendSlice(alloc, line) catch return;
        buf.append(alloc, '\n') catch return;
    }

    fs_ops.ensureDir(".ziv") catch return;
    var tmp_buf: [128]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp{d}", .{ INPUT_HISTORY_FILE, std.c.getpid() }) catch return;
    fs_ops.writeFile(tmp, buf.items) catch
        return logger.warning("input history save failed", .{});
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), INPUT_HISTORY_FILE, io_state.io()) catch {
        // Rename failed — fall back to a plain write so the history is at
        // least saved, not silently dropped.
        fs_ops.writeFile(INPUT_HISTORY_FILE, buf.items) catch
            logger.warning("input history save failed", .{});
    };
}



test "mergeInputHistory unions concurrent windows and caps the tail" {
    const alloc = std.testing.allocator;
    // Window B wrote entries after our startup snapshot of [a, b].
    const file = [_][]const u8{ "a", "b", "B1", "B2" };
    const session = [_][]const u8{ "a", "b", "mine" };
    const merged = try mergeInputHistory(alloc, &file, &session);
    defer alloc.free(merged);
    // Their new entries survive, ours appended, no duplicates.
    try std.testing.expectEqual(@as(usize, 5), merged.len);
    try std.testing.expectEqualStrings("B1", merged[2]);
    try std.testing.expectEqualStrings("B2", merged[3]);
    try std.testing.expectEqualStrings("mine", merged[4]);

    // Re-typed old command (final session line) moves to the TAIL — the
    // global-skip used to strand it mid-file, regressing single-window
    // recall order.
    const f2 = [_][]const u8{ "a", "b", "c" };
    const s2 = [_][]const u8{ "a", "b", "c", "a" };
    const m3 = try mergeInputHistory(alloc, &f2, &s2);
    defer alloc.free(m3);
    try std.testing.expectEqual(@as(usize, 3), m3.len);
    try std.testing.expectEqualStrings("a", m3[2]); // moved to tail

    // Consecutive duplicates collapse.
    const f3 = [_][]const u8{"x"};
    const m4 = try mergeInputHistory(alloc, &f3, &f3);
    defer alloc.free(m4);
    try std.testing.expectEqual(@as(usize, 1), m4.len);

    // Tail cap: 10 file + 495 fresh session entries → exactly 500, oldest dropped.
    var big_file: [10][]const u8 = undefined;
    for (&big_file, 0..) |*e, i| e.* = if (i % 2 == 0) "old-even" else "old-odd";
    var names: [495][]const u8 = undefined;
    var name_bufs: [495][16]u8 = undefined;
    var big_sess: std.ArrayList([]const u8) = .empty;
    defer big_sess.deinit(alloc);
    var n: usize = 0;
    while (n < 495) : (n += 1) {
        names[n] = try std.fmt.bufPrint(&name_bufs[n], "fresh{d}", .{n});
        try big_sess.append(alloc, names[n]);
    }
    const m5 = try mergeInputHistory(alloc, &big_file, big_sess.items);
    defer alloc.free(m5);
    try std.testing.expectEqual(@as(usize, 500), m5.len);
    try std.testing.expectEqualStrings("old-odd", m5[0]); // 5 oldest file lines dropped
    try std.testing.expectEqualStrings("fresh494", m5[499]);
}

