/// Skill loader (T7.1/T8.1) — discovers SKILL.md packs in
/// ~/.config/ziv/skills/<name>/ and ./.ziv/skills/<name>/ (project-local),
/// parses the Claude-compatible frontmatter subset (name / description /
/// when_to_use), and builds the system-prompt manifest within a token
/// budget. Skills are prompt-only in v1: invoking /<skill-name> injects
/// the skill body into the conversation.
const std = @import("std");
const env_mod = @import("../util/env.zig");
const tokens = @import("../util/tokens.zig");

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    /// T7.1: optional frontmatter `tools:` hint (comma-separated). Purely
    /// advisory — shown at trigger time so the user sees what the skill
    /// intends to use. Empty when absent (backward compatible).
    tools: []const u8 = "",
    when_to_use: ?[]const u8,
    /// Absolute path of the SKILL.md file (body re-read on invoke).
    path: []const u8,
    source: Source,
};

pub const Source = enum { user, project };

pub const SkillLoader = struct {
    allocator: std.mem.Allocator,
    skills: std.ArrayList(Skill) = .empty,
    io: std.Io,
    /// Test seam: overrides the user skill root (ZIV_SKILLS_DIR fallback).
    user_dir_override: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Self) void {
        for (self.skills.items) |s| {
            self.allocator.free(s.name);
            self.allocator.free(s.description);
            if (s.when_to_use) |w| self.allocator.free(w);
            if (s.tools.len > 0) self.allocator.free(s.tools);
            self.allocator.free(s.path);
        }
        self.skills.deinit(self.allocator);
    }

    /// Scan both skill roots. Unreadable dirs are skipped silently — a bad
    /// skill must never break startup.
    pub fn load(self: *Self) void {
        self.loadRoot(true) catch {};
        self.loadRoot(false) catch {};
        // Name collisions were resolved during load (project replaced user).
    }

    fn loadRoot(self: *Self, user_root: bool) !void {
        const root = if (user_root) try self.userRoot() else try self.projectRoot();
        defer self.allocator.free(root);
        self.loadDir(root, if (user_root) Source.user else Source.project) catch {};
    }

    fn userRoot(self: *Self) ![]u8 {
        if (self.user_dir_override) |d| return self.allocator.dupe(u8, d);
        if (env_mod.get("ZIV_SKILLS_DIR")) |d| return self.allocator.dupe(u8, d);
        const home = env_mod.homeDir() orelse return error.NoHome;
        return std.fmt.allocPrint(self.allocator, "{s}/.config/ziv/skills", .{home});
    }

    fn projectRoot(self: *Self) ![]u8 {
        return self.allocator.dupe(u8, ".ziv/skills");
    }

    fn loadDir(self: *Self, root: []const u8, source: Source) !void {
        const dir_opt = if (std.fs.path.isAbsolute(root))
            std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true })
        else
            std.Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true });
        var dir = dir_opt catch |e| {
            if (env_mod.get("ZIV_SKILL_DEBUG") != null) std.debug.print("[skill] openDir fail {s}: {}\n", .{ root, e });
            return;
        };
        defer dir.close(self.io);
        var it = dir.iterate();
        if (env_mod.get("ZIV_SKILL_DEBUG") != null) std.debug.print("[skill] scanning {s}\n", .{root});
        while (true) {
            const entry_opt = it.next(self.io) catch null;
            const entry = entry_opt orelse break;
            if (entry.kind != .directory) continue;
            const skill_md = std.fmt.allocPrint(self.allocator, "{s}/{s}/SKILL.md", .{ root, entry.name }) catch continue;
            defer self.allocator.free(skill_md);
            const text = std.Io.Dir.cwd().readFileAlloc(self.io, skill_md, self.allocator, .limited(256 * 1024)) catch |e| {
                if (env_mod.get("ZIV_SKILL_DEBUG") != null) std.debug.print("[skill] read fail {s}: {}\n", .{ skill_md, e });
                continue;
            };
            defer self.allocator.free(text);

            const fm = parseFrontmatter(text) orelse {
                if (env_mod.get("ZIV_SKILL_DEBUG") != null) std.debug.print("[skill] fm fail {s}\n", .{skill_md});
                continue;
            };
            // name defaults to the directory name; description is required
            // (without it the LLM can't decide when to use the skill).
            if (fm.description.len == 0) continue;

            const skill = Skill{
                .name = self.allocator.dupe(u8, if (fm.name.len > 0) fm.name else entry.name) catch continue,
                .description = self.allocator.dupe(u8, fm.description) catch continue,
                .when_to_use = if (fm.when_to_use.len > 0) (self.allocator.dupe(u8, fm.when_to_use) catch null) else null,
                .tools = if (fm.tools.len > 0) (self.allocator.dupe(u8, fm.tools) catch continue) else "",
                .path = self.allocator.dupe(u8, skill_md) catch continue,
                .source = source,
            };
            // Name collision: project-local replaces user-global (more
            // specific); a user skill never overwrites a project one.
            if (self.findByName(skill.name)) |existing| {
                if (existing.source == .project or skill.source == .user) continue;
                self.allocator.free(existing.name);
                self.allocator.free(existing.description);
                if (existing.when_to_use) |w| self.allocator.free(w);
                if (existing.tools.len > 0) self.allocator.free(existing.tools);
                self.allocator.free(existing.path);
                existing.* = skill;
                continue;
            }
            self.skills.append(self.allocator, skill) catch {};
        }
    }

    pub fn findByName(self: *const Self, name: []const u8) ?*Skill {
        var i = self.skills.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.skills.items[i].name, name)) return &self.skills.items[i];
        }
        return null;
    }

    /// System-prompt manifest: one line per skill, newest-source-first
    /// within a token budget. Body text is NOT included — only /<name>
    /// invocation pulls it in.
    pub fn buildManifest(self: *const Self, allocator: std.mem.Allocator, budget_tokens: u32) !?[]u8 {
        if (self.skills.items.len == 0) return null;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("Available skills (invoke with /<name>):\n");
        var used: u32 = 8;
        var included: usize = 0;
        var i = self.skills.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.skills.items[i];
            var line_buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "- /{s}: {s}\n", .{
                s.name,
                s.description[0..@min(s.description.len, 400)],
            }) catch continue;
            const cost = tokens.estimateTokens(line);
            if (used + cost > budget_tokens and included > 0) break;
            try w.writeAll(line);
            used += cost;
            included += 1;
        }
        if (included == 0) return null;
        var list = aw.toArrayList();
        const out: ?[]u8 = try list.toOwnedSlice(allocator);
        return out;
    }

    /// Read the skill body (everything after the frontmatter).
    pub fn readBody(self: *const Self, skill: *const Skill, allocator: std.mem.Allocator) ![]u8 {
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, skill.path, allocator, .limited(1024 * 1024)) catch
            return error.SkillUnreadable;
        defer allocator.free(text);
        const fm = parseFrontmatter(text) orelse return allocator.dupe(u8, text);
        return allocator.dupe(u8, text[fm.body_start..]);
    }
};

