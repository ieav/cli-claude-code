/// Basic REPL for Zage — reads user input, dispatches commands and queries.
/// Adapted for Zig 0.16 I/O API.

const std = @import("std");
const tools_mod = @import("tools/mod.zig");
const allocator = std.heap.smp_allocator;

pub fn run(io: std.Io, stdin_file: std.Io.File, stdout_file: std.Io.File) !void {
    // Writer setup
    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(stdout_file, io, &write_buf);
    const w = &file_writer.interface;

    // Reader setup
    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(stdin_file, io, &read_buf);
    const r = &file_reader.interface;

    try std.Io.Writer.writeAll(w, "Type your message (or /quit to exit):\n\n");
    try std.Io.File.Writer.flush(&file_writer);

    var message_count: usize = 0;

    while (true) {
        // Prompt
        try std.Io.Writer.writeAll(w, "ziv> ");
        try std.Io.File.Writer.flush(&file_writer);

        // Read line
        var line_buf: [4096]u8 = undefined;
        var line_writer = std.Io.Writer.fixed(&line_buf);
        const lw = &line_writer;

        const n = std.Io.Reader.streamDelimiter(r, lw, '\n') catch |err| {
            if (err == error.EndOfStream or err == error.ReadFailed) {
                try std.Io.Writer.writeAll(w, "\nGoodbye!\n");
                try std.Io.File.Writer.flush(&file_writer);
                return;
            }
            std.debug.print("Error reading input: {}\n", .{err});
            return;
        };

        if (n == 0) {
            try std.Io.Writer.writeAll(w, "\nGoodbye!\n");
            try std.Io.File.Writer.flush(&file_writer);
            return;
        }

        const input = std.mem.trim(u8, line_buf[0..n], " \t\r\n");
        if (input.len == 0) continue;

        // Meta commands
        if (std.mem.startsWith(u8, input, "/")) {
            if (std.mem.eql(u8, input, "/quit") or std.mem.eql(u8, input, "/q") or std.mem.eql(u8, input, "/exit")) {
                try std.Io.Writer.writeAll(w, "Goodbye!\n");
                try std.Io.File.Writer.flush(&file_writer);
                break;
            } else if (std.mem.eql(u8, input, "/help") or std.mem.eql(u8, input, "/h")) {
                try printHelp(w);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/tools")) {
                try std.Io.Writer.writeAll(w, "Registered tools:\n");
                inline for (tools_mod.default_tools) |tool| {
                    try std.Io.Writer.print(w, "  {s} - {s} [{s}]\n", .{
                        tool.name,
                        tool.description,
                        if (tool.is_read_only) "read" else "write",
                    });
                }
                try std.Io.Writer.writeAll(w, "\n");
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.startsWith(u8, input, "/run ")) {
                // Direct tool execution: /run Bash {"command":"ls"}
                const rest = input[5..];
                const space_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse {
                    try std.Io.Writer.writeAll(w, "Usage: /run <ToolName> <json-input>\n\n");
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };
                const tool_name = rest[0..space_idx];
                const json_str = rest[space_idx + 1 ..];

                const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, json_str, .{}) catch {
                    try std.Io.Writer.writeAll(w, "Invalid JSON input\n\n");
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };

                try std.Io.Writer.print(w, "  Running {s}...\n", .{tool_name});
                try std.Io.File.Writer.flush(&file_writer);

                const result = tools_mod.DefaultRegistry.execute(tool_name, allocator, parsed, io) catch |err| {
                    try std.Io.Writer.print(w, "  Tool error: {}\n\n", .{err});
                    try std.Io.File.Writer.flush(&file_writer);
                    continue;
                };

                if (result.is_error) {
                    try std.Io.Writer.print(w, "  ERROR: {s}\n\n", .{result.output});
                } else {
                    try std.Io.Writer.print(w, "  {s}\n\n", .{result.output});
                }
                allocator.free(result.output);
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/stats")) {
                try std.Io.Writer.print(w, "Messages sent: {d}\n\n", .{message_count});
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else if (std.mem.eql(u8, input, "/version")) {
                try std.Io.Writer.writeAll(w, "Ziv v0.1.0 (Zig 0.16.0)\n\n");
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            } else {
                try std.Io.Writer.print(w, "Unknown command: {s}\nType /help for available commands.\n\n", .{input});
                try std.Io.File.Writer.flush(&file_writer);
                continue;
            }
        }

        // Process message
        message_count += 1;
        try std.Io.Writer.print(w, "\n  [Processing: \"{s}\"]\n\n", .{input});
        try std.Io.File.Writer.flush(&file_writer);

        // TODO: Connect to LLM provider and stream response
        try std.Io.Writer.writeAll(w, "  Agent: I received your message. LLM integration coming next.\n\n");
        try std.Io.File.Writer.flush(&file_writer);
    }
}

fn printHelp(w: *std.Io.Writer) !void {
    try std.Io.Writer.writeAll(w,
        \\Available commands:
        \\  /help, /h     Show this help
        \\  /quit, /q     Exit zage
        \\  /version      Show version
        \\  /stats        Show session statistics
        \\  /tools        List registered tools
        \\  /run <tool> <json>  Execute a tool directly
        \\
        \\Example:
        \\  /run Bash {"command":"ls -la"}
        \\  /run FileRead {"path":"/tmp/test.txt"}
        \\
        \\Mathematical constants:
        \\  pi  = 3.14159...  Circular information coverage
        \\  e   = 2.71828...  Natural growth limits
        \\  phi = 0.61803...  Knowledge condensation ratio
        \\
    );
}
