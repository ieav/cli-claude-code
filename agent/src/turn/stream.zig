/// Stream-phase machinery (P1 extraction from repl.zig — pure move):
/// StreamAgg event aggregation, the line-buffered live transcript, the
/// tool-call preview, StreamJob pump + streamComplete UI loop.
const std = @import("std");
const termio = @import("../util/termio.zig");
const wincompat = @import("../util/wincompat.zig");
const llm = @import("../llm/mod.zig");
const lineinput = @import("../util/lineinput.zig");
const util_time = @import("../util/time.zig");
const turn_clock = @import("../util/turn_clock.zig");
const task_mod = @import("../task/mod.zig");
const logger = @import("../util/log.zig");
const task_store = @import("../tools/task_store.zig");
const mpsc_queue = @import("../task/mpsc_queue.zig");
const llm_watchdog = @import("../util/llm_watchdog.zig");
const menu = @import("../util/menu.zig");
const json_tree = @import("../util/json_tree.zig");
const allocator = std.heap.smp_allocator;

const dupeJsonValue = json_tree.dupeJsonValue;
const freeJsonValue = json_tree.freeJsonValue;

const StreamAgg = struct {
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    /// Table-aware transcript writer (the turn loop's RegionWriter). When
    /// set, whole lines flow through its emitLine — pipe tables buffer and
    /// render aligned (renderTableBlock) instead of dumping raw markdown.
    /// Null keeps the legacy raw regionPrintLine path (non-turn callers).
    tw: ?*std.Io.Writer = null,
    file_writer: *std.Io.File.Writer,
    text: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(llm.provider.ToolUseBlock) = .empty,
    usage: llm.provider.Usage = .{ .input_tokens = 0, .output_tokens = 0 },
    stop_reason: llm.provider.CompleteResponse.StopReason = .end_turn,
    saw_error: ?llm.provider.ProviderError = null,
    /// One-shot dim "(thinking…)" marker: reasoning streams (GLM
    /// reasoning_content / Claude thinking) used to render as dead silence
    /// for seconds, reading like a hang.
    thinking_shown: bool = false,
    /// Line-buffered display: complete lines flush above the live region
    /// (flushLine); a partial tail waits for its newline or turn end.
    /// Seeded with the one-space response margin. line_cols is the
    /// buffered content's display width — reaching the terminal width is
    /// a SOFT-WRAP flush point (single-line responses must stream, not
    /// sit invisible in the buffer until the turn ends).
    line_buf: std.ArrayList(u8) = .empty,
    line_cols: usize = 0,
    tick_n: usize = 0,
    /// Response left margin: every displayed response line opens with one
    /// space (user preference); the flag survives across delta chunks so a
    /// line broken between chunks still gets its margin.
    at_line_start: bool = true,
    /// Esc-interrupt: when set, streamCb polls stdin (throttled) so Esc
    /// cancels generation and recalls the input for editing.
    /// Live-region timing: request start (elapsed "等待响应 Ns") and the
    /// last stream event (silence gates when the region appears).
    req_t0: i64 = 0,
    last_event_ms: i64 = 0,

    fn deinit(self: *StreamAgg) void {
        self.line_buf.deinit(self.alloc);
        self.text.deinit(self.alloc);
        // Tool strings are session-lifetime (freed with history); just drop the list.
        self.tools.deinit(self.alloc);
    }

    /// Flush one buffered output line above the live region. The buffer is
    /// seeded with the one-space response margin, so items ARE the line.
    fn flushLine(self: *StreamAgg) void {
        if (self.tw) |tw| {
            // Route whole lines through the RegionWriter so pipe tables
            // hit isTableRow → renderTableBlock (the 2026-11-06 fix: live
            // deltas used to regionPrintLine on the RAW writer, so the
            // table machinery existed but model text never reached it).
            // A soft-wrapped partial gets a synthetic newline — display-
            // identical to the terminal's own wrap, and it releases the
            // RegionWriter's line buffer.
            if (self.line_buf.items.len > 0 and self.line_buf.items[self.line_buf.items.len - 1] != '\n') {
                self.line_buf.append(self.alloc, '\n') catch {};
            }
            tw.writeAll(self.line_buf.items) catch {};
        } else {
            lineinput.regionPrintLine(self.w, self.line_buf.items);
        }
        self.line_buf.clearRetainingCapacity();
        self.line_buf.append(self.alloc, ' ') catch {}; // margin seed
        self.line_cols = 0;
        std.Io.File.Writer.flush(self.file_writer) catch {};
    }
};

