//! ScheduleWakeup 工具（M3/T3.2，2026-11-19）：模型自定时唤醒——
//! one-shot cron job 到点把 prompt 塞进 REPL 的 auto_submit 槽位触发
//! 自主回合（区别于 attachment 通知：通知随行不触发回合，唤醒必须触发）。
//!
//! 线程纪律（RPN 210 缓解 + 复审 🟡4 修正，2026-11-19）：工具声明
//! neverConcurrencySafe 只是**串行**，仍跑在 REPL 的 worker 线程（UI
//! 循环留守主线程）——「addTask 只在主线程调用」的旧前提不成立。两道
//! 防护：①tasks 列表操作全走 cron 自旋锁（addTask/disableTaskByName/
//! drainDue）；②active_prompt 的换装（worker）与读取（主线程 quiet
//! slice 的 drainDue→wakeupFire）经 prompt_lock 互斥，锁内 dupe 出手。
//! 子代理可见性拒绝表同步拉黑（subagent.zig）。空闲提示符期 readLine
//! 阻塞，唤醒最长等到下一次终端活动（A-6，已文档化；USAGE §见唤醒条目）。
//! ZIV_CRON_SCALE 同样缩放本工具的延迟（测试加速）。

const std = @import("std");
const registry = @import("registry.zig");
const task_mod = @import("../task/mod.zig");
const attachment = @import("../util/attachment.zig");
const wincompat = @import("../util/wincompat.zig");
const env = @import("../util/env.zig");

pub const MIN_DELAY_S: u64 = 60;
pub const MAX_DELAY_S: u64 = 3600;
pub const MAX_PROMPT: usize = 2000;

