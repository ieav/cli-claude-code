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
    /// The tool stopped BY DESIGN — timeout kill, user cancel, declined
    /// question. Still surfaced to the model (is_error semantics hold),
    /// but excluded from the reflection window's error-rate signal: a
    /// debugging marathon that deliberately kills hung commands must not
    /// be diagnosed as "unstable environment" (2026-11-06).
    expected_stop: bool = false,
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
    /// Current model name — scopes the auto-mode classifier's verdict cache
    /// so switching models re-judges instead of replaying the old model's
    /// decisions.
    model_name: []const u8 = "",
};

// ──── Enhanced ToolDefinition ────

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    execute_fn: *const fn (std.mem.Allocator, std.json.Value, std.Io) anyerror!ToolResult,
    /// Context-carrying executor (dynamic tools, e.g. MCP bridge): when
    /// set, execute() dispatches here with `execute_ctx`.
    execute_ctx_fn: ?*const fn (?*anyopaque, std.mem.Allocator, std.json.Value, std.Io) anyerror!ToolResult = null,
    execute_ctx: ?*anyopaque = null,
    is_read_only: bool = true,
    is_destructive: bool = false,
    /// 复审 🔴1（2026-11-19）：交互工具（AskUserQuestion / plan_approve）
    /// 的 execute 会在工具体里 COOKED 读 stdin。REPL 的工具波次默认跑在
    /// worker 线程（UI 循环留在主线程 pollInput）——交互批次必须凭本
    /// 标志被识别为同步执行，否则两个线程抢同一个 stdin Reader：首键
    /// 被 editorLiveKey 吃掉、答案撕裂。新增交互工具时置 true。
    is_interactive: bool = false,

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

    /// Execute through whichever executor the definition carries.
    pub fn execute(self: *const ToolDefinition, allocator: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!ToolResult {
        if (self.execute_ctx_fn) |f| return f(self.execute_ctx, allocator, input, io);
        return self.execute_fn(allocator, input, io);
    }

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
    // Wrong-typed field used to hit `.string` on an inactive union field —
    // panic in Debug, UB in ReleaseFast. Degrade to null (callers report
    // "missing field") instead of crashing the tool loop.
    if (obj != .string) return null;
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

/// History-bound tool-output cap. Everything the model sees of a tool
/// result passes through here (REPL finishToolCall AND headless
/// subagents) — the cut MUST carry a marker so the model knows the output
/// continues and how to page (FileRead offset/limit) or narrow (Bash/
/// Grep). A silent cut made the model edit files it had only partially
/// seen (2026-11-15 长链路/多文件排查, fix #1/#5). Under the cap the
/// input slice is returned as-is (no copy, ownership unchanged); over it
/// a fresh allocation comes back (caller frees the original).
pub const HISTORY_OUTPUT_CAP: usize = 16 * 1024;

pub fn capToolOutputForHistory(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len <= HISTORY_OUTPUT_CAP) return raw;
    // Back off to a UTF-8 boundary — a mid-汉字 cut poisons every later
    // request with "Invalid UTF-8 middle byte" (same lesson as the old
    // finishToolCall inline logic).
    var cut: usize = HISTORY_OUTPUT_CAP;
    while (cut > 0 and (raw[cut] & 0xC0) == 0x80) cut -= 1;
    const marker = try std.fmt.allocPrint(alloc, "\n[输出已截断：显示前 {d}/{d} 字节。FileRead 请传 offset/limit 分页续读；Bash/Grep 请收窄输出范围后重试]", .{ cut, raw.len });
    defer alloc.free(marker);
    return std.mem.concat(alloc, u8, &.{ raw[0..cut], marker });
}

