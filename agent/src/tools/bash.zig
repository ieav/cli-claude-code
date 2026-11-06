/// Bash tool — shell command execution.
/// Hard timeout (default 30s, clampable to 300s, 0 = unlimited), optional
/// working_directory, per-stream output caps, and whole-process-GROUP kill
/// on timeout. std.process.run kills only the direct child (/bin/sh), so a
/// compound command's grandchildren (`printf x; sleep 60`) survived as
/// orphans after the timeout — the child now runs in its own process group
/// (setpgid via SpawnOptions.pgid) and the watchdog kills the entire group.
const std = @import("std");
const registry = @import("registry.zig");
const util_time = @import("../util/time.zig");
const cancel = @import("../util/cancel.zig");
const cleanup = @import("../util/cleanup.zig");

/// Hard ceiling for one command; explicit timeouts clamp to this.
const MAX_TIMEOUT_S: i64 = 300;
/// Applied when the caller does not specify a timeout.
const DEFAULT_TIMEOUT_S: i64 = 30;
/// Grace for the pipe readers after the shell is reaped: an in-group
/// descendant holding the write-end gets group-killed; if EOF STILL
/// hasn't arrived by the end of this window the readers are forced off
/// the pipe (2026-11-06: /tmp/ziv_check_mpmc_queue held the write-end
/// forever and the tool call never returned).
const PIPE_EOF_GRACE_MS: i64 = 1000;

/// Live tool groups (spawn → reap window), so ziv's EXIT can group-kill
/// them: a session death mid-Bash used to orphan the whole tree (the
/// mpmc_serial ×4 incident burned ~4 cores for 1h14m after the owning
/// ziv died — the groups stayed running, reparented to launchd).
/// Lock-free fixed slots; the races are benign (worst case a sweep
/// re-kills an ESRCH pid). A descendant that setsid's out of BOTH the
/// group and the ppid tree stays unreachable — documented limit.
const ActiveGroups = struct {
    const N = 16;
    var slots: [N]std.atomic.Value(i32) = @splat(std.atomic.Value(i32).init(0));

    fn put(pid: i32) void {
        for (&slots) |*s| {
            if (s.cmpxchgStrong(0, pid, .acq_rel, .monotonic) == null) return;
        }
    }

    fn take(pid: i32) void {
        for (&slots) |*s| {
            if (s.load(.acquire) == pid) {
                s.store(0, .release);
                return;
            }
        }
    }

    fn killAll() void {
        for (&slots) |*s| {
            const pid = s.load(.acquire);
            if (pid > 0) {
                _ = std.c.kill(-pid, .KILL);
                _ = std.c.kill(pid, .KILL);
            }
        }
    }
};

var cleanup_registered = false;

