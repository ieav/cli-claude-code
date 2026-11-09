//! Interactive configuration — the config/model/API-key menu cluster
//! carved out of repl.zig (P1 step 6, pure move): /config arrow-key menu,
//! model picker (gateway model list + custom prompt), API keys editor.
//! Settings persistence goes through ModelSwitcher + config_mod, with the
//! hot-reload fingerprint baseline owned by repl.zig.

const std = @import("std");
const auth = @import("../tools/auth_mode.zig");
const menu = @import("../util/menu.zig");
const llm = @import("../llm/mod.zig");
const config_mod = @import("../config.zig");
const format_mod = @import("../util/format.zig");
const repl_mod = @import("../repl.zig");

const ModelSwitcher = repl_mod.ModelSwitcher;

// ──── Interactive config menu ────

fn autoSaveSettings(w: *std.Io.Writer, file_writer: *std.Io.File.Writer, switcher: *ModelSwitcher, alloc: std.mem.Allocator, io: std.Io) void {
    config_mod.saveSettings(&switcher.settings, alloc, io) catch |err| {
        w.print("  保存失败: {any}\n", .{err}) catch {};
        return;
    };
    // Own save — refresh the hot-reload baseline so the next prompt does
    // not "reload" what we just wrote ourselves.
    repl_mod.settings_fp_baseline = config_mod.settingsFingerprint(alloc, io);
    w.writeAll("  ✓ 已自动保存\n") catch {};
    std.Io.File.Writer.flush(file_writer) catch {};
}

