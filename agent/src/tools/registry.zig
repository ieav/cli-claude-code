/// Enhanced tool registry — comptime tool registration with permissions, validation,
/// concurrency safety, aliases, and tool search.
/// Extended from Claude Code CLI's Tool interface patterns.
const std = @import("std");
const llm = @import("../llm/mod.zig");

// ──── Core types ────

pub const ToolError = error{
    InvalidInput,
    PermissionDenied,
    ExecutionFailed,
    Timeout,
    ToolNotFound,
};

pub const ToolResult = struct {
    output: []const u8,
    is_error: bool = false,
};

pub const ValidationResult = union(enum) {
    valid,
    invalid: struct {
        message: []const u8,
        error_code: u32 = 0,
    },
};

pub const PermissionDecision = union(enum) {
    allow,
    deny: struct {
        message: []const u8,
    },
    ask: struct {
        message: []const u8,
    },
};

// ──── Permission context (forward declaration, defined in auth_mode.zig) ────

pub const PermissionMode = enum {
    default,
    accept_edits,
    plan,
    bypass,
    dont_ask,
    auto,
};

pub const RuleBehavior = enum { allow, deny, ask };

pub const PermissionRule = struct {
    source: enum { user_settings, project_settings, local_settings, session },
    behavior: RuleBehavior,
    tool_name: []const u8,
    content_pattern: ?[]const u8 = null,
};

pub const PermissionContext = struct {
    mode: PermissionMode,
    allow_rules: []const PermissionRule,
    deny_rules: []const PermissionRule,
    /// Rules that force a confirmation prompt even in permissive modes
    /// (bypass-immune, like deny rules).
    ask_rules: []const PermissionRule = &.{},
    provider: ?llm.Provider = null,
    allocator: ?std.mem.Allocator = null,
};

// ──── Enhanced ToolDefinition ────

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    execute_fn: *const fn (std.mem.Allocator, std.json.Value, std.Io) anyerror!ToolResult,
    is_read_only: bool = true,
    is_destructive: bool = false,

    // NEW: input-aware behavioral functions
    is_concurrency_safe_fn: ?*const fn (std.json.Value) bool = null,
    is_read_only_fn: ?*const fn (std.json.Value) bool = null,
    is_destructive_fn: ?*const fn (std.json.Value) bool = null,
    validate_input_fn: ?*const fn (std.json.Value) ValidationResult = null,
    check_permissions_fn: ?*const fn (std.json.Value, *const PermissionContext) PermissionDecision = null,

    // NEW: metadata
    aliases: ?[]const []const u8 = null,
    user_facing_name: ?[]const u8 = null,
    max_result_size: usize = 100_000,
    search_hint: ?[]const u8 = null,

    // ──── Helper methods ────

    /// Check if this tool can run concurrently with others for the given input.
    pub fn isConcurrencySafe(self: *const ToolDefinition, input: std.json.Value) bool {
        if (self.is_concurrency_safe_fn) |fn_ptr| return fn_ptr(input);
        return false; // fail-closed: default not concurrent-safe
    }

    /// Check if this tool only reads (no writes) for the given input.
    pub fn isReadOnly(self: *const ToolDefinition, input: std.json.Value) bool {
        if (self.is_read_only_fn) |fn_ptr| return fn_ptr(input);
        return self.is_read_only;
    }

    /// Check if this tool performs destructive operations for the given input.
    pub fn isDestructive(self: *const ToolDefinition, input: std.json.Value) bool {
        if (self.is_destructive_fn) |fn_ptr| return fn_ptr(input);
        return self.is_destructive;
    }

    /// Validate tool input before execution.
    pub fn validateInput(self: *const ToolDefinition, input: std.json.Value) ValidationResult {
        if (self.validate_input_fn) |fn_ptr| return fn_ptr(input);
        return .valid;
    }

    /// Check tool permissions for the given input and context.
    pub fn checkPermissions(self: *const ToolDefinition, input: std.json.Value, ctx: *const PermissionContext) PermissionDecision {
        if (self.check_permissions_fn) |fn_ptr| return fn_ptr(input, ctx);
        return .allow;
    }

    /// Get the user-facing display name.
    pub fn displayName(self: *const ToolDefinition) []const u8 {
        return self.user_facing_name orelse self.name;
    }

    /// Check if this tool matches a given name (including aliases).
    pub fn matchesName(self: *const ToolDefinition, name: []const u8) bool {
        if (std.mem.eql(u8, self.name, name)) return true;
        if (self.aliases) |alias_list| {
            for (alias_list) |alias| {
                if (std.mem.eql(u8, alias, name)) return true;
            }
        }
        return false;
    }
};

