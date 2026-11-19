//! 通知收件箱（M1/T1.1，2026-11-19）：后台事实（bg 任务完成等）→ 下
//! 一次用户查询随行注入的 `<system-reminder>` 单帧。CC getAttachments
//! 的 ziv 极简版——语义关键点是**通知不触发回合**：收件箱只攒事实，
//! 由 repl 在「用户行 append 前一拍」与「工具轮间」两处 drain，合并
//! 成一条 user 消息（保前缀稳定）。唤醒类（ScheduleWakeup）不走这里
//! ——它经 auto_submit 触发自主回合，语义相反。
//!
//! 所有权契约（P35 教训成文）：push 侧在生产线程把文本 dupe 到
//! `alloc`（生产方传进程级 gpa；测试传 testing.allocator 做泄漏审计），
//! pop 侧 main 线程持有；drainAndRender 消费后统一 free。push 满箱
//! （容量 16）即丢——通知是尽力而为，不阻塞不排队膨胀。

const std = @import("std");
const task_mod = @import("../task/mod.zig");

pub const NoteKind = enum { bg_done };

pub const Note = struct {
    kind: NoteKind,
    text: []u8, // owned by the drainer (dupe'd at push onto `alloc`)
};

const INBOX_CAP = 16;
var inbox: task_mod.BoundedMPSC(Note, INBOX_CAP) = undefined;
var inbox_init = false;

/// 惰性初始化（pub：repl 启动时主动调一次，使后续任意线程的首个
/// pushNote 无 init 竞争——waiter 线程可能多路并发）。
pub fn ensureInit() void {
    if (!inbox_init) {
        inbox = task_mod.BoundedMPSC(Note, INBOX_CAP).init();
        inbox_init = true;
    }
}

/// 满箱丢弃计数（观测用；多 waiter 并发递增——复审 🟢8 原子化）。
pub var dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// 生产侧（任意线程）：格式化 → dupe → 入箱。满箱丢弃返回 false。
pub fn pushNote(alloc: std.mem.Allocator, kind: NoteKind, comptime fmt: []const u8, args: anytype) bool {
    ensureInit();
    const text = alloc.print(fmt, args) catch return false;
    if (!inbox.push(.{ .kind = kind, .text = text })) {
        alloc.free(text); // 满箱：丢通知不丢内存
        _ = dropped.fetchAdd(1, .monotonic);
        return false;
    }
    return true;
}

/// 消费侧（main 线程）：drain 全部 → 合并为单帧 system-reminder 文本
/// （无 note 返回 null）。`w` 非空时每条打一行 `[note] …` UI 提示。
/// 返回文本为 `alloc` 持有，调用方负责 free。已弹出的 note 无论中途
/// 是否 OOM 都在本函数内释放（所有权单边移交）。
pub fn drainAndRender(alloc: std.mem.Allocator, w: ?*std.Io.Writer) ?[]u8 {
    ensureInit();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var count: usize = 0;
    while (inbox.pop()) |note| {
        defer alloc.free(note.text);
        if (count == 0) {
            aw.writer.writeAll("<system-reminder>\n") catch return null;
        }
        aw.writer.print("{s}\n", .{note.text}) catch {};
        if (w) |wr| {
            std.Io.Writer.print(wr, "\x1b[2m  [note] {s}\x1b[0m\n", .{note.text}) catch {};
        }
        count += 1;
    }
    if (count == 0) return null;
    aw.writer.writeAll("</system-reminder>") catch {};
    return alloc.dupe(u8, aw.writer.buffered()) catch null;
}

test "T1.1 inbox: FIFO order, cap drops oldest-newcomer, render single frame" {
    // 复位模块态（容量内测试不触 drop 分支）
    ensureInit();
    while (inbox.pop()) |n| std.heap.smp_allocator.free(n.text);
    dropped.store(0, .monotonic);

    const alloc = std.testing.allocator;
    try std.testing.expect(pushNote(alloc, .bg_done, "first {d}", .{1}));
    try std.testing.expect(pushNote(alloc, .bg_done, "second", .{}));

    const frame = drainAndRender(alloc, null) orelse return error.NoFrame;
    defer alloc.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "<system-reminder>") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "</system-reminder>") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "first 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "second") != null);
    // first 在 second 前（FIFO）
    const ia = std.mem.indexOf(u8, frame, "first 1").?;
    const ib = std.mem.indexOf(u8, frame, "second").?;
    try std.testing.expect(ia < ib);
    // 排空后再 drain → null
    try std.testing.expect(drainAndRender(alloc, null) == null);
}

test "T1.1 ownership: push/drain/free cycle is leak-clean (DebugAllocator)" {
    ensureInit();
    while (inbox.pop()) |n| std.heap.smp_allocator.free(n.text);
    const alloc = std.testing.allocator;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = pushNote(alloc, .bg_done, "note {d} with some payload text", .{i});
    }
    if (drainAndRender(alloc, null)) |frame| alloc.free(frame);
    // 满箱丢弃路径：塞满后 push 失败并把 dupe 释放干净
    var j: usize = 0;
    while (j < INBOX_CAP + 4) : (j += 1) {
        _ = pushNote(alloc, .bg_done, "overflow {d}", .{j});
    }
    if (drainAndRender(alloc, null)) |frame| alloc.free(frame);
    try std.testing.expect(dropped.load(.monotonic) >= 4);
}
