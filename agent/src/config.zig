/// Configuration system — hierarchical settings loading from multiple sources.
/// Priority: session > cli_args > local_settings > project_settings > user_settings
const std = @import("std");
const system_dirs = @import("util/system_dirs.zig");
const json_helpers = @import("util/json_helpers.zig");
const auth_mode = @import("tools/auth_mode.zig");
const env_mod = @import("util/env.zig");

pub const SettingSource = enum {
    user_settings,
    project_settings,
    local_settings,
    cli_args,
    session,
};

pub const Settings = struct {
    permission_mode: auth_mode.PermissionMode = .default,
    allow_rules: []const auth_mode.PermissionRule = &.{},
    deny_rules: []const auth_mode.PermissionRule = &.{},
    api_keys: ApiKeys = .{},
    default_model: []const u8 = "gpt-4o",
    /// Explicit backend override ("openai"/"claude"/"ollama"). When set it
    /// beats name-based detection, so custom model names (glm-4.6, deepseek-…)
    /// can be routed through a configured compatible gateway.
    default_backend: ?[]const u8 = null,
    max_tokens: u32 = 4096,
    max_snapshots: u32 = 100,
    checkpointing_enabled: bool = true,
    system_prompt: ?[]const u8 = null,

    pub const ApiKeys = struct {
        openai: ?[]const u8 = null,
        openai_base_url: ?[]const u8 = null,
        anthropic: ?[]const u8 = null,
        anthropic_base_url: ?[]const u8 = null,
        ollama_host: []const u8 = "http://localhost:11434",
        brave_api_key: ?[]const u8 = null,
    };
};

/// Load settings from all sources, merged in priority order.
pub fn loadSettings(allocator: std.mem.Allocator, io: std.Io) !Settings {
    var settings = Settings{};

    // Load from each source in order (later overrides earlier)
    loadFromUserSettings(&settings, allocator, io) catch {};
    loadFromProjectSettings(&settings, allocator, io) catch {};
    loadFromLocalSettings(&settings, allocator, io) catch {};

    // Environment variable fallback for API keys and base URLs
    if (settings.api_keys.openai == null) {
        if (env_mod.get("OPENAI_API_KEY")) |k| {
            settings.api_keys.openai = k;
        }
    }
    if (settings.api_keys.openai_base_url == null) {
        if (env_mod.get("OPENAI_BASE_URL")) |u| {
            settings.api_keys.openai_base_url = u;
        }
    }
    if (settings.api_keys.anthropic == null) {
        if (env_mod.get("ANTHROPIC_API_KEY")) |k| {
            settings.api_keys.anthropic = k;
        }
    }
    if (settings.api_keys.anthropic_base_url == null) {
        if (env_mod.get("ANTHROPIC_BASE_URL")) |u| {
            settings.api_keys.anthropic_base_url = u;
        }
    }
    if (settings.api_keys.brave_api_key == null) {
        if (env_mod.get("BRAVE_API_KEY")) |k| {
            settings.api_keys.brave_api_key = k;
        }
    }

    return settings;
}

fn loadFromUserSettings(settings: *Settings, allocator: std.mem.Allocator, io: std.Io) !void {
    const dir = system_dirs.configDir(allocator) catch return;
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "settings.json" });
    defer allocator.free(path);
    loadJsonIntoSettings(settings, allocator, io, path) catch {};
}

fn loadFromProjectSettings(settings: *Settings, allocator: std.mem.Allocator, io: std.Io) !void {
    const path = ".ziv/settings.json";
    loadJsonIntoSettings(settings, allocator, io, path) catch {};
}

fn loadFromLocalSettings(settings: *Settings, allocator: std.mem.Allocator, io: std.Io) !void {
    const path = ".ziv/settings.local.json";
    loadJsonIntoSettings(settings, allocator, io, path) catch {};
}

