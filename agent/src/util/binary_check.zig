/// Binary file detection — check if a file contains binary content.
const std = @import("std");

/// Check if a byte slice appears to be binary data.
/// Uses heuristic: if the first 8KB contain a null byte before any text,
/// or contain a high ratio of non-text bytes, it's binary.
pub fn isBinary(data: []const u8) bool {
    const check_len = @min(data.len, 8192);
    if (check_len == 0) return false;

    var non_text: usize = 0;
    for (data[0..check_len]) |byte| {
        if (byte == 0) return true; // null byte = definitely binary
        if (byte > 0x7F or (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t')) {
            non_text += 1;
        }
    }

    // If >30% non-text bytes, likely binary
    const ratio = @as(f64, @floatFromInt(non_text)) / @as(f64, @floatFromInt(check_len));
    return ratio > 0.3;
}

/// Check if a file path has a known binary extension.
pub fn hasBinaryExtension(path: []const u8) bool {
    const binary_exts = [_][]const u8{
        ".png",  ".jpg",   ".jpeg", ".gif",    ".bmp",   ".ico", ".webp",
        ".pdf",  ".zip",   ".tar",  ".gz",     ".bz2",   ".xz",  ".7z",
        ".exe",  ".dll",   ".so",   ".dylib",  ".o",     ".a",   ".lib",
        ".woff", ".woff2", ".ttf",  ".eot",    ".otf",   ".mp3", ".mp4",
        ".avi",  ".mov",   ".wav",  ".flac",   ".class", ".jar", ".war",
        ".pyc",  ".pyd",   ".wasm", ".sqlite", ".db",
    };

    for (binary_exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

test "isBinary text" {
    try std.testing.expect(!isBinary("Hello, world!\nThis is text."));
}

test "isBinary null" {
    try std.testing.expect(isBinary("Hello\x00World"));
}

test "hasBinaryExtension" {
    try std.testing.expect(hasBinaryExtension("image.png"));
    try std.testing.expect(hasBinaryExtension("/path/to/file.pdf"));
    try std.testing.expect(!hasBinaryExtension("main.zig"));
    try std.testing.expect(!hasBinaryExtension("README.md"));
}
