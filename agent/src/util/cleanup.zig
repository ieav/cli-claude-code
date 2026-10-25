/// Cleanup registry — register shutdown handlers that run on exit.
const std = @import("std");

const CleanupFn = *const fn () void;

pub const CleanupEntry = struct {
    name: []const u8,
    fn_ptr: CleanupFn,
};

var entries: std.ArrayListUnmanaged(CleanupEntry) = .empty;
var initialized = false;

/// Register a cleanup function to be called on shutdown.
pub fn register(name: []const u8, func: CleanupFn) !void {
    if (!initialized) {
        initialized = true;
    }
    try entries.append(std.heap.smp_allocator, .{ .name = name, .fn_ptr = func });
}

/// Run all registered cleanup functions in LIFO order.
pub fn runAll() void {
    var i: usize = entries.items.len;
    while (i > 0) {
        i -= 1;
        entries.items[i].fn_ptr();
    }
}

/// Remove a cleanup entry by name.
pub fn remove(name: []const u8) void {
    for (entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) {
            _ = entries.orderedRemove(i);
            return;
        }
    }
}

/// Clear all cleanup entries.
pub fn clear() void {
    entries.clearRetainingCapacity();
}
