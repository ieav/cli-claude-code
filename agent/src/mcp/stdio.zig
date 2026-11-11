/// stdio transport for MCP servers: spawns the server process and speaks
/// newline-delimited JSON-RPC over its stdin/stdout pipes.
const std = @import("std");
const builtin = @import("builtin");
const wincompat = @import("../util/wincompat.zig");
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
        if (builtin.os.tag == .windows) {
            return error.StdioUnsupported; // M3: CreatePipe lands here
        } else {
            return spawnPosix(allocator, io, argv);
        }
    }

    fn spawnPosix(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) anyerror!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .child = undefined,
            .stdin_file = undefined,
            .stdout_file = undefined,
        };
        const in_pipe = wincompat.pipeBlocking() catch return error.PipeUnavailable;
        const out_pipe = wincompat.pipeBlocking() catch {
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
            // Own process group (same discipline as the Bash tool): npx
            // spawns the real server as a GRANDCHILD — killing npx's pid
            // alone leaves the grandchild holding the stdout pipe, so the
            // handshake-read never sees EOF and connect wedges forever
            // (reproduced live 2026-11-10). kill(-pgid) takes the tree.
            .pgid = 0,
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
            // Process GROUP kill (spawn sets pgid=0 → group id = child pid):
            // a single-pid SIGKILL lets deep-spawned grandchildren (npx →
            // node) survive holding the pipe write end — EOF never arrives.
            wincompat.killGroup(pid);
            wincompat.killOne(pid); // direct child, in case setpgid raced
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
            // Pull more bytes from the pipe. Consume EVERYTHING peeked:
            // the reader (and its buffer) is stack-local per iteration —
            // tossing only part of the peek discarded the remainder with
            // it, so any single reply larger than the leftover window
            // (tools/list easily exceeds 4 KiB) never saw its trailing
            // bytes again and the next peek BLOCKED on fresh fd data until
            // the watchdog killed the group (lived as "npx stdio 握手不
            // 兼容" — root cause 2026-11-10).
            var fr = self.stdout_file.reader(io, &self.stdout_buf);
            const chunk = fr.interface.peekGreedy(1) catch return null; // EOF / pipe closed
            if (chunk.len == 0) return null;
            try self.pending.appendSlice(self.allocator, chunk);
            fr.interface.toss(chunk.len);
            // A hostile/buggy server streaming an endless line must not
            // grow `pending` without bound.
            if (self.pending.items.len > 4 * 1024 * 1024) return error.LineTooLong;
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
        // Group kill first (deep-spawned grandchildren hold the pipes —
        // see spawn's pgid note), then reap the direct child via std.
        if (self.child.id) |pid| {
            wincompat.killGroup(pid);
        }
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
