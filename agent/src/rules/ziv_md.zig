//! Project rules loading — the ziv.md single source of truth (2026-11-11).
//!
//! Model: ziv's rules ARE `ziv.md` (project anchor root, ziv's own turf —
//! readable AND writable by ziv). AGENTS.md / CLAUDE.md are FOREIGN files:
//! recognized READ-ONLY, used as bootstrap material when ziv.md does not
//! exist yet (their contents are stitched into a freshly generated ziv.md,
//! whole-file per source — deterministic, lossless, zero LLM calls). After
//! generation ziv.md is the only injected source; foreign files are NOT
//! silently tracked (resyncing is the explicit /agents sync).
//!
//! Layers (each with its OWN token budget, never stealing from the other):
//!   global  ~/.config/ziv/ziv.md    — hand-written personal rules, never
//!                                     auto-generated (nothing to stitch)
//!   project <anchor>/ziv.md         — generated on demand from foreign files
//!
//! All three file names match CASE-INSENSITIVELY (ziv.md/ZIV.md, agents.md,
//! claude.md) — Linux case-sensitive filesystems still find either case.
//!
//! Injection: an independent text block appended to history[0]'s system
//! content (same primitives as the plan/facts blocks — append/swap/remove
//! by slice identity); REPL only, oneshot (-p) appends to its single
//! system string instead (headless: reads, never generates).
const std = @import("std");
const zivroot = @import("../util/zivroot.zig");
const env_mod = @import("../util/env.zig");
const time_mod = @import("../util/time.zig");
const tokens_mod = @import("../util/tokens.zig");
const subagent = @import("../agent/subagent.zig");
const logger = @import("../util/log.zig");

/// Per-layer injection budget. Oversize files are cut at a UTF-8 boundary
/// with a visible tail note (which file, full size) — silent truncation
/// would look like the rules themselves saying less than they do.
pub const RULES_BUDGET_TOKENS: u32 = 4000;

/// The external-marker fence /agents sync replaces; everything OUTSIDE it
/// is the user's own writing and is never touched by sync.
pub const marker_start = "<!-- ziv:external-start -->";
pub const marker_end = "<!-- ziv:external-end -->";

/// One loaded rules layer.
pub const Layer = struct {
    /// Actual path found (owned; real case as it exists on disk).
    path: []u8,
    /// Budgeted injection text (owned; already cut).
    text: []u8,
    /// Full-file token estimate BEFORE the cut (for the truncation note).
    full_tokens: u32,
    truncated: bool,
};

pub const RulesState = struct {
    global: ?Layer = null,
    project: ?Layer = null,
    /// Set when THIS call generated a ziv.md (startup bootstrap): the
    /// caller prints one visible line — never silently write into the
    /// user's project.
    generated_path: ?[]u8 = null,
};

/// Case-insensitive single-file discovery inside `dir_path`: returns the
/// REAL entry name (owned) whose lower() equals lower(`want`). Directory
/// order is filesystem-dependent; first hit wins (two files differing only
/// in case is already pathological).
pub fn findInsensitive(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8, want: []const u8) ?[]u8 {
    var dir = (if (std.fs.path.isAbsolute(dir_path))
        std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true })
    else
        std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true })) catch return null;
    defer dir.close(io);
    var want_buf: [64]u8 = undefined;
    if (want.len > want_buf.len) return null;
    const want_l = std.ascii.lowerString(&want_buf, want);
    var it = dir.iterate();
    while (true) {
        const ent = (it.next(io) catch return null) orelse return null;
        if (ent.kind != .file) continue;
        var nb: [64]u8 = undefined;
        if (ent.name.len > nb.len) continue;
        if (std.mem.eql(u8, std.ascii.lowerString(&nb, ent.name), want_l)) {
            return alloc.dupe(u8, ent.name) catch return null;
        }
    }
}

fn joinPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch null;
}