/// True for the write-family tool names (canonical + wire aliases) — the
/// calls whose ARGUMENTS are the edit trail (old_string/new_string,
/// content). Shared by the TUI diff preview and the fold policy (F3:
/// history keeps these inputs unfolded — the model needs its own edit
/// record when revisiting a file mid-marathon).
pub fn isFileModifyingToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "FileWrite") or
        std.mem.eql(u8, name, "FileEdit") or
        std.mem.eql(u8, name, "Write") or
        std.mem.eql(u8, name, "Edit");
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
        "rm ",              "rm\t",      "rmdir",      "dd ",         "mkfs.",    "format",
        "> /dev/",          "chmod 000", "chown root", "chmod -R",    "chown -R",
        // P28: chained/piped destructive forms the old 8-substring list missed
        "git reset --hard",
        "git push --force", "git clean", "shred",      "truncate -s", "curl ",    "wget ",
        "sudo ",            "shutdown",  "reboot",     "kill -9",     "pkill ",   "find -delete",
        "xargs rm",         "srm ",
    };
    for (dangerous_cmds) |dc| {
        if (std.mem.indexOf(u8, cmd, dc) != null) return true;
    }
    return false;
}

/// Bash tool: read-only ONLY when every segment of the command starts with
/// a known read-only verb and nothing redirects to a file. Fail-closed —
/// plan mode used to deny even `ls`, yet allow nothing shell-shaped.
fn bashIsReadOnly(input: std.json.Value) bool {
    const cmd = getStringField(input, "command") orelse return false;
    if (std.mem.indexOf(u8, cmd, ">") != null) return false; // redirect writes
    var rest = cmd;
    while (rest.len > 0) {
        const cut = std.mem.indexOfAny(u8, rest, ";&|\n") orelse rest.len;
        const seg = std.mem.trim(u8, rest[0..cut], " \t");
        if (seg.len == 0) return false;
        const verb_end = std.mem.indexOfScalar(u8, seg, ' ') orelse seg.len;
        const verb = seg[0..verb_end];
        const ro_verbs = [_][]const u8{
            "ls",     "cat",  "pwd", "echo",  "head", "tail", "wc",    "grep",
            "rg",     "find", "fd",  "which", "file", "stat", "du",    "df",
            "whoami", "date", "env", "print", "type", "id",   "uname",
            "git", // only if subcommand is status/log/diff/show/branch — checked below
        };
        var ok = false;
        for (ro_verbs) |v| {
            if (std.mem.eql(u8, verb, v)) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
        if (std.mem.eql(u8, verb, "git")) {
            // git write subcommands are not read-only
            const git_write_subs = [_][]const u8{ "push", "pull", "commit", "reset", "checkout", "merge", "rebase", "clean", "add", "rm", "mv", "stash" };
            const sub_end = std.mem.indexOfScalarPos(u8, seg, verb_end + 1, ' ') orelse seg.len;
            const sub = seg[verb_end + 1 .. @min(sub_end, seg.len)];
            for (git_write_subs) |gws| {
                if (std.mem.eql(u8, sub, gws)) return false;
            }
        }
        var i = cut;
        while (i < rest.len) : (i += 1) {
            if (rest[i] != '&' and rest[i] != ';' and rest[i] != '|' and rest[i] != '\n') break;
        }
        rest = rest[i..];
    }
    return true;
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
    .description = "Execute a shell command and return its output. To wait for a long process or poll, use run_in_background and short checks instead of idling — bare foreground sleeps over 20s are rejected",
    .input_schema =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The command to execute"},"timeout":{"type":"integer","description":"Timeout in seconds (default 30, max 300; 0 = unlimited; ignored when run_in_background)"},"run_in_background":{"type":"boolean","description":"Run detached and return immediately with a task id (watch/dev-server/long builds). View or stop via /tasks; output lands in .ziv/tasks/<id>.log"},"working_directory":{"type":"string","description":"Working directory for the command (default: current)"}},"required":["command"]}
    ,
    .execute_fn = @import("bash.zig").execute,
    .is_read_only = false,
    .is_destructive = true,
    .is_concurrency_safe_fn = bashIsConcurrencySafe,
    .is_read_only_fn = bashIsReadOnly,
    .is_destructive_fn = bashIsDestructive,
    .aliases = &.{ "Shell", "sh" },
    .search_hint = "shell command execute run",
    .max_result_size = 200_000,
};

pub const file_read_tool: ToolDefinition = .{
    .name = "FileRead",
    .description = "Read a file with 1-based line numbers. Whole-file reads cap at 400 lines / 15 KiB — the tail marker names the file's true line count and the next offset; page large files with offset (starting line) + limit (line count).",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"offset":{"type":"integer","description":"Starting line number, 1-based inclusive (default 1 = whole file from the top)"},"limit":{"type":"integer","description":"Maximum number of lines to return (use with offset for large files)"}},"required":["path"]}
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
    .description = "Write content to a file (full overwrite). The file is created if missing, and missing parent directories are created automatically — no mkdir needed.",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"content":{"type":"string","description":"Full file content to write"}},"required":["path","content"]}
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
    .description = "Find files matching a pattern in a directory tree (build/vendor dirs pruned)",
    .input_schema =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. *.zig, src/**/*.ts)"},"path":{"type":"string","description":"Directory to search in"},"maxDepth":{"type":"integer","description":"Maximum directory depth (default 10)"}},"required":["pattern"]}
    ,
    .execute_fn = @import("glob.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .aliases = &.{"find"},
    .search_hint = "find search files pattern glob",
};