/// Claude-Code-style one-line tool call display: `⏺ Bash(ls -la)`. Picks
/// the most informative argument field for the tool; falls back to the raw
/// JSON. Returned slice is caller-owned (arena/temporary use); empty when
/// nothing useful to show.
fn toolArgSummary(alloc: std.mem.Allocator, tool: []const u8, input: std.json.Value) []const u8 {
    _ = tool;
    var pick: []const u8 = "";
    if (toolArgPick(input)) |p| {
        pick = p;
    } else {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        std.json.Stringify.value(input, .{}, &aw.writer) catch return "";
        pick = aw.written();
        if (pick.len <= 2) return ""; // "{}"
    }
    const s = summarize(alloc, pick) catch return "";
    return std.fmt.allocPrint(alloc, "({s})", .{s}) catch "";
}

/// The "interesting" string arg for a call preview (command/path/pattern/
/// query/topic/url/name), or null when none exists (the JSON-fallback
/// case handled by toolArgSummary).
fn toolArgPick(input: std.json.Value) ?[]const u8 {
    const interesting = [_][]const u8{ "command", "path", "pattern", "query", "topic", "url", "name" };
    for (interesting) |field| {
        if (input == .object) {
            if (input.object.get(field)) |v| {
                if (v == .string and v.string.len > 0) return v.string;
            }
        }
    }
    return null;
}

/// Full-visibility call preview (2026-11-06): a short single-line arg
/// stays inline `⏺ Bash(cmd)` — UNTRUNCATED; a long or multi-line arg
/// prints the WHOLE value as an indented body under the header. The old
/// 80-col one-line cut reduced long commands to "(cd ~/… && grep …)" —
/// the user could never see what was about to run. JSON-fallback
/// previews (no interesting field) keep the summarized one-line shape.
pub fn printToolCallPreview(w: *std.Io.Writer, alloc: std.mem.Allocator, name: []const u8, input: std.json.Value) void {
    if (toolArgPick(input)) |pick| {
        if (pick.len <= 96 and std.mem.indexOfScalar(u8, pick, '\n') == null) {
            var tb: [192]u8 = undefined;
            const line_opt: ?[]const u8 = std.fmt.bufPrint(&tb, "  \x1b[36m⏺ {s}\x1b[0m\x1b[2m({s})\x1b[0m\n", .{ name, pick }) catch null;
            if (line_opt) |line| {
                lineinput.regionPrintLine(w, line);
                return;
            }
            // Buffer overflow (huge name?) → header+body path below.
        }
        var hb: [96]u8 = undefined;
        const head = std.fmt.bufPrint(&hb, "  \x1b[36m⏺ {s}\x1b[0m\n", .{name}) catch "";
        lineinput.regionPrintLine(w, head);
        var rest = pick;
        var shown: usize = 0;
        while (rest.len > 0 and shown < 50) : (shown += 1) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            var tb: [4096]u8 = undefined;
            const line = std.fmt.bufPrint(&tb, "  {s}\n", .{std.mem.trimEnd(u8, rest[0..nl], " \t\r")}) catch
                std.fmt.bufPrint(&tb, "  …(单行超 4KiB)\n", .{}) catch "";
            lineinput.regionPrintLine(w, line);
            rest = if (nl < rest.len) rest[nl + 1 ..] else "";
        }
        const total = std.mem.count(u8, pick, "\n") + @intFromBool(pick.len > 0 and pick[pick.len - 1] != '\n');
        if (shown < total) {
            var mb: [96]u8 = undefined;
            const marker: ?[]const u8 = std.fmt.bufPrint(&mb, "  \x1b[2m…参数过长已截断（{d}/{d} 行）\x1b[0m\n", .{ shown, total }) catch null;
            if (marker) |line| {
                lineinput.regionPrintLine(w, line);
            }
        }
        return;
    }
    var tb: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&tb, "  ⏺ \x1b[1m{s}\x1b[0m{s}\n", .{ name, toolArgSummary(alloc, name, input) }) catch "";
    lineinput.regionPrintLine(w, line);
}

