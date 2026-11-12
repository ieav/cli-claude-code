//! Terminal I/O primitives (M1 of the Windows port, 2026-11-12).
//!
//! The seam every terminal-touching call goes through. POSIX behavior
//! is the moved-verbatim status quo (termios/poll/ioctl); the Windows
//! side maps onto the console API:
//!
//!   raw mode      SetConsoleMode: drop LINE_INPUT|ECHO_INPUT|
//!                 PROCESSED_INPUT → the app reads a UTF-8 BYTE stream
//!                 (console CP must be 65001 first — ReadFile on a
//!                 console returns input-CP bytes), Enter arrives as \r,
//!                 Ctrl-C as byte 0x03 — the same contract as posix raw
//!                 with ISIG/ICRNL off. Kitty protocol / bracketed paste
//!                 / CSI parsing are pure byte-stream logic and work
//!                 unchanged on Windows Terminal.
//!   input poll    WaitForSingleObject on the console input handle —
//!                 it IS waitable, unlike posix fds (Spike-S1 risk
//!                 resolved: the byte-stream emulation holds, verified
//!                 against MS docs; live verification is T7.1).
//!   size          GetConsoleScreenBufferInfo.
//!   VT output     ENABLE_VIRTUAL_TERMINAL_PROCESSING at init (Windows
//!                 Terminal has it on by default; legacy conhost needs
//!                 the explicit bit).
const std = @import("std");
const builtin = @import("builtin");
const logger = @import("log.zig");

const windows = builtin.os.tag == .windows;

// ─── Win32 console declarations (absent from 0.17's minimal std) ───
const w = if (windows) struct {
    pub const HANDLE = *anyopaque;
    pub const DWORD = std.os.windows.DWORD;
    pub const BOOL = std.os.windows.BOOL;

    pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetConsoleCP(wCodePageID: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetConsoleCP() callconv(.winapi) DWORD;
    pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) DWORD;
    pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleHandle: HANDLE, lpInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;

    pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
    pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
    pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
    pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
    pub const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
    pub const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
    pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
    pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
    pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

    pub const COORD = extern struct { X: i16, Y: i16 };
    pub const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
    pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };
} else struct {};

var vt_initialized = false;
/// VT processing actually enabled on the output console (windows).
/// False = the TUI's escape-sequence layer (DECSTBM 滚动区、绝对定位、
/// SGR) would print as raw bytes — main() gates the interactive REPL on
/// this. Posix: always true.
var vt_ok = !windows;
/// Original console codepages, restored at exit — leaving a cmd window
/// switched to 65001 changes how every later program prints (mojibake in
/// the shell the user returns to).
const Cp = if (windows) w.DWORD else u0;
var orig_in_cp: Cp = 0;
var orig_out_cp: Cp = 0;

/// Whether the output terminal accepts VT sequences. Meaningful only on
/// windows AFTER init(); posix terminals are VT by default.
pub fn vtEnabled() bool {
    return vt_ok;
}

/// One-shot at startup: enable VT processing + UTF-8 codepage on
/// windows; no-op on posix (terminals are VT by default there).
/// MUST run before the first byte of output (main() calls it first —
/// the startup banner used to print before this, i.e. under the ORIGINAL
/// console CP: on a default cmd.exe (GBK) the UTF-8 banner decoded as
/// garbage — the "Windows 打开有乱码" report class, 2026-11-13).
pub fn init() void {
    if (!windows or vt_initialized) return;
    vt_initialized = true;
    const out = w.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse return;
    var mode: w.DWORD = 0;
    if (@intFromEnum(w.GetConsoleMode(out, &mode)) != 0) {
        mode |= w.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        vt_ok = @intFromEnum(w.SetConsoleMode(out, mode)) != 0;
        if (!vt_ok) {
            logger.warning("termio: VT processing not enabled (legacy conhost?)", .{});
        }
    }
    // Console CP 65001: ReadFile on the input console returns UTF-8 —
    // the byte-stream contract the whole editor layer assumes — and
    // WriteFile UTF-8 bytes render correctly.
    orig_in_cp = w.GetConsoleCP();
    orig_out_cp = w.GetConsoleOutputCP();
    _ = w.SetConsoleCP(65001);
    _ = w.SetConsoleOutputCP(65001);
    // Exit politeness: hand the shell back its original codepages. LIFO
    // cleanup registry (util/cleanup.zig) runs on every REPL exit path.
    const cleanup = @import("cleanup.zig");
    cleanup.register("termio-restore-cp", restoreConsoleCp) catch {};
}