/// REPL 侧接线：fire 时填 auto_submit（槽位空闲）；槽位被占（用户已
/// 排队输入，优先级更高）则降级为 attachment 通知随行送达。
pub const WakeupCtx = struct {
    sched: *task_mod.CronScheduler,
    auto_submit: *?[]u8,
    alloc: std.mem.Allocator,
    /// 当前已装 job 的 prompt（覆盖式安装时释放旧的；REPL 退出时由
    /// 会话生命周期兜底）。
    active_prompt: ?[]u8 = null,
    /// 复审 🟡4：active_prompt 的读写互斥（worker 换装 vs 主线程
    /// drainDue 触发读取）。与 cron.mutex 同款自旋锁——临界区是一次
    /// 指针交换/一次 dupe，纳秒级。
    prompt_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn promptLock(self: *WakeupCtx) void {
    while (self.prompt_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}

fn promptUnlock(self: *WakeupCtx) void {
    self.prompt_lock.store(false, .release);
}

pub fn scheduleWakeupExecute(ctx_opaque: ?*anyopaque, alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const wctx: *WakeupCtx = @ptrCast(@alignCast(ctx_opaque orelse return error.NoCtx));

    const prompt = registry.getStringField(input, "prompt") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: prompt") catch "", .is_error = true };
    if (prompt.len == 0 or prompt.len > MAX_PROMPT) {
        return registry.ToolResult{ .output = try alloc.print("prompt must be 1-{d} chars", .{MAX_PROMPT}), .is_error = true };
    }
    var delay_s: u64 = MIN_DELAY_S;
    if (input == .object) {
        if (input.object.get("delay_seconds")) |d| {
            if (d == .integer and d.integer > 0) delay_s = @intCast(@min(@max(d.integer, @as(i64, @intCast(MIN_DELAY_S))), @as(i64, @intCast(MAX_DELAY_S))));
        }
    }

    // 覆盖式：一次一个唤醒 job。先失效旧 job（锁内——见 🟡4/🟢8），
    // 再换 prompt（prompt_lock 内交换）。顺序刻意：若先换后失效，被
    // 替换掉的旧 job 在窗口期到点会把【新】prompt 提前送出。
    wctx.sched.disableTaskByName("wakeup");
    const prompt_owned = wctx.alloc.dupe(u8, prompt) catch
        return registry.ToolResult{ .output = alloc.dupe(u8, "wakeup install failed (oom)") catch "", .is_error = true };
    promptLock(wctx);
    const old_prompt = wctx.active_prompt;
    wctx.active_prompt = prompt_owned;
    promptUnlock(wctx);
    if (old_prompt) |o| wctx.alloc.free(o);

    // ZIV_CRON_SCALE 与 repl 启动同源缩放（测试里 1000×：60s→60ms）。
    var scale: u64 = 1;
    if (env.get("ZIV_CRON_SCALE")) |s| {
        if (std.fmt.parseInt(u64, s, 10)) |sc| {
            if (sc >= 1) scale = sc;
        } else |_| {}
    }
    const interval_ms: u64 = delay_s * 1000 / @max(scale, 1);

    wctx.sched.addTask(.{
        .name = "wakeup",
        .interval_ms = interval_ms,
        .last_run = std.atomic.Value(i64).init(0),
        .enabled = std.atomic.Value(bool).init(true),
        .task_fn = wakeupFire,
        .ctx = @ptrCast(wctx),
        .one_shot = true,
    }) catch {
        // 装不上 job 就把刚换入的 prompt 撤下（锁内换出再释放）。
        promptLock(wctx);
        const cur = wctx.active_prompt;
        wctx.active_prompt = null;
        promptUnlock(wctx);
        if (cur) |c| wctx.alloc.free(c);
        return registry.ToolResult{ .output = alloc.dupe(u8, "wakeup install failed") catch "", .is_error = true };
    };

    return registry.ToolResult{
        .output = try alloc.print("scheduled: the session will wake in ~{d}s and continue with your prompt. Note: while the prompt is idle the wake fires on the next terminal activity", .{delay_s}),
    };
}

/// 到点（drainDue 主线程）：填 auto_submit 触发回合；槽位被用户排队
/// 输入占用时降级随行通知（用户输入优先）。prompt 读取走锁内 dupe
///（🟡4：安装侧可能在 worker 线程同时换装——裸读拿到刚 free 的指针
/// 就是 UAF）。
fn wakeupFire(ctx_opaque: ?*anyopaque) anyerror!void {
    const wctx: *WakeupCtx = @ptrCast(@alignCast(ctx_opaque orelse return));
    promptLock(wctx);
    const prompt_copy = if (wctx.active_prompt) |p|
        wctx.alloc.dupe(u8, p) catch null
    else
        null;
    promptUnlock(wctx);
    const prompt = prompt_copy orelse return;
    defer wctx.alloc.free(prompt);
    if (wctx.auto_submit.* == null) {
        wctx.auto_submit.* = wctx.alloc.dupe(u8, prompt) catch null;
        if (wctx.auto_submit.* != null) return;
    }
    // 槽位占用或 dupe 失败：随行送达（下一次用户查询可见）。
    _ = attachment.pushNote(wctx.alloc, .bg_done, "scheduled wakeup (prompt was): {s}", .{prompt});
}

test "T3.2 wakeup: install → one-shot fire fills auto_submit, refire impossible" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const jalloc = arena.allocator();
    var sched = task_mod.CronScheduler.init(alloc);
    defer sched.deinit();
    var slot: ?[]u8 = null;
    var wctx = WakeupCtx{ .sched = &sched, .auto_submit = &slot, .alloc = alloc };

    // 直接调工具体（绕过注册表）：delay 最小 60s，interval 用 1ms 手工
    // 装的等价 job 验证 fire 语义。
    const input = try std.json.parseFromSliceLeaky(std.json.Value, jalloc, "{\"prompt\":\"check the build\",\"delay_seconds\":60}", .{});
    const res1 = try scheduleWakeupExecute(@ptrCast(&wctx), alloc, input, undefined);
    alloc.free(res1.output);
    try std.testing.expect(sched.tasks.items.len == 1);
    try std.testing.expectEqualStrings("wakeup", sched.tasks.items[0].name);

    // 到点：主线程 drain → slot 填充 + job 失效。
    sched.tasks.items[0].interval_ms = 1;
    try sched.start();
    var spins: usize = 0;
    while (sched.due_inbox.isEmpty() and spins < 200) : (spins += 1) wincompat.sleepMs(10);
    sched.drainDue();
    try std.testing.expect(slot != null);
    try std.testing.expectEqualStrings("check the build", slot.?);
    try std.testing.expect(!sched.tasks.items[0].enabled.load(.monotonic));
    alloc.free(slot.?);
    slot = null;
    // one-shot 不会再触发（enabled=false，drainDue 跳过）
    spins = 0;
    while (sched.due_inbox.isEmpty() and spins < 50) : (spins += 1) wincompat.sleepMs(10);
    sched.drainDue();
    try std.testing.expect(slot == null);

    // 覆盖式安装释放旧 prompt
    const input2 = try std.json.parseFromSliceLeaky(std.json.Value, jalloc, "{\"prompt\":\"second\"}", .{});
    const res2 = try scheduleWakeupExecute(@ptrCast(&wctx), alloc, input2, undefined);
    alloc.free(res2.output);
    try std.testing.expectEqualStrings("second", wctx.active_prompt.?);
    // 覆盖同时失效旧 job（disableTaskByName 锁内路径）并装新 job
    try std.testing.expect(!sched.tasks.items[0].enabled.load(.monotonic));
    try std.testing.expect(sched.tasks.items.len == 2);
    wctx.alloc.free(wctx.active_prompt.?);
    wctx.active_prompt = null;
}