/// Arrow-key driven configuration menu. Every change auto-saves to
/// ~/.config/ziv/settings.json immediately.
pub fn runConfigMenu(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    while (true) {
        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        var b3: [64]u8 = undefined;
        var b4: [64]u8 = undefined;
        var b5: [64]u8 = undefined;
        var b6: [64]u8 = undefined;
        var b7: [64]u8 = undefined;
        var b8: [96]u8 = undefined;
        var b9: [64]u8 = undefined;
        var b10: [112]u8 = undefined;
        var b11: [64]u8 = undefined;
        const items = [_][]const u8{
            "API Keys",
            try_std_fmt(&b1, "默认模型: {s}", .{switcher.settings.default_model}),
            try_std_fmt(&b2, "最大 tokens: {d}", .{switcher.settings.max_tokens}),
            try_std_fmt(&b6, "记忆注入预算: {d} tokens", .{switcher.settings.memory_budget_tokens}),
            try_std_fmt(&b7, "子代理并发: {d}", .{switcher.settings.subagent_concurrency}),
            try_std_fmt(&b3, "权限模式: {s}", .{auth.modeLabel(switcher.settings.permission_mode)}),
            try_std_fmt(&b4, "检查点: {s}", .{if (switcher.settings.checkpointing_enabled) "开" else "关"}),
            try_std_fmt(&b5, "系统提示词: {s}", .{if (switcher.settings.system_prompt != null) "(自定义)" else "(默认)"}),
            try_std_fmt(&b11, "输出风格: {s}", .{switcher.settings.output_style}),
            try_std_fmt(&b8, "自动错误修复: {s}", .{if (switcher.settings.auto_fix) "开（429/超时退避重试）" else "关（直接出选择器）"}),
            try_std_fmt(&b9, "回合工具轮上限: {d}", .{switcher.settings.agent_loop_limit}),
            try_std_fmt(&b10, "上下文提炼压缩: {s}", .{if (switcher.settings.auto_deep_compact) "开（LLM 摘要优先，截断兜底）" else "关（压力直落 φ 截断）"}),
            "退出",
        };
        const picked = (menu.select(w, r, file_writer, "=== Ziv 配置 ===", &items, 0) catch break) orelse break;

        switch (picked) {
            0 => try runApiKeysMenu(w, r, file_writer, switcher, alloc, io),
            1 => try configPickModel(w, r, file_writer, switcher, alloc, io),
            2 => {
                var vbuf: [32]u8 = undefined;
                const val = (menu.readLine(r, w, file_writer, "  最大 tokens (1-128000): ", &vbuf) catch continue) orelse continue;
                if (val.len == 0) continue;
                const mt = std.fmt.parseInt(u32, val, 10) catch {
                    try std.Io.Writer.writeAll(w, "  无效数字\n");
                    continue;
                };
                if (mt > 0 and mt <= 128000) {
                    switcher.settings.max_tokens = mt;
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                } else try std.Io.Writer.writeAll(w, "  超出范围\n");
            },
            3 => {
                var mbbuf: [32]u8 = undefined;
                const mval = (menu.readLine(r, w, file_writer, "  记忆注入预算 tokens (200-8000): ", &mbbuf) catch continue) orelse continue;
                if (mval.len == 0) continue;
                const mbt = std.fmt.parseInt(u32, mval, 10) catch {
                    try std.Io.Writer.writeAll(w, "  无效数字\n");
                    continue;
                };
                if (mbt >= 200 and mbt <= 8000) {
                    switcher.settings.memory_budget_tokens = mbt;
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                } else try std.Io.Writer.writeAll(w, "  超出范围\n");
            },
            4 => {
                var scbuf: [32]u8 = undefined;
                const sval = (menu.readLine(r, w, file_writer, "  子代理并发数 (1-10，1=串行): ", &scbuf) catch continue) orelse continue;
                if (sval.len == 0) continue;
                const sc = std.fmt.parseInt(u32, sval, 10) catch {
                    try std.Io.Writer.writeAll(w, "  无效数字\n");
                    continue;
                };
                if (sc >= 1 and sc <= 10) {
                    switcher.settings.subagent_concurrency = sc;
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                } else try std.Io.Writer.writeAll(w, "  超出范围\n");
            },
            5 => {
                const mode_items = [_][]const u8{ "Default — 危险操作询问", "Accept Edits — 自动接受编辑", "Plan — 只读", "Bypass — 跳过检查", "Don't Ask — 自动拒绝", "Auto — LLM 分类" };
                const mode_map = [_]auth.PermissionMode{ .default, .accept_edits, .plan, .bypass, .dont_ask, .auto };
                const mp = (menu.select(w, r, file_writer, "选择权限模式:", &mode_items, 0) catch continue) orelse continue;
                switcher.settings.permission_mode = mode_map[mp];
                autoSaveSettings(w, file_writer, switcher, alloc, io);
            },
            6 => {
                switcher.settings.checkpointing_enabled = !switcher.settings.checkpointing_enabled;
                autoSaveSettings(w, file_writer, switcher, alloc, io);
            },
            7 => {
                const sp_items = [_][]const u8{ "输入自定义提示词", "恢复默认", "返回" };
                const sp = (menu.select(w, r, file_writer, "系统提示词:", &sp_items, 0) catch continue) orelse continue;
                if (sp == 0) {
                    var pbuf: [4096]u8 = undefined;
                    const pval = (menu.readLine(r, w, file_writer, "  提示词内容: ", &pbuf) catch continue) orelse continue;
                    if (pval.len > 0) {
                        switcher.settings.system_prompt = try alloc.dupe(u8, pval);
                        autoSaveSettings(w, file_writer, switcher, alloc, io);
                    }
                } else if (sp == 1) {
                    switcher.settings.system_prompt = null;
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                }
            },
            8 => {
                // 输出风格：菜单层只改 settings——system prompt 的重建由
                // dispatch /config 分支的 reapplySystemPromptIfNeeded 双键
                // 对比自动完成（与 settings 热重载同一条路径）。
                const style_items = [_][]const u8{ "default — 完整叙述（现行为）", "concise — 结果优先（省略开场白/过程/结尾复述）" };
                const st = (menu.select(w, r, file_writer, "输出风格（也可会话中 Ctrl+T 互切）:", &style_items, 0) catch continue) orelse continue;
                const val: []const u8 = if (st == 0) "default" else "concise";
                switcher.settings.output_style = try alloc.dupe(u8, val);
                autoSaveSettings(w, file_writer, switcher, alloc, io);
                try std.Io.Writer.print(w, "  输出风格: {s}（下一回合生效）\n", .{val});
            },
            9 => {
                switcher.settings.auto_fix = !switcher.settings.auto_fix;
                autoSaveSettings(w, file_writer, switcher, alloc, io);
                try std.Io.Writer.print(w, "  自动错误修复: {s}\n", .{if (switcher.settings.auto_fix) "开" else "关"});
            },
            10 => {
                var lbuf: [32]u8 = undefined;
                const lval = (menu.readLine(r, w, file_writer, "  回合工具轮上限 (1-200，50=默认，200=最宽): ", &lbuf) catch continue) orelse continue;
                if (lval.len == 0) continue;
                const lv = std.fmt.parseInt(u32, lval, 10) catch {
                    try std.Io.Writer.writeAll(w, "  无效数字\n");
                    continue;
                };
                if (lv >= 1 and lv <= 200) {
                    switcher.settings.agent_loop_limit = lv;
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                } else try std.Io.Writer.writeAll(w, "  超出范围（1-200）\n");
            },
            11 => {
                switcher.settings.auto_deep_compact = !switcher.settings.auto_deep_compact;
                autoSaveSettings(w, file_writer, switcher, alloc, io);
                try std.Io.Writer.print(w, "  上下文提炼压缩: {s}\n", .{if (switcher.settings.auto_deep_compact) "开" else "关"});
            },
            12 => break,
            else => {},
        }
    }
    try std.Io.Writer.writeAll(w, "\n");
}