fn restoreConsoleCp() void {
    if (!windows or !vt_initialized) return;
    if (orig_in_cp != 0 and orig_in_cp != 65001) _ = w.SetConsoleCP(orig_in_cp);
    if (orig_out_cp != 0 and orig_out_cp != 65001) _ = w.SetConsoleOutputCP(orig_out_cp);
}

/// Saved terminal mode — ONE SLOT PER GUARD (nested session + confirm
/// guards each own theirs; a module-global slot would let a nested
/// restore clobber the session's original mode — the exact bug class
/// menu.zig's per-instance `orig` field prevents on posix).
pub const Mode = if (windows) w.DWORD else std.c.termios;

/// Enter raw mode; `saved` receives the previous mode for a later
/// restore(). False when stdin is not a console/TTY (pipe) — same
/// contract as the old tcgetattr probe.
pub fn rawEnter(saved: *Mode, no_sig: bool) bool {
    if (windows) {
        const in = w.GetStdHandle(w.STD_INPUT_HANDLE) orelse return false;
        var mode: w.DWORD = 0;
        if (@intFromEnum(w.GetConsoleMode(in, &mode)) == 0) return false; // pipe
        saved.* = mode;
        // Clear line discipline + echo; PROCESSED_INPUT off = Ctrl-C
        // arrives as byte 0x03 (no_sig is effectively always true on
        // windows — the double-Ctrl-C exit consumes the byte, same as
        // posix ISIG off).
        var raw_mode = mode & ~(@as(w.DWORD, w.ENABLE_LINE_INPUT) | w.ENABLE_ECHO_INPUT | w.ENABLE_PROCESSED_INPUT);
        // Window-input reports resize as INPUT_RECORD events that surface
        // as garbage bytes in ReadFile — keep it off; termWidth re-queries
        // live. Mouse likewise (ziv never enables mouse reporting).
        raw_mode &= ~w.ENABLE_WINDOW_INPUT;
        raw_mode &= ~w.ENABLE_MOUSE_INPUT;
        // VT INPUT: arrow keys / Ctrl-combos must arrive as CSI byte
        // sequences (\x1b[A …) for the editor's parser — without this bit
        // legacy input translation may deliver nothing useful on ReadFile.
        // Windows Terminal's conpty usually implies it; setting it
        // explicitly is the stable contract. Older conhosts may reject the
        // bit: fall back to the mode without it rather than failing raw.
        raw_mode |= w.ENABLE_VIRTUAL_TERMINAL_INPUT;
        if (@intFromEnum(w.SetConsoleMode(in, raw_mode)) == 0) {
            raw_mode &= ~w.ENABLE_VIRTUAL_TERMINAL_INPUT;
            return @intFromEnum(w.SetConsoleMode(in, raw_mode)) != 0;
        }
        return true;
    } else {
        if (std.c.tcgetattr(0, saved) != 0) return false;
        var raw = saved.*;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        if (no_sig) raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@backingInt(std.c.V.MIN)] = 1;
        raw.cc[@backingInt(std.c.V.TIME)] = 0;
        return std.c.tcsetattr(0, .NOW, &raw) == 0;
    }
}

pub fn rawRestore(saved: *const Mode) void {
    if (windows) {
        const in = w.GetStdHandle(w.STD_INPUT_HANDLE) orelse return;
        _ = w.SetConsoleMode(in, saved.*);
    } else {
        _ = std.c.tcsetattr(0, .NOW, @constCast(saved));
    }
}

/// Session keyboard-protocol push/pop (2026-11-12). Pushed once for the
/// whole session (bracketed paste ?2004 + kitty disambiguate >1u + xterm
/// modifyOtherKeys level 1); popped on every normal exit. modifyOtherKeys
/// L1 is what makes Shift+Enter/Ctrl+Enter arrive as CSI 13;2u/13;5u on
/// xterm-family terminals (VS Code, Windows Terminal, VTE) — level 1
/// only re-encodes MODIFIED well-known keys, never plain letters.
/// POSIX: written to fd 1 directly (callers reach here before any writer
/// exists). Windows: console API ignores VT input negotiation on the
/// input side — a no-op there (the editor still parses whatever the
/// terminal sends).
pub fn writeProtocol(push: bool) void {
    if (builtin.os.tag == .windows) return;
    const seq = if (push)
        "\x1b[?2004h\x1b[>1u\x1b[>4;1m"
    else
        "\x1b[<u\x1b[>4m\x1b[?2004l";
    _ = std.c.write(1, seq.ptr, seq.len); // libc write: no writer exists at push time
}