fn ensureCleanupRegistered() void {
    if (cleanup_registered) return;
    cleanup_registered = true;
    cleanup.register("bash-tool-groups", ActiveGroups.killAll) catch {};
}
/// Output capture ceiling per stream. finishToolCall truncates tool results
/// to 4 KiB for history anyway — 256 KiB headroom is plenty for display
/// while a runaway producer (`yes`, `cat /dev/zero`) cannot OOM us.
const OUTPUT_LIMIT: usize = 256 * 1024;

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const command = getStringField(input, "command") orelse
        return registry.ToolResult{ .output = "Error: 'command' field is required", .is_error = true };

    // Batch already cancelled (Esc) — don't even spawn. Ownership rule:
    // output transfers to history which FREES it — must be allocated,
    // never a literal (freeContentBlocks would free static memory).
    if (cancel.toolBatchCancelled()) {
        return registry.ToolResult{ .output = try alloc.dupe(u8, "cancelled by user (not run)"), .is_error = true };
    }

    // timeout in seconds; 0 = unlimited, negative treated as 0.
    const timeout_s: i64 = @min(@max(getIntField(input, "timeout") orelse DEFAULT_TIMEOUT_S, 0), MAX_TIMEOUT_S);

    var spawn_opts: std.process.SpawnOptions = .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // Own process group: the watchdog can kill(-pgid) the whole tree.
        .pgid = 0,
    };
    if (getStringField(input, "working_directory")) |cwd| {
        if (cwd.len > 0) spawn_opts.cwd = .{ .path = cwd };
    }

    const child = std.process.spawn(io, spawn_opts) catch |err| {
        const msg = alloc.print("Failed to execute: {}", .{err}) catch "exec failed";
        return registry.ToolResult{ .output = msg, .is_error = true };
    };
    const pid: i32 = child.id orelse {
        // Spawn returned but no pid (already reaped) — nothing to run.
        if (child.stdout) |f| f.close(io);
        if (child.stderr) |f| f.close(io);
        return registry.ToolResult{ .output = "Failed to execute: no child pid", .is_error = true };
    };

    // Register the group so a ziv exit mid-command can kill it (see
    // ActiveGroups); deregistered right after the reap below.
    ensureCleanupRegistered();
    ActiveGroups.put(pid);

    // Drain both pipes on their own threads so a full pipe can never block
    // the child; the main thread blocks in waitpid until exit or group kill.
    var out_reader = PipeReader{ .alloc = alloc, .io = io, .file = child.stdout.? };
    var err_reader = PipeReader{ .alloc = alloc, .io = io, .file = child.stderr.? };
    const out_thread = std.Thread.spawn(.{}, PipeReader.run, .{&out_reader}) catch null;
    if (out_thread == null) out_reader.run();
    const err_thread = std.Thread.spawn(.{}, PipeReader.run, .{&err_reader}) catch null;
    if (err_thread == null) err_reader.run();

    var timed_out = std.atomic.Value(bool).init(false);
    var user_cancelled = std.atomic.Value(bool).init(false);
    var watch = Watchdog{
        .pid = pid,
        .deadline_ms = if (timeout_s == 0) 0 else util_time.nowMillis() + timeout_s * 1000, // 0 = no deadline
        .timed_out = &timed_out,
        .user_cancelled = &user_cancelled,
        .done = std.atomic.Value(bool).init(false),
    };
    const watch_thread = std.Thread.spawn(.{}, Watchdog.run, .{&watch}) catch null;

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    ActiveGroups.take(pid);
    watch.done.store(true, .release);
    if (watch_thread) |t| t.join();

    // Shell reaped. Readers normally hit EOF at once; a descendant that
    // outlived the shell while holding the pipe WRITE-end (a backgrounded
    // child, still in-group) blocks the joins forever — kill the surviving
    // group (the holder dies → EOF), grace-wait, then force the readers
    // off the pipe and flag the truncation in the result.
    var pipe_forced = false;
    if (!readersDone(&out_reader, &err_reader)) {
        _ = std.c.kill(-pid, .KILL); // ESRCH when nothing survives — fine
        const t0 = util_time.nowMillis();
        while (!readersDone(&out_reader, &err_reader) and util_time.nowMillis() - t0 < PIPE_EOF_GRACE_MS) sleepMs(25);
        if (!readersDone(&out_reader, &err_reader)) {
            out_reader.stop.store(true, .release);
            err_reader.stop.store(true, .release);
            pipe_forced = true;
        }
    }

    if (out_thread) |t| t.join();
    if (err_thread) |t| t.join();
    out_reader.file.close(io);
    err_reader.file.close(io);

    defer out_reader.buf.deinit(alloc);
    defer err_reader.buf.deinit(alloc);

    if (timed_out.load(.acquire)) {
        return registry.ToolResult{
            .output = try alloc.print("Command timed out after {d}s and was killed: {s}", .{ timeout_s, command }),
            .is_error = true,
        };
    }
    if (user_cancelled.load(.acquire)) {
        return registry.ToolResult{
            .output = try alloc.print("Command cancelled by user (Esc) and was killed: {s}", .{command}),
            .is_error = true,
        };
    }
    if (out_reader.truncated or err_reader.truncated) {
        return registry.ToolResult{
            .output = try alloc.print("Command output exceeded the {d} KiB capture limit and was truncated.", .{OUTPUT_LIMIT / 1024}),
            .is_error = true,
        };
    }

    // Own one combined buffer, then release the reader buffers.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    out.appendSlice(alloc, out_reader.buf.items) catch {};
    if (err_reader.buf.items.len > 0) {
        if (out.items.len > 0) out.append(alloc, '\n') catch {};
        out.appendSlice(alloc, err_reader.buf.items) catch {};
    }
    if (pipe_forced) {
        out.appendSlice(alloc, "\n[ziv] 输出管道被存活子进程占住，已强制断开（输出可能不完整）") catch {};
    }

    // POSIX wait status: bits 0-6 = signal (0 = exited), 8-15 = exit code.
    const exit_code: u8 = @intCast((status >> 8) & 0xff);
    const signaled = (status & 0x7f) != 0;
    return registry.ToolResult{
        .output = try out.toOwnedSlice(alloc),
        .is_error = signaled or exit_code != 0,
    };
}

