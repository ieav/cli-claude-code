//! M6 Hooks（harness-efficiency-plan §5 P2 简版）：Pre/PostToolUse 外部
//! 钩子——让用户脚本在工具调用前后插一脚（guard / lint / 记账）。
//!
//! 配置（settings.json，用户级与项目级同权限规则）：
//!   "hooks": {
//!     "PreToolUse":  [{"matcher": "Bash",    "command": "./guard.sh"}],
//!     "PostToolUse": [{"matcher": "FileEdit","command": "make lint"}]
//!   }
//!
//! 语义（对齐 CC 已验证的 UX，保持最小面）：
//!   · matcher 精确匹配工具名；空/省略 = 全部工具
//!   · command 经 /bin/sh -c 执行，cwd = 当前目录，10s 超时强杀
//!   · stdin 喂 JSON：{"tool": 名, "input": 原参数}（Post 另带 "output"）
//!   · PreToolUse 退出码：0 = 放行；2 = 阻断（stderr 摘要作为
//!     tool_result 回给模型，模型可改道重试）；其他非零 = 非阻断（记日志）
//!   · PostToolUse 退出码忽略（失败只记日志——钩子不许破坏回合）
//!
//! 接入点（三个工具执行口全走这里）：orchestration.executeToolCall
//! （REPL 回合）、subagent.executeWhitelisted（无头/oneshot）、
//! /run 直达命令。顺序恒定：权限判定 → PreToolUse → 执行 → PostToolUse。
//!
//! 线程模型：active 配置是回合边界换装的全局（与 skills gate 同模式）——
//! REPL 主线程仅在回合之间 setConfig；执行线程（并行工具波次、子代理
//! worker）只读。回合中不存在换装窗口。

const std = @import("std");
const json_helpers = @import("../util/json_helpers.zig");
const logger = @import("../util/log.zig");
const util_time = @import("../util/time.zig");

pub const HOOK_TIMEOUT_MS: i64 = 10_000;
/// stdin 载荷上限：FileWrite 的 content 可能极大，喂给钩子的只是参数
/// 快照——超限截尾并标记（钩子需要全量就该自己去读文件）。
const PAYLOAD_CAP: usize = 32 * 1024;
const STDERR_CAP: usize = 4 * 1024;
const STDOUT_CAP: usize = 16 * 1024;

pub const HookEntry = struct {
    matcher: []const u8 = "",
    command: []const u8 = "",
};

pub const HookConfig = struct {
    pre: []const HookEntry = &.{},
    post: []const HookEntry = &.{},
};

/// 当前生效配置（回合边界换装；执行线程只读）。
var active: HookConfig = .{};

pub fn setConfig(cfg: HookConfig) void {
    active = cfg;
}

pub fn configLoaded() bool {
    return active.pre.len > 0 or active.post.len > 0;
}

fn entryMatches(entry: HookEntry, tool_name: []const u8) bool {
    return entry.matcher.len == 0 or std.mem.eql(u8, entry.matcher, tool_name);
}

const HookRun = struct {
    code: i32,
    stderr: []u8,
    timed_out: bool,
};

/// PreToolUse：null = 放行；返回 = 阻断消息（caller 持有，alloc 分配）。
/// 匹配的钩子依序全跑；任一 exit 2 即阻断（首个阻断者的 stderr 生效）。
pub fn preToolUse(alloc: std.mem.Allocator, io: std.Io, tool_name: []const u8, input: ?std.json.Value) ?[]u8 {
    if (active.pre.len == 0) return null;
    for (active.pre) |entry| {
        if (!entryMatches(entry, tool_name)) continue;
        const payload = buildPayload(alloc, tool_name, input, null);
        defer alloc.free(payload);
        const run = runHook(alloc, io, entry.command, payload, HOOK_TIMEOUT_MS);
        defer alloc.free(run.stderr);
        if (run.timed_out) {
            logger.warning("hook PreToolUse[{s}] timed out (>{d}ms) — non-blocking", .{ entry.command, HOOK_TIMEOUT_MS });
            continue;
        }
        if (run.code == 2) {
            const msg = std.fmt.allocPrint(alloc, "blocked by PreToolUse hook ({s}): {s}", .{ entry.command, run.stderr }) catch
                return null; // OOM：放行比误阻断安全
            return msg;
        }
        if (run.code != 0) {
            logger.warning("hook PreToolUse[{s}] exit {d} (non-blocking): {s}", .{ entry.command, run.code, run.stderr });
        }
    }
    return null;
}

