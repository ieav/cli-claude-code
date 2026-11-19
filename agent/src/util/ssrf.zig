//! SSRF 地址闸（T6.1b，2026-11-19）：WebFetch 进连接前解析 host 并
//! 校验落点——环回 / RFC1918 / CGNAT / 链路本地 / IPv6 ULA / v4 映射
//! v6 / NAT64 全拒。WebFetch 原先只有 http(s) 前缀检查，且 std http
//! 默认透明跟随 3 跳重定向、换 host 不再校验（web_fetch.zig 手动逐跳
//! 后由本模块在每一跳复验）。
//!
//! shortcut: 本模块校验「自己 resolve 的地址」与 std.http.Client 内部
//! 的 resolve 之间存在 TOCTOU 窗口（DNS rebinding 理论可绕）；单机
//! CLI 威胁模型下接受，std 暴露注入式连接（绑定预解析 IP）时消除。

const std = @import("std");

/// 单个地址是否允许出站：所有内网/环回/链路本地形态拒绝。
pub fn addressAllowed(addr: std.Io.net.IpAddress) bool {
    switch (addr) {
        .ip4 => |v4| return v4Allowed(v4.bytes),
        .ip6 => |v6| {
            const b = v6.bytes;
            // ::（未指定）与 ::1（环回）
            if (std.mem.allEqual(u8, b[0..15], 0) and (b[15] == 0 or b[15] == 1)) return false;
            // ::ffff:0:0/96 —— v4 映射：按内嵌 v4 判
            if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) {
                return v4Allowed(b[12..16].*);
            }
            // 64:ff9b::/96 —— NAT64：内嵌 v4 判
            if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b and
                std.mem.allEqual(u8, b[4..8], 0) and std.mem.allEqual(u8, b[8..12], 0))
            {
                return v4Allowed(b[12..16].*);
            }
            // fc00::/7 ULA（含 fd 私有段）
            if ((b[0] & 0xfe) == 0xfc) return false;
            // fe80::/10 链路本地
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return false;
            return true;
        },
    }
}

fn v4Allowed(b: [4]u8) bool {
    // 0.0.0.0/8（「本网络」）与 10/8（RFC1918）
    if (b[0] == 0 or b[0] == 10) return false;
    // 100.64/10（CGNAT 共享地址）
    if (b[0] == 100 and (b[1] & 0xc0) == 64) return false;
    // 127/8（环回）
    if (b[0] == 127) return false;
    // 169.254/16（链路本地，含云元数据 169.254.169.254）
    if (b[0] == 169 and b[1] == 254) return false;
    // 172.16/12（RFC1918）
    if (b[0] == 172 and (b[1] & 0xf0) == 16) return false;
    // 192.168/16（RFC1918）
    if (b[0] == 192 and b[1] == 168) return false;
    return true;
}

/// host 文本（字面 IP 或域名）→ resolve → 校验。解析失败按拒（fail
/// closed：一个连 DNS 都查不到的 host 没有放行的理由）。
pub fn hostAllowed(io: std.Io, host: []const u8) bool {
    if (host.len == 0) return false;
    const addr = std.Io.net.IpAddress.resolve(io, host, 0) catch return false;
    return addressAllowed(addr);
}

test "T6.1b addressAllowed: private/loopback/link-local all rejected, public passes" {
    const p4 = struct {
        fn f(a: u8, b: u8, c: u8, d: u8) std.Io.net.IpAddress {
            return .{ .ip4 = .{ .bytes = .{ a, b, c, d }, .port = 0 } };
        }
    };
    // 拒绝清单
    try std.testing.expect(!addressAllowed(p4.f(127, 0, 0, 1))); // 环回
    try std.testing.expect(!addressAllowed(p4.f(127, 8, 8, 8))); // 环回任意
    try std.testing.expect(!addressAllowed(p4.f(0, 0, 0, 0))); // 未指定
    try std.testing.expect(!addressAllowed(p4.f(10, 1, 1, 1))); // RFC1918
    try std.testing.expect(!addressAllowed(p4.f(172, 16, 0, 1))); // RFC1918
    try std.testing.expect(!addressAllowed(p4.f(172, 31, 255, 255))); // RFC1918 上界
    try std.testing.expect(!addressAllowed(p4.f(192, 168, 1, 1))); // RFC1918
    try std.testing.expect(!addressAllowed(p4.f(169, 254, 169, 254))); // 云元数据
    try std.testing.expect(!addressAllowed(p4.f(100, 64, 0, 1))); // CGNAT
    // 放行
    try std.testing.expect(addressAllowed(p4.f(1, 1, 1, 1)));
    try std.testing.expect(addressAllowed(p4.f(8, 8, 8, 8)));
    try std.testing.expect(addressAllowed(p4.f(172, 32, 0, 1))); // 172.32 在 /12 之外
    try std.testing.expect(addressAllowed(p4.f(100, 128, 0, 1))); // CGNAT 之外

    // IPv6 形态
    try std.testing.expect(!addressAllowed(.{ .ip6 = .{ .bytes = ip6(&.{ 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1 }), .port = 0 } })); // ::1
    try std.testing.expect(!addressAllowed(.{ .ip6 = .{ .bytes = ip6(&.{ 0xfd,0x12,0,0,0,0,0,0,0,0,0,0,0,0,0,1 }), .port = 0 } })); // fd ULA
    try std.testing.expect(!addressAllowed(.{ .ip6 = .{ .bytes = ip6(&.{ 0xfe,0x80,0,0,0,0,0,0,0,0,0,0,0,0,0,1 }), .port = 0 } })); // fe80
    // ::ffff:127.0.0.1（v4 映射按内嵌 v4 拒）
    try std.testing.expect(!addressAllowed(.{ .ip6 = .{ .bytes = ip6(&.{ 0,0,0,0,0,0,0,0,0,0,0xff,0xff,127,0,0,1 }), .port = 0 } }));
    // 公网 v6 放行（2001:db8::1）
    try std.testing.expect(addressAllowed(.{ .ip6 = .{ .bytes = ip6(&.{ 0x20,0x01,0x0d,0xb8,0,0,0,0,0,0,0,0,0,0,0,1 }), .port = 0 } }));
}

fn ip6(b: *const [16]u8) [16]u8 {
    return b.*;
}