// ──── Comptime tool registry ────

/// Comptime tool registry. Pass a compile-time known slice of ToolDefinitions.
/// Generates type-safe lookup, execution, and JSON schema export.
pub fn ToolRegistry(comptime tools: []const ToolDefinition) type {
    return struct {
        const Self = @This();

        pub fn getDefinition(comptime name: []const u8) ?*const ToolDefinition {
            comptime for (tools) |*tool| {
                if (std.mem.eql(u8, tool.name, name)) return tool;
            };
            return null;
        }

        pub fn getByName(name: []const u8) ?*const ToolDefinition {
            comptime for (tools) |*tool| {
                if (std.mem.eql(u8, tool.name, name)) return tool;
            };
            return null;
        }

        /// Find a tool by name, including aliases.
        pub fn findByName(name: []const u8) ?*const ToolDefinition {
            inline for (tools) |*tool| {
                if (std.mem.eql(u8, tool.name, name)) return tool;
                if (comptime tool.aliases != null) {
                    inline for (tool.aliases.?) |alias| {
                        if (std.mem.eql(u8, alias, name)) return tool;
                    }
                }
            }
            return null;
        }

        pub fn allDefinitions() []const ToolDefinition {
            return tools;
        }

        pub fn count() usize {
            return tools.len;
        }

        pub fn execute(
            name: []const u8,
            allocator: std.mem.Allocator,
            input: std.json.Value,
            io: std.Io,
        ) anyerror!ToolResult {
            inline for (tools) |tool| {
                if (std.mem.eql(u8, tool.name, name)) {
                    return tool.execute_fn(allocator, input, io);
                }
            }
            return error.ToolNotFound;
        }

        /// Generate JSON array of tool definitions for LLM function calling.
        pub fn toJsonSchema(allocator: std.mem.Allocator) ![]u8 {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, "[");
            inline for (tools, 0..) |tool, i| {
                if (i > 0) try buf.appendSlice(allocator, ",");
                const entry = std.fmt.comptimePrint(
                    \\{{"type":"function","function":{{"name":"{s}","description":"{s}","parameters":{s}}}}}
                , .{ tool.name, tool.description, tool.input_schema });
                try buf.appendSlice(allocator, entry);
            }
            try buf.appendSlice(allocator, "]");
            return buf.toOwnedSlice(allocator);
        }

        pub fn has(name: []const u8) bool {
            inline for (tools) |tool| {
                if (std.mem.eql(u8, tool.name, name)) return true;
            }
            return false;
        }
    };
}

// ──── Helper functions ────

/// Extract a string field from JSON input.
pub fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const obj = input.object.get(key) orelse return null;
    return obj.string;
}

/// Extract an integer field from JSON input.
pub fn getIntField(input: std.json.Value, key: []const u8) ?i64 {
    if (input != .object) return null;
    const obj = input.object.get(key) orelse return null;
    return switch (obj) {
        .integer => |v| v,
        else => null,
    };
}

/// Extract a boolean field from JSON input.
pub fn getBool(input: std.json.Value, key: []const u8) ?bool {
    const obj = input.object.get(key) orelse return null;
    return switch (obj) {
        .bool => |v| v,
        else => null,
    };
}

// ──── Behavioral function helpers for existing tools ────

/// Bash tool: never concurrency-safe.
fn bashIsConcurrencySafe(_: std.json.Value) bool {
    return false;
}

/// Bash tool: destructive if command contains rm, dd, mkfs, etc.
/// The list intentionally over-matches (curl/wget are code-execution
/// vectors when piped to a shell) — destructive only tightens permissions.
fn bashIsDestructive(input: std.json.Value) bool {
    const cmd = getStringField(input, "command") orelse return false; // malformed input is rejected by validateInput, not here
    const dangerous_cmds = [_][]const u8{
        "rm ",        "rm\t",    "rmdir",             "dd ",            "mkfs.",    "format",
        "> /dev/",    "chmod 000", "chown root",     "chmod -R",       "chown -R",
        // P28: chained/piped destructive forms the old 8-substring list missed
        "git reset --hard", "git push --force", "git clean", "shred",
        "truncate -s", "curl ", "wget ", "sudo ", "shutdown", "reboot",
        "kill -9", "pkill ", "find -delete", "xargs rm", "srm ",
    };
    for (dangerous_cmds) |dc| {
        if (std.mem.indexOf(u8, cmd, dc) != null) return true;
    }
    return false;
}

