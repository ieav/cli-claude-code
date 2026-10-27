/// Runtime-extensible tool registry (M1).
///
/// The comptime ToolRegistry generic stays for the built-in tools (tests
/// still use it); this runtime view is what the REPL owns. MCP tools are
/// registered here at session start (or when a server connects) with
/// namespaced names — `mcp__<server>__<tool>` — and everything downstream
/// (tool declarations, permission gate, parallel orchestration, /tools)
/// reads from the same list.
const std = @import("std");
const registry = @import("registry.zig");
const llm = @import("../llm/mod.zig");

const Entry = struct {
    def: registry.ToolDefinition,
    /// True when name/description/input_schema are heap copies the
    /// registry owns (dynamic tools); built-ins point at comptime literals.
    owned: bool,
};

pub const RuntimeRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    defs_cache: ?[]registry.ToolDefinition = null,
    /// Wire specs maintained in sync with entries (always duped so every
    /// spec is freed uniformly).
    specs: std.ArrayList(llm.ToolSpec) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{ .allocator = allocator };
        for (registry.default_tools) |tool| {
            self.entries.append(allocator, .{ .def = tool, .owned = false }) catch {};
            const spec = llm.ToolSpec{
                .name = tool.name,
                .description = tool.description,
                .input_schema = tool.input_schema,
            };
            self.appendSpec(spec) catch {};
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.defs_cache) |c| self.allocator.free(c);
        for (self.entries.items) |e| {
            if (e.owned) {
                self.allocator.free(e.def.name);
                self.allocator.free(e.def.description);
                self.allocator.free(e.def.input_schema);
            }
        }
        self.entries.deinit(self.allocator);
        for (self.specs.items) |s| {
            self.allocator.free(s.name);
            self.allocator.free(s.description);
            self.allocator.free(s.input_schema);
        }
        self.specs.deinit(self.allocator);
    }

    fn appendSpec(self: *Self, spec: llm.ToolSpec) !void {
        try self.specs.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, spec.name),
            .description = try self.allocator.dupe(u8, spec.description),
            .input_schema = try self.allocator.dupe(u8, spec.input_schema),
        });
    }

    /// Register a dynamic tool. All strings are copied; `execute_ctx_fn` +
    /// `execute_ctx` are the trampoline the MCP bridge uses (ctx = server
    /// session). Rejects name collisions with anything already registered.
    pub fn registerDynamic(
        self: *Self,
        name: []const u8,
        description: []const u8,
        input_schema: []const u8,
        execute_ctx_fn: *const fn (?*anyopaque, std.mem.Allocator, std.json.Value, std.Io) anyerror!registry.ToolResult,
        execute_ctx: ?*anyopaque,
    ) !void {
        if (self.findByName(name) != null) return error.ToolNameTaken;
        if (self.defs_cache) |c| self.allocator.free(c);
        self.defs_cache = null;
        try self.entries.append(self.allocator, .{
            .def = .{
                .name = try self.allocator.dupe(u8, name),
                .description = try self.allocator.dupe(u8, description),
                .input_schema = try self.allocator.dupe(u8, input_schema),
                .execute_fn = unreachable_fn,
                .execute_ctx_fn = execute_ctx_fn,
                .execute_ctx = execute_ctx,
                .is_read_only = false,
                // MCP tools are unauditable → concurrency-unsafe and
                // "destructive unknown": the permission gate asks.
                .is_destructive = false,
            },
            .owned = true,
        });
        try self.appendSpec(.{ .name = name, .description = description, .input_schema = input_schema });
    }

    /// Remove every dynamic tool whose name starts with `prefix`
    /// (e.g. "mcp__playwright__"). Returns how many were removed.
    pub fn removeByPrefix(self: *Self, prefix: []const u8) usize {
        if (self.defs_cache) |c| self.allocator.free(c);
        self.defs_cache = null;
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (e.owned and std.mem.startsWith(u8, e.def.name, prefix)) {
                self.allocator.free(e.def.name);
                self.allocator.free(e.def.description);
                self.allocator.free(e.def.input_schema);
                _ = self.entries.orderedRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        if (removed > 0) self.rebuildSpecs() catch {};
        return removed;
    }

    fn rebuildSpecs(self: *Self) !void {
        for (self.specs.items) |s| {
            self.allocator.free(s.name);
            self.allocator.free(s.description);
            self.allocator.free(s.input_schema);
        }
        self.specs.clearRetainingCapacity();
        for (self.entries.items) |e| {
            try self.appendSpec(.{
                .name = e.def.name,
                .description = e.def.description,
                .input_schema = e.def.input_schema,
            });
        }
    }

    /// Find a tool by name or alias.
    pub fn findByName(self: *Self, name: []const u8) ?*const registry.ToolDefinition {
        for (self.entries.items) |*e| {
            if (e.def.matchesName(name)) return &e.def;
        }
        return null;
    }

    /// Wire-format tool declarations for CompleteOptions.tools.
    pub fn toolSpecs(self: *const Self) []const llm.ToolSpec {
        return self.specs.items;
    }

    /// Compact view for orchestration/partition calls (they want
    /// []const ToolDefinition, not our Entry pairs). Cached; rebuilt on
    /// any mutation.
    pub fn definitions(self: *Self) []const registry.ToolDefinition {
        if (self.defs_cache) |c| return c;
        const out = self.allocator.alloc(registry.ToolDefinition, self.entries.items.len) catch return &.{};
        for (self.entries.items, 0..) |e, i| out[i] = e.def;
        self.defs_cache = out;
        return out;
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    /// Placeholder execute_fn for dynamic entries — never called because
    /// ToolDefinition.execute() dispatches to execute_ctx_fn when set.
    fn unreachable_fn(_: std.mem.Allocator, _: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
        return error.DynamicToolHasNoStaticExecutor;
    }
};

// ── Tests ──

fn testExec(_: ?*anyopaque, _: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    _ = input;
    return .{ .output = "dyn-ok" };
}

test "RuntimeRegistry: built-ins present, specs in sync" {
    var reg = RuntimeRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqual(registry.default_tools.len, reg.count());
    try std.testing.expect(reg.findByName("Bash") != null);
    try std.testing.expect(reg.findByName("Shell") != null); // alias
    try std.testing.expectEqual(reg.count(), reg.toolSpecs().len);
    // /tools output must stay byte-identical to the comptime view: same
    // names in the same order.
    for (registry.default_tools, 0..) |tool, i| {
        try std.testing.expectEqualStrings(tool.name, reg.definitions()[i].name);
        try std.testing.expectEqualStrings(tool.name, reg.toolSpecs()[i].name);
    }
}

test "RuntimeRegistry: dynamic register, lookup, prefix removal" {
    var reg = RuntimeRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerDynamic("mcp__srv__echo", "Echo", "{\"type\":\"object\"}", testExec, null);
    try std.testing.expect(reg.findByName("mcp__srv__echo") != null);
    try std.testing.expectEqual(registry.default_tools.len + 1, reg.toolSpecs().len);

    // Duplicate names are rejected.
    try std.testing.expectError(error.ToolNameTaken, reg.registerDynamic("mcp__srv__echo", "x", "{}", testExec, null));

    // execute() dispatches through the ctx trampoline.
    const def = reg.findByName("mcp__srv__echo").?;
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    const res = try def.execute(std.testing.allocator, .null, io_state.io());
    try std.testing.expectEqualStrings("dyn-ok", res.output);

    // Prefix removal drops only the dynamic tools.
    const removed = reg.removeByPrefix("mcp__srv__");
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expect(reg.findByName("mcp__srv__echo") == null);
    try std.testing.expectEqual(registry.default_tools.len, reg.count());
    try std.testing.expectEqual(registry.default_tools.len, reg.toolSpecs().len);
}
