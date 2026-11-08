//! 项目根锚定（docs/ziv-project-root.md，2026-11-10）：从 cwd 向上
//! （含自身）找第一个已存在的 `.ziv` 作为存储锚点——子目录会话与项目
//! 根共享记忆/会话/索引/检查点。找不到则锚在 cwd（历史行为）。
//! 启动时 init(io) 解析一次（realpath 归一，符号链接不分裂）；
//! 之后所有 `.ziv/...` 路径经 sub() 生成。

const std = @import("std");

var root_buf: [std.fs.max_path_bytes]u8 = undefined;
var root_len: usize = 0;
/// true = 锚点不是 cwd（继承了上级项目的 .ziv）——启动提示用。
pub var inherited: bool = false;

/// 解析锚点。必须在任何存储初始化之前调用（repl.run 顶部）。
pub fn rootLen() usize {
    return root_len;
}

pub fn init(io: std.Io) void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return;
    const cwd: []const u8 = cwd_buf[0..cwd_len];
    // 逐级向上：dir 本身有 .ziv → 锚定；到根都没有 → 锚在 cwd。
    var dir: []const u8 = cwd;
    while (true) {
        if (hasZiv(io, dir)) {
            const is_cwd = std.mem.eql(u8, dir, cwd);
            inherited = !is_cwd;
            @memcpy(root_buf[0..dir.len], dir);
            root_len = dir.len;
            return;
        }
        const parent = std.fs.path.dirname(dir) orelse break;
        if (parent.len >= dir.len) break; // "/" 防御
        dir = parent;
    }
    inherited = false;
    @memcpy(root_buf[0..cwd.len], cwd);
    root_len = cwd.len;
}

fn hasZiv(io: std.Io, dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.ziv", .{dir}) catch return false;
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

/// 锚点根目录（绝对路径）。init 之前调用返回 cwd 长度 0 的兜底。
pub fn rootDir() []const u8 {
    return root_buf[0..root_len];
}

/// 锚点下的子路径：sub(&buf, "memory.db") → "<root>/.ziv/memory.db"。
pub fn sub(buf: []u8, rel: []const u8) []const u8 {
    // 未 init（单测/库形态）：按迁移前语义回落 cwd 相对路径。
    if (root_len == 0) return std.fmt.bufPrint(buf, ".ziv/{s}", .{rel}) catch rel;
    return std.fmt.bufPrint(buf, "{s}/.ziv/{s}", .{ rootDir(), rel }) catch rel;
}

test "zivroot: nearest .ziv wins, cwd fallback, sub override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var io_state = std.Io.Threaded.init(a, .{});
    defer io_state.deinit();
    const io = io_state.io();

    // 建三层：proj/.ziv + proj/sub/ + proj/sub/deep/
    var tmp_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    var saved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const saved_len0 = std.process.currentPath(io, &saved_buf) catch return error.TestUnexpectedResult;
    const saved0 = try a.dupe(u8, saved_buf[0..saved_len0]);
    const base = blk: {
        const p = try std.fmt.bufPrint(&tmp_abs_buf, "/tmp/ziv_zivroot_{d}", .{@import("time.zig").nowMillis()});
        std.Io.Dir.cwd().createDirPath(io, p) catch return error.TestUnexpectedResult;
        // macOS /tmp 是符号链接——chdir 后 currentPath 拿物理路径，与
        // init() 的解析同口径（否则断言比较 /tmp vs /private/tmp 必炸）。
        try std.process.setCurrentPath(io, p);
        var phys: [std.fs.max_path_bytes]u8 = undefined;
        const plen = std.process.currentPath(io, &phys) catch return error.TestUnexpectedResult;
        const owned = try a.dupe(u8, phys[0..plen]);
        try std.process.setCurrentPath(io, saved0);
        break :blk owned;
    };
    defer {
        // 测试目录清理：sh -c 递归删（测试代码从简）。
        var argv_buf: [4][]const u8 = .{ "/bin/sh", "-c", undefined, "" };
        var cmd_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        argv_buf[2] = std.fmt.bufPrint(&cmd_buf, "rm -rf {s}", .{base}) catch "";
        if (argv_buf[2].len > 0) {
            _ = std.process.spawn(io, .{ .argv = &argv_buf }) catch {};
        }
    }
    const root = try std.fmt.allocPrint(a, "{s}/proj", .{base});
    const sub1 = try std.fmt.allocPrint(a, "{s}/sub", .{root});
    const deep = try std.fmt.allocPrint(a, "{s}/deep", .{sub1});
    for ([_][]const u8{ root, sub1, deep }) |d| {
        std.Io.Dir.cwd().createDirPath(io, d) catch {};
    }
    std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/.ziv", .{root})) catch {};

    // 场景 1：cwd=deep → 锚到 proj（继承）。
    {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const saved_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const saved = cwd_buf[0..saved_len];
        defer std.process.setCurrentPath(io, saved) catch {};
        try std.process.setCurrentPath(io, deep);
        init(io);
        try std.testing.expectEqualStrings(root, rootDir());
        try std.testing.expect(inherited);
    }
    // 场景 2：sub 自建 .ziv → 最近者胜（本地覆盖）。
    std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/.ziv", .{sub1})) catch {};
    {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const saved_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const saved = cwd_buf[0..saved_len];
        defer std.process.setCurrentPath(io, saved) catch {};
        try std.process.setCurrentPath(io, deep);
        init(io);
        try std.testing.expectEqualStrings(sub1, rootDir());
    }
    // 场景 3：无任何 .ziv（tmp 根之上）→ 锚在 cwd 本身。
    {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const saved_len = std.process.currentPath(io, &cwd_buf) catch 0;
        const saved = cwd_buf[0..saved_len];
        defer std.process.setCurrentPath(io, saved) catch {};
        try std.process.setCurrentPath(io, base);
        init(io);
        try std.testing.expectEqualStrings(base, rootDir());
        try std.testing.expect(!inherited);
    }
    // sub() 拼接形态。
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const p2 = sub(&b, "memory.db");
    try std.testing.expect(std.mem.endsWith(u8, p2, "/.ziv/memory.db"));
}
