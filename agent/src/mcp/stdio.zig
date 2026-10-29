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
    ///
    /// Pipes are created MANUALLY (posix.pipe2, no O_NONBLOCK): Zig's
    /// `.pipe` StdIO uses nonblocking pipes, and the flag propagates into
    /// the child's fds — node/libuv then loses readable events for any
    /// data written AFTER the child attached its stdin stream (verified:
    /// immediate-write handshakes work, delayed writes wedge forever,
    /// python children are unaffected). Blocking pipes restore the POSIX
    /// contract for every child.
    pub fn spawn(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) anyerror!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .child = undefined,
            .stdin_file = undefined,
            .stdout_file = undefined,
        };
        const in_pipe = std.Io.Threaded.pipe2(.{}) catch return error.PipeUnavailable;
        const out_pipe = std.Io.Threaded.pipe2(.{}) catch {
            blockingFile(in_pipe[0]).close(io);
            blockingFile(in_pipe[1]).close(io);
            return error.PipeUnavailable;
        };

        self.env_map = buildEnvironMap(allocator) catch null;
        self.child = std.process.spawn(io, .{
            .exe = .detect,
            .argv = argv,
            .stdin = .{ .file = .{ .handle = in_pipe[0], .flags = .{ .nonblocking = false } } },
            .stdout = .{ .file = .{ .handle = out_pipe[1], .flags = .{ .nonblocking = false } } },
            .stderr = .ignore,
            .environ_map = self.env_map,
        }) catch |err| {
            blockingFile(in_pipe[0]).close(io);
            blockingFile(in_pipe[1]).close(io);
            blockingFile(out_pipe[0]).close(io);
            blockingFile(out_pipe[1]).close(io);
            if (self.env_map) |m| {
                m.deinit();
                allocator.destroy(m);
            }
            return err;
        };
        // The child owns its ends now; the parent keeps the others.
        blockingFile(in_pipe[0]).close(io);
        blockingFile(out_pipe[1]).close(io);
        self.stdin_file = .{ .handle = in_pipe[1], .flags = .{ .nonblocking = false } };
        self.stdout_file = .{ .handle = out_pipe[0], .flags = .{ .nonblocking = false } };
        return self;
    }

    /// Async-signal-safe kill used by the handshake watchdog: a SIGKILL
    /// unblocks any read parked on the stdout pipe (EOF after reaping).
    pub fn killPid(self: *Self) void {
        if (self.child.id) |pid| {
            _ = std.c.kill(pid, .KILL);
        }
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

    /// Read messages until the response for `id` arrives, skipping server
    /// notifications (the spec allows them at any moment) and stale replies
    /// to abandoned requests. This is the contract sendRequest documents:
    /// reading positionally desynchronizes replies the moment a server
    /// emits one notification between two calls. Null on EOF.
    pub fn readReply(self: *Self, io: std.Io, arena: std.mem.Allocator, id: i64) anyerror!?jsonrpc.Incoming {
        var skipped: usize = 0;
        while (skipped < 64) : (skipped += 1) {
            const msg = (try self.readMessage(io, arena)) orelse return null;
            if (msg.id) |mid| {
                if (mid == id) return msg;
            }
            // Notification or stale response — drop it and keep reading.
        }
        return error.NotificationFlood; // a server that never answers: stop, don't spin
    }

    /// Close stdin (server sees EOF and exits), then force-kill if still
    /// alive. Idempotent; frees the transport.
    pub fn close(self: *Self, io: std.Io) void {
        self.pending.deinit(self.allocator);
        if (self.env_map) |m| {
            m.deinit();
            self.allocator.destroy(m);
        }
        // Closing our write end signals EOF to a well-behaved server.
        self.stdin_file.close(io);
        if (self.child.id != null) {
            self.child.kill(io);
        }
        self.stdout_file.close(io);
        self.allocator.destroy(self);
    }
};

fn blockingFile(fd: std.posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

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