fn try_std_fmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch fmt;
}

/// Shared custom-model entry: read the name, and when it is unrecognized
/// while a compatible gateway is configured, ask which backend serves it.
fn promptCustomModel(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
) !?[]const u8 {
    var vbuf: [128]u8 = undefined;
    const val = (menu.readLine(r, w, file_writer, "  模型名（如 glm-4.6 / deepseek-v3）: ", &vbuf) catch return null) orelse return null;
    if (val.len == 0) return null;
    // vbuf is a stack buffer — dupe BEFORE any further calls, otherwise the
    // returned slice dangles (first bytes got clobbered: "glm-5.3" -> " lm-5.3").
    const owned = try alloc.dupe(u8, val);

    if (llm.detectBackend(val) == .ollama and (switcher.settings.api_keys.openai != null or switcher.settings.api_keys.anthropic != null)) {
        const be_items = [_][]const u8{ "OpenAI 兼容接入（用已配的 OpenAI Key/网关）", "Anthropic 兼容接入（用已配的 Anthropic Key/网关）", "Ollama 本地" };
        const be = menu.select(w, r, file_writer, "该模型走哪个后端？", &be_items, 0) catch null;
        if (be) |choice| {
            switcher.settings.default_backend = switch (choice) {
                0 => "openai",
                1 => "claude",
                else => "ollama",
            };
        }
    }
    return owned;
}

