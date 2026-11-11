//! Background task store (P5 M1) — Bash `run_in_background` 的家。
//! 生命周期跟会话：ziv 退出 → cleanup 钩子杀全部任务进程组（S5 的
//! 进程组收割语义推广到后台，零孤儿）。
//!
//! 捕获语义与前台 Bash 对齐：内存环形捕获 ≤256 KiB（超限截断标注）；
//! 任务结束时一次性落盘 `.ziv/tasks/<id>.log`。运行中的 /tasks 预览
//! 取内存尾巴——不做逐块落盘（省掉流式文件写的全部复杂度；代价是
//! kill -9 ziv 时日志丢失，可接受：进程都没了输出本就不完整）。

const std = @import("std");
const winproc = @import("../util/winproc.zig");
const builtin = @import("builtin");
const wincompat = @import("../util/wincompat.zig");
const util_time = @import("../util/time.zig");
const cleanup = @import("../util/cleanup.zig");
const system_dirs = @import("../util/system_dirs.zig");

pub const N: usize = 8;
/// 与前台 Bash OUTPUT_LIMIT 同口径：跑飞的生产者（yes）不能 OOM 我们。
pub const CAPTURE_LIMIT: usize = 256 * 1024;
/// /tasks 预览尾巴。
pub const TAIL_CAP: usize = 4 * 1024;
/// 进程退出后泵线程的 EOF 宽限（存活子孙占管道的场景，同 bash.zig）。
const PUMP_GRACE_MS: i64 = 1000;

pub const Task = struct {
    id: u32,
    pid: i32,
    command: []const u8, // store 拥有（alloc）
    started_ms: i64,
    output_path: []const u8, // store 拥有（alloc）
    alloc: std.mem.Allocator,
    io: std.Io,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exit_code: i32 = -1, // 原始 wait status；-1 = 运行中（互斥下读写）
    captured: std.ArrayList(u8) = .empty, // 互斥下追加
    truncated: bool = false,
};

var mutex_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var slots: [N]?*Task = @splat(null);
var next_id = std.atomic.Value(u32).init(1);
var cleanup_registered = false;

