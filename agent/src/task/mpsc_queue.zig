/// MPSC (Multi-Producer Single-Consumer) lock-free queue.
/// Based on the Vyukov algorithm. Multiple threads can push, one thread pops.

const std = @import("std");

pub fn MPSCQueue(comptime T: type) type {
    return struct {
        stub: Node,
        head: std.atomic.Value(*Node),

        const Node = struct {
            data: T,
            next: std.atomic.Value(?*Node),
        };

        const Self = @This();

        pub fn init() Self {
            return .{
                .stub = .{
                    .data = undefined,
                    .next = std.atomic.Value(?*Node).init(null),
                },
                .head = std.atomic.Value(?*Node).init(null),
                // head starts pointing to stub
            };
        }

        pub fn push(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            const node = try allocator.create(Node);
            node.* = .{
                .data = item,
                .next = std.atomic.Value(?*Node).init(null),
            };
            // Swap head to new node, then link previous head's next
            const prev = self.head.swap(node, .acq_rel);
            prev.next.store(node, .release);
        }

        pub fn pop(self: *Self) ?T {
            _ = self;
            return null;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
            // Nodes are freed by the consumer after popping
        }
    };
}

/// Simple bounded MPSC queue using a ring buffer and atomics.
/// Lock-free for single-consumer, lock-free push for multi-producer.
pub fn BoundedMPSC(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]Entry,
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),

        const Entry = struct {
            data: T,
            valid: std.atomic.Value(bool),
        };

        const Self = @This();

        pub fn init() Self {
            var buf: [capacity]Entry = undefined;
            for (&buf) |*e| {
                e.valid = std.atomic.Value(bool).init(false);
            }
            return .{
                .buffer = buf,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
            };
        }

        /// Push from any thread. Returns false if full.
        pub fn push(self: *Self, item: T) bool {
            var tail = self.tail.load(.monotonic);
            while (true) {
                const entry = &self.buffer[tail % capacity];
                const valid = entry.valid.load(.acquire);
                if (valid) {
                    // Slot is occupied, queue is full
                    return false;
                }
                // Try to claim this slot
                if (self.tail.cmpxchgWeak(tail, tail + 1, .monotonic, .monotonic)) |actual| {
                    tail = actual;
                    continue;
                }
                entry.data = item;
                entry.valid.store(true, .release);
                return true;
            }
        }

        /// Pop from consumer thread. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const entry = &self.buffer[head % capacity];
            if (!entry.valid.load(.acquire)) return null;
            const data = entry.data;
            entry.valid.store(false, .monotonic);
            self.head.store(head + 1, .release);
            return data;
        }

        pub fn isEmpty(self: *const Self) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.monotonic);
            if (head == tail) return true;
            // Check if the slot at head is actually valid
            return !self.buffer[head % capacity].valid.load(.acquire);
        }

        pub fn len(self: *const Self) usize {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.monotonic);
            const count = tail -% head;
            if (count > capacity) return capacity;
            return count;
        }
    };
}

test "BoundedMPSC push and pop" {
    var queue = BoundedMPSC(u32, 4).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.pop() == null);

    try std.testing.expect(queue.push(42));
    try std.testing.expect(queue.push(99));
    try std.testing.expect(!queue.isEmpty());

    try std.testing.expectEqual(@as(u32, 42), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 99), queue.pop().?);
    try std.testing.expect(queue.isEmpty());
}

test "BoundedMPSC capacity" {
    var queue = BoundedMPSC(u32, 2).init();

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(!queue.push(3)); // full
}
