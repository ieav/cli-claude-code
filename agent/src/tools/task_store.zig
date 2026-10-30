/// Session-scoped task store backing the TaskCreate/TaskList/TaskUpdate tools.
/// Tool execute() has no context parameter, so the store is a process-wide
/// singleton living for the whole REPL session.
const std = @import("std");

pub const TaskStatus = enum {
    pending,
    in_progress,
    completed,

    pub fn label(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "○ pending",
            .in_progress => "◐ in_progress",
            .completed => "● completed",
        };
    }
};

pub const Task = struct {
    id: usize,
    subject: []u8,
    description: []u8,
    status: TaskStatus,
    /// P3: 1-5, 5 = highest. Drives list ordering (and mirrors the
    /// subagent dispatch claim order semantics).
    priority: u8 = 3,
};

pub const TaskStore = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task) = .empty,
    next_id: usize = 1,
    /// TaskList/TaskCreate run on the parallel executor — the shared store
    /// must survive concurrent calls. Spin lock (short critical sections,
    /// same style as thread_pool.workerLoop).
    mu: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    fn lockMu(self: *Self) void {
        while (self.mu.cmpxchgWeak(0, 1, .acquire, .acquire)) |_| {
            std.Thread.yield() catch {};
        }
    }

    fn unlockMu(self: *Self) void {
        self.mu.store(0, .release);
    }

    pub fn deinit(self: *Self) void {
        self.lockMu();
        defer self.unlockMu();
        for (self.tasks.items) |t| {
            self.allocator.free(t.subject);
            self.allocator.free(t.description);
        }
        self.tasks.deinit(self.allocator);
    }

    pub fn create(self: *Self, subject: []const u8, description: []const u8, priority: u8) !usize {
        self.lockMu();
        defer self.unlockMu();
        const task = Task{
            .id = self.next_id,
            .subject = try self.allocator.dupe(u8, subject),
            .description = try self.allocator.dupe(u8, description),
            .status = .pending,
            .priority = std.math.clamp(priority, 1, 5),
        };
        try self.tasks.append(self.allocator, task);
        self.next_id += 1;
        return task.id;
    }

    /// Returns false when the id is unknown or the status string invalid.
    pub fn update(self: *Self, id: usize, status_str: []const u8) bool {
        const status = std.meta.stringToEnum(TaskStatus, status_str) orelse return false;
        self.lockMu();
        defer self.unlockMu();
        for (self.tasks.items) |*t| {
            if (t.id == id) {
                t.status = status;
                return true;
            }
        }
        return false;
    }

    pub fn find(self: *Self, id: usize) ?*Task {
        for (self.tasks.items) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    pub fn count(self: *const Self) usize {
        return self.tasks.items.len;
    }

    pub fn completedCount(self: *const Self) usize {
        var n: usize = 0;
        for (self.tasks.items) |t| {
            if (t.status == .completed) n += 1;
        }
        return n;
    }

    /// Render the list; caller owns the returned string. P3: active tasks
    /// first (in_progress over pending), higher priority before lower —
    /// priority finally has a consumer, not just a stored byte.
    pub fn render(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        if (self.tasks.items.len == 0) {
            try w.writeAll("No tasks.");
        } else {
            const Order = struct {
                fn rank(t: Task) u8 {
                    return switch (t.status) {
                        .in_progress => 0,
                        .pending => 1,
                        .completed => 2,
                    };
                }
                fn lessThan(_: void, a: Task, b: Task) bool {
                    const ra = rank(a);
                    const rb = rank(b);
                    if (ra != rb) return ra < rb;
                    if (a.priority != b.priority) return a.priority > b.priority;
                    return a.id < b.id;
                }
            };
            const sorted = try allocator.dupe(Task, self.tasks.items);
            defer allocator.free(sorted);
            std.sort.pdq(Task, sorted, {}, Order.lessThan);

            try w.print("Tasks ({d}/{d} completed):\n", .{ self.completedCount(), self.tasks.items.len });
            for (sorted) |t| {
                try w.print("  #{d} {s} — {s}\n", .{ t.id, t.status.label(), t.subject });
                if (t.priority != 3) {
                    try w.print("      [优先级 {d}/5]\n", .{t.priority});
                }
                if (t.description.len > 0) {
                    try w.print("      {s}\n", .{t.description});
                }
            }
        }
        var list = aw.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

var g_store: ?TaskStore = null;
var g_store_init = std.atomic.Value(bool).init(false);

/// The process-wide session store (lazily initialized, never deinit'd —
/// task data is session-scoped and freed at process exit). Init is
/// locked: parallel workers used to race the null-check and could get
/// two stores (one leaked, one divergent).
pub fn global() *TaskStore {
    if (!g_store_init.load(.acquire)) {
        while (g_init_mu.cmpxchgWeak(0, 1, .acquire, .acquire)) |_| {
            std.Thread.yield() catch {};
        }
        defer g_init_mu.store(0, .release);
        if (!g_store_init.load(.acquire)) {
            g_store = TaskStore.init(std.heap.smp_allocator);
            g_store_init.store(true, .release);
        }
    }
    return &g_store.?;
}

var g_init_mu = std.atomic.Value(u8).init(0);

/// Reset and free the global store (used by tests).
pub fn resetGlobal() void {
    while (g_init_mu.cmpxchgWeak(0, 1, .acquire, .acquire)) |_| {
        std.Thread.yield() catch {};
    }
    defer g_init_mu.store(0, .release);
    if (g_store) |*s| s.deinit();
    g_store = null;
    g_store_init.store(false, .release);
}

test "TaskStore create/update/render lifecycle" {
    var store = TaskStore.init(std.testing.allocator);
    defer store.deinit();

    const id1 = try store.create("Fix parser bug", "SSE delimiter off by one", 3);
    const id2 = try store.create("Write docs", "", 5);
    try std.testing.expectEqual(@as(usize, 1), id1);
    try std.testing.expectEqual(@as(usize, 2), id2);
    try std.testing.expectEqual(@as(usize, 2), store.count());

    try std.testing.expect(store.update(id1, "in_progress"));
    try std.testing.expect(store.update(id1, "completed"));
    try std.testing.expect(!store.update(99, "pending")); // unknown id
    try std.testing.expect(!store.update(id2, "bogus")); // invalid status

    const rendered = try store.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1/2 completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "#1 ● completed — Fix parser bug") != null);
    // P3 priority ordering: pending #2 (priority 5) renders before the
    // completed #1, and the non-default priority is visible.
    const idx2 = std.mem.indexOf(u8, rendered, "#2").?;
    const idx1 = std.mem.indexOf(u8, rendered, "#1").?;
    try std.testing.expect(idx2 < idx1);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[优先级 5/5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "SSE delimiter off by one") != null);
}