fn loadJsonIntoSettings(settings: *Settings, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch return;
    defer allocator.free(contents);

    const parsed = json_helpers.parse(allocator, contents) catch return;
    defer parsed.deinit();
    const value = parsed.value;

    // NOTE: every string assigned below must be duped — slices into `parsed`
    // dangle after this function returns (the DOM is freed by defer above).
    if (json_helpers.getString(value, "default_model")) |model| {
        settings.default_model = try allocator.dupe(u8, model);
    }
    if (json_helpers.getInt(value, "max_tokens")) |mt| {
        if (mt > 0 and mt <= 128000) {
            settings.max_tokens = @intCast(mt);
        }
    }
    if (json_helpers.getBool(value, "checkpointing_enabled")) |ce| {
        settings.checkpointing_enabled = ce;
    }

    // Parse permission mode
    if (json_helpers.getString(value, "permission_mode")) |mode_str| {
        if (std.mem.eql(u8, mode_str, "default")) settings.permission_mode = .default else if (std.mem.eql(u8, mode_str, "accept_edits")) settings.permission_mode = .accept_edits else if (std.mem.eql(u8, mode_str, "plan")) settings.permission_mode = .plan else if (std.mem.eql(u8, mode_str, "bypass")) settings.permission_mode = .bypass else if (std.mem.eql(u8, mode_str, "auto")) settings.permission_mode = .auto;
    }

    if (json_helpers.getString(value, "default_backend")) |b| {
        if (std.mem.eql(u8, b, "openai") or std.mem.eql(u8, b, "claude") or std.mem.eql(u8, b, "ollama")) {
            settings.default_backend = try allocator.dupe(u8, b);
        }
    }

    // Parse API keys
    if (json_helpers.getObject(value, "api_keys")) |keys| {
        if (json_helpers.getString(keys, "openai")) |k| settings.api_keys.openai = try allocator.dupe(u8, k);
        if (json_helpers.getString(keys, "openai_base_url")) |u| settings.api_keys.openai_base_url = try allocator.dupe(u8, u);
        if (json_helpers.getString(keys, "anthropic")) |k| settings.api_keys.anthropic = try allocator.dupe(u8, k);
        if (json_helpers.getString(keys, "anthropic_base_url")) |u| settings.api_keys.anthropic_base_url = try allocator.dupe(u8, u);
        if (json_helpers.getString(keys, "brave")) |k| settings.api_keys.brave_api_key = try allocator.dupe(u8, k);
    }

    // Parse system prompt
    if (json_helpers.getString(value, "system_prompt")) |sp| {
        settings.system_prompt = try allocator.dupe(u8, sp);
    }
}

/// Save settings to user config file (~/.config/ziv/settings.json).
fn writeJsonTopField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, value: []const u8) void {
    writeJsonField(allocator, buf, "  ", name, value);
}

fn writeJsonNestedField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, value: []const u8) void {
    writeJsonField(allocator, buf, "    ", name, value);
    // Last field of the object: writeJsonField ends with ",\n" — swap the
    // comma for a space so the closing brace has no trailing comma.
    if (buf.items.len >= 2 and buf.items[buf.items.len - 2] == ',') {
        buf.items[buf.items.len - 2] = ' ';
    }
}

fn writeJsonField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), indent: []const u8, name: []const u8, value: []const u8) void {
    buf.appendSlice(allocator, indent) catch return;
    buf.appendSlice(allocator, "\"") catch return;
    buf.appendSlice(allocator, name) catch return;
    buf.appendSlice(allocator, "\": \"") catch return;
    for (value) |ch| {
        switch (ch) {
            '"' => buf.appendSlice(allocator, "\\\"") catch return,
            '\\' => buf.appendSlice(allocator, "\\\\") catch return,
            '\n' => buf.appendSlice(allocator, "\\n") catch return,
            '\r' => buf.appendSlice(allocator, "\\r") catch return,
            '\t' => buf.appendSlice(allocator, "\\t") catch return,
            else => buf.append(allocator, ch) catch return,
        }
    }
    buf.appendSlice(allocator, "\",\n") catch return;
}