/// DirTree: structural overview ("what does this tree look like") —
/// Glob's complement for the first contact with an unfamiliar project.
/// Shares Glob's prune list; stable dirs-first ordering.
pub const dir_tree_tool: ToolDefinition = .{
    .name = "DirTree",
    .description = "Show a directory's structure as an indented tree (dirs first, vendored trees pruned). Use for project overviews; use Glob to find files matching a pattern",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to overview (default: cwd)"},"maxDepth":{"type":"integer","description":"Maximum depth (default 3 — an overview, not an inventory)"},"maxEntries":{"type":"integer","description":"Entry cap (default 400, max 2000); truncation is visible"}},"required":[]}
    ,
    .execute_fn = @import("dir_tree.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .aliases = &.{ "Tree", "tree" },
    .search_hint = "directory tree structure overview project layout",
    .max_result_size = 100_000,
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
    .description = "Replace an exact string in a file. Read the file first. old_string must match the file BYTE-FOR-BYTE (indentation, blank lines, trailing spaces) and must be UNIQUE in the file — include 2-5 surrounding context lines around the change to make it unique. If it is not unique, add more context or set replaceAll.",
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"old_string":{"type":"string","description":"Exact text to find — copy it verbatim from the file, including surrounding context lines so it is unique"},"new_string":{"type":"string","description":"Replacement text (the context lines stay, change only what should change)"},"replaceAll":{"type":"boolean","description":"Replace every occurrence instead of requiring uniqueness"}},"required":["path","old_string","new_string"]}
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

