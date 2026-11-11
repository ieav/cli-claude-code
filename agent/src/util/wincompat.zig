//! Platform seam for the Windows port (L0 of the 2026-11-12 plan).
//!
//! Every POSIX-only call the codebase makes routes through here. The
//! POSIX side is the CURRENT behavior, moved verbatim; the Windows side
//! starts as conservative compile-passing stubs that FAIL CLOSED (poll
//! reports "not ready", kills are no-ops with a log line) so a stubbed
//! build cannot pretend to work — L1 (termio) and L2 (winproc Job
//! Objects) replace the stubs with real implementations:
//!   sleepMs        done (std.Thread.sleep is cross-platform)
//!   pollInReady    L1: WaitForSingleObject/GetNumberOfConsoleInputEvents
//!   termWidth/Height L1: GetConsoleScreenBufferInfo
//!   raw-mode guard L1: SetConsoleMode(+ENABLE_VIRTUAL_TERMINAL_*)
//!   killGroup      L2: TerminateJobObject
//!   shutdownFd     L3: CancelIoEx on a duplicated handle
//!   sigaction INT  L1: SetConsoleCtrlHandler
const std = @import("std");
const builtin = @import("builtin");
const logger = @import("log.zig");
const termio = @import("termio.zig");

pub const is_windows = builtin.os.tag == .windows;

// ─── Win32 declarations (0.17's std binds almost none of these) ───
// Wrapped in a comptime-chosen struct so a posix build never analyzes
// the .winapi callconv (illegal off windows).
const w = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) void;
    pub extern "kernel32" fn GetSystemTimeAsFileTime(lpFileTime: *std.os.windows.FILETIME) callconv(.winapi) void;
    pub extern "kernel32" fn WaitForSingleObject(hHandle: std.os.windows.HANDLE, dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) std.os.windows.DWORD;
    pub extern "kernel32" fn GetExitCodeProcess(hProcess: std.os.windows.HANDLE, lpExitCode: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn TerminateProcess(hProcess: std.os.windows.HANDLE, uExitCode: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    pub const STD_ERROR_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -12));
} else struct {};

pub const win32 = if (builtin.os.tag == .windows) struct {
    pub const sleepMs = w.Sleep;
    pub const fileTimeNow = w.GetSystemTimeAsFileTime;
    pub const waitFor = w.WaitForSingleObject;
    pub const exitCode = w.GetExitCodeProcess;
    pub const terminate = w.TerminateProcess;
} else struct {};

/// Blocking anonymous pipe pair (no O_NONBLOCK — the POSIX contract the
/// MCP stdio transport depends on). posix: Io.Threaded.pipe2; windows:
/// mingw's _pipe (binary, blocking).
pub fn pipeBlocking() ![2]i32 {
    // Windows lands with M3 (CreatePipe + HANDLE-typed seam); MCP stdio
    // was cut from the MVP, so L0 stubs closed here.
    if (builtin.os.tag == .windows) return error.PipeUnavailable;
    return std.Io.Threaded.pipe2(.{});
}

/// Millisecond sleep — the ONE primitive that works everywhere on day
/// one: kernel32.Sleep on windows, nanosleep on posix. (std.Thread.sleep
/// is gone in 0.17; std.Io.sleep needs an Io instance the pure helpers
/// don't have.) The comptime tag check keeps the posix arm from being
/// type-checked on windows (std.c.timespec is void there).
pub fn sleepMs(ms: u64) void {
    // Single implementation lives in util/time.zig (kernel32 Sleep on
    // windows, nanosleep on posix) — this used to be a duplicate.
    @import("time.zig").sleepMs(ms);
}

/// poll(fd) readability: >0 = ready, 0 = timeout, -1 = error. Covers both
/// stdin key probes and child-process pipe waits.
pub fn pollFd(fd: anytype, timeout_ms: i32) i32 {
    if (builtin.os.tag == .windows) {
        return -1; // L1 stub: fail closed
    } else {
        var pfd = [1]std.c.pollfd{.{ .fd = @intCast(fd), .events = std.c.POLL.IN, .revents = 0 }};
        return std.c.poll(&pfd, 1, timeout_ms);
    }
}

/// Terminal size. L1 replaces the Windows fallback with
/// GetConsoleScreenBufferInfo.
pub fn termWidth() u16 {
    if (is_windows) return 80;
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(0, std.c.T.IOCGWINSZ, &ws) == 0 and ws.col > 0) return ws.col;
    return 80;
}

pub fn termHeight() u16 {
    if (is_windows) return 24;
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(0, std.c.T.IOCGWINSZ, &ws) == 0 and ws.row > 0) return ws.row;
    return 24;
}

/// Kill a whole process GROUP (spawn must set pgid=0). L2 replaces the
/// Windows side with TerminateJobObject.
/// Normalize an id that is an int on posix or a HANDLE pointer on
/// windows into an i64 (callers pass either shape).
fn idAsI64(id: anytype) i64 {
    return switch (@typeInfo(@TypeOf(id))) {
        .pointer => @intCast(@intFromPtr(id)),
        .int => @intCast(id),
        else => @compileError("id must be an int or pointer"),
    };
}

pub fn killGroup(id: anytype) void {
    if (builtin.os.tag == .windows) {
        @import("winproc.zig").killTree(id);
    } else {
        const p: i32 = @intCast(idAsI64(id));
        _ = std.c.kill(-p, .KILL);
    }
}

