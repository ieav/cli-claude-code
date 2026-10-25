/// Utility modules — collection of reusable tools from Claude Code CLI patterns.
pub const cancel = @import("cancel.zig");
pub const shell_quote = @import("shell_quote.zig");
pub const hash = @import("hash.zig");
pub const uuid = @import("uuid.zig");
pub const log = @import("log.zig");
pub const format = @import("format.zig");
pub const string_utils = @import("string_utils.zig");
pub const path = @import("path.zig");
pub const platform = @import("platform.zig");
pub const env = @import("env.zig");
pub const system_dirs = @import("system_dirs.zig");
pub const json_helpers = @import("json_helpers.zig");
pub const tokens = @import("tokens.zig");
pub const time = @import("time.zig");
pub const file_cache = @import("file_cache.zig");
pub const binary_check = @import("binary_check.zig");
pub const find_executable = @import("find_executable.zig");
pub const sanitization = @import("sanitization.zig");
pub const subprocess = @import("subprocess.zig");
pub const cleanup = @import("cleanup.zig");
pub const tempfile = @import("tempfile.zig");
pub const diff = @import("diff.zig");
pub const fs_ops = @import("fs_ops.zig");
pub const lockfile = @import("lockfile.zig");
pub const semver = @import("semver.zig");
pub const memoize = @import("memoize.zig");
pub const glob_match = @import("glob_match.zig");
pub const ripgrep = @import("ripgrep.zig");
pub const http_client = @import("http_client.zig");

// Re-export common types
pub const CancelToken = cancel.CancelToken;
pub const FileStateCache = file_cache.FileStateCache;
pub const TokenBudget = tokens.TokenBudget;
pub const Version = semver.Version;
