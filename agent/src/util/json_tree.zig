/// Deep-copy / free json.Value trees across allocator boundaries
/// (extracted from repl.zig P1; shared by the stream cluster and the
/// content-block history utilities).
const std = @import("std");

/// Deep-copy a json.Value tree onto `alloc` (the response DOM is arena-owned
/// and freed after history takes over).
pub fn dupeJsonValue(alloc: std.mem.Allocator, v: std.json.Value) anyerror!std.json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .string, .number_string => |s| blk: {
            const d = try alloc.dupe(u8, s);
            break :blk if (v == .string) .{ .string = d } else .{ .number_string = d };
        },
        .array => |arr| blk: {
            var out = std.json.Array.init(alloc);
            for (arr.items) |item| try out.append(try dupeJsonValue(alloc, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            errdefer out.deinit(alloc);
            var it = obj.iterator();
            while (it.next()) |e| {
                try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), try dupeJsonValue(alloc, e.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

pub fn freeJsonValue(alloc: std.mem.Allocator, v: std.json.Value) void {
    switch (v) {
        .null, .bool, .integer, .float => {},
        .string, .number_string => |s| alloc.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(alloc, item);
            var mut = arr;
            mut.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |e| {
                alloc.free(e.key_ptr.*);
                freeJsonValue(alloc, e.value_ptr.*);
            }
            var mut = obj;
            mut.deinit(alloc);
        },
    }
}

