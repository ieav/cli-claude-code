/// Platform detection — OS, architecture, paths.
const std = @import("std");

pub const Os = enum {
    linux,
    macos,
    windows,
    bsd,
    unknown,

    pub fn current() Os {
        return switch (std.Target.current.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            .freebsd, .netbsd, .openbsd, .dragonfly => .bsd,
            else => .unknown,
        };
    }

    pub fn isUnix(self: Os) bool {
        return switch (self) {
            .linux, .macos, .bsd => true,
            else => false,
        };
    }

    pub fn shell(self: Os) []const u8 {
        return switch (self) {
            .windows => "cmd.exe",
            else => "/bin/sh",
        };
    }
};

pub const Arch = enum {
    x86_64,
    aarch64,
    riscv64,
    unknown,

    pub fn current() Arch {
        return switch (std.Target.current.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .riscv64 => .riscv64,
            else => .unknown,
        };
    }
};

test "platform detection" {
    const os = Os.current();
    try std.testing.expect(os != .unknown);
}