test "task tools end-to-end via execute()" {
    const task_create = @import("task_create.zig");
    const task_list = @import("task_list.zig");
    const task_update = @import("task_update.zig");
    const json_helpers = @import("../util/json_helpers.zig");
    resetGlobal();
    defer resetGlobal();

    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    // Create two tasks.
    {
        const p = try json_helpers.parse(std.testing.allocator, "{\"subject\":\"M6 wiring\",\"description\":\"task tools real\"}");
        defer p.deinit();
        const r = try task_create.execute(std.testing.allocator, p.value, io);
        defer std.testing.allocator.free(r.output);
        try std.testing.expect(!r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.output, "Task #1") != null);
    }
    {
        const p = try json_helpers.parse(std.testing.allocator, "{\"subject\":\"M7 parallel\"}");
        defer p.deinit();
        const r = try task_create.execute(std.testing.allocator, p.value, io);
        defer std.testing.allocator.free(r.output);
        try std.testing.expect(std.mem.indexOf(u8, r.output, "Task #2") != null);
    }

    // Update #1 to completed with a bad-then-good status.
    {
        const bad = try json_helpers.parse(std.testing.allocator, "{\"taskId\":\"1\",\"status\":\"nope\"}");
        defer bad.deinit();
        const r = try task_update.execute(std.testing.allocator, bad.value, io);
        defer std.testing.allocator.free(r.output);
        try std.testing.expect(r.is_error);
    }
    {
        const good = try json_helpers.parse(std.testing.allocator, "{\"taskId\":\"1\",\"status\":\"completed\"}");
        defer good.deinit();
        const r = try task_update.execute(std.testing.allocator, good.value, io);
        defer std.testing.allocator.free(r.output);
        try std.testing.expect(!r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.output, "#1 → ● completed") != null);
    }

    // List shows 1/2 completed.
    {
        const r = try task_list.execute(std.testing.allocator, .null, io);
        defer std.testing.allocator.free(r.output);
        try std.testing.expect(std.mem.indexOf(u8, r.output, "1/2 completed") != null);
    }
}
