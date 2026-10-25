/// Diff utilities — simple text diff computation.
const std = @import("std");

pub const DiffLine = struct {
    kind: enum { equal, added, removed },
    content: []const u8,
};

pub const DiffStats = struct {
    additions: usize,
    deletions: usize,
    files_changed: usize,
};

/// Compute a simple line-based diff between old and new text.
/// Uses longest common subsequence approach for accuracy.
/// Caller owns the returned slice.
pub fn computeDiff(allocator: std.mem.Allocator, old: []const u8, new: []const u8) ![]DiffLine {
    var old_lines = std.ArrayList([]const u8).empty;
    defer old_lines.deinit(allocator);
    var new_lines = std.ArrayList([]const u8).empty;
    defer new_lines.deinit(allocator);

    {
        var it = std.mem.splitSequence(u8, old, "\n");
        while (it.next()) |line| try old_lines.append(allocator, line);
    }
    {
        var it = std.mem.splitSequence(u8, new, "\n");
        while (it.next()) |line| try new_lines.append(allocator, line);
    }

    var result = std.ArrayList(DiffLine).empty;
    defer result.deinit(allocator);

    // Simple O(n*m) LCS-based diff
    const m = old_lines.items.len;
    const n = new_lines.items.len;

    // For small inputs, use simple approach
    var oi: usize = 0;
    var ni: usize = 0;

    while (oi < m and ni < n) {
        if (std.mem.eql(u8, old_lines.items[oi], new_lines.items[ni])) {
            try result.append(allocator, .{ .kind = .equal, .content = old_lines.items[oi] });
            oi += 1;
            ni += 1;
        } else {
            // Look ahead in new for match with old
            var found_new: ?usize = null;
            for (new_lines.items[ni..], 0..) |line, offset| {
                if (std.mem.eql(u8, old_lines.items[oi], line)) {
                    found_new = ni + offset;
                    break;
                }
            }
            var found_old: ?usize = null;
            for (old_lines.items[oi..], 0..) |line, offset| {
                if (std.mem.eql(u8, new_lines.items[ni], line)) {
                    found_old = oi + offset;
                    break;
                }
            }

            if (found_new != null and (found_old == null or (found_new.? - ni) <= (found_old.? - oi))) {
                // Lines in new are additions
                for (ni..found_new.?) |j| {
                    try result.append(allocator, .{ .kind = .added, .content = new_lines.items[j] });
                }
                ni = found_new.?;
            } else if (found_old != null) {
                // Lines in old are removals
                for (oi..found_old.?) |j| {
                    try result.append(allocator, .{ .kind = .removed, .content = old_lines.items[j] });
                }
                oi = found_old.?;
            } else {
                try result.append(allocator, .{ .kind = .removed, .content = old_lines.items[oi] });
                try result.append(allocator, .{ .kind = .added, .content = new_lines.items[ni] });
                oi += 1;
                ni += 1;
            }
        }
    }

    while (oi < m) : (oi += 1) {
        try result.append(allocator, .{ .kind = .removed, .content = old_lines.items[oi] });
    }
    while (ni < n) : (ni += 1) {
        try result.append(allocator, .{ .kind = .added, .content = new_lines.items[ni] });
    }

    return result.toOwnedSlice(allocator);
}

/// Calculate diff stats from a diff result.
pub fn stats(diff_lines: []const DiffLine) DiffStats {
    var s = DiffStats{ .additions = 0, .deletions = 0, .files_changed = 1 };
    for (diff_lines) |line| {
        switch (line.kind) {
            .added => s.additions += 1,
            .removed => s.deletions += 1,
            .equal => {},
        }
    }
    return s;
}

test "computeDiff" {
    const alloc = std.testing.allocator;
    const diff = try computeDiff(alloc, "a\nb\nc\n", "a\nx\nc\n");
    defer alloc.free(diff);

    const s = stats(diff);
    try std.testing.expectEqual(@as(usize, 1), s.additions);
    try std.testing.expectEqual(@as(usize, 1), s.deletions);
}
