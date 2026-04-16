/// Comptime tool registry — tools are registered at compile time via a generic type.
/// Produces type-safe execute() and JSON schema generation with zero runtime overhead.

const std = @import("std");

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

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8, // JSON schema string (comptime-known)
    execute_fn: *const fn (std.mem.Allocator, std.json.Value, std.Io) anyerror!ToolResult,
    is_read_only: bool = true,
    is_destructive: bool = false,
};

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
        /// Caller owns the returned slice.
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

        /// Check if a tool name is registered.
        pub fn has(name: []const u8) bool {
            inline for (tools) |tool| {
                if (std.mem.eql(u8, tool.name, name)) return true;
            }
            return false;
        }
    };
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
};

/// The default tool set — add more tools here to register them at compile time.
pub const default_tools = &[_]ToolDefinition{
    bash_tool,
    file_read_tool,
    file_write_tool,
};

/// Convenience type for the default registry.
pub const DefaultRegistry = ToolRegistry(default_tools);

test "ToolRegistry has and getByName" {
    comptime {
        try std.testing.expect(DefaultRegistry.has("Bash"));
        try std.testing.expect(DefaultRegistry.has("FileRead"));
        try std.testing.expect(DefaultRegistry.has("FileWrite"));
        try std.testing.expect(!DefaultRegistry.has("NonExistent"));
    }
}

test "ToolRegistry count" {
    try std.testing.expectEqual(@as(usize, 3), DefaultRegistry.count());
}