pub fn killOne(id: anytype) void {
    if (builtin.os.tag == .windows) {
        // TerminateProcess on a HANDLE pid (hooks stores handles as ints).
        const h: std.os.windows.HANDLE = @ptrFromInt(@as(usize, @intCast(idAsI64(id))));
        _ = win32.terminate(h, 1);
    } else {
        const p: i32 = @intCast(idAsI64(id));
        _ = std.c.kill(p, .KILL);
    }
}

/// shutdown(2) on a socket/pipe fd — the cross-thread unblock trick the
/// LLM watchdog and MCP cancellation rely on. L3 wires CancelIoEx.
pub fn shutdownFd(fd: anytype) void {
    if (is_windows) {
        logger.warning("wincompat: shutdownFd stub on windows (L3)", .{});
        return;
    }
    _ = std.c.shutdown(fd, 2); // SHUT_RDWR
}

/// SIGINT routing for the agent-dispatch cooperative cancel. L1 wires
/// SetConsoleCtrlHandler; on Windows the stub means Ctrl-C keeps its
/// default disposition (process dies) during a dispatch — acceptable for
/// a compile-passing L0 build, fixed in L1.
pub const SigintGuard = struct {
    old: ?*anyopaque = null, // posix.Sigaction on posix targets
    installed: bool = false,

    pub fn install(handler: *const fn (std.posix.SIG) callconv(.c) void) SigintGuard {
        if (is_windows) return .{};
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(.INT, &act, &old);
        const old_boxed = std.heap.smp_allocator.create(std.posix.Sigaction) catch return .{};
        old_boxed.* = old;
        return .{ .old = old_boxed, .installed = true };
    }

    pub fn restore(self: SigintGuard) void {
        if (!self.installed) return;
        if (builtin.os.tag == .windows) {
            // unreachable: install never sets the flag on windows
        } else {
            const old_boxed: *std.posix.Sigaction = @ptrCast(@alignCast(self.old.?));
            std.posix.sigaction(.INT, old_boxed, null);
            std.heap.smp_allocator.destroy(old_boxed);
        }
    }
};

/// Cross-process exclusive file lock (input_history's single-writer
/// discipline). posix: flock; windows: LockFileEx non-blocking.
pub fn lockExNb(handle: anytype) bool {
    if (builtin.os.tag == .windows) {
        const lock_c = struct {
            const OVERLAPPED = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32 = 0, offset_high: u32 = 0, h_event: ?*anyopaque = null };
            const LOCKFILE_EXCLUSIVE_LOCK: u32 = 0x2;
            const LOCKFILE_FAIL_IMMEDIATELY: u32 = 0x1;
            extern "kernel32" fn LockFileEx(hFile: std.os.windows.HANDLE, dwFlags: u32, dwReserved: u32, nNumberOfBytesToLockLow: u32, nNumberOfBytesToLockHigh: u32, lpOverlapped: *OVERLAPPED) callconv(.winapi) std.os.windows.BOOL;
            extern "kernel32" fn UnlockFileEx(hFile: std.os.windows.HANDLE, dwReserved: u32, nNumberOfBytesToUnlockLow: u32, nNumberOfBytesToUnlockHigh: u32, lpOverlapped: *OVERLAPPED) callconv(.winapi) std.os.windows.BOOL;
        };
        var ov: lock_c.OVERLAPPED = .{};
        const h: std.os.windows.HANDLE = if (@typeInfo(@TypeOf(handle)) == .pointer) handle else @ptrFromInt(@as(usize, @intCast(@as(i64, @intCast(handle)))));
        return @intFromEnum(lock_c.LockFileEx(h, lock_c.LOCKFILE_EXCLUSIVE_LOCK | lock_c.LOCKFILE_FAIL_IMMEDIATELY, 0, 0xFFFF_FFFF, 0, &ov)) != 0;
    } else {
        return std.c.flock(handle, std.posix.LOCK.EX | std.posix.LOCK.NB) == 0;
    }
}

pub fn lockUn(handle: anytype) void {
    if (builtin.os.tag == .windows) {
        const lock_c = struct {
            const OVERLAPPED = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32 = 0, offset_high: u32 = 0, h_event: ?*anyopaque = null };
            extern "kernel32" fn UnlockFileEx(hFile: std.os.windows.HANDLE, dwReserved: u32, nNumberOfBytesToUnlockLow: u32, nNumberOfBytesToUnlockHigh: u32, lpOverlapped: *OVERLAPPED) callconv(.winapi) std.os.windows.BOOL;
        };
        var ov: lock_c.OVERLAPPED = .{};
        const h: std.os.windows.HANDLE = if (@typeInfo(@TypeOf(handle)) == .pointer) handle else @ptrFromInt(@as(usize, @intCast(@as(i64, @intCast(handle)))));
        _ = lock_c.UnlockFileEx(h, 0, 0xFFFF_FFFF, 0, &ov);
    } else {
        _ = std.c.flock(handle, std.posix.LOCK.UN);
    }
}

pub fn isTtyStdinStdout() bool {
    if (builtin.os.tag == .windows) {
        // L1 wires GetConsoleMode probing; L0 assumes a console when the
        // user ran the exe interactively (pipes would misbehave mildly).
        return true;
    }
    return std.c.isatty(0) == 1 and std.c.isatty(1) == 1;
}

/// Current process id as a printable integer (posix getpid; windows
/// GetCurrentProcessId — std.c.getpid returns a HANDLE-ish there).
pub fn pid() i64 {
    if (builtin.os.tag == .windows) {
        const gcpid = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
        };
        return @intCast(gcpid.GetCurrentProcessId());
    }
    return @intCast(std.c.getpid());
}

pub fn isTtyStderr() bool {
    if (builtin.os.tag == .windows) return true;
    return std.c.isatty(2) == 1;
}