/// FileRead tool: always concurrency-safe.
fn fileReadIsConcurrencySafe(_: std.json.Value) bool {
    return true;
}

/// FileWrite tool: never concurrency-safe.
fn fileWriteIsConcurrencySafe(_: std.json.Value) bool {
    return false;
}

/// Glob/Grep/Search tools: always concurrency-safe.
fn alwaysConcurrencySafe(_: std.json.Value) bool {
    return true;
}

/// FileEdit tool: never concurrency-safe.
fn neverConcurrencySafe(_: std.json.Value) bool {
    return false;
}

// ──── Built-in tool definitions ────

pub const bash_tool: ToolDefinition = .{
    .name = "Bash",
    .description = "Execute a shell command and return its output",
    .input_schema =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The command to execute"},"timeout":{"type":"integer","description":"Timeout in seconds"}},"required":["command"]}
    ,
    .execute_fn = @import("bash.zig").execute,
    .is_read_only = false,
    .is_destructive = true,
    .is_concurrency_safe_fn = bashIsConcurrencySafe,
    .is_destructive_fn = bashIsDestructive,
    .aliases = &.{ "Shell", "sh" },
    .search_hint = "shell command execute run",
    .max_result_size = 200_000,
};

pub const file_read_tool: ToolDefinition = .{
    .name = "FileRead",
    .description = "Read the contents of a file",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute file path"},"offset":{"type":"integer","description":"Starting line number (0-based)"},"limit":{"type":"integer","description":"Maximum number of lines to read"}},"required":["path"]}
    ,
    .execute_fn = @import("file_read.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = fileReadIsConcurrencySafe,
    .aliases = &.{ "Read", "cat" },
    .search_hint = "read file contents cat",
};

pub const file_write_tool: ToolDefinition = .{
    .name = "FileWrite",
    .description = "Write content to a file, creating it if needed",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute file path"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}
    ,
    .execute_fn = @import("file_write.zig").execute,
    .is_read_only = false,
    .is_destructive = false,
    .is_concurrency_safe_fn = fileWriteIsConcurrencySafe,
    .aliases = &.{"Write"},
    .search_hint = "write file create save",
};

pub const glob_tool: ToolDefinition = .{
    .name = "Glob",
    .description = "Find files matching a pattern in a directory tree",
    .input_schema =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. *.zig, src/**/*.ts)"},"path":{"type":"string","description":"Directory to search in"}},"required":["pattern"]}
    ,
    .execute_fn = @import("glob.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .aliases = &.{"find"},
    .search_hint = "find search files pattern glob",
};

pub const grep_tool: ToolDefinition = .{
    .name = "Grep",
    .description = "Search file contents for a pattern",
    .input_schema =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"path":{"type":"string","description":"Directory or file to search in"},"maxResults":{"type":"integer","description":"Maximum number of results"}},"required":["pattern"]}
    ,
    .execute_fn = @import("grep.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .aliases = &.{"search"},
    .search_hint = "search content pattern regex find text",
};

pub const file_edit_tool: ToolDefinition = .{
    .name = "FileEdit",
    .description = "Find and replace strings in a file",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute file path"},"old_string":{"type":"string","description":"String to find"},"new_string":{"type":"string","description":"String to replace with"},"replaceAll":{"type":"boolean","description":"Replace all occurrences"}},"required":["path","old_string","new_string"]}
    ,
    .execute_fn = @import("file_edit.zig").execute,
    .is_read_only = false,
    .is_destructive = false,
    .is_concurrency_safe_fn = neverConcurrencySafe,
    .aliases = &.{ "Edit", "sed" },
    .search_hint = "edit file replace modify",
};

pub const web_search_tool: ToolDefinition = .{
    .name = "WebSearch",
    .description = "Search the web for information",
    .input_schema =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"maxResults":{"type":"integer","description":"Maximum number of results"}},"required":["query"]}
    ,
    .execute_fn = @import("web_search.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .search_hint = "search web internet google",
};

