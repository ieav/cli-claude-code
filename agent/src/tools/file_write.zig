/// FileWrite tool — writes content to a file.
const std = @import("std");
const registry = @import("registry.zig");
const treesitter = @import("../util/treesitter.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = getStringField(input, "path") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Error: 'path' field is required") catch "", .is_error = true };

    const content = getStringField(input, "content") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Error: 'content' field is required") catch "", .is_error = true };

    // Parent directories auto-create: a deep new path (src/a/b/c.zig)
    // used to fail round one and cost a `mkdir -p` Bash detour — the
    // schema promises "missing parent directories are created
    // automatically", so the implementation owes exactly that.
    // createDirPath is idempotent; a failure here still surfaces through
    // writeFile's own (more specific) error below.
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = content,
    }) catch |err| {
        const msg = alloc.print("Failed to write '{s}': {}", .{ path, err }) catch return error.OutOfMemory;
        return registry.ToolResult{ .output = msg, .is_error = true };
    };

    // 所有权纪律：output alloc-owned（history freeContentBlocks 无差别
    // free，静态串会炸）。print OOM 直接走 error 路径，不再用字面量兜底。
    const base = try alloc.print("Wrote {} bytes to {s}", .{ content.len, path });
    // ③ 里程碑 1：整文件重写与定点编辑同一套落盘后语法校验。
    if (treesitter.appendValidationWarning(alloc, path, content)) |warn| {
        defer alloc.free(warn);
        defer alloc.free(base);
        return registry.ToolResult{ .output = try std.mem.concat(alloc, u8, &.{ base, warn }) };
    }
    return registry.ToolResult{ .output = base };
}

fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = input.object.get(key) orelse return null;
    if (obj != .string) return null;
    return obj.string;
}

test "FileWrite creates deep parent directories automatically" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    // Fresh depth-3 path that does not exist anywhere.
    const util_time = @import("../util/time.zig");
    var rm_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&rm_buf, "/tmp/ziv_fw_test_{d}", .{@as(u32, @truncate(@as(u64, @bitCast(util_time.nowMillis()))))});
    var path_buf: [160]u8 = undefined;
    const deep = try std.fmt.bufPrint(&path_buf, "{s}/a/b/c/new.zig", .{root});
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(alloc);
    try obj.put(alloc, "path", .{ .string = deep });
    try obj.put(alloc, "content", .{ .string = "pub const x = 1;\n" });

    const r = try execute(alloc, .{ .object = obj }, io);
    defer alloc.free(r.output);
    try std.testing.expect(!r.is_error);
    const read_back = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, deep, alloc, .limited(4096)) catch "MISSING";
    defer if (std.mem.eql(u8, read_back, "MISSING")) {} else alloc.free(read_back);
    try std.testing.expect(std.mem.indexOf(u8, read_back, "pub const x") != null);

    // Cleanup the tree (the test owns it).
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
}