/// "(summary)" — first line, display-width-capped (CJK-aware, per CHAR not
/// per byte), control bytes stripped, never cut mid-UTF-8.
fn summarize(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var end = @min(s.len, std.mem.indexOfScalar(u8, s, '\n') orelse s.len);
    if (end > 80) end = 80;
    // Back off to a char boundary (byte cuts used to split CJK chars and
    // print mojibake).
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;

    var out = std.ArrayList(u8).empty;
    var w: usize = 0;
    var i: usize = 0;
    while (i < end) {
        const c = s[i];
        if (c < 0x20) {
            i += 1;
            continue;
        }
        const cw: usize = if (c >= 0xE0) 2 else 1;
        if (w + cw > 48) break;
        var j = i + 1;
        while (j < end and (s[j] & 0xC0) == 0x80) j += 1;
        try out.appendSlice(alloc, s[i..j]);
        w += cw;
        i = j;
    }
    if (i < s.len or w >= 48) try out.appendSlice(alloc, "…");
    return out.toOwnedSlice(alloc);
}

fn streamCb(ctx_opaque: ?*anyopaque, event: llm.provider.StreamEvent) anyerror!void {
    // P2: PURE event processing — stdin belongs to the UI loop, which
    // drains this callback from its mini-loop in streamComplete.
    const self: *StreamAgg = @ptrCast(@alignCast(ctx_opaque.?));
    if (event != .tick) self.last_event_ms = util_time.nowMillis();
    switch (event) {
        .content_delta => |d| {
            // History keeps the raw text; the display is LINE-BUFFERED:
            // whole lines print above the live region (regionPrintLine),
            // a trailing partial line waits for its newline or turn end.
            // Line-atomicity is what lets the input region stay visible
            // while text flows — no mid-line text ever crosses it.
            try self.text.appendSlice(self.alloc, d);
            self.tick_n = 0; // data flows — silence-flush cadence restarts
            for (d) |ch| {
                // Continuation bytes belong to the char already counted —
                // they can never be a flush point (a flush mid-char split
                // UTF-8 and printed mojibake at the wrap boundary).
                if (ch >= 0x80 and ch < 0xC0) {
                    try self.line_buf.append(self.alloc, ch);
                    continue;
                }
                // A new char begins: flush FIRST if the buffered content
                // already reached the terminal width — the soft-wrap
                // point the terminal would take anyway, so single-line
                // responses stream visibly below… above the region.
                if (self.line_cols + 1 >= lineinput.currentTermWidth()) {
                    self.flushLine();
                }
                try self.line_buf.append(self.alloc, ch);
                if (ch == '\n') {
                    self.flushLine();
                    continue;
                }
                // Display width (UTF-8 lead bytes count — mirrors
                // lineinput.charWidth).
                if (ch >= 0xE0) {
                    self.line_cols += 2;
                } else if (ch >= 0x20) {
                    self.line_cols += 1;
                }
            }
        },
        .thinking_delta => {
            if (!self.thinking_shown) {
                self.thinking_shown = true;
                lineinput.regionPrintLine(self.w, "\x1b[2m(thinking…)\x1b[0m\n");
                std.Io.File.Writer.flush(self.file_writer) catch {};
            }
        },
        .tool_call => |tu| {
            // Per-event arena: the summary strings are print-and-done.
            var sum_arena = std.heap.ArenaAllocator.init(self.alloc);
            defer sum_arena.deinit();
            printToolCallPreview(self.w, sum_arena.allocator(), tu.name, tu.input);
            std.Io.File.Writer.flush(self.file_writer) catch {};
            try self.tools.append(self.alloc, .{
                .id = try self.alloc.dupe(u8, tu.id),
                .name = try self.alloc.dupe(u8, tu.name),
                .input = try dupeJsonValue(self.alloc, tu.input),
            });
            self.stop_reason = .tool_use;
        },
        .done => |u| {
            if (u.usage) |uu| self.usage = uu;
            // Adopt the wire's stop verdict (max_tokens would previously
            // vanish here — finish_reason was dropped on the stream path
            // and every capped truncation read as end_turn). A .tool_use
            // from the tool_call events outranks anything the final chunk
            // says.
            if (u.stop_reason) |sr| {
                if (self.stop_reason != .tool_use) self.stop_reason = sr;
            }
        },
        .error_occurred => |e| self.saw_error = e,
        .tick => {
            // ~100ms of socket silence. After 1.5s of CONTINUOUS silence
            // (15 ticks — content arrival resets the count) flush any
            // buffered partial line so a trickling single-line response
            // still becomes visible; newline and soft-wrap stay the clean
            // flush points during normal flow, keeping text from
            // shattering into fragments. Then refresh the status row.
            self.tick_n += 1;
            if (self.tick_n % 15 == 0 and self.line_cols > 0) {
                self.flushLine();
            }
            const now = util_time.nowMillis();
            // P1: BOTH clocks — this round (req_t0) and the whole turn
            // (turn_clock). The old status showed only the round clock,
            // which reset to 0.0s on every generation and hid what the
            // previous rounds cost.
            const round_ms = now - self.req_t0;
            const elapsed = turn_clock.elapsedMs(now);
            const turn_ms = if (elapsed > 0) elapsed else round_ms;
            const queued = lineinput.queuedCount();
            const ts = task_store.global();
            var task_seg: [40]u8 = undefined;
            const tseg: []const u8 = if (ts.count() > 0)
                std.fmt.bufPrint(&task_seg, " · 任务 {d}/{d}", .{ ts.completedCount(), ts.count() }) catch ""
            else
                "";
            var sb: [128]u8 = undefined;
            const st = if (queued > 0)
                std.fmt.bufPrint(&sb, "⏳ 第{d}轮 {d}.{d}s · 累计 {d}.{d}s{s} · Esc 中断 · Enter 排队 · 已排队 {d} 条", .{
                    turn_clock.roundsDone() + 1,
                    @divTrunc(round_ms, 1000),
                    @mod(@divTrunc(round_ms, 100), 10),
                    @divTrunc(turn_ms, 1000),
                    @mod(@divTrunc(turn_ms, 100), 10),
                    tseg,
                    queued,
                }) catch "⏳ 等待响应 · Esc 中断 · Enter 排队"
            else
                std.fmt.bufPrint(&sb, "⏳ 第{d}轮 {d}.{d}s · 累计 {d}.{d}s{s} · Esc 中断 · Enter 排队", .{
                    turn_clock.roundsDone() + 1,
                    @divTrunc(round_ms, 1000),
                    @mod(@divTrunc(round_ms, 100), 10),
                    @divTrunc(turn_ms, 1000),
                    @mod(@divTrunc(turn_ms, 100), 10),
                    tseg,
                }) catch "⏳ 等待响应 · Esc 中断 · Enter 排队";
            lineinput.regionStatus(self.w, st);
            std.Io.File.Writer.flush(self.file_writer) catch {};
        },
    }
}