fn writeJsonStringField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, value: []const u8) void {
    buf.appendSlice(allocator, "    \"") catch return;
    buf.appendSlice(allocator, name) catch return;
    buf.appendSlice(allocator, "\": \"") catch return;
    for (value) |ch| {
        switch (ch) {
            '"' => buf.appendSlice(allocator, "\\\"") catch return,
            '\\' => buf.appendSlice(allocator, "\\\\") catch return,
            '\n' => buf.appendSlice(allocator, "\\n") catch return,
            '\r' => buf.appendSlice(allocator, "\\r") catch return,
            '\t' => buf.appendSlice(allocator, "\\t") catch return,
            else => buf.append(allocator, ch) catch return,
        }
    }
    buf.appendSlice(allocator, "\",\n") catch return;
}

pub fn saveSettings(settings: *const Settings, allocator: std.mem.Allocator, io: std.Io) !void {
    const dir = system_dirs.configDir(allocator) catch |err| return err;
    defer allocator.free(dir);

    // Ensure directory exists
    system_dirs.ensureDir(dir, io) catch |err| return err;

    const path = try std.fs.path.join(allocator, &.{ dir, "settings.json" });
    defer allocator.free(path);

    // Build JSON
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\n") catch return;

    // default_model (escaped — a quote/backslash here corrupts the file)
    writeJsonTopField(allocator, &buf, "default_model", settings.default_model);
    // max_tokens
    buf.print(allocator, "  \"max_tokens\": {d},\n", .{settings.max_tokens}) catch {};
    // checkpointing_enabled
    buf.print(allocator, "  \"checkpointing_enabled\": {},\n", .{settings.checkpointing_enabled}) catch {};
    // permission_mode
    const mode_str = @tagName(settings.permission_mode);
    buf.print(allocator, "  \"permission_mode\": \"{s}\",\n", .{mode_str}) catch {};
    if (settings.default_backend) |b| {
        writeJsonTopField(allocator, &buf, "default_backend", b);
    }

    // system_prompt
    if (settings.system_prompt) |sp| {
        buf.appendSlice(allocator, "  \"system_prompt\": \"") catch {};
        // Simple escaping for JSON string
        for (sp) |ch| {
            switch (ch) {
                '"' => buf.appendSlice(allocator, "\\\"") catch {},
                '\\' => buf.appendSlice(allocator, "\\\\") catch {},
                '\n' => buf.appendSlice(allocator, "\\n") catch {},
                '\r' => buf.appendSlice(allocator, "\\r") catch {},
                '\t' => buf.appendSlice(allocator, "\\t") catch {},
                else => buf.append(allocator, ch) catch {},
            }
        }
        buf.appendSlice(allocator, "\",\n") catch {};
    }

    // api_keys (escaped: a quote/backslash in a key would corrupt the file
    // and the next load would silently drop EVERYTHING)
    buf.appendSlice(allocator, "  \"api_keys\": {\n") catch {};
    if (settings.api_keys.openai) |k| {
        writeJsonStringField(allocator, &buf, "openai", k);
    }
    if (settings.api_keys.openai_base_url) |u| {
        writeJsonStringField(allocator, &buf, "openai_base_url", u);
    }
    if (settings.api_keys.anthropic) |k| {
        writeJsonStringField(allocator, &buf, "anthropic", k);
    }
    if (settings.api_keys.anthropic_base_url) |u| {
        writeJsonStringField(allocator, &buf, "anthropic_base_url", u);
    }
    if (settings.api_keys.brave_api_key) |k| {
        writeJsonStringField(allocator, &buf, "brave", k);
    }
    writeJsonNestedField(allocator, &buf, "ollama_host", settings.api_keys.ollama_host);
    buf.appendSlice(allocator, "  }\n") catch {};

    buf.appendSlice(allocator, "}\n") catch {};

    // Write file
    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = path,
        .data = buf.items,
    }) catch |err| return err;
}