/// Read one rules file into a budgeted Layer. Null when absent/unreadable.
fn loadLayer(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?Layer {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(512 * 1024)) catch return null;
    defer alloc.free(raw);
    const est = tokens_mod.estimateTokens(raw);
    if (est > RULES_BUDGET_TOKENS) {
        const cut = subagent.utf8TokenCut(raw, RULES_BUDGET_TOKENS);
        const text = std.fmt.allocPrint(alloc, "{s}\n\n（截断：{s} 全文约 {d} tokens，超出 {d} 预算——请精简或拆分）\n", .{ cut, path, est, RULES_BUDGET_TOKENS }) catch return null;
        return .{ .path = alloc.dupe(u8, path) catch return null, .text = text, .full_tokens = est, .truncated = true };
    }
    return .{
        .path = alloc.dupe(u8, path) catch return null,
        .text = alloc.dupe(u8, raw) catch return null,
        .full_tokens = est,
        .truncated = false,
    };
}

pub fn freeRulesState(alloc: std.mem.Allocator, s: *RulesState) void {
    if (s.global) |*l| {
        alloc.free(l.path);
        alloc.free(l.text);
    }
    if (s.project) |*l| {
        alloc.free(l.path);
        alloc.free(l.text);
    }
    if (s.generated_path) |g| alloc.free(g);
    s.* = .{};
}

/// Build the single injected block text from both layers (global first,
/// project after — the more specific source comes later in context).
pub fn buildBlockText(alloc: std.mem.Allocator, s: *const RulesState) ?[]u8 {
    if (s.global == null and s.project == null) return null;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (s.global) |g| {
        w.print("# 全局规则（~/.config/ziv/ziv.md）\n{s}\n\n", .{g.text}) catch return null;
    }
    if (s.project) |p| {
        w.print("# 项目规则（ziv.md）\n{s}\n", .{p.text}) catch return null;
    }
    return aw.toOwnedSlice() catch null;
}

/// The generation template. Foreign contents go between the markers;
/// everything after the fence is the user's own section (sync-safe).
fn generationTemplate(alloc: std.mem.Allocator, agents_md: ?[]const u8, claude_md: ?[]const u8) ?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    const dt = time_mod.localDateTime(time_mod.nowMillis());
    w.print(
        \\<!-- ziv 项目规则 —— 由 ziv 于 {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} 整合生成 -->
        \\<!-- /agents sync 只替换 ziv:external 标记区之间的内容，标记区外（你的专属规则）永不被动 -->
        \\
    , .{ dt.year, dt.month, dt.day, dt.hour, dt.minute }) catch return null;
    w.writeAll(marker_start ++ "\n") catch return null;
    if (agents_md) |c| w.print("# 来自 AGENTS.md\n{s}\n\n", .{c}) catch return null;
    if (claude_md) |c| w.print("# 来自 CLAUDE.md\n{s}\n\n", .{c}) catch return null;
    w.writeAll(marker_end ++ "\n\n") catch return null;
    w.writeAll(
        \\# ziv 专属规则（自由编辑；/agents sync 不触碰本节）
        \\- 在这里写项目级专属约定
        \\
    ) catch return null;
    return aw.toOwnedSlice() catch null;
}

/// Bootstrap generation: project ziv.md missing AND at least one foreign
/// file present → write <anchor>/ziv.md with the stitched template.
/// Returns the written path (owned) for the caller's visible notice.
/// Explicitly NOT called on the hot-reload path or from oneshot.
pub fn maybeGenerate(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    const anchor = zivroot.rootDir();
    if (findInsensitive(alloc, io, anchor, "ziv.md") != null) return null; // already there
    const agents_name = findInsensitive(alloc, io, anchor, "agents.md");
    defer if (agents_name) |n| alloc.free(n);
    const claude_name = findInsensitive(alloc, io, anchor, "claude.md");
    defer if (claude_name) |n| alloc.free(n);
    if (agents_name == null and claude_name == null) return null;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const agents_txt: ?[]const u8 = if (agents_name) |n| blk: {
        const p = joinPath(a, anchor, n) orelse break :blk null;
        break :blk std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(256 * 1024)) catch null;
    } else null;
    const claude_txt: ?[]const u8 = if (claude_name) |n| blk: {
        const p = joinPath(a, anchor, n) orelse break :blk null;
        break :blk std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(256 * 1024)) catch null;
    } else null;

    const tmpl = generationTemplate(alloc, agents_txt, claude_txt) orelse return null;
    defer alloc.free(tmpl);
    const out_path = joinPath(alloc, anchor, "ziv.md") orelse return null;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = tmpl }) catch {
        alloc.free(out_path);
        return null;
    };
    logger.info("rules: generated {s} (from {s}{s}{s})", .{
        out_path,
        if (agents_name != null) "AGENTS.md" else "",
        if (agents_name != null and claude_name != null) " + " else "",
        if (claude_name != null) "CLAUDE.md" else "",
    });
    return out_path;
}

