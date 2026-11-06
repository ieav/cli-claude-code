//! ModelSwitcher — the active model state (name buffer, backend, lazily
//! built providers, parked retired providers) plus the settings-reload
//! satellites that swap settings in place. Carved out of repl.zig
//! (P1 step 7a, pure move); repl.zig re-exports the type.

const std = @import("std");
const llm = @import("../llm/mod.zig");
const config_mod = @import("../config.zig");
const logger = @import("../util/log.zig");

const allocator = std.heap.smp_allocator; // same stateless global as repl.zig

/// Active model state — holds the current model name and the provider instance.
pub const ModelSwitcher = struct {
    model_name_buf: [64]u8 = undefined,
    model_name_len: usize = 0,
    backend: llm.BackendType,
    io: std.Io,
    openai_provider: ?llm.OpenAIProvider = null,
    claude_provider: ?llm.ClaudeProvider = null,
    ollama_provider: ?llm.OllamaProvider = null,
    /// A provider retired by a model switch but NOT deinit'd yet: a
    /// detached reflection worker (3 s deadline abandon) may still be
    /// running a request on it — deinit-ing in place was a use-after-free
    /// on /model switches. Parked here and freed at switcher deinit
    /// (process exit). At most one detached worker exists at a time, so
    /// one slot suffices.
    retired: ?RetiredProvider = null,
    settings: config_mod.Settings,

    const RetiredProvider = union(enum) {
        openai: llm.OpenAIProvider,
        claude: llm.ClaudeProvider,
        ollama: llm.OllamaProvider,
    };

    const Self = @This();

    pub fn modelName(self: *const Self) []const u8 {
        return self.model_name_buf[0..self.model_name_len];
    }

    /// Park the current provider of `backend` into the retired slot instead
    /// of deinit-ing it (the slot is nulled either way, so getProvider
    /// rebuilds with the new model name — semantics unchanged).
    fn retireProvider(self: *Self, backend: llm.BackendType) void {
        if (self.retired != null) self.freeRetired(); // previous retiree must die now
        switch (backend) {
            .openai => if (self.openai_provider) |p| {
                self.retired = .{ .openai = p };
                self.openai_provider = null;
            },
            .claude => if (self.claude_provider) |p| {
                self.retired = .{ .claude = p };
                self.claude_provider = null;
            },
            .ollama => if (self.ollama_provider) |p| {
                self.retired = .{ .ollama = p };
                self.ollama_provider = null;
            },
        }
    }

    fn freeRetired(self: *Self) void {
        if (self.retired) |*r| {
            switch (r.*) {
                .openai => |*p| p.deinit(),
                .claude => |*p| p.deinit(),
                .ollama => |*p| p.deinit(),
            }
            self.retired = null;
        }
    }

    /// Backend routing, in priority order:
    ///   1. known-model table entry (authoritative — an override must not
    ///      hijack claude-*/gpt-*/table models after pinning a custom name)
    ///   2. recognizable name prefixes (claude-*, gpt-*, …)
    ///   3. explicit settings.default_backend — rescues UNRECOGNIZED names
    ///      (glm-4.6, deepseek-v3, …) into a configured compatible gateway
    ///   4. Ollama fallback (the old behavior)
    pub fn effectiveBackend(self: *const Self, model: []const u8) llm.BackendType {
        if (llm.findKnownModel(model)) |entry| return entry.backend;
        const detected = llm.detectBackend(model);
        if (detected != .ollama) return detected;
        if (self.settings.default_backend) |b| {
            if (std.meta.stringToEnum(llm.BackendType, b)) |be| return be;
        }
        return .ollama;
    }

    pub fn init(settings: config_mod.Settings, io: std.Io) Self {
        const model = settings.default_model;
        const len = @min(model.len, 64);
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..len], model[0..len]);
        var switcher = Self{
            .model_name_buf = buf,
            .model_name_len = len,
            .backend = llm.detectBackend(model),
            .io = io,
            .settings = settings,
        };
        switcher.backend = switcher.effectiveBackend(model);
        return switcher;
    }

    pub fn deinit(self: *Self) void {
        if (self.openai_provider) |*p| p.deinit();
        if (self.claude_provider) |*p| p.deinit();
        if (self.ollama_provider) |*p| p.deinit();
        self.freeRetired();
    }

    /// Switch to a new model. Returns error if API key is missing.
    pub fn switchModel(self: *Self, new_model: []const u8) !void {
        const new_backend = self.effectiveBackend(new_model);

        // Validate API key availability before switching
        switch (new_backend) {
            .openai => {
                if (self.settings.api_keys.openai == null) {
                    return error.MissingApiKey;
                }
            },
            .claude => {
                if (self.settings.api_keys.anthropic == null) {
                    return error.MissingApiKey;
                }
            },
            .ollama => {},
        }

        // Park the old provider of the same backend type in `retired`
        // (deinit-in-place was a UAF for a detached reflection worker
        // still mid-request on it; see retireProvider).
        self.retireProvider(new_backend);

        // Re-pin the backend without changing the name may pass the CURRENT
        // name back in (switchModel(modelName()) from the gateway pin flow):
        // skip the copy — @memcpy with aliasing src/dst is a panic in Zig.
        if (!std.mem.eql(u8, new_model[0..@min(new_model.len, 64)], self.modelName())) {
            const len = @min(new_model.len, 64);
            @memcpy(self.model_name_buf[0..len], new_model[0..len]);
            self.model_name_len = len;
        }
        self.backend = new_backend;

        logger.info("Model switched: {s} (backend={s})", .{ new_model, @tagName(new_backend) });
    }

    /// Get or create the provider for the current model.
    pub fn getProvider(self: *Self) !llm.Provider {
        switch (self.backend) {
            .openai => {
                if (self.openai_provider == null) {
                    const api_key = self.settings.api_keys.openai orelse return error.MissingApiKey;
                    self.openai_provider = llm.OpenAIProvider.init(allocator, self.io, .{
                        .api_key = api_key,
                        .model = self.modelName(),
                        .base_url = self.settings.api_keys.openai_base_url orelse "https://api.openai.com/v1",
                    });
                }
                return self.openai_provider.?.toProvider();
            },
            .claude => {
                if (self.claude_provider == null) {
                    const api_key = self.settings.api_keys.anthropic orelse return error.MissingApiKey;
                    self.claude_provider = llm.ClaudeProvider.init(allocator, self.io, .{
                        .api_key = api_key,
                        .model = self.modelName(),
                        .base_url = self.settings.api_keys.anthropic_base_url orelse "https://api.anthropic.com",
                    });
                }
                return self.claude_provider.?.toProvider();
            },
            .ollama => {
                if (self.ollama_provider == null) {
                    self.ollama_provider = llm.OllamaProvider.init(allocator, self.io, .{
                        .model = self.modelName(),
                        .base_url = self.settings.api_keys.ollama_host,
                    });
                }
                return self.ollama_provider.?.toProvider();
            },
        }
    }

    pub fn backendLabel(self: *const Self) []const u8 {
        return switch (self.backend) {
            .openai => "OpenAI",
            .claude => "Claude",
            .ollama => "Ollama",
        };
    }
};