// ── P2: stream pump job ──────────────────────────────────────────────
// The provider's socket pump runs on a WORKER thread; every event is
// deep-copied into the lock-free bounded queue (task/mpsc_queue) that
// the UI loop (main thread, the only terminal writer) drains. Stdin
// belongs to the UI loop exclusively: keystrokes edit the persistent
// editor while the network runs in parallel; Esc sets the cancel flag
// and the pump fails with error.EscCancelled — the same recall path as
// before, now cross-thread.
const StreamJob = struct {
    const Q = mpsc_queue.BoundedMPSC(llm.provider.StreamEvent, 1024);
    queue: Q,
    /// Set (release) by the pump thread when prov.stream returns; err is
    /// written BEFORE it, so an acquire read of done makes err visible.
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The pump publishes its connection's fd here once connected
    /// (-1 = none). The UI loop, on cancel, shutdown(2)s it — the pump's
    /// blocking read fails and the stream unwinds.
    cancel_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    alloc: std.mem.Allocator,

    /// UI-loop side of cancellation: set the flag and kill the socket.
    /// The pump's transport error then surfaces (EscCancelled is mapped
    /// from the killed connection by the provider's error path).
    fn requestCancel(self: *StreamJob) void {
        self.cancel.store(true, .release);
        const fd = self.cancel_fd.load(.acquire);
        if (fd >= 0) wincompat.shutdownFd(fd);
    }

    fn isDone(self: *StreamJob) bool {
        return self.done.load(.acquire) and self.queue.isEmpty();
    }

    /// Deep-copy an event's payloads into job-owned storage (provider
    /// slices are only valid for the callback's duration).
    fn dupeEvent(self: *StreamJob, ev: llm.provider.StreamEvent) !llm.provider.StreamEvent {
        return switch (ev) {
            .content_delta => |d| .{ .content_delta = try self.alloc.dupe(u8, d) },
            .thinking_delta => |d| .{ .thinking_delta = try self.alloc.dupe(u8, d) },
            .tool_call => |tc| .{ .tool_call = .{
                .id = try self.alloc.dupe(u8, tc.id),
                .name = try self.alloc.dupe(u8, tc.name),
                .input = try dupeJsonValue(self.alloc, tc.input),
            } },
            .done => |u| .{ .done = u },
            .error_occurred => |e| .{ .error_occurred = e },
            .tick => .tick,
        };
    }

    /// Release a consumed event's job-owned payloads.
    fn release(self: *StreamJob, ev: llm.provider.StreamEvent) void {
        switch (ev) {
            .content_delta => |d| self.alloc.free(@constCast(d)),
            .thinking_delta => |d| self.alloc.free(@constCast(d)),
            .tool_call => |tc| {
                self.alloc.free(tc.id);
                self.alloc.free(tc.name);
                freeJsonValue(self.alloc, tc.input);
            },
            else => {},
        }
    }

    /// Provider callback (pump thread). A full queue backs off 1ms at a
    /// time — the SSE socket's TCP backpressure equivalent.
    fn callback(ctx_opaque: ?*anyopaque, event: llm.provider.StreamEvent) anyerror!void {
        const self: *StreamJob = @ptrCast(@alignCast(ctx_opaque.?));
        const ev = try self.dupeEvent(event);
        errdefer self.release(ev);
        while (!self.queue.push(ev)) {
            if (self.cancel.load(.acquire)) return error.EscCancelled;
            util_time.sleepMs(1);
        }
    }

    /// Thread entry: run the pump; record the outcome.
    fn pump(self: *StreamJob, prov: llm.provider.Provider, history: []const llm.Message, opts: llm.provider.CompleteOptions) void {
        prov.stream(history, opts, @ptrCast(self), callback) catch |e| {
            self.err = e;
        };
        self.done.store(true, .release);
    }
};