/// Startup entry: (maybe) generate, then load both layers.
pub fn loadStartup(alloc: std.mem.Allocator, io: std.Io, generate: bool) RulesState {
    var s = RulesState{};
    if (generate) {
        s.generated_path = maybeGenerate(alloc, io);
    }
    // Global layer: hand-written only; absence is normal, no notice.
    if (env_mod.homeDir()) |home| {
        var gb: [std.fs.max_path_bytes]u8 = undefined;
        const gdir = std.fmt.bufPrint(&gb, "{s}/.config/ziv", .{home}) catch "";
        if (gdir.len > 0) {
            if (findInsensitive(alloc, io, gdir, "ziv.md")) |name| {
                defer alloc.free(name);
                if (joinPath(alloc, gdir, name)) |p| {
                    if (loadLayer(alloc, io, p)) |l| {
                        s.global = l;
                    }
                    alloc.free(p);
                }
            }
        }
    }
    // Project layer.
    if (findInsensitive(alloc, io, zivroot.rootDir(), "ziv.md")) |name| {
        defer alloc.free(name);
        if (joinPath(alloc, zivroot.rootDir(), name)) |p| {
            if (loadLayer(alloc, io, p)) |l| {
                s.project = l;
            }
            alloc.free(p);
        }
    }
    return s;
}

/// Hot-reload fingerprint: per-layer mtime+size (cheaper than hashing the
/// content; a same-size same-mtime edit is not a real editing workflow).
pub const Fingerprint = struct {
    g_ms: i64 = 0,
    g_len: u64 = 0,
    p_ms: i64 = 0,
    p_len: u64 = 0,
};

fn statLayer(io: std.Io, path: []const u8) struct { ms: i64, len: u64 } {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .ms = 0, .len = 0 };
    return .{ .ms = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms)), .len = st.size };
}

/// Fingerprint by FIXED canonical paths (not the case-insensitive hits):
/// a case rename changes the found name but not these stats — acceptable,
/// a rename is a save in practice.
pub fn fingerprint(io: std.Io) Fingerprint {
    var fp = Fingerprint{};
    if (env_mod.homeDir()) |home| {
        var gb: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&gb, "{s}/.config/ziv/ziv.md", .{home})) |p| {
            const st = statLayer(io, p);
            fp.g_ms = st.ms;
            fp.g_len = st.len;
        } else |_| {}
    }
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const ppath = zivroot.sub(&pb, "ziv.md");
    const pst = statLayer(io, ppath);
    fp.p_ms = pst.ms;
    fp.p_len = pst.len;
    return fp;
}

pub fn sameFingerprint(a: Fingerprint, b: Fingerprint) bool {
    return a.g_ms == b.g_ms and a.g_len == b.g_len and a.p_ms == b.p_ms and a.p_len == b.p_len;
}

pub const SyncOutcome = union(enum) {
    /// Markers found and the fenced region replaced in place.
    /// Sources are FLAGS (not borrowed strings — an earlier version
    /// returned arena-backed slices that dangled after this function
    /// returned; the caller printed freed memory).
    replaced: struct { agents: bool, claude: bool },
    /// No markers (hand-made file) — backed up to ziv.md.bak, regenerated.
    /// The backup path is derivable (<ziv.md>.bak), never returned.
    regenerated: struct { agents: bool, claude: bool },
    no_ziv_md,
    no_foreign_files,
    write_failed,
};