/// Swap in freshly loaded (hot-reloaded) settings, dropping cached providers
/// whose credentials changed so the next getProvider() rebuilds them.
pub fn applyReloadedSettings(switcher: *ModelSwitcher, fresh: config_mod.Settings) void {
    invalidateStaleProviders(switcher, &fresh);
    switcher.settings = fresh;
}

/// Old settings slices are intentionally not freed: reloads happen once per
/// external file edit (rare), and a bounded leak is cheaper than retrofitting
/// ownership through every Settings consumer.
fn invalidateStaleProviders(switcher: *ModelSwitcher, fresh: *const config_mod.Settings) void {
    const differs = struct {
        fn f(a: ?[]const u8, b: ?[]const u8) bool {
            if (a == null and b == null) return false;
            if (a == null or b == null) return true;
            return !std.mem.eql(u8, a.?, b.?);
        }
    }.f;
    const old = switcher.settings;
    if (switcher.openai_provider != null and
        (differs(old.api_keys.openai, fresh.api_keys.openai) or
            differs(old.api_keys.openai_base_url, fresh.api_keys.openai_base_url)))
    {
        if (switcher.openai_provider) |*p| p.deinit();
        switcher.openai_provider = null;
    }
    if (switcher.claude_provider != null and
        (differs(old.api_keys.anthropic, fresh.api_keys.anthropic) or
            differs(old.api_keys.anthropic_base_url, fresh.api_keys.anthropic_base_url)))
    {
        if (switcher.claude_provider) |*p| p.deinit();
        switcher.claude_provider = null;
    }
    if (switcher.ollama_provider != null and
        !std.mem.eql(u8, old.api_keys.ollama_host, fresh.api_keys.ollama_host))
    {
        if (switcher.ollama_provider) |*p| p.deinit();
        switcher.ollama_provider = null;
    }
}
