/// Single source of truth for the ziv version. The startup banner, the
/// REPL /version command, `ziv --version`, and release.sh all read this
/// constant — release.sh extracts it with a regex, so keep the exact form:
///   pub const version = "X.Y.Z";
pub const version = "0.6.0";

const std = @import("std");

test "version is three numeric dot-fields" {
    var it = std.mem.splitScalar(u8, version, '.');
    var fields: usize = 0;
    while (it.next()) |part| {
        try std.testing.expect(part.len > 0);
        for (part) |c| try std.testing.expect(c >= '0' and c <= '9');
        fields += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), fields);
}