/// /agents sync: refresh the external (fenced) region of the project
/// ziv.md from the current AGENTS.md/CLAUDE.md. Caller owns nothing in the
/// outcome's slices but MUST NOT free them (they point into `alloc`'s
/// arena the caller passes… no — keep it simple: outcome strings are
/// static or borrowed from caller-owned args).
pub fn syncExternal(alloc: std.mem.Allocator, io: std.Io) SyncOutcome {
    const anchor = zivroot.rootDir();
    const ziv_name = findInsensitive(alloc, io, anchor, "ziv.md") orelse return .no_ziv_md;
    defer alloc.free(ziv_name);

    const agents_name = findInsensitive(alloc, io, anchor, "agents.md");
    defer if (agents_name) |n| alloc.free(n);
    const claude_name = findInsensitive(alloc, io, anchor, "claude.md");
    defer if (claude_name) |n| alloc.free(n);
    if (agents_name == null and claude_name == null) return .no_foreign_files;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ziv_path = joinPath(a, anchor, ziv_name) orelse return .write_failed;
    const existing = std.Io.Dir.cwd().readFileAlloc(io, ziv_path, a, .limited(512 * 1024)) catch return .write_failed;

    if (findFence(existing)) |fence| {
        // Replace only the fenced region; the user's sections survive.
        const agents_txt: ?[]const u8 = if (agents_name) |n| readForeign(a, io, anchor, n) else null;
        const claude_txt: ?[]const u8 = if (claude_name) |n| readForeign(a, io, anchor, n) else null;
        var aw: std.Io.Writer.Allocating = .init(a);
        const w = &aw.writer;
        w.writeAll(existing[0..fence.start]) catch return .write_failed;
        w.writeAll(marker_start ++ "\n") catch return .write_failed;
        if (agents_txt) |c| w.print("# 来自 AGENTS.md\n{s}\n\n", .{c}) catch return .write_failed;
        if (claude_txt) |c| w.print("# 来自 CLAUDE.md\n{s}\n\n", .{c}) catch return .write_failed;
        w.writeAll(marker_end) catch return .write_failed;
        w.writeAll(existing[fence.end..]) catch return .write_failed;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ziv_path, .data = aw.written() }) catch return .write_failed;
        return .{ .replaced = .{ .agents = agents_txt != null, .claude = claude_txt != null } };
    }

    // No fence (hand-made or foreign format): back up, regenerate whole.
    var bak_buf: [std.fs.max_path_bytes]u8 = undefined;
    const backup = std.fmt.bufPrint(&bak_buf, "{s}.bak", .{ziv_path}) catch return .write_failed;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = backup, .data = existing }) catch return .write_failed;
    const agents_txt: ?[]const u8 = if (agents_name) |n| readForeign(a, io, anchor, n) else null;
    const claude_txt: ?[]const u8 = if (claude_name) |n| readForeign(a, io, anchor, n) else null;
    const tmpl = generationTemplate(a, agents_txt, claude_txt) orelse return .write_failed;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ziv_path, .data = tmpl }) catch return .write_failed;
    return .{ .regenerated = .{ .agents = agents_txt != null, .claude = claude_txt != null } };
}

fn readForeign(a: std.mem.Allocator, io: std.Io, anchor: []const u8, name: []const u8) ?[]const u8 {
    const p = joinPath(a, anchor, name) orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(256 * 1024)) catch null;
}

const Fence = struct { start: usize, end: usize };

fn findFence(text: []const u8) ?Fence {
    const s = std.mem.indexOf(u8, text, marker_start) orelse return null;
    const e = std.mem.indexOf(u8, text, marker_end) orelse return null;
    if (e <= s) return null;
    return .{ .start = s, .end = e + marker_end.len };
}

// ─── tests ───

test "findInsensitive matches any case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var io_state = std.Io.Threaded.init(a, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const ts: u32 = @truncate(@as(u64, @bitCast(time_mod.nowMillis())));
    const base = try std.fmt.allocPrint(a, "/tmp/ziv_rules_ci_{d}", .{ts});
    std.Io.Dir.cwd().createDirPath(io, base) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    // Uppercase on disk, lowercase needle.
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/ZIV.MD", .{base}), .data = "x" }) catch unreachable;
    const hit = findInsensitive(a, io, base, "ziv.md") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ZIV.MD", hit);
    try std.testing.expect(findInsensitive(a, io, base, "agents.md") == null);
}

test "generation template stitches foreign files between markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = generationTemplate(a, "rule-A", "rule-B") orelse return error.TestUnexpectedResult;
    const f = findFence(t) orelse return error.TestUnexpectedResult;
    // Fence covers both foreign bodies; the user section stays outside.
    try std.testing.expect(std.mem.indexOf(u8, t[f.start..f.end], "rule-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, t[f.start..f.end], "rule-B") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "ziv 专属规则") != null);
    // Sync replaces [fence) only: user text after fence.end survives.
    try std.testing.expect(f.end < t.len);
}
