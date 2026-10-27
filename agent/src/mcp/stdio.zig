/// stdio transport for MCP servers: spawns the server process and speaks
/// newline-delimited JSON-RPC over its stdin/stdout pipes.
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

pub const StdioTransport = struct {
    allocator: std.mem.Allocator,
    env_map: ?*std.process.Environ.Map = null,
    child: std.process.Child,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    stdin_buf: [4096]u8 = undefined,
    stdout_buf: [8192]u8 = undefined,
    /// Leftover bytes of a partial line (no trailing '\n' yet).
    pending: std.ArrayList(u8) = .empty,
    next_id: i64 = 1,

    const Self = @This();

    pub const SpawnError = std.process.SpawnError;

    /// Spawn `argv` (argv[0] resolved via PATH) with piped stdio.
    pub fn spawn(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) anyerror!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .child = undefined,
            .stdin_file = undefined,
            .stdout_file = undefined,
        };
        // The child must inherit the real OS environment (PATH above all):
        // Io.Threaded defaults to an empty environ, and node/npx launched via
        // shebang `env node` die with "env: node: No such file or directory".
        self.env_map = buildEnvironMap(allocator) catch null;
        self.child = try std.process.spawn(io, .{
            .exe = .detect,
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .environ_map = self.env_map,
        });
        self.stdin_file = self.child.stdin orelse return error.PipeUnavailable;
        self.stdout_file = self.child.stdout orelse return error.PipeUnavailable;
        return self;
    }

    /// Allocate a request id.
    pub fn nextId(self: *Self) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Send one JSON-RPC request; returns its id (read the reply with
    /// readMessage until the id matches).
    pub fn sendRequest(self: *Self, io: std.Io, method: []const u8, params_json: ?[]const u8) !i64 {
        const id = self.nextId();
        const line = try jsonrpc.encodeRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(line);
        try self.writeLine(io, line);
        return id;
    }

    pub fn sendNotification(self: *Self, io: std.Io, method: []const u8, params_json: ?[]const u8) !void {
        const line = try jsonrpc.encodeNotification(self.allocator, method, params_json);
        defer self.allocator.free(line);
        try self.writeLine(io, line);
    }

    fn writeLine(self: *Self, io: std.Io, line: []const u8) !void {
        var fw = self.stdin_file.writer(io, &self.stdin_buf);
        const w = &fw.interface;
        try w.writeAll(line);
        try w.writeAll("\n");
        try fw.flush();
    }

    /// Read the next complete incoming message (one JSON object per line).
    /// Returned strings are owned by `arena`. Null on EOF.
    pub fn readMessage(self: *Self, io: std.Io, arena: std.mem.Allocator) !?jsonrpc.Incoming {
        while (true) {
            // Any buffered partial line?
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
                const line = try arena.dupe(u8, self.pending.items[0..nl]);
                const keep = self.pending.items[nl + 1 ..];
                std.mem.copyForwards(u8, self.pending.items, keep);
                self.pending.shrinkRetainingCapacity(keep.len);
                if (line.len == 0) continue;
                return jsonrpc.parseIncoming(arena, line) orelse continue;
            }
            // Pull more bytes from the pipe.
            var fr = self.stdout_file.reader(io, &self.stdout_buf);
            const chunk = fr.interface.peekGreedy(1) catch return null; // EOF / pipe closed
            if (chunk.len == 0) return null;
            const n = @min(chunk.len, 4096);
            try self.pending.appendSlice(self.allocator, chunk[0..n]);
            fr.interface.toss(n);
        }
    }

    /// Close stdin (server sees EOF and exits), then force-kill if still
    /// alive. Idempotent; frees the transport.
    pub fn close(self: *Self, io: std.Io) void {
        self.pending.deinit(self.allocator);
        if (self.env_map) |m| {
            m.deinit();
            self.allocator.destroy(m);
        }
        if (self.child.id != null) {
            // Closing our write end signals EOF; a well-behaved server exits.
            if (self.child.stdin) |*f| {
                f.close(io);
                self.child.stdin = null;
            }
            self.child.kill(io);
        }
        self.allocator.destroy(self);
    }
};

/// Copy the real libc environ into a Map the spawn options accept.
/// (Io.Threaded.init(.{}) defaults to an empty environ — children spawned
/// through it would lose PATH and every other variable.)
fn buildEnvironMap(allocator: std.mem.Allocator) !*std.process.Environ.Map {
    const m = try allocator.create(std.process.Environ.Map);
    errdefer allocator.destroy(m);
    m.* = std.process.Environ.Map.init(allocator);
    errdefer m.deinit();

    var n: usize = 0;
    while (std.c.environ[n]) |_| : (n += 1) {}
    const entries = std.c.environ[0..n];
    // View wants non-optional pointers; PosixBlock.slice kept them
    // non-optional on the way in — cast the null-terminated window.
    const view: std.process.Environ.PosixBlock.View = .{
        .slice = @ptrCast(entries),
    };
    try m.putPosixBlock(view);
    return m;
}