/// Default-model picker shared by /config: known models + custom entry.
fn configPickModel(w: *std.Io.Writer, r: *std.Io.Reader, file_writer: *std.Io.File.Writer, switcher: *ModelSwitcher, alloc: std.mem.Allocator, io: std.Io) !void {
    var labels: [llm.KNOWN_MODELS.len + 2][]const u8 = undefined;
    for (&llm.KNOWN_MODELS, 0..) |entry, i| {
        const marker: []const u8 = if (std.mem.eql(u8, entry.name, switcher.settings.default_model)) " ●" else "";
        labels[i] = try std.fmt.allocPrint(alloc, "{s:<20} {s}{s}", .{ entry.name, entry.description, marker });
    }
    labels[llm.KNOWN_MODELS.len] = "自定义…（手动输入）";
    labels[llm.KNOWN_MODELS.len + 1] = "取消";
    defer for (labels[0..llm.KNOWN_MODELS.len]) |l| alloc.free(l);

    const picked = (menu.select(w, r, file_writer, "选择默认模型:", &labels, 0) catch return) orelse return;
    if (picked == llm.KNOWN_MODELS.len + 1) return;
    // promptCustomModel returns a heap string; static table names are not.
    // Track which one we hold so it is freed exactly once (default_model
    // gets its own dupe below — the old code leaked the prompt's copy).
    var owned_name: ?[]const u8 = null;
    defer if (owned_name) |n| alloc.free(n);
    const name: []const u8 = if (picked == llm.KNOWN_MODELS.len) blk: {
        const n = (try promptCustomModel(w, r, file_writer, switcher, alloc)) orelse return;
        owned_name = n;
        break :blk n;
    } else llm.KNOWN_MODELS[picked].name;

    // Persist AND switch the live session — previously this only wrote the
    // settings file, so nothing changed until a restart (and it looked like
    // "configuring the model did nothing").
    switcher.settings.default_model = try alloc.dupe(u8, name);
    switcher.switchModel(name) catch |err| {
        autoSaveSettings(w, file_writer, switcher, alloc, io);
        if (err == error.MissingApiKey) {
            try std.Io.Writer.print(w, "  已保存默认模型 {s}，但该后端未配 API key（当前会话暂未切换）。\n  请先在「API Keys」里配置，或 /quit 重启后使用。\n", .{name});
        } else {
            try std.Io.Writer.print(w, "  已保存，但切换失败: {any}\n", .{err});
        }
        try std.Io.File.Writer.flush(file_writer);
        return;
    };
    autoSaveSettings(w, file_writer, switcher, alloc, io);
    try std.Io.Writer.print(w, "  ✓ 已切换并保存: {s} ({s})\n", .{ switcher.modelName(), switcher.backendLabel() });
    try std.Io.File.Writer.flush(file_writer);
}

/// Fetch the model list a configured endpoint exposes.
/// OpenAI-compatible: GET {base}/models (Bearer); Anthropic: GET {base}/v1/models
/// (x-api-key); Ollama: GET {host}/api/tags. Caller frees each name + slice.
fn fetchGatewayModels(alloc: std.mem.Allocator, io: std.Io, switcher: *ModelSwitcher, backend: llm.BackendType) ![][]const u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    var auth_buf: [512]u8 = undefined;
    const url: []const u8, const key: ?[]const u8 = switch (backend) {
        .openai => .{
            std.fmt.bufPrint(&url_buf, "{s}/models", .{switcher.settings.api_keys.openai_base_url orelse "https://api.openai.com/v1"}) catch return error.BadURL,
            switcher.settings.api_keys.openai,
        },
        .claude => .{
            std.fmt.bufPrint(&url_buf, "{s}/v1/models", .{switcher.settings.api_keys.anthropic_base_url orelse "https://api.anthropic.com"}) catch return error.BadURL,
            switcher.settings.api_keys.anthropic,
        },
        .ollama => .{
            std.fmt.bufPrint(&url_buf, "{s}/api/tags", .{switcher.settings.api_keys.ollama_host}) catch return error.BadURL,
            null,
        },
    };

    const uri = try std.Uri.parse(url);
    var auth_header: []const u8 = "";
    var auth_val: std.http.Client.Request.Headers.Value = .default;
    if (backend == .openai and key != null) {
        auth_header = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key.?});
        auth_val = .{ .override = auth_header };
    }
    var extra: [1]std.http.Header = undefined;
    var n_extra: usize = 0;
    if (backend == .claude and key != null) {
        extra[0] = .{ .name = "x-api-key", .value = key.? };
        n_extra = 1;
    }

    var req = try client.request(.GET, uri, .{
        .headers = .{ .authorization = auth_val },
        .extra_headers = extra[0..n_extra],
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status.class() != .success) return error.FetchFailed;

    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = try readHttpBodyCapped(reader, alloc);
    defer alloc.free(body);
    // DOM lives in an arena that dies here; model names are duped out below
    // (the old leaky parse left the whole DOM behind on the session heap).
    var dom_arena = std.heap.ArenaAllocator.init(alloc);
    defer dom_arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, dom_arena.allocator(), body, .{}) catch return error.BadJSON;

    // openai/claude: {data:[{id:...}]}; ollama: {models:[{name:...}]}
    const arr = if (parsed.object.get("data")) |d| d.array.items else if (parsed.object.get("models")) |m| m.array.items else return error.BadJSON;
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    for (arr) |item| {
        const id = item.object.get("id") orelse item.object.get("name") orelse continue;
        if (id != .string) continue;
        try names.append(alloc, try alloc.dupe(u8, id.string));
    }
    return names.toOwnedSlice(alloc);
}

