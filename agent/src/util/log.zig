/// Structured logging — info, warning, error, debug levels.
/// Writes to stderr. View with: ./ziv 2>ziv.log
const std = @import("std");
const wincompat = @import("./wincompat.zig");
const time_mod = @import("time.zig");

pub const Level = enum {
    debug,
    info,
    notice,
    warning,
    error_level,

    pub fn tag(self: Level) []const u8 {
        return switch (self) {
            .debug => "DBG",
            .info => "INF",
            .notice => "INF",
            .warning => "WRN",
            .error_level => "ERR",
        };
    }
};

var current_level: Level = .notice;

// ── Persistent file sink ──────────────────────────────────────────────
// The interactive-stderr mute below means a TUI session produces NO
// visible diagnostics at all — users reported "看不到详细日志" when a
// gateway stream died mid-flight. The file sink always receives every
// line, mute or not. One file per session (previous session renamed to
// ziv.log.prev), so "what just went wrong" is the file's whole content.
var log_file: ?std.Io.File = null;
// Must start as null, NOT undefined: log() may fire before setLogFile
// (startup paths, unit tests), and branching on an undefined optional is
// UB that only "works" while .bss happens to be zero-filled.
var log_writer_state: ?std.Io.File.Writer = null;
var log_buf: [4096]u8 = undefined;
var log_file_path: [256]u8 = undefined;
var log_file_path_len: usize = 0;
/// Spin lock: log() runs on any thread but holds are nanoseconds-long
/// writes; a contended line is skipped (stderr still gets it).
var file_mutex: std.atomic.Mutex = .unlocked;

/// Open <dir>/ziv.log as the persistent sink (called once at REPL start,
/// after the data dir exists). Previous session's log moves to .prev.
/// Best effort: any failure leaves logging stderr-only.
pub fn setLogFile(io: std.Io, dir_path: []const u8) void {
    const d: std.Io.Dir = .cwd();
    d.createDirPath(io, dir_path) catch return;

    // Separate buffers: one shared buffer would alias `path` onto the
    // longer `prev_path` content (works only by shared-prefix luck).
    var path_buf: [256]u8 = undefined;
    var prev_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/ziv.log", .{dir_path}) catch return;
    const prev_path = std.fmt.bufPrint(&prev_buf, "{s}/ziv.log.prev", .{dir_path}) catch return;

    // Rotate: last session's log becomes .prev (delete stale .prev first).
    d.deleteFile(io, prev_path) catch {};
    d.rename(path, d, prev_path, io) catch {};

    const file = d.createFile(io, path, .{}) catch return;
    log_file = file;
    log_writer_state = std.Io.File.Writer.init(file, io, &log_buf);
    const stored = std.fmt.bufPrint(&log_file_path, "{s}", .{path}) catch return;
    log_file_path_len = stored.len;
}

/// The active log file path, or "" when file logging is off.
pub fn logFilePath() []const u8 {
    return if (log_file == null) "" else log_file_path[0..log_file_path_len];
}

/// Interactive-TTY mute: stderr is also the terminal ziv is DRAWING its
/// TUI on — a log line printed mid-generation lands on the cursor (often
/// the live region's input row) and smears the layout. When stderr is a
/// TTY, logs are suppressed unless ZIV_LOG_STDERR=1; a redirect
/// (./ziv 2>ziv.log) is not a TTY and keeps the documented behavior.
var stderr_quiet: ?bool = null;

fn stderrMuted() bool {
    if (stderr_quiet) |q| return q;
    const q = if (wincompat.isTtyStderr())
        !isLogStderrForced()
    else
        false;
    stderr_quiet = q;
    return q;
}

fn isLogStderrForced() bool {
    const env = @import("env.zig");
    const v = env.get("ZIV_LOG_STDERR") orelse return false;
    return std.mem.eql(u8, v, "1");
}

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
    const ts = time_mod.nowMillis();
    const prefix: []const u8 = switch (level) {
        .debug => "[DBG]",
        .info => "[INF]",
        .notice => "[INF]",
        .warning => "[WRN]",
        .error_level => "[ERR]",
    };

    // File sink first — noisier than stderr by design: its floor is info,
    // so whenever the stderr bar sits ABOVE info (the default notice), the
    // file still records info lines; when ZIV_LOG lowers the bar below
    // info, the file follows it down. It ignores the interactive-stderr
    // mute entirely. Backing order: debug < info < notice < warning < err.
    if (log_writer_state) |*lw| {
        const file_min: Level = if (@backingInt(current_level) > @backingInt(Level.info)) .info else current_level;
        if (@backingInt(level) >= @backingInt(file_min)) {
            if (file_mutex.tryLock()) {
                defer file_mutex.unlock();
                var fbuf: [2048]u8 = undefined;
                const line = std.fmt.bufPrint(&fbuf, "{s} {d} " ++ format ++ "\n", .{ prefix, ts } ++ args) catch "| <log line too long>\n";
                lw.interface.writeAll(line) catch {};
                std.Io.File.Writer.flush(lw) catch {};
            }
        }
    }

    if (@backingInt(level) < @backingInt(current_level)) return;
    if (stderrMuted()) return;
    std.debug.print("{s} {d} " ++ format ++ "\n", .{ prefix, ts } ++ args);
}

pub fn notice(comptime format: []const u8, args: anytype) void {
    log(.notice, format, args);
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

test "file sink records info lines at the default notice level" {
    // Regression: file_min's comparison was backwards, so with the default
    // notice bar the "noisier than stderr" sink silently dropped every info
    // line — ziv.log existed but stayed empty for a whole session.
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    var dir_buf: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "/tmp/ziv_log_test_{d}", .{std.c.getpid()}) catch return;
    var path_buf: [256]u8 = undefined;
    const log_path = std.fmt.bufPrint(&path_buf, "{s}/ziv.log", .{dir}) catch return;

    setLogFile(io, dir);
    // Keep the sink from leaking into other tests (fd leak of one open
    // handle is acceptable for the process lifetime).
    defer {
        log_writer_state = null;
        log_file = null;
        log_file_path_len = 0;
        const d: std.Io.Dir = .cwd();
        d.deleteFile(io, log_path) catch {};
        d.deleteDir(io, dir) catch {};
    }

    info("extraction parsed: {d} facts", .{3});

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, log_path, std.testing.allocator, .limited(4096)) catch |e| {
        // Surface WHY (missing file vs unreadable) — this test failed
        // silently-empty once already.
        std.debug.print("read back failed: {s}\n", .{@errorName(e)});
        return error.LogFileUnreadable;
    };
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "extraction parsed: 3 facts") != null);
}