/// Drains one pipe into a growable buffer until EOF, the capture cap, or
/// a force-stop. Reads are POLL-GATED (200ms cadence) so the main thread
/// can break a reader off a pipe whose write-end is held forever by an
/// escaped descendant — a blocking read here was unbreakable.
const PipeReader = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    buf: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *PipeReader) void {
        defer self.done.store(true, .release);
        var rbuf: [8192]u8 = undefined;
        var fr = self.file.reader(self.io, &rbuf);
        const r = &fr.interface;
        const fd: i32 = self.file.handle;
        while (!self.stop.load(.acquire)) {
            // Readiness first: EOF arrives as POLLHUP instantly, a quiet
            // pipe costs at most one 200ms poll per loop, and a stop is
            // honored within the same cadence.
            var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            const n = std.c.poll(&pfd, 1, 200);
            if (n != 1 or (pfd[0].revents & (std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR)) == 0) continue;
            const chunk = r.peekGreedy(1) catch break; // EOF / error
            if (chunk.len == 0) break;
            if (self.buf.items.len >= OUTPUT_LIMIT) {
                self.truncated = true;
                break;
            }
            const n2 = @min(chunk.len, OUTPUT_LIMIT - self.buf.items.len);
            self.buf.appendSlice(self.alloc, chunk[0..n2]) catch {
                self.truncated = true;
                break;
            };
            r.toss(n2);
        }
    }
};

fn readersDone(a: *PipeReader, b: *PipeReader) bool {
    return a.done.load(.acquire) and b.done.load(.acquire);
}

/// Polls until the child exits, the deadline passes, or the user cancels
/// the tool batch — whichever comes first — then, on the latter two, kills
/// the child's whole process group (the group id equals the child pid —
/// setpgid(0,0) at spawn). The blocked waitpid in the main thread returns
/// as soon as the leader dies. The watchdog runs even for unlimited
/// commands (deadline 0): a user cancel must be able to unbind a
/// `timeout: 0` hang, which was previously uncancellable forever.
const Watchdog = struct {
    pid: i32,
    deadline_ms: i64, // 0 = no deadline (unlimited)
    timed_out: *std.atomic.Value(bool),
    user_cancelled: *std.atomic.Value(bool),
    done: std.atomic.Value(bool),

    fn run(self: *Watchdog) void {
        while (true) {
            if (self.done.load(.acquire)) return;
            if (cancel.toolBatchCancelled()) {
                self.killGroup();
                self.user_cancelled.store(true, .release);
                return;
            }
            if (self.deadline_ms != 0 and util_time.nowMillis() >= self.deadline_ms) {
                self.killGroup();
                self.timed_out.store(true, .release);
                return;
            }
            sleepMs(25);
        }
    }

    /// Kill the group, then the leader directly in case setpgid lost a
    /// race we cannot observe. Both errors (ESRCH) are harmless.
    fn killGroup(self: *Watchdog) void {
        _ = std.c.kill(-self.pid, .KILL);
        _ = std.c.kill(self.pid, .KILL);
    }
};

fn sleepMs(ms: u32) void {
    var req: std.c.timespec = .{ .sec = 0, .nsec = @as(i64, ms) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&req, null);
}

fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const obj = input.object.get(key) orelse return null;
    if (obj != .string) return null;
    return obj.string;
}

fn getIntField(input: std.json.Value, key: []const u8) ?i64 {
    if (input != .object) return null;
    const obj = input.object.get(key) orelse return null;
    if (obj != .integer) return null;
    return obj.integer;
}

test "bash executes with output capture" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "command", .{ .string = "printf BASH_OK" });
    const result = try execute(std.testing.allocator, .{ .object = obj }, io_state.io());
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("BASH_OK", result.output);
}

test "bash timeout kills a hung command" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "command", .{ .string = "sleep 30" });
    try obj.put(std.testing.allocator, "timeout", .{ .integer = 1 });
    const t0 = util_time.nowMillis();
    const result = try execute(std.testing.allocator, .{ .object = obj }, io_state.io());
    defer std.testing.allocator.free(result.output);
    const elapsed = util_time.nowMillis() - t0;
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "timed out") != null);
    // Killed at ~1s, not 30s (allow generous scheduling slack).
    try std.testing.expect(elapsed < 10_000);
}