/// Auto-escalation ceiling for the reasoning-burn retry: doublings from
/// the default cover deep-thinking turns without letting a runaway retry
/// burn unbounded tokens.
pub const MAX_OUTPUT_BUDGET: u32 = 32_768;

/// True when a response shows the budget-truncation signature: the wire
/// said max_tokens, OR output landed on the cap (some gateways report
/// end_turn at the length cap — out==cap is the tell). Reasoning models
/// burning the whole budget on thinking produce exactly this shape: zero
/// visible text, out == max_tokens.
pub fn outputBudgetExhausted(stop: llm.provider.CompleteResponse.StopReason, out: u32, cap: u32) bool {
    if (stop == .max_tokens) return true;
    return cap > 0 and out >= cap;
}

test "outputBudgetExhausted detects the cap signature" {
    const SR = llm.provider.CompleteResponse.StopReason;
    // Wire-honest cap.
    try std.testing.expect(outputBudgetExhausted(SR.max_tokens, 4096, 4096));
    // Gateway lies about end_turn but out landed on the cap.
    try std.testing.expect(outputBudgetExhausted(SR.end_turn, 4096, 4096));
    // Healthy empty response (no spend) must NOT read as capped.
    try std.testing.expect(!outputBudgetExhausted(SR.end_turn, 0, 4096));
    // Normal completion below the cap.
    try std.testing.expect(!outputBudgetExhausted(SR.end_turn, 3800, 4096));
    // Zero/absent cap never triggers the out>=cap branch.
    try std.testing.expect(!outputBudgetExhausted(SR.end_turn, 5000, 0));
}