/// Toggle ONLY bracketed paste (CookedGuard): a y/N or answer read must
/// see a pasted answer verbatim, not wrapped in 200~/201~ markers.
pub fn writeBracketedPaste(on: bool) void {
    if (builtin.os.tag == .windows) return;
    _ = std.c.write(1, if (on) "\x1b[?2004h" else "\x1b[?2004l", 8);
}

/// One cooked-with-echo confirmation read (menu.CookedGuard primitive).
pub fn cookedEnter(saved: *Mode) bool {
    if (windows) {
        const in = w.GetStdHandle(w.STD_INPUT_HANDLE) orelse return false;
        var mode: w.DWORD = 0;
        if (@intFromEnum(w.GetConsoleMode(in, &mode)) == 0) return false;
        saved.* = mode;
        const cooked = mode | w.ENABLE_LINE_INPUT | w.ENABLE_ECHO_INPUT;
        return @intFromEnum(w.SetConsoleMode(in, cooked)) != 0;
    } else {
        if (std.c.tcgetattr(0, saved) != 0) return false;
        var cooked = saved.*;
        cooked.lflag.ICANON = true;
        cooked.lflag.ECHO = true;
        cooked.iflag.ICRNL = true;
        return std.c.tcsetattr(0, .NOW, &cooked) == 0;
    }
}

/// stdin readiness: >0 ready, 0 timeout, -1 error/not-console.
pub fn pollInput(timeout_ms: i32) i32 {
    if (!windows) return pollInputPosix(timeout_ms);
    const in = w.GetStdHandle(w.STD_INPUT_HANDLE) orelse return -1;
    const rc = w.WaitForSingleObject(in, @intCast(timeout_ms));
    return switch (rc) {
        0 => 1, // WAIT_OBJECT_0
        0x102 => 0, // WAIT_TIMEOUT
        else => -1,
    };
}

pub fn termWidth() u16 {
    if (!windows) return sizePosix(.width);
    const out = w.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse return 80;
    var info: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (@intFromEnum(w.GetConsoleScreenBufferInfo(out, &info)) == 0) return 80;
    const cols = info.srWindow.Right - info.srWindow.Left + 1;
    return if (cols > 0) @intCast(cols) else 80;
}

pub fn termHeight() u16 {
    if (!windows) return sizePosix(.height);
    const out = w.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse return 24;
    var info: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (@intFromEnum(w.GetConsoleScreenBufferInfo(out, &info)) == 0) return 24;
    const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
    return if (rows > 0) @intCast(rows) else 24;
}

pub fn stdinIsTty() bool {
    if (!windows) {
        var t: std.c.termios = undefined;
        return std.c.tcgetattr(0, &t) == 0;
    }
    const in = w.GetStdHandle(w.STD_INPUT_HANDLE) orelse return false;
    var mode: w.DWORD = 0;
    return @intFromEnum(w.GetConsoleMode(in, &mode)) != 0;
}

pub fn stdoutIsTty() bool {
    if (!windows) return std.c.isatty(1) == 1;
    const out = w.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse return false;
    var mode: w.DWORD = 0;
    return @intFromEnum(w.GetConsoleMode(out, &mode)) != 0;
}

// ─── posix leftovers (poll + size still shared) ───

fn pollInputPosix(timeout_ms: i32) i32 {
    var pfd = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
    return std.c.poll(&pfd, 1, timeout_ms);
}

const Dim = enum { width, height };

fn sizePosix(dim: Dim) u16 {
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(0, std.c.T.IOCGWINSZ, &ws) == 0) {
        return switch (dim) {
            .width => if (ws.col > 0) ws.col else 80,
            .height => if (ws.row > 0) ws.row else 24,
        };
    }
    return switch (dim) {
        .width => 80,
        .height => 24,
    };
}