/// 自旋锁（std.Thread.Mutex 在 0.17 已移除，同 provider.zig 惯例）：
/// 临界区都是 memcpy/拷贝级，纳秒到微秒。
fn mutex() void {
    while (mutex_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}

fn unlock() void {
    mutex_lock.store(false, .release);
}

const PumpCtx = struct {
    task: *Task,
    src: std.Io.File,
};

const WaiterCtx = struct {
    task: *Task,
    pumps: [2]std.Thread,
};

/// 注册后台任务并接管子进程的两根管道（调用方此后不得再碰它们）。
/// 返回任务 id；槽满（8 个全在跑）返回 error.TooManyBackgroundTasks。
pub fn start(
    alloc: std.mem.Allocator,
    io: std.Io,
    pid: i32,
    stdout_f: std.Io.File,
    stderr_f: std.Io.File,
    command: []const u8,
) !u32 {
    ensureCleanup();
    const id = next_id.fetchAdd(1, .monotonic);
    const path = try std.fmt.allocPrint(alloc, ".ziv/tasks/{d}.log", .{id});
    errdefer alloc.free(path);

    const t = try alloc.create(Task);
    errdefer alloc.destroy(t);
    t.* = .{
        .id = id,
        .pid = pid,
        .command = try alloc.dupe(u8, command),
        .output_path = path,
        .started_ms = util_time.nowMillis(),
        .alloc = alloc,
        .io = io,
    };
    errdefer alloc.free(t.command);

    {
        mutex();
        defer unlock();
        var slot: ?usize = null;
        for (&slots, 0..) |*s, i| {
            if (s.* == null and slot == null) slot = i;
        }
        if (slot == null) { // 空槽没有 → 复用一个已完成的
            for (&slots, 0..) |*s, i| {
                if (s.* != null and s.*.?.done.load(.acquire)) {
                    freeTask(s.*.?);
                    s.* = null;
                    slot = i;
                    break;
                }
            }
        }
        const idx = slot orelse {
            freeTask(t);
            return error.TooManyBackgroundTasks;
        };
        slots[idx] = t;
    }

    // 泌两根管道 + 一个收割者。失败路径：回滚槽位并报错（调用方杀组）。
    const p0 = std.Thread.spawn(.{}, pump, .{ PumpCtx{ .task = t, .src = stdout_f } }) catch {
        mutex();
        defer unlock();
        freeInSlot(t);
        return error.PumpSpawnFailed;
    };
    const p1 = std.Thread.spawn(.{}, pump, .{ PumpCtx{ .task = t, .src = stderr_f } }) catch {
        p0.join();
        mutex();
        defer unlock();
        freeInSlot(t);
        return error.PumpSpawnFailed;
    };
    const w = std.Thread.spawn(.{}, waiter, .{ WaiterCtx{ .task = t, .pumps = .{ p0, p1 } } }) catch {
        // 极罕见：直接杀组让泵自然 EOF，任务标失败。
        wincompat.killGroup(pid);
        p0.join();
        p1.join();
        mutex();
        defer unlock();
        freeInSlot(t);
        return error.WaiterSpawnFailed;
    };
    _ = w.detach();
    return id;
}

/// poll 门控读管道 → 互斥下追加捕获（同前台 PipeReader 的节奏）。
fn pump(ctx: PumpCtx) void {
    const t = ctx.task;
    defer ctx.src.close(t.io);
    var rbuf: [8192]u8 = undefined;
    var fr = ctx.src.reader(t.io, &rbuf);
    const r = &fr.interface;
    const fd: i32 = if (builtin.os.tag == .windows) @intCast(@intFromPtr(ctx.src.handle)) else ctx.src.handle;
    while (true) {
                const n = wincompat.pollFd(fd, 200);
        if (n != 1) {
            if (t.done.load(.acquire)) return;
            continue;
        }
        const chunk = r.peekGreedy(1) catch return; // EOF / error
        if (chunk.len == 0) return;
        mutex();
        if (t.captured.items.len >= CAPTURE_LIMIT) {
            t.truncated = true;
            unlock();
            return; // 同前台：到帽即断（子孙再写会吃 SIGPIPE）
        }
        t.captured.appendSlice(t.alloc, chunk) catch {
            t.truncated = true;
            unlock();
            return;
        };
        unlock();
        r.toss(chunk.len);
    }
}

/// 收割 + 落盘 + 收尾。done 在文件写完后才置位——/tasks 对运行中的
/// 任务给内存预览，对完成任务给文件全文，两者不混淆。
fn waiter(ctx: WaiterCtx) void {
    const t = ctx.task;
    var status: c_int = 0;
    if (builtin.os.tag == .windows) {
        const h: std.os.windows.HANDLE = @ptrFromInt(@as(usize, @intCast(t.pid)));
        _ = wincompat.win32.waitFor(h, 0xFFFFFFFF);
        var ec: std.os.windows.DWORD = 0;
        if (@intFromEnum(wincompat.win32.exitCode(h, &ec)) != 0) status = @intCast(ec);
        winproc.untrack(t.pid);
    } else {
        _ = std.c.waitpid(t.pid, &status, 0);
    }
    // 泵收尾宽限：子孙占管道时强停（200ms 轮询内退出）。
    const t0 = util_time.nowMillis();
    while (util_time.nowMillis() - t0 < PUMP_GRACE_MS) sleepMs(25);
    ctx.pumps[0].join();
    ctx.pumps[1].join();
    // 一次性落盘（截断标注附加在尾部）。
    {
        mutex();
        const captured = t.captured.items;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(t.alloc);
        if (captured.len > 0) body.appendSlice(t.alloc, captured) catch {};
        if (t.truncated) body.appendSlice(t.alloc, "\n[ziv] 输出超过 256 KiB 捕获上限，已截断\n") catch {};
        if (body.items.len > 0) {
            system_dirs.ensureDir(".ziv/tasks", t.io) catch {};
            std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = t.output_path, .data = body.items }) catch {};
        }
        t.exit_code = status;
        unlock();
    }
    t.done.store(true, .release);
}