pub fn streamComplete(
    prov: llm.Provider,
    cron: ?*task_mod.CronScheduler,
    history: []const llm.Message,
    opts: llm.provider.CompleteOptions,
    r: ?*std.Io.Reader,
    w: *std.Io.Writer,
    /// Transcript writer for model text: the turn loop's RegionWriter
    /// (table-aware). Null for non-TUI callers.
    tw: ?*std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    alloc: std.mem.Allocator,
    had_thinking: *bool,
) !llm.provider.CompleteResponse {
    var agg = StreamAgg{
        .alloc = alloc,
        .w = w,
        .tw = tw,
        .file_writer = file_writer,
        .req_t0 = util_time.nowMillis(),
        .last_event_ms = util_time.nowMillis(),
    };
    defer agg.deinit();
    agg.line_buf.append(alloc, ' ') catch {}; // response margin seed

    // The live region is owned by the AGENT LOOP (begun once per turn,
    // ended once after it) — streamComplete only prints INTO it. This
    // defer flushes any trailing partial response line above the region
    // on every exit path (flushLine is regionPrintLine-based); the region
    // itself stays up for the caller to end or keep.
    defer {
        if (agg.line_buf.items.len > 1) {
            agg.line_buf.append(alloc, '\n') catch {};
            agg.flushLine();
        }
    }

    // Keep the terminal RAW for the whole generation: readLine restores
    // cooked mode when it returns, and under cooked input discipline the
    // Esc probe is crippled — ESC parks in the line buffer until some
    // later \r flushes the line (ICRNL rewriting it to \n on the way in,
    // which then leaked into the editor as a newline), and 0x7f is eaten
    // as ERASE, deleting the queued Esc entirely. Raw makes Esc visible
    // within one 50 ms probe.
    var esc_guard = menu.RawGuard{};
    if (r != null) {
        esc_guard.enterNoSig();
        if (esc_guard.active) {
            // Drain bytes that queued during the cooked tool-execution
            // window between two generations: an Esc pressed THERE must
            // not cancel this generation's very first stream event. The
            // pump keeps ordinary typed-ahead bytes (they edit the
            // persistent editor) and drops the stale Esc (true return).
            while (lineinput.editorLiveKey(r.?, null)) {}
        }
    }
    defer if (r != null) esc_guard.restore();

    // P2: the pump runs on a worker thread; THIS thread is the UI loop —
    // it drains the event queue, keeps the editor interactive (full
    // editing while the network runs), ticks the status row, and cancels
    // via the flag on Esc/Ctrl-C.
    var job = StreamJob{ .alloc = allocator, .queue = .init() };
    var job_opts = opts;
    if (r != null) {
        job_opts.cancel_flag = &job.cancel;
        job_opts.cancel_fd = &job.cancel_fd;
    }
    var cb_err: ?anyerror = null;
    {
        const th = std.Thread.spawn(.{}, StreamJob.pump, .{ &job, prov, history, job_opts }) catch null;
        if (th) |t| {
            t.detach(); // joined logically below by waiting for done
            ui: while (true) {
                // 1) Drain events into the aggregator (pure processing —
                //    streamCb no longer touches stdin).
                while (job.queue.pop()) |ev| {
                    streamCb(@ptrCast(&agg), ev) catch |err| {
                        cb_err = err;
                        job.cancel.store(true, .release);
                        break :ui;
                    };
                    job.release(ev);
                }
                if (job.isDone()) break :ui;
                // 2) Stdin: 100ms slice. Bytes edit the persistent editor
                //    (editorLiveKey drains everything available); a quiet
                //    slice ticks the status row.
                if (r) |rr| {
                    const n = termio.pollInput(100);
                    if (n == 1) {
                        if (lineinput.editorLiveKey(rr, w)) {
                            job.requestCancel();
                        }
                    } else if (n == 0) {
                        // Quiet slice: cron tasks (same starvation fix as
                        // the tool-phase loop) + the status tick.
                        if (cron) |cp| cp.drainDue();
                        streamCb(@ptrCast(&agg), .tick) catch {};
                    }
                } else {
                    // No reader (non-interactive): wait for the pump.
                    util_time.sleepMs(50);
                }
            }
            // Wait for the pump to land (cancellation needs it to notice
            // the flag and exit; the queue may still receive its last
            // events — drain them without processing on the error path).
            while (!job.isDone()) {
                while (job.queue.pop()) |ev| {
                    if (cb_err == null) {
                        streamCb(@ptrCast(&agg), ev) catch |err| {
                            cb_err = err;
                            job.requestCancel();
                        };
                    }
                    job.release(ev);
                }
                util_time.sleepMs(10);
            }
        } else {
            // No thread available: degrade to the synchronous pump (no
            // live editing — same shape as before P2).
            prov.stream(history, job_opts, @ptrCast(&agg), streamCb) catch |err| {
                job.err = err;
            };
        }
    }
    if (cb_err) |err| {
        for (agg.tools.items) |*tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
            freeJsonValue(alloc, tu.input);
        }
        return err;
    }
    if (job.err) |err| {
        // Hard transport failure / Esc cancel / TTFT kill before any
        // event: the saw_error path below never ran, so free the duped
        // tool strings here — they never reached history.
        for (agg.tools.items) |*tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
            freeJsonValue(alloc, tu.input);
        }
        return err;
    }
    if (agg.saw_error) |e| {
        // These dupes never made it into history — free them here.
        for (agg.tools.items) |*tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
            freeJsonValue(alloc, tu.input);
        }
        return e;
    }

    var blocks: std.ArrayList(llm.ContentBlock) = .empty;
    errdefer blocks.deinit(alloc);
    // Reasoning-stream marker out for the caller: a thinking-only response
    // (reasoning deltas, zero content) gets a distinct diagnosis.
    had_thinking.* = had_thinking.* or agg.thinking_shown;
    if (agg.text.items.len > 0) {
        const t = try alloc.dupe(u8, agg.text.items);
        try blocks.append(alloc, .{ .text = t });
    }
    for (agg.tools.items) |tu| {
        try blocks.append(alloc, .{ .tool_use = tu });
    }

    // Success: flush the trailing partial line (region-aware — the region
    // stays up; the agent loop keeps printing above it or ends it). No
    // teardown here: the old regionEnd+"\n" was per-generation; the region
    // is now turn-scoped.
    if (agg.line_buf.items.len > 1) {
        agg.line_buf.append(alloc, '\n') catch {};
        agg.flushLine();
    }
    return .{
        .content = try blocks.toOwnedSlice(alloc),
        .usage = agg.usage,
        .stop_reason = agg.stop_reason,
    };
}

