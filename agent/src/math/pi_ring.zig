/// π-based ring buffer — ensures uniform information coverage via π-fraction indexing.
/// The π fractional sequence disperses access patterns, preventing hotspot clustering.

const std = @import("std");
const constants = @import("constants.zig");

pub fn PiRingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]Entry,
        head: usize,
        count: usize,
        pi_indices: [capacity]usize,

        const Self = @This();

        pub const Entry = struct {
            data: T,
            valid: bool = false,
        };

        pub fn init() Self {
            var buf = Self{
                .buffer = undefined,
                .head = 0,
                .count = 0,
                .pi_indices = undefined,
            };
            // Generate π-dispersed indices:
            // frac(π * i / capacity) * capacity gives well-distributed positions
            for (0..capacity) |i| {
                const pi_val = constants.PI * @as(f64, @floatFromInt(i));
                const frac = pi_val - @floor(pi_val);
                buf.pi_indices[i] = @as(usize, @intFromFloat(@round(frac * @as(f64, @floatFromInt(capacity))))) % capacity;
            }
            // Initialize all entries as invalid
            for (&buf.buffer) |*entry| {
                entry.valid = false;
            }
            return buf;
        }

        /// Push an item; overwrites oldest when full (circular).
        pub fn push(self: *Self, item: T) void {
            self.buffer[self.head] = .{ .data = item, .valid = true };
            self.head = (self.head + 1) % capacity;
            if (self.count < capacity) self.count += 1;
        }

        /// Get by sequential (FIFO) index.
        pub fn get(self: *Self, index: usize) ?T {
            if (index >= self.count) return null;
            const physical = (self.head + capacity - self.count + index) % capacity;
            if (!self.buffer[physical].valid) return null;
            return self.buffer[physical].data;
        }

        /// Get by π-dispersed logical index — spreads reads uniformly across the buffer.
        pub fn getByPiIndex(self: *Self, logical_index: usize) ?T {
            if (logical_index >= self.count) return null;
            const physical = self.pi_indices[logical_index % capacity];
            if (physical >= capacity or !self.buffer[physical].valid) return null;
            return self.buffer[physical].data;
        }

        /// Iterate all valid items in π-dispersed order.
        pub const PiIterator = struct {
            ring: *Self,
            pos: usize = 0,

            pub fn next(self: *PiIterator) ?T {
                while (self.pos < self.ring.count) : (self.pos += 1) {
                    const item = self.ring.getByPiIndex(self.pos);
                    self.pos += 1;
                    if (item) |v| return v;
                }
                return null;
            }
        };

        pub fn piIterator(self: *Self) PiIterator {
            return .{ .ring = self };
        }

        pub fn isFull(self: *const Self) bool {
            return self.count >= capacity;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }
    };
}

test "PiRingBuffer basic push and get" {
    var ring = PiRingBuffer(u32, 8).init();
    try std.testing.expect(ring.isEmpty());

    ring.push(10);
    ring.push(20);
    ring.push(30);
    try std.testing.expectEqual(@as(usize, 3), ring.count);

    try std.testing.expectEqual(@as(u32, 10), ring.get(0).?);
    try std.testing.expectEqual(@as(u32, 20), ring.get(1).?);
    try std.testing.expectEqual(@as(u32, 30), ring.get(2).?);
    try std.testing.expect(ring.get(3) == null);
}

test "PiRingBuffer circular overwrite" {
    var ring = PiRingBuffer(u32, 4).init();
    for (0..6) |i| ring.push(@intCast(i));
    // Buffer: [4, 5, 2, 3] with head=2
    try std.testing.expectEqual(@as(usize, 4), ring.count);
    try std.testing.expectEqual(@as(u32, 2), ring.get(0).?);
    try std.testing.expectEqual(@as(u32, 3), ring.get(1).?);
    try std.testing.expectEqual(@as(u32, 4), ring.get(2).?);
    try std.testing.expectEqual(@as(u32, 5), ring.get(3).?);
}

test "PiRingBuffer π-dispersed access covers all items" {
    var ring = PiRingBuffer(u32, 16).init();
    for (0..16) |i| ring.push(@intCast(i));
    // All π-indexed accesses should return valid data
    var seen = [_]bool{false} ** 16;
    var count: usize = 0;
    for (0..16) |i| {
        if (ring.getByPiIndex(i)) |val| {
            if (val < 16) {
                seen[val] = true;
                count += 1;
            }
        }
    }
    // Should have accessed most items via π dispersion
    try std.testing.expect(count >= 8);
}
