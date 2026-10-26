/// JSON helpers — safe field extraction and common JSON operations.
const std = @import("std");

/// Get a string field from a JSON value. Returns null if missing or not a string.
pub fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = value.object.get(key) orelse return null;
    return obj.string;
}

/// Get an integer field from a JSON value. Returns null if missing or not an integer.
pub fn getInt(value: std.json.Value, key: []const u8) ?i64 {
    const obj = value.object.get(key) orelse return null;
    return switch (obj) {
        .integer => |v| v,
        else => null,
    };
}

/// Get a float field from a JSON value. Returns null if missing or not a number.
pub fn getFloat(value: std.json.Value, key: []const u8) ?f64 {
    const obj = value.object.get(key) orelse return null;
    return switch (obj) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => null,
    };
}

/// Get a boolean field from a JSON value. Returns null if missing or not a bool.
pub fn getBool(value: std.json.Value, key: []const u8) ?bool {
    const obj = value.object.get(key) orelse return null;
    return switch (obj) {
        .bool => |v| v,
        else => null,
    };
}

/// Get an array field from a JSON value. Returns null if missing or not an array.
pub fn getArray(value: std.json.Value, key: []const u8) ?[]std.json.Value {
    const obj = value.object.get(key) orelse return null;
    return switch (obj) {
        .array => |v| v.items,
        else => null,
    };
}

/// Get a nested object field. Returns null if missing or not an object.
pub fn getObject(value: std.json.Value, key: []const u8) ?std.json.Value {
    const obj = value.object.get(key) orelse return null;
    return switch (obj) {
        .object => obj,
        else => null,
    };
}

/// Parse a JSON string into a Value. Returns a Parsed wrapper; call
/// `parsed.deinit()` to free the DOM.
pub fn parse(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
}

/// Serialize a JSON Value to a string. Caller owns the returned slice.
pub fn serialize(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try std.json.stringify(value, .{}, buf.writer(allocator));
    return buf.toOwnedSlice(allocator);
}

/// Serialize a JSON Value to a pretty-printed string. Caller owns the returned slice.
pub fn serializePretty(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try std.json.stringify(value, .{ .whitespace = .indent_2 }, buf.writer(allocator));
    return buf.toOwnedSlice(allocator);
}

test "getString" {
    const alloc = std.testing.allocator;
    const parsed = try parse(alloc,
        \\{"name":"test","count":42,"active":true}
    );
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqualStrings("test", getString(v, "name").?);
    try std.testing.expectEqual(@as(i64, 42), getInt(v, "count").?);
    try std.testing.expectEqual(true, getBool(v, "active").?);
    try std.testing.expect(getString(v, "missing") == null);
}
