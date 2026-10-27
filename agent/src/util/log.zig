/// Structured logging — info, warning, error, debug levels.
/// Writes to stderr. View with: ./ziv 2>ziv.log
const std = @import("std");
const time_mod = @import("time.zig");

pub const Level = enum {
    debug,
    info,
    warning,
    error_level,

    pub fn tag(self: Level) []const u8 {
        return switch (self) {
            .debug => "DBG",
            .info => "INF",
            .warning => "WRN",
            .error_level => "ERR",
        };
    }
};

var current_level: Level = .warning;

/// Raise verbosity via ZIV_LOG=debug|info|warning (call once at startup).
pub fn initFromEnv() void {
    const v = @import("env.zig").get("ZIV_LOG") orelse return;
    if (std.mem.eql(u8, v, "debug")) current_level = .debug;
    if (std.mem.eql(u8, v, "info")) current_level = .info;
    if (std.mem.eql(u8, v, "warning")) current_level = .warning;
}

pub fn setLevel(level: Level) void {
    current_level = level;
}

pub fn log(comptime level: Level, comptime format: []const u8, args: anytype) void {
    if (@backingInt(level) < @backingInt(current_level)) return;

    const ts = time_mod.nowMillis();
    const prefix: []const u8 = switch (level) {
        .debug => "[DBG]",
        .info => "[INF]",
        .warning => "[WRN]",
        .error_level => "[ERR]",
    };
    std.debug.print("{s} {d} " ++ format ++ "\n", .{ prefix, ts } ++ args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    log(.debug, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    log(.info, format, args);
}

pub fn warning(comptime format: []const u8, args: anytype) void {
    log(.warning, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    log(.error_level, format, args);
}