test "bash timeout kills the whole process group (compound command)" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    // sh forks a grandchild for the second segment — the old single-pid
    // kill left it alive as an orphan.
    try obj.put(std.testing.allocator, "command", .{ .string = "printf G; sleep 15" });
    try obj.put(std.testing.allocator, "timeout", .{ .integer = 1 });
    const result = try execute(std.testing.allocator, .{ .object = obj }, io_state.io());
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.is_error);

    // Give the group kill a moment, then verify no orphan survives. The
    // anchor ^ makes the probe shell's own cmdline (which merely contains
    // the string) not match; an orphan's cmdline starts with "sleep 15".
    sleepMs(300);
    const probe = std.process.run(std.testing.allocator, io_state.io(), .{
        .argv = &.{ "/bin/sh", "-c", "pgrep -f '^sleep 15$' || true" },
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(5), .clock = .awake } },
    }) catch return error.ProbeFailed;
    defer std.testing.allocator.free(probe.stdout);
    defer std.testing.allocator.free(probe.stderr);
    try std.testing.expectEqual(@as(usize, 0), probe.stdout.len); // no orphans
}

test "bash working_directory is honored" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "command", .{ .string = "basename $(pwd)" });
    try obj.put(std.testing.allocator, "working_directory", .{ .string = "/tmp" });
    const result = try execute(std.testing.allocator, .{ .object = obj }, io_state.io());
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("tmp", std.mem.trim(u8, result.output, " \n"));
}

/// Helper: fire the batch-cancel flag after `delay_ms` (detached thread).
fn cancelAfter(delay_ms: u32) void {
    const t = std.Thread.spawn(.{}, struct {
        fn run(d: u32) void {
            sleepMs(d);
            cancel.toolBatchCancel();
        }
    }.run, .{delay_ms}) catch return;
    t.detach();
}

test "bash cancel kills an unlimited hung command" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    defer cancel.toolBatchReset(); // never leak a `true` into other tests
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    // timeout 0 = unlimited — previously uncancellable FOREVER; the only
    // escape is the batch-cancel watchdog path this test locks.
    try obj.put(std.testing.allocator, "command", .{ .string = "sleep 30" });
    try obj.put(std.testing.allocator, "timeout", .{ .integer = 0 });
    cancelAfter(300);
    const t0 = util_time.nowMillis();
    const result = try execute(std.testing.allocator, .{ .object = obj }, io_state.io());
    defer std.testing.allocator.free(result.output);
    const elapsed = util_time.nowMillis() - t0;
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "cancelled by user") != null);
    // Killed at ~300ms, not 30s (generous scheduling slack).
    try std.testing.expect(elapsed < 10_000);
}

test "bash pre-cancelled batch never spawns" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    defer cancel.toolBatchReset();
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    // If the command ran at all, its stdout would contain X.
    try obj.put(std.testing.allocator, "command", .{ .string = "printf X_CANCEL_PROBE" });
    cancel.toolBatchCancel();
    const result = try execute(std.testing.allocator, .{ .object = obj }, io_state.io());
    defer std.testing.allocator.free(result.output); // allocated: the ownership rule for history
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("cancelled by user (not run)", result.output);
}

test "bash does not wait for an in-group pipe holder outliving the shell" {
    // Regression (2026-11-06): sh exits immediately, a backgrounded
    // in-group child holds the pipe write-end for 30s. The old join
    // blocked on its EOF the full 30s — with a never-exiting holder
    // (ziv_check_mpmc_queue) it blocked FOREVER. Now: group-kill → EOF
    // within the grace window.
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "command", .{ .string = "sleep 30 & exit 0" });
    const t0 = util_time.nowMillis();
    const result = try execute(std.testing.allocator, .{ .object = obj }, io_state.io());
    defer std.testing.allocator.free(result.output);
    const elapsed = util_time.nowMillis() - t0;
    // Killed inside the ~1s grace, not the holder's 30s lifetime
    // (10s slack for slow machines).
    try std.testing.expect(elapsed < 10_000);
    // And the holder itself is dead — no orphan left burning CPU.
    sleepMs(200);
    const probe = std.process.run(std.testing.allocator, io_state.io(), .{
        .argv = &.{ "/bin/sh", "-c", "pgrep -f '^sleep 30$' || true" },
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(5), .clock = .awake } },
    }) catch return error.ProbeFailed;
    defer std.testing.allocator.free(probe.stdout);
    defer std.testing.allocator.free(probe.stderr);
    try std.testing.expectEqual(@as(usize, 0), probe.stdout.len);
}

test "ActiveGroups killAll on a bogus pid is a harmless no-op" {
    ActiveGroups.put(999_999);
    ActiveGroups.killAll(); // ESRCH swallowed
    ActiveGroups.take(999_999);
}