/// PostToolUse：全部 best-effort，任何失败只记日志。
pub fn postToolUse(alloc: std.mem.Allocator, io: std.Io, tool_name: []const u8, input: ?std.json.Value, output: []const u8) void {
    if (active.post.len == 0) return;
    for (active.post) |entry| {
        if (!entryMatches(entry, tool_name)) continue;
        const payload = buildPayload(alloc, tool_name, input, output);
        defer alloc.free(payload);
        const run = runHook(alloc, io, entry.command, payload, HOOK_TIMEOUT_MS);
        defer alloc.free(run.stderr);
        if (run.timed_out) {
            logger.warning("hook PostToolUse[{s}] timed out (>{d}ms)", .{ entry.command, HOOK_TIMEOUT_MS });
        } else if (run.code != 0) {
            logger.warning("hook PostToolUse[{s}] exit {d}: {s}", .{ entry.command, run.code, run.stderr });
        }
    }
}

/// 钩子载荷：{"tool":名,"input":<原参数 JSON>}（Post 另带 "output"）。
/// input 超 PAYLOAD_CAP 时整体换成截断标记——宁可少喂也不喂半截 JSON
/// （钩子解析必炸）。序列化失败 → "null"（钩子仍跑，只是看不到参数）。
fn buildPayload(alloc: std.mem.Allocator, tool_name: []const u8, input: ?std.json.Value, output: ?[]const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;

    var in_buf: std.ArrayList(u8) = .empty;
    defer in_buf.deinit(alloc);
    var in_json: []const u8 = "null";
    if (input) |v| {
        if (json_helpers.serialize(alloc, v)) |s| {
            defer alloc.free(s);
            if (s.len > PAYLOAD_CAP) {
                in_buf.print(alloc, "{{\"_payload_truncated\":true,\"bytes\":{d}}}", .{s.len}) catch {};
            } else {
                in_buf.appendSlice(alloc, s) catch {};
            }
            in_json = in_buf.items;
        } else |_| {}
    }

    std.Io.Writer.print(w, "{{\"tool\":\"{s}\",\"input\":{s}", .{ tool_name, in_json }) catch return "{}";
    if (output) |out| {
        const out_cut = if (out.len > PAYLOAD_CAP) out[0..PAYLOAD_CAP] else out;
        std.Io.Writer.writeAll(w, ",\"output\":\"") catch return "{}";
        appendEscaped(w, out_cut);
        std.Io.Writer.writeAll(w, "\"") catch return "{}";
    }
    std.Io.Writer.writeAll(w, "}") catch return "{}";
    return alloc.dupe(u8, aw.written()) catch "{}";
}

/// JSON 字符串转义（output 是原始文本，不转义会产生非法 JSON）。
fn appendEscaped(w: *std.Io.Writer, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => std.Io.Writer.writeAll(w, "\\\"") catch return,
            '\\' => std.Io.Writer.writeAll(w, "\\\\") catch return,
            '\n' => std.Io.Writer.writeAll(w, "\\n") catch return,
            '\r' => std.Io.Writer.writeAll(w, "\\r") catch return,
            '\t' => std.Io.Writer.writeAll(w, "\\t") catch return,
            else => {
                if (c < 0x20) {
                    var eb: [8]u8 = undefined;
                    const e = std.fmt.bufPrint(&eb, "\\u{x:0>4}", .{c}) catch continue;
                    std.Io.Writer.writeAll(w, e) catch return;
                } else {
                    std.Io.Writer.writeByte(w, c) catch return;
                }
            },
        }
    }
}

