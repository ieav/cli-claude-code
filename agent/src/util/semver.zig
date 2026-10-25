/// Semantic versioning — parse and compare versions.
const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: ?[]const u8 = null,

    pub fn init(major: u32, minor: u32, patch: u32) Version {
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    /// Parse a version string like "1.2.3" or "1.2.3-beta.1".
    pub fn parse(s: []const u8) ?Version {
        var parts = std.mem.splitSequence(u8, s, "-");
        const version_part = parts.first();
        const pre_part = parts.next();

        var nums = std.mem.splitSequence(u8, version_part, ".");
        const major_str = nums.next() orelse return null;
        const minor_str = nums.next() orelse return null;
        const patch_str = nums.next() orelse return null;

        return .{
            .major = std.fmt.parseInt(u32, major_str, 10) catch return null,
            .minor = std.fmt.parseInt(u32, minor_str, 10) catch return null,
            .patch = std.fmt.parseInt(u32, patch_str, 10) catch return null,
            .pre = pre_part,
        };
    }

    pub fn eql(a: Version, b: Version) bool {
        return a.major == b.major and a.minor == b.minor and a.patch == b.patch;
    }

    pub fn gt(a: Version, b: Version) bool {
        if (a.major != b.major) return a.major > b.major;
        if (a.minor != b.minor) return a.minor > b.minor;
        return a.patch > b.patch;
    }

    pub fn gte(a: Version, b: Version) bool {
        return a.eql(b) or a.gt(b);
    }

    pub fn lt(a: Version, b: Version) bool {
        return !a.gte(b);
    }

    /// Format as "major.minor.patch".
    pub fn format(self: Version, buf: *[32]u8) []const u8 {
        if (self.pre) |pre| {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}-{s}", .{ self.major, self.minor, self.patch, pre }) catch "0.0.0";
        }
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch }) catch "0.0.0";
    }
};

test "Version parse" {
    const v = Version.parse("1.2.3").?;
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 2), v.minor);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
}

test "Version compare" {
    const v1 = Version.parse("1.2.3").?;
    const v2 = Version.parse("1.2.4").?;
    try std.testing.expect(v1.lt(v2));
    try std.testing.expect(v2.gt(v1));
    try std.testing.expect(!v1.eql(v2));
}

test "Version pre-release" {
    const v = Version.parse("0.16.0-dev").?;
    try std.testing.expect(v.pre != null);
    try std.testing.expectEqualStrings("dev", v.pre.?);
}