/// P5 M2: fetch a URL as readable Markdown（搜索的下一步——搜到链接后
/// 读内容）。与 WebSearch 同权限级（is_read_only，ziv 既有口径）。
pub const web_fetch_tool: ToolDefinition = .{
    .name = "WebFetch",
    .description = "Fetch a URL and return its content converted to Markdown",
    .input_schema =
    \\{"type":"object","properties":{"url":{"type":"string","description":"The http(s) URL to fetch"}},"required":["url"]}
    ,
    .execute_fn = @import("web_fetch.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .aliases = &.{"Fetch"},
    .search_hint = "fetch url webpage http read page",
    .max_result_size = 40_000,
};

pub const task_create_tool: ToolDefinition = .{
    .name = "TaskCreate",
    .description = "Create a new task for tracking",
    .input_schema =
    \\{"type":"object","properties":{"subject":{"type":"string","description":"Task title"},"description":{"type":"string","description":"Task description"},"priority":{"type":"integer","description":"Priority 1-5, 5 highest (default 3)"}},"required":["subject"]}
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

/// TaskGet：按 id 查单条完整详情（列表截断描述，Get 给全文）。
pub const task_get_tool: ToolDefinition = .{
    .name = "TaskGet",
    .description = "Get one task's full details by id (TaskList truncates descriptions)",
    .input_schema =
    \\{"type":"object","properties":{"id":{"type":"integer","description":"Task id from TaskList"}},"required":["id"]}
    ,
    .execute_fn = @import("task_get.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .search_hint = "task detail get by id",
};

/// BgTask：模型对后台任务的自管理（对称性：能启动就该能查看/停止）。
/// status/output 纯读；stop 杀进程组（default 模式走审批）。
pub const bg_task_tool: ToolDefinition = .{
    .name = "BgTask",
    .description = "Manage background tasks started with Bash run_in_background: status (all or one by id), output tail, stop (kills the process group)",
    .input_schema =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["status","output","stop"],"description":"What to do"},"id":{"type":"integer","description":"Background task id (required for output/stop)"}},"required":["action"]}
    ,
    .execute_fn = @import("bg_task.zig").execute,
    .is_read_only = true,
    .is_read_only_fn = @import("bg_task.zig").bgTaskIsReadOnly,
    .is_destructive = false,
    .is_concurrency_safe_fn = alwaysConcurrencySafe,
    .search_hint = "background task status stop kill output",
};

pub const ask_user_tool: ToolDefinition = .{
    .name = "AskUserQuestion",
    .description = "Ask the user a question during execution. With `options` (2-8 short choices) the user picks a number instead of typing a free answer — prefer options for A-or-B style decisions",
    .input_schema =
    \\{"type":"object","properties":{"question":{"type":"string","description":"Question to ask"},"options":{"type":"array","items":{"type":"string"},"description":"Optional 2-8 short choices; the user answers by number (omit for free-text)"}},"required":["question"]}
    ,
    .execute_fn = @import("ask_user.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    .is_interactive = true,
    .is_concurrency_safe_fn = neverConcurrencySafe,
    .search_hint = "ask question user prompt choose option",
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

/// T9.1 plan 出环门（2026-11-19）。is_read_only=true 是刻意的：它不碰
/// 文件，且若标成写操作，plan 模式的写拦截（auth_mode Step .plan =>
/// deny）会把自己人也拦在外面——出环门必须在 plan 模式里可用。
pub const plan_approve_tool: ToolDefinition = .{
    .name = "plan_approve",
    .description = "Present your plan to the user for approval while in plan mode. Call it once the plan in the summary is complete. On approval the session leaves plan mode and you may execute immediately; other answers come back as instructions (refine or stop). Usable only in plan mode",
    .input_schema =
    \\{"type":"object","properties":{"summary":{"type":"string","description":"The plan to approve: goal, steps, files to touch"}},"required":["summary"]}
    ,
    .execute_fn = @import("plan_approve.zig").execute,
    .is_read_only = true,
    .is_destructive = false,
    // 🔴1：呈批读 stdin（编号选择/Esc）——交互工具，必须同步执行。
    .is_interactive = true,
    .is_concurrency_safe_fn = neverConcurrencySafe,
    .search_hint = "plan approve exit approval gate",
};

/// The default tool set — add more tools here to register them at compile time.
pub const default_tools = &[_]ToolDefinition{
    bash_tool,
    file_read_tool,
    file_write_tool,

    // File operations
    glob_tool,
    grep_tool,
    dir_tree_tool,
    file_edit_tool,

    // Web
    web_search_tool,
    web_fetch_tool,

    // Task management
    task_create_tool,
    task_list_tool,
    task_update_tool,
    task_get_tool,

    // Background task self-management (Bash run_in_background 闭环)
    bg_task_tool,

    // Interaction
    ask_user_tool,

    // Plan exit gate（T9.1：plan 模式出环）
    plan_approve_tool,

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
    // +2 于 2026-11-09：TaskGet（任务详情）+ BgTask（后台任务自管理）。
    // +1 于 2026-11-19：plan_approve（T9.1 plan 出环门）。
    try std.testing.expectEqual(@as(usize, 17), DefaultRegistry.count());
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

test "getStringField degrades wrong-typed field to null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        "{\"path\": 123, \"name\": \"ok\"}", .{});
    // Wrong-typed field: null, not a union-field panic.
    try std.testing.expect(getStringField(parsed, "path") == null);
    try std.testing.expectEqualStrings("ok", getStringField(parsed, "name").?);
    // Missing key / non-object input.
    try std.testing.expect(getStringField(parsed, "nope") == null);
    try std.testing.expect(getStringField(std.json.Value{ .integer = 1 }, "path") == null);
}

// L4 护栏（2026-11-09 崩溃事故）：ToolResult.output 进 history 后由
// freeContentBlocks 无差别 free——静态字面量 = free 只读段 = 分配器
// 损坏，崩在任意后续分配（实测：utf8proc 宽度计算段错误、SIGSEGV、
// defer 不跑 → 后台进程孤儿）。本测试扫源码，新写一个字面量输出
// 直接挂 zig build test——让这类错写不出来。
test "guard: no static-literal ToolResult outputs (free-safety)" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();
    var offenders: usize = 0;
    const dirs = [_][]const u8{ "src/tools", "src/turn" };
    for (dirs) |dir_name| {
        var d = std.Io.Dir.cwd().openDir(io, dir_name, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".zig")) continue;
            var pb: [512]u8 = undefined;
            const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir_name, ent.name }) catch continue;
            const src = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, p, alloc, std.Io.Limit.limited(4 * 1024 * 1024)) catch continue;
            defer alloc.free(src);
            var lines = std.mem.splitScalar(u8, src, '\n');
            var ln: usize = 0;
            while (lines.next()) |line| : (ln += 1) {
                if (std.mem.indexOf(u8, line, ".output = \"") != null and
                    std.mem.indexOf(u8, line, "dupe") == null and
                    std.mem.indexOf(u8, line, "\"\"") == null) // 空串豁免：free() 零长 no-op
                {
                    offenders += 1;
                    std.debug.print("LITERAL {s}:{d}: {s}\n", .{ p, ln + 1, std.mem.trim(u8, line, " \t") });
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), offenders);
}