pub const task_create_tool: ToolDefinition = .{
    .name = "TaskCreate",
    .description = "Create a new task for tracking",
    .input_schema =
    \\{"type":"object","properties":{"subject":{"type":"string","description":"Task title"},"description":{"type":"string","description":"Task description"}},"required":["subject"]}
    ,
    .execute_fn = @import("task_create.zig").execute,
    .is_read_only = false,
    .is_destructive = false,
    .search_hint = "create task todo",
};

pub const task_list_tool: ToolDefinition = .{
    .name = "TaskList",
    .description = "List all tasks",
    .input_schema =
    \\{"type":"object","properties":{}}
    ,
    .execute_fn = @import("task_list.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .search_hint = "list tasks todo",
};

pub const task_update_tool: ToolDefinition = .{
    .name = "TaskUpdate",
    .description = "Update task status",
    .input_schema =
    \\{"type":"object","properties":{"taskId":{"type":"string","description":"Task ID"},"status":{"type":"string","description":"New status"}},"required":["taskId"]}
    ,
    .execute_fn = @import("task_update.zig").execute,
    .is_read_only = false,
    .is_destructive = false,
    .search_hint = "update task status",
};

pub const ask_user_tool: ToolDefinition = .{
    .name = "AskUserQuestion",
    .description = "Ask the user a question during execution",
    .input_schema =
    \\{"type":"object","properties":{"question":{"type":"string","description":"Question to ask"}},"required":["question"]}
    ,
    .execute_fn = @import("ask_user.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = neverConcurrencySafe,
    .search_hint = "ask question user prompt",
};

pub const tool_search_tool: ToolDefinition = .{
    .name = "ToolSearch",
    .description = "Search available tools by keyword",
    .input_schema =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Search query for tools"}},"required":["query"]}
    ,
    .execute_fn = @import("tool_search.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .search_hint = "search find tool discover",
};

/// The default tool set — add more tools here to register them at compile time.
pub const default_tools = &[_]ToolDefinition{
    bash_tool,
    file_read_tool,
    file_write_tool,

    // File operations
    glob_tool,
    grep_tool,
    file_edit_tool,

    // Web
    web_search_tool,

    // Task management
    task_create_tool,
    task_list_tool,
    task_update_tool,

    // Interaction
    ask_user_tool,

    // Discovery
    tool_search_tool,
};

/// Convenience type for the default registry.
pub const DefaultRegistry = ToolRegistry(default_tools);

/// Provider-agnostic specs for every default tool — pass as
/// CompleteOptions.tools so the model sees the tool declarations.
pub const default_tool_specs = blk: {
    var specs: [default_tools.len]llm.ToolSpec = undefined;
    for (default_tools, 0..) |tool, i| {
        specs[i] = .{
            .name = tool.name,
            .description = tool.description,
            .input_schema = tool.input_schema,
        };
    }
    break :blk specs;
};

// ──── Tests ────

test "ToolRegistry has and getByName" {
    comptime {
        try std.testing.expect(DefaultRegistry.has("Bash"));
        try std.testing.expect(DefaultRegistry.has("FileRead"));
        try std.testing.expect(DefaultRegistry.has("FileWrite"));
        try std.testing.expect(!DefaultRegistry.has("NonExistent"));
    }
}

test "ToolRegistry count" {
    try std.testing.expectEqual(@as(usize, 12), DefaultRegistry.count());
}

test "ToolDefinition matchesName" {
    try std.testing.expect(bash_tool.matchesName("Bash"));
    try std.testing.expect(bash_tool.matchesName("Shell"));
    try std.testing.expect(bash_tool.matchesName("sh"));
    try std.testing.expect(!bash_tool.matchesName("Read"));
}

test "ToolDefinition concurrency safety" {
    try std.testing.expect(!bash_tool.isConcurrencySafe(.null));
    try std.testing.expect(file_read_tool.isConcurrencySafe(.null));
    try std.testing.expect(!file_write_tool.isConcurrencySafe(.null));
}

test "ToolDefinition destructive detection" {
    const input = std.json.Value{ .object = .{} };
    try std.testing.expect(!bash_tool.isDestructive(input));
}