fn readHttpBodyCapped(reader: *std.Io.Reader, alloc: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var chunk: [8192]u8 = undefined;
    while (list.items.len < 4 * 1024 * 1024) {
        const n = reader.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try list.appendSlice(alloc, chunk[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

/// After configuring an endpoint, offer the models it actually serves.
fn offerGatewayModels(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    io: std.Io,
    backend: llm.BackendType,
) !void {
    // 失败必须可见（设计 §2.4）：原来静默 return，用户不知道为什么没反应。
    const names = fetchGatewayModels(alloc, io, switcher, backend) catch {
        try std.Io.Writer.writeAll(w, "  拉取模型列表失败（检查 Key / Base URL 是否可用）\n");
        try std.Io.File.Writer.flush(file_writer);
        return;
    };
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    if (names.len == 0) {
        try std.Io.Writer.writeAll(w, "  网关未返回任何模型\n");
        try std.Io.File.Writer.flush(file_writer);
        return;
    }

    try std.Io.Writer.print(w, "\n  网关上发现 {d} 个模型。\n", .{names.len});
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(alloc);
    for (names) |n| try labels.append(alloc, n);
    try labels.append(alloc, "跳过");
    const picked = (menu.select(w, r, file_writer, "选一个作为当前模型？", labels.items, 0) catch return) orelse return;
    if (picked >= names.len) return;

    const model = names[picked];
    switcher.settings.default_model = try alloc.dupe(u8, model);
    if (llm.detectBackend(model) == .ollama and backend != .ollama) {
        switcher.settings.default_backend = switch (backend) {
            .openai => "openai",
            .claude => "claude",
            .ollama => null,
        };
    }
    switcher.switchModel(model) catch {};
    autoSaveSettings(w, file_writer, switcher, alloc, io);
    try std.Io.Writer.print(w, "  ✓ 已切换: {s}\n", .{switcher.modelName()});
}

fn runApiKeysMenu(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    switcher: *ModelSwitcher,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    while (true) {
        var b1: [80]u8 = undefined;
        var b2: [80]u8 = undefined;
        const items = [_][]const u8{
            try_std_fmt(&b1, "OpenAI 接入（Key + 网关地址）: {s}", .{if (switcher.settings.api_keys.openai) |k| maskKey(k) else "(未配置)"}),
            try_std_fmt(&b2, "Anthropic 接入（Key + 网关地址）: {s}", .{if (switcher.settings.api_keys.anthropic) |k| maskKey(k) else "(未配置)"}),
            "Brave Key（网络搜索）",
            "Ollama Host（本地模型）",
            "返回",
        };
        const picked = (menu.select(w, r, file_writer, "=== 模型接入配置 ===", &items, 0) catch break) orelse break;
        switch (picked) {
            0, 1 => {
                // 设计见 docs/config-ux-design.md §2.1：一条规则走天下
                //（回车=保留 · -=清除 · 输入=修改），两字段问完一次保存，
                // 保存即终点——无网络往返、无连环菜单（D2/D3 修复）。
                const is_openai = picked == 0;
                const cur_key: ?[]const u8 = if (is_openai) switcher.settings.api_keys.openai else switcher.settings.api_keys.anthropic;
                const cur_url: ?[]const u8 = if (is_openai) switcher.settings.api_keys.openai_base_url else switcher.settings.api_keys.anthropic_base_url;

                try std.Io.Writer.print(w, "\n  {s} 接入（回车=保留 · -=清除 · 输入=修改）\n", .{if (is_openai) "OpenAI" else "Anthropic"});
                try std.Io.File.Writer.flush(file_writer);

                var kbuf: [256]u8 = undefined;
                var kp: [96]u8 = undefined;
                const key_prompt = try_std_fmt(&kp, "  API Key（当前 {s}）: ", .{if (cur_key) |k| maskKey(k) else "(未配置)"});
                const key = (menu.readLine(r, w, file_writer, key_prompt, &kbuf) catch continue) orelse continue; // Esc=取消整个编辑
                // Guard: typing menu-ish escape hatches ("q", "/quit") at the
                // value prompt used to store them AS the key — producing
                // confusing 401s on the next LLM call.
                if (std.mem.eql(u8, key, "q") or std.mem.eql(u8, key, "/quit") or std.mem.indexOfScalar(u8, key, ' ') != null) {
                    try std.Io.Writer.writeAll(w, "  (忽略：疑似误输入的命令/含空格，配置未更改)\n");
                    continue;
                }
                var ubuf: [256]u8 = undefined;
                var up: [160]u8 = undefined;
                const url_prompt = try_std_fmt(&up, "  Base URL（当前 {s}，-=恢复官方）: ", .{cur_url orelse "官方默认"});
                const url = (menu.readLine(r, w, file_writer, url_prompt, &ubuf) catch continue) orelse continue; // Esc=取消，零写入

                // 应用唯一规则（P1）。两字段都直接回车 → 未更改，不落盘。
                var new_key: ?[]const u8 = cur_key;
                var new_url: ?[]const u8 = cur_url;
                var changed = false;
                if (key.len > 0) {
                    new_key = if (std.mem.eql(u8, key, "-")) null else try alloc.dupe(u8, key);
                    changed = true;
                }
                if (url.len > 0) {
                    new_url = if (std.mem.eql(u8, url, "-")) null else try alloc.dupe(u8, url);
                    changed = true;
                }
                if (!changed) {
                    try std.Io.Writer.writeAll(w, "  未更改\n");
                    continue;
                }
                if (is_openai) {
                    switcher.settings.api_keys.openai = new_key;
                    switcher.settings.api_keys.openai_base_url = new_url;
                } else {
                    switcher.settings.api_keys.anthropic = new_key;
                    switcher.settings.api_keys.anthropic_base_url = new_url;
                }
                // Drop cached providers so the new key/URL takes effect now.
                if (switcher.openai_provider) |*p| {
                    p.deinit();
                    switcher.openai_provider = null;
                }
                if (switcher.claude_provider) |*p| {
                    p.deinit();
                    switcher.claude_provider = null;
                }
                autoSaveSettings(w, file_writer, switcher, alloc, io);
                try std.Io.Writer.print(w, "  ✓ 已保存  Key: {s} · Base URL: {s}\n", .{ if (new_key) |k| maskKey(k) else "(未配置)", new_url orelse "官方默认" });
                try std.Io.Writer.writeAll(w, "  （/model 可查看/切换模型）\n");
                try std.Io.File.Writer.flush(file_writer);
                // Routing hint: one TEXT line, never a menu (D3) — only when
                // the current model name routes to Ollama and would ignore
                // the gateway just configured.
                const want: llm.BackendType = if (is_openai) .openai else .claude;
                if (switcher.backend != want and switcher.backend == .ollama) {
                    try std.Io.Writer.print(w, "  提示：当前模型 {s} 按名称走 Ollama；要走此接入请用 /model 重选。\n", .{switcher.modelName()});
                    try std.Io.File.Writer.flush(file_writer);
                }
            },
            2 => {
                const cur: ?[]const u8 = switcher.settings.api_keys.brave_api_key;
                var pbuf: [96]u8 = undefined;
                const prompt = try_std_fmt(&pbuf, "  Brave Key（当前 {s}，回车=保留 · -=清除）: ", .{if (cur) |k| maskKey(k) else "(未配置)"});
                var vbuf: [256]u8 = undefined;
                const val = (menu.readLine(r, w, file_writer, prompt, &vbuf) catch continue) orelse continue;
                if (val.len > 0) {
                    switcher.settings.api_keys.brave_api_key = if (std.mem.eql(u8, val, "-")) null else try alloc.dupe(u8, val);
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                } else try std.Io.Writer.writeAll(w, "  未更改\n");
            },
            3 => {
                const cur: []const u8 = switcher.settings.api_keys.ollama_host;
                var pbuf: [128]u8 = undefined;
                const prompt = try_std_fmt(&pbuf, "  Ollama Host（当前 {s}，回车=保留）: ", .{cur});
                var vbuf: [256]u8 = undefined;
                const val = (menu.readLine(r, w, file_writer, prompt, &vbuf) catch continue) orelse continue;
                if (val.len > 0) {
                    switcher.settings.api_keys.ollama_host = try alloc.dupe(u8, val);
                    // The provider caches base_url at init — drop it so the
                    // new host takes effect this session.
                    if (switcher.ollama_provider) |*p| {
                        p.deinit();
                        switcher.ollama_provider = null;
                    }
                    autoSaveSettings(w, file_writer, switcher, alloc, io);
                    try std.Io.Writer.writeAll(w, "  （/model 可从网关列出本地模型）\n");
                } else try std.Io.Writer.writeAll(w, "  未更改\n");
            },
            else => break,
        }
    }
    try std.Io.Writer.writeAll(w, "\n");
}
var mask_buf: [16]u8 = undefined;

fn maskKey(key: []const u8) []const u8 {
    if (key.len <= 6) return "***";
    const prefix_len = @min(@as(usize, 3), key.len);
    const suffix_start = key.len - @min(@as(usize, 3), key.len);
    var i: usize = 0;
    for (key[0..prefix_len]) |ch| {
        mask_buf[i] = ch;
        i += 1;
    }
    mask_buf[i] = '.';
    i += 1;
    mask_buf[i] = '.';
    i += 1;
    mask_buf[i] = '.';
    i += 1;
    for (key[suffix_start..]) |ch| {
        mask_buf[i] = ch;
        i += 1;
    }
    return mask_buf[0..i];
}

/// Interactive model picker: arrow keys + Enter to switch at runtime.
pub fn runModelPicker(w: *std.Io.Writer, r: *std.Io.Reader, file_writer: *std.Io.File.Writer, switcher: *ModelSwitcher, io: std.Io) !void {
    // Pipes/scripts get the text table directly — the interactive picker
    // used to spin its redraw loop on the piped byte stream.
    if (!menu.isTty()) {
        try printModelInfo(w, switcher);
        return;
    }
    var labels: [llm.KNOWN_MODELS.len + 3][]const u8 = undefined;
    for (&llm.KNOWN_MODELS, 0..) |entry, i| {
        const marker: []const u8 = if (std.mem.eql(u8, entry.name, switcher.modelName())) " ●" else "";
        labels[i] = try std.fmt.allocPrint(std.heap.smp_allocator, "{s:<20} {s}{s}", .{ entry.name, entry.description, marker });
    }
    labels[llm.KNOWN_MODELS.len] = "自定义…（输入模型名，兼容网关可用）";
    // 网关发现的唯一入口（设计 §2.4）：从 API Keys 保存流程迁来——配置
    // 动作不再自动拉列表（D3），发现由用户在此主动触发。
    labels[llm.KNOWN_MODELS.len + 1] = "从网关列出模型（需已配 Key / Base URL）";
    labels[llm.KNOWN_MODELS.len + 2] = "取消 (q)";
    defer for (labels[0..llm.KNOWN_MODELS.len]) |l| std.heap.smp_allocator.free(l);

    const picked = menu.select(w, r, file_writer, "选择模型 (Enter 切换):", &labels, 0) catch {
        try printModelInfo(w, switcher);
        return;
    } orelse {
        try printModelInfo(w, switcher); // cancelled — show the table
        return;
    };

    if (picked == llm.KNOWN_MODELS.len + 2) return; // 取消
    if (picked == llm.KNOWN_MODELS.len + 1) {
        try offerGatewayModels(w, r, file_writer, switcher, std.heap.smp_allocator, io, switcher.backend);
        return;
    }
    const name: []const u8 = if (picked == llm.KNOWN_MODELS.len) blk: {
        break :blk (try promptCustomModel(w, r, file_writer, switcher, std.heap.smp_allocator)) orelse return;
    } else llm.KNOWN_MODELS[picked].name;
    switcher.switchModel(name) catch |err| {
        if (err == error.MissingApiKey) {
            const be: llm.BackendType = if (picked < llm.KNOWN_MODELS.len) llm.KNOWN_MODELS[picked].backend else switcher.effectiveBackend(name);
            try std.Io.Writer.print(w, "  Error: API key not configured for {s}.\n  Use /config to set keys.\n\n", .{be.label()});
        } else {
            try std.Io.Writer.print(w, "  Error switching model: {}\n\n", .{err});
        }
        return;
    };
    switcher.settings.default_model = name;
    config_mod.saveSettings(&switcher.settings, std.heap.smp_allocator, io) catch {};
    repl_mod.settings_fp_baseline = config_mod.settingsFingerprint(std.heap.smp_allocator, io);
    try std.Io.Writer.print(w, "  ✓ 已切换: {s} ({s})\n\n", .{ switcher.modelName(), switcher.backendLabel() });
}

fn printModelInfo(w: *std.Io.Writer, switcher: *ModelSwitcher) !void {
    try std.Io.Writer.writeAll(w, "\n  Current model: ");
    try std.Io.Writer.print(w, "{s} ({s})\n\n", .{ switcher.modelName(), switcher.backendLabel() });

    try std.Io.Writer.writeAll(w, "  Available models:\n");
    try std.Io.Writer.writeAll(w, "  ┌─────────────────────┬──────────┬────────────────────────────────┐\n");
    try std.Io.Writer.writeAll(w, "  │ Model               │ Backend  │ Description                    │\n");
    try std.Io.Writer.writeAll(w, "  ├─────────────────────┼──────────┼────────────────────────────────┤\n");

    for (&llm.KNOWN_MODELS) |entry| {
        const marker: []const u8 = if (std.mem.eql(u8, entry.name, switcher.modelName())) "*" else " ";
        const backend_str = switch (entry.backend) {
            .claude => "Claude",
            .openai => "OpenAI",
            .ollama => "Ollama",
        };
        // Bordered rows matching the header (the old space-padded rows
        // under a box header were the "table that isn't a table"); padding
        // is display-width aware so non-ASCII stays aligned.
        var cell: [40]u8 = undefined;
        const name_cell = std.fmt.bufPrint(&cell, "{s} {s}", .{ marker, entry.name }) catch entry.name;
        try std.Io.Writer.writeAll(w, "  │ ");
        try format_mod.writePadded(w, name_cell, 19);
        try std.Io.Writer.writeAll(w, " │ ");
        try format_mod.writePadded(w, backend_str, 8);
        try std.Io.Writer.writeAll(w, " │ ");
        try format_mod.writePadded(w, entry.description, 30);
        try std.Io.Writer.writeAll(w, " │\n");
    }
    try std.Io.Writer.writeAll(w, "  └─────────────────────┴──────────┴────────────────────────────────┘\n");

    try std.Io.Writer.writeAll(w, "\n  * = current model\n");
    try std.Io.Writer.writeAll(w, "  Usage: /model <name>  (e.g. /model claude-sonnet-4-6)\n\n");
}