/// 停止一个运行中的任务（杀整个进程组，waiter 随后收割落状态）。
pub fn stop(id: u32) bool {
    mutex();
    defer unlock();
    for (&slots) |*s| {
        const t = s.* orelse continue;
        if (t.id == id) {
            if (t.done.load(.acquire)) return false;
            wincompat.killGroup(t.pid);
            return true;
        }
    }
    return false;
}

pub const Snapshot = struct {
    id: u32,
    running: bool,
    exit_code: i32, // 原始 status；运行中为 -1
    signaled: bool,
    command: []const u8, // caller frees
    elapsed_ms: i64,
};

/// /tasks 列表快照（caller 释放每个 command 与切片本身）。
pub fn snapshot(alloc: std.mem.Allocator) ![]Snapshot {
    mutex();
    defer unlock();
    var list: std.ArrayList(Snapshot) = .empty;
    errdefer list.deinit(alloc);
    for (&slots) |*s| {
        const t = s.* orelse continue;
        try list.append(alloc, .{
            .id = t.id,
            .running = !t.done.load(.acquire),
            .exit_code = t.exit_code,
            .signaled = (t.exit_code & 0x7f) != 0,
            .command = try alloc.dupe(u8, t.command),
            .elapsed_ms = util_time.nowMillis() - t.started_ms,
        });
    }
    return list.toOwnedSlice(alloc);
}

/// 输出预览：运行中取内存尾巴；已结束读落盘文件（caller 释放）。
/// 两个来源都以 TAIL_CAP*2 为帽——预览是给人和模型看的，不是转储。
pub fn previewOf(alloc: std.mem.Allocator, io: std.Io, id: u32) ?[]u8 {
    mutex();
    var path_copy: ?[]u8 = null;
    var tail_copy: ?[]u8 = null;
    var done = false;
    for (&slots) |*s| {
        const t = s.* orelse continue;
        if (t.id != id) continue;
        done = t.done.load(.acquire);
        if (done) {
            path_copy = alloc.dupe(u8, t.output_path) catch null;
        } else {
            const tail = t.captured.items;
            const from = if (tail.len > TAIL_CAP) tail.len - TAIL_CAP else 0;
            tail_copy = alloc.dupe(u8, tail[from..]) catch null;
        }
        break;
    }
    unlock();
    if (!done) return tail_copy;
    const p = path_copy orelse return null;
    defer alloc.free(p);
    const full = std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(TAIL_CAP * 2)) catch {
        alloc.free(p);
        return null;
    };
    const from = if (full.len > TAIL_CAP * 2) full.len - TAIL_CAP * 2 else 0;
    if (from == 0) return full;
    const out = alloc.dupe(u8, full[from..]) catch {
        alloc.free(full);
        return null;
    };
    alloc.free(full);
    return out;
}

/// ziv 退出钩子：杀全部仍在跑的任务进程组。
fn killAll() void {
    mutex();
    defer unlock();
    for (&slots) |*s| {
        const t = s.* orelse continue;
        if (!t.done.load(.acquire)) wincompat.killGroup(t.pid);
    }
}

fn ensureCleanup() void {
    if (cleanup_registered) return;
    cleanup_registered = true;
    cleanup.register("bg-tasks", killAll) catch {};
}

/// 互斥已持有。从槽中摘除并释放（waiter 完成后由下一次 start 复用）。
fn freeInSlot(t: *Task) void {
    for (&slots) |*s| {
        if (s.* == t) {
            s.* = null;
            break;
        }
    }
    freeTask(t);
}

fn freeTask(t: *Task) void {
    const a = t.alloc;
    a.free(t.command);
    a.free(@constCast(t.output_path));
    t.captured.deinit(a);
    a.destroy(t);
}

fn sleepMs(ms: u64) void {
    wincompat.sleepMs(@intCast(@as(u128, (ms * std.time.ns_per_ms)) / std.time.ns_per_ms));
}

test "empty store: snapshot empty, stop unknown false" {
    const a = std.testing.allocator;
    const snap = try snapshot(a);
    defer a.free(snap);
    try std.testing.expectEqual(@as(usize, 0), snap.len);
    try std.testing.expect(!stop(99999));
}