test "toolArgSummary picks the informative field and caps length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cmd = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":\"ls -la /tmp\"}", .{});
    try std.testing.expectEqualStrings("(ls -la /tmp)", toolArgSummary(a, "Bash", cmd));

    const path = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"/etc/hosts\"}", .{});
    try std.testing.expectEqualStrings("(/etc/hosts)", toolArgSummary(a, "FileRead", path));

    // Empty object: nothing to show.
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{});
    try std.testing.expectEqualStrings("", toolArgSummary(a, "ToolSearch", empty));

    // Long command gets the ellipsis cap.
    const longv = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}", .{});
    const out = toolArgSummary(a, "Bash", longv);
    try std.testing.expect(std.mem.endsWith(u8, out, "…)"));
}

test "printToolCallPreview: short inline untruncated, long becomes header+full body" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // Short: single inline line, the full command visible.
    var o1: std.json.ObjectMap = .empty;
    defer o1.deinit(std.testing.allocator);
    try o1.put(std.testing.allocator, "command", .{ .string = "ls -la" });
    printToolCallPreview(&aw.writer, std.testing.allocator, "Bash", .{ .object = o1 });
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "⏺") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(ls -la)") != null);

    // Long (>96): header line, then the FULL command indented — the old
    // 80-col cut showed "(cd ~/… && grep …)" and nothing more.
    const long_cmd = "cd ~/temp/chat/algorithms/build/04-ds && grep -rn \"^- \\[ \\]\" README.md TODO.md NOTES.md docs/ 2>/dev/null | head -20";
    var o2: std.json.ObjectMap = .empty;
    defer o2.deinit(std.testing.allocator);
    try o2.put(std.testing.allocator, "command", .{ .string = long_cmd });
    aw.clearRetainingCapacity();
    printToolCallPreview(&aw.writer, std.testing.allocator, "Bash", .{ .object = o2 });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "| head -20") != null); // tail visible
    try std.testing.expect(std.mem.indexOf(u8, out, "\n  cd ~/temp/chat") != null); // indented body
}