test "capToolOutputForHistory: under cap passes through, over cap cuts with marker" {
    const alloc = std.testing.allocator;
    // Under the cap: same slice back, no allocation, no marker.
    const small = "hello world";
    const same = try capToolOutputForHistory(alloc, small);
    try std.testing.expectEqual(small.ptr, same.ptr);

    // Over the cap: fresh slice, ends with the marker naming both sizes,
    // never cuts mid-UTF-8.
    const fat = try alloc.alloc(u8, HISTORY_OUTPUT_CAP + 3000);
    defer alloc.free(fat);
    @memset(fat[0 .. fat.len - 6], 'x');
    @memcpy(fat[fat.len - 6 ..], "字尾"); // 6-byte CJK tail: the cut must land on a boundary
    const capped = try capToolOutputForHistory(alloc, fat);
    defer alloc.free(capped);
    try std.testing.expect(capped.len < fat.len + 200);
    try std.testing.expect(std.mem.indexOf(u8, capped, "输出已截断") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "offset/limit") != null);
    // Size report: shown bytes are the pre-marker body length (the UTF-8-
    // backed-off cut), which is also where the marker starts.
    const marker_start = std.mem.lastIndexOf(u8, capped, "\n[输出已截断").?;
    const shown_fmt = try std.fmt.allocPrint(alloc, "显示前 {d}/{d} 字节", .{ marker_start, fat.len });
    defer alloc.free(shown_fmt);
    try std.testing.expect(std.mem.indexOf(u8, capped, shown_fmt) != null);
    // Valid UTF-8 up to the marker start (the cut body must not end mid-rune).
    const body = capped[0..marker_start];
    try std.testing.expect(std.unicode.utf8ValidateSlice(body));
}