/// 同步跑一个钩子：写 stdin → 双管道排水 → WNOHANG 轮询到退出或超时
/// （超时 SIGKILL，bash 工具同款纪律，只是钩子不需要进程组——命令
/// 预期短小，孤儿子进程风险由钩子作者自负）。
fn runHook(alloc: std.mem.Allocator, io: std.Io, command: []const u8, payload: []const u8, timeout_ms: i64) HookRun {
    const child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return .{ .code = -1, .stderr = alloc.dupe(u8, "hook spawn failed") catch "", .timed_out = false };
    const pid: i32 = child.id orelse {
        if (child.stdout) |f| f.close(io);
        if (child.stderr) |f| f.close(io);
        return .{ .code = -1, .stderr = alloc.dupe(u8, "hook spawn: no pid") catch "", .timed_out = false };
    };

    // stdin：载荷 ≤PAYLOAD_CAP < 管道缓冲，写完即关；钩子不读也不阻塞
    // 我们（EPIPE 吞掉——`exit 2` 不读 stdin 的钩子是合法形态）。
    if (child.stdin) |f| {
        var wb: [8192]u8 = undefined;
        var fw = f.writer(io, &wb);
        std.Io.Writer.writeAll(&fw.interface, payload) catch {};
        std.Io.File.Writer.flush(&fw) catch {};
        f.close(io);
    }

    var out_drain = PipeDrain{ .alloc = alloc, .io = io, .file = child.stdout.?, .cap = STDOUT_CAP };
    var err_drain = PipeDrain{ .alloc = alloc, .io = io, .file = child.stderr.?, .cap = STDERR_CAP };
    const out_t = std.Thread.spawn(.{}, PipeDrain.run, .{&out_drain}) catch null;
    if (out_t == null) out_drain.run();
    const err_t = std.Thread.spawn(.{}, PipeDrain.run, .{&err_drain}) catch null;
    if (err_t == null) err_drain.run();

    // WNOHANG 轮询：每 25ms 看一眼，超时 SIGKILL 后阻塞收割。
    const deadline = util_time.nowMillis() + timeout_ms;
    var status: c_int = 0;
    var timed_out = false;
    while (true) {
        const r = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
        if (r == pid) break;
        if (util_time.nowMillis() > deadline) {
            timed_out = true;
            _ = std.c.kill(pid, .KILL);
            _ = std.c.waitpid(pid, &status, 0);
            break;
        }
        sleepMs(25);
    }
    // 收割后管道正常 EOF；残留持写端的孤儿子进程 → 有界宽限再强停
    // 排水线程（bash 工具同款收尾）。
    const t0 = util_time.nowMillis();
    while (!(out_drain.done.load(.acquire) and err_drain.done.load(.acquire)) and util_time.nowMillis() - t0 < 500) sleepMs(25);
    out_drain.stop.store(true, .release);
    err_drain.stop.store(true, .release);
    if (out_t) |t| t.join();
    if (err_t) |t| t.join();

    const ustatus: u32 = @bitCast(status);
    const code: i32 = if (std.posix.W.IFEXITED(ustatus)) @intCast(std.posix.W.EXITSTATUS(ustatus)) else -1;
    return .{ .code = code, .stderr = err_drain.buf.toOwnedSlice(alloc) catch "", .timed_out = timed_out };
}

/// bash.zig PipeDrain 的精简版：poll 就绪 + peek/toss，容量封顶即停。
const PipeDrain = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    cap: usize,
    buf: std.ArrayList(u8) = .empty,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *PipeDrain) void {
        defer self.done.store(true, .release);
        var rbuf: [4096]u8 = undefined;
        var fr = self.file.reader(self.io, &rbuf);
        const r = &fr.interface;
        const fd: i32 = self.file.handle;
        while (!self.stop.load(.acquire)) {
            var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            const n = std.c.poll(&pfd, 1, 100);
            if (n != 1 or (pfd[0].revents & (std.c.POLL.IN | std.c.POLL.HUP | std.c.POLL.ERR)) == 0) continue;
            const chunk = r.peekGreedy(1) catch break;
            if (chunk.len == 0) break;
            if (self.buf.items.len >= self.cap) break;
            const n2 = @min(chunk.len, self.cap - self.buf.items.len);
            self.buf.appendSlice(self.alloc, chunk[0..n2]) catch break;
            r.toss(n2);
        }
    }
};

fn sleepMs(ms: u32) void {
    var req: std.c.timespec = .{ .sec = 0, .nsec = @as(i64, ms) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&req, null);
}