const Frontmatter = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    tools: []const u8 = "",
    when_to_use: []const u8 = "",
    body_start: usize = 0,
};

/// Minimal `---` frontmatter parser: key: value lines between the opening
/// and closing `---`, values may be single- or double-quoted.
pub fn parseFrontmatter(text: []const u8) ?Frontmatter {
    if (!std.mem.startsWith(u8, text, "---")) return null;
    const first_nl = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    var rest = text[first_nl + 1 ..];
    var out = Frontmatter{};
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
        var line = std.mem.trim(u8, rest[0..nl], " \t\r");
        rest = rest[nl + 1 ..];
        if (std.mem.eql(u8, line, "---")) {
            out.body_start = @intFromPtr(rest.ptr) - @intFromPtr(text.ptr);
            return out;
        }
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
            value = value[1 .. value.len - 1];
        }
        if (std.mem.eql(u8, key, "name")) {
            out.name = value;
        } else if (std.mem.eql(u8, key, "description")) {
            out.description = value;
        } else if (std.mem.eql(u8, key, "when_to_use")) {
            out.when_to_use = value;
        } else if (std.mem.eql(u8, key, "tools")) {
            out.tools = value; // T7.1: advisory tool hint, comma-separated
        }
    }
}

/// T7.1: count the body's top-level list items ("- " lines outside code
/// fences) — a cheap "how many steps does this skill declare" signal for
/// the trigger-time preview.
pub fn countSteps(body: []const u8) usize {
    var n: usize = 0;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (std.mem.startsWith(u8, t, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (std.mem.startsWith(u8, t, "- ")) n += 1;
    }
    return n;
}

// ── Tests ──

test "parseFrontmatter extracts the Claude subset" {
    const sample =
        \\---
        \\name: code-review
        \\description: "Review code for quality and bugs"
        \\when_to_use: reviewing PRs or diffs
        \\allowed-tools: Read, Grep
        \\---
        \\
        \\# Body starts here
        \\Review the diff carefully.
    ;
    const fm = parseFrontmatter(sample).?;
    try std.testing.expectEqualStrings("code-review", fm.name);
    try std.testing.expectEqualStrings("Review code for quality and bugs", fm.description);
    try std.testing.expectEqualStrings("reviewing PRs or diffs", fm.when_to_use);
    try std.testing.expect(std.mem.startsWith(u8, sample[fm.body_start..], "\n# Body starts here"));

    // no frontmatter -> null; unterminated -> null
    try std.testing.expect(parseFrontmatter("plain text") == null);
    try std.testing.expect(parseFrontmatter("---\nname: x\n") == null);
}

test "SkillLoader discovers and dedupes by name (project wins)" {
    // Fixture skills under a temp dir; the loader reads ZIV_SKILLS_DIR.
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    // 0.17 has no Dir.realpath; use a unique absolute fixture dir instead.
    const root = try std.fmt.allocPrint(std.testing.allocator, "/tmp/ziv_skill_fixture_{d}", .{std.c.getpid()});
    defer std.testing.allocator.free(root);
    std.Io.Dir.cwd().createDirPath(io, root) catch {};

    // user skill
    {
        const d = try std.fmt.allocPrint(std.testing.allocator, "{s}/skills/user-skill", .{root});
        defer std.testing.allocator.free(d);
        const skills_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/skills", .{root});
        defer std.testing.allocator.free(skills_dir);
        std.Io.Dir.createDirAbsolute(io, skills_dir, .default_dir) catch {};
        std.Io.Dir.createDirAbsolute(io, d, .default_dir) catch {};
        const p = try std.fmt.allocPrint(std.testing.allocator, "{s}/skills/user-skill/SKILL.md", .{root});
        defer std.testing.allocator.free(p);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "---\nname: greet\ndescription: Say hi politely\n---\nBody: say hi.\n" });
    }
    // project skill with the SAME name -> must win
    {
        try std.Io.Dir.cwd().createDirPath(io, ".ziv/skills/proj-skill");
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".ziv/skills/proj-skill/SKILL.md", .data = "---\nname: greet\ndescription: Project greeting wins\n---\nBody: project.\n" });
    }
    defer std.Io.Dir.cwd().deleteFile(io, ".ziv/skills/proj-skill/SKILL.md") catch {};
    defer std.Io.Dir.cwd().deleteDir(io, ".ziv/skills/proj-skill") catch {};
    defer std.Io.Dir.cwd().deleteDir(io, ".ziv/skills") catch {};

    const user_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/skills", .{root});
    defer std.testing.allocator.free(user_root);

    var loader = SkillLoader.init(std.testing.allocator, io);
    defer loader.deinit();
    loader.user_dir_override = user_root;
    loader.load();
    // Same name in both roots -> ONE entry, project wins.
    try std.testing.expectEqual(@as(usize, 1), loader.skills.items.len);
    const skill = loader.findByName("greet").?;
    try std.testing.expectEqualStrings("Project greeting wins", skill.description);

    const body = try loader.readBody(skill, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "project.") != null);

    const manifest = (try loader.buildManifest(std.testing.allocator, 200)).?;
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "/greet:") != null);

    // fixture cleanup (recursive-by-hand: only what we created)
    const rm = try std.fmt.allocPrint(std.testing.allocator, "{s}/user-skill/SKILL.md", .{user_root});
    defer std.testing.allocator.free(rm);
    std.Io.Dir.deleteFileAbsolute(io, rm) catch {};
}

test "frontmatter tools hint parses and body steps count (T7.1)" {
    const md =
        \\---
        \\name: release
        \\description: Cut a release
        \\tools: Grep, FileRead, Bash
        \\---
        \\Steps:
        \\- bump version
        \\- run tests
        \\- tag
        \\
        \\```sh
        \\- this is code, not a step
        \\```
        \\
    ;
    const fm = parseFrontmatter(md).?;
    try std.testing.expectEqualStrings("release", fm.name);
    try std.testing.expectEqualStrings("Grep, FileRead, Bash", fm.tools);
    const body = md[@intCast(fm.body_start)..];
    try std.testing.expectEqual(@as(usize, 3), countSteps(body));

    // Old skill without `tools:` parses unchanged (backward compat).
    const legacy = "---\nname: x\ndescription: y\n---\nno lists";
    const fm2 = parseFrontmatter(legacy).?;
    try std.testing.expectEqualStrings("", fm2.tools);
    try std.testing.expectEqual(@as(usize, 0), countSteps("no lists"));
}
