/// Environment variable utilities.
/// Compatible with Zig 0.16.
const std = @import("std");

/// Get an environment variable as a string slice. Returns null if not set.
/// Uses C getenv via std.c since Zig 0.16 removed std.posix.getenv.
pub fn get(key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const key_z: [*:0]const u8 = @ptrCast(buf[0 .. key.len + 1]);

    const result = std.c.getenv(key_z) orelse return null;
    return std.mem.sliceTo(result, 0);
}

/// Get an environment variable or return a default value.
pub fn getOr(key: []const u8, default: []const u8) []const u8 {
    return get(key) orelse default;
}

/// Get an environment variable and parse as integer.
pub fn getInt(key: []const u8, comptime T: type, default: T) T {
    const val = get(key) orelse return default;
    return std.fmt.parseInt(T, val, 10) catch default;
}

/// Get an environment variable and parse as boolean.
/// Accepts: "1", "true", "yes", "on" as true.
pub fn getBool(key: []const u8, default: bool) bool {
    const val = get(key) orelse return default;
    if (std.mem.eql(u8, val, "1")) return true;
    if (std.mem.eqlCaseInsensitiveASCII(val, "true")) return true;
    if (std.mem.eqlCaseInsensitiveASCII(val, "yes")) return true;
    if (std.mem.eqlCaseInsensitiveASCII(val, "on")) return true;
    return false;
}

/// Get the HOME directory path.
pub fn homeDir() ?[]const u8 {
    return get("HOME") orelse get("USERPROFILE");
}

/// Get the PATH environment variable.
pub fn pathEnv() ?[]const u8 {
    return get("PATH");
}

/// Get the EDITOR environment variable, with fallback.
pub fn editor() []const u8 {
    return get("EDITOR") orelse get("VISUAL") orelse "vi";
}

/// Get the SHELL environment variable, with fallback.
pub fn shellPath() []const u8 {
    return get("SHELL") orelse "/bin/sh";
}

test "env getOr" {
    const val = getOr("NONEXISTENT_VAR_ZIG_TEST", "default_val");
    try std.testing.expectEqualStrings("default_val", val);
}

test "env getBool" {
    try std.testing.expect(!getBool("NONEXISTENT_BOOL_ZIG", false));
    try std.testing.expect(getBool("NONEXISTENT_BOOL_ZIG", true));
}