// ──── tests ────

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{});
}

test "entryMatches: empty matcher hits all, exact otherwise" {
    try std.testing.expect(entryMatches(.{ .matcher = "", .command = "x" }, "Anything"));
    try std.testing.expect(entryMatches(.{ .matcher = "Bash", .command = "x" }, "Bash"));
    try std.testing.expect(!entryMatches(.{ .matcher = "Bash", .command = "x" }, "FileRead"));
}

test "preToolUse: exit 2 blocks with stderr, exit 0 passes, matcher filters" {
    var io_state = testIo();
    defer io_state.deinit();
    const alloc = std.testing.allocator;
    const entries = [_]HookEntry{.{ .matcher = "Bash", .command = "echo BLOCK-REASON-X >&2; exit 2" }};
    setConfig(.{ .pre = &entries });
    defer setConfig(.{});

    const blocked = preToolUse(alloc, io_state.io(), "Bash", .null);
    try std.testing.expect(blocked != null);
    defer alloc.free(blocked.?);
    try std.testing.expect(std.mem.indexOf(u8, blocked.?, "BLOCK-REASON-X") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocked.?, "blocked by PreToolUse hook") != null);

    // 非 Bash 工具：不匹配 → 放行。
    try std.testing.expect(preToolUse(alloc, io_state.io(), "FileRead", .null) == null);
}

test "preToolUse: exit 0 and non-2 failures are non-blocking" {
    var io_state = testIo();
    defer io_state.deinit();
    const alloc = std.testing.allocator;
    const entries = [_]HookEntry{.{ .matcher = "", .command = "exit 0" }};
    setConfig(.{ .pre = &entries });
    defer setConfig(.{});
    try std.testing.expect(preToolUse(alloc, io_state.io(), "Bash", null) == null);

    const noisy = [_]HookEntry{.{ .matcher = "", .command = "echo noise >&2; exit 1" }};
    setConfig(.{ .pre = &noisy });
    try std.testing.expect(preToolUse(alloc, io_state.io(), "Bash", null) == null);
}

test "runHook: timeout kills and reports" {
    var io_state = testIo();
    defer io_state.deinit();
    const alloc = std.testing.allocator;
    const run = runHook(alloc, io_state.io(), "sleep 5", "{}", 120);
    defer alloc.free(run.stderr);
    try std.testing.expect(run.timed_out);
    // 挂起的钩子不阻断回合（preToolUse 视为非阻断失败）。
    const entries = [_]HookEntry{.{ .matcher = "", .command = "sleep 5" }};
    setConfig(.{ .pre = &entries });
    defer setConfig(.{});
    const blocked = preToolUse(alloc, io_state.io(), "Bash", null);
    try std.testing.expect(blocked == null);
}

test "runHook: hook receives valid JSON payload on stdin" {
    var io_state = testIo();
    defer io_state.deinit();
    const alloc = std.testing.allocator;
    // 带转义敏感内容的 output（引号/换行）——载荷必须仍是合法 JSON。
    const payload = buildPayload(alloc, "Bash", .null, "line1 \"quoted\"\nline2\t—");
    defer alloc.free(payload);
    const run = runHook(alloc, io_state.io(), "cat >&2", payload, HOOK_TIMEOUT_MS);
    defer alloc.free(run.stderr);
    try std.testing.expect(run.code == 0);
    // 钩子侧能直接被 jq/python 解析：用 ziv 自己的解析器回验。
    const parsed = json_helpers.parse(alloc, run.stderr) catch return error.PayloadNotJson;
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("Bash", parsed.value.object.get("tool").?.string);
    const out = parsed.value.object.get("output").?.string;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"quoted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n") != null);
}

test "postToolUse: smoke (no crash, config off = no-op)" {
    var io_state = testIo();
    defer io_state.deinit();
    const alloc = std.testing.allocator;
    postToolUse(alloc, io_state.io(), "FileRead", .null, "x"); // 无配置 → no-op
    const entries = [_]HookEntry{.{ .matcher = "FileRead", .command = "true" }};
    setConfig(.{ .post = &entries });
    defer setConfig(.{});
    postToolUse(alloc, io_state.io(), "FileRead", .null, "x");
}
