/// Memoization cache — store computed results keyed by input.
const std = @import("std");

/// Simple key-value memoization cache with a maximum capacity.
pub fn MemoCache(comptime Key: type, comptime Value: type, comptime capacity: usize) type {
    return struct {
        entries: [capacity]?Entry,
        count: usize,

        const Entry = struct {
            key: Key,
            value: Value,
        };

        const Self = @This();

        pub fn init() Self {
            return .{
                .entries = @splat(null),
                .count = 0,
            };
        }

        pub fn get(self: *const Self, key: Key) ?Value {
            for (self.entries) |e| {
                if (e) |entry| {
                    if (keyEql(entry.key, key)) return entry.value;
                }
            }
            return null;
        }

        pub fn put(self: *Self, key: Key, value: Value) void {
            // Check for existing key
            for (&self.entries) |*e| {
                if (e.*) |*entry| {
                    if (keyEql(entry.key, key)) {
                        entry.value = value;
                        return;
                    }
                }
            }
            // Find empty slot or evict oldest (index 0)
            var slot: usize = 0;
            var found = false;
            for (self.entries, 0..) |e, i| {
                if (e == null) {
                    slot = i;
                    found = true;
                    break;
                }
            }
            if (!found) {
                slot = 0; // Evict first entry
            } else {
                self.count += 1;
            }
            self.entries[slot] = .{ .key = key, .value = value };
        }

        pub fn clear(self: *Self) void {
            for (&self.entries) |*e| e.* = null;
            self.count = 0;
        }

        fn keyEql(a: Key, b: Key) bool {
            return switch (@typeInfo(Key)) {
                .pointer => std.mem.eql(u8, a, b),
                else => a == b,
            };
        }
    };
}

test "MemoCache basic" {
    var cache = MemoCache([]const u8, u32, 4).init();
    try std.testing.expect(cache.get("key") == null);
    cache.put("key", 42);
    try std.testing.expectEqual(@as(u32, 42), cache.get("key").?);
    cache.put("key", 100);
    try std.testing.expectEqual(@as(u32, 100), cache.get("key").?);
}
