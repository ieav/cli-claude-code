/// HTTP client — simple HTTP GET with retry support.
/// Compatible with Zig 0.16 HTTP Client API.
const std = @import("std");
const e_growth = @import("../math/e_growth.zig");

pub const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
    content_type: ?[]const u8,
};

/// HTTP GET request with exponential backoff retry.
/// Caller owns the body slice.
pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    max_retries: u32,
) !HttpResponse {
    var last_error: ?anyerror = null;
    var attempt: u32 = 0;

    while (attempt < max_retries) : (attempt += 1) {
        if (attempt > 0) {
            const delay = e_growth.retryDelay(1000, attempt, 30000);
            std.time.sleep(delay * std.time.ns_per_ms);
        }

        var client = std.http.Client{ .allocator = allocator, .io = io };
        defer client.deinit();

        const uri = std.Uri.parse(url) catch {
            last_error = error.InvalidUrl;
            continue;
        };

        const extra_headers = [_]std.http.Header{};

        var req = client.request(.GET, uri, .{
            .extra_headers = &extra_headers,
        }) catch |err| {
            last_error = err;
            continue;
        };
        defer req.deinit();

        req.sendBodyComplete(@constCast("")) catch |err| {
            last_error = err;
            continue;
        };

        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            last_error = err;
            continue;
        };

        const body = body: {
            var body_buf: [1024 * 1024]u8 = undefined;
            const reader = response.reader(&body_buf);
            break :body reader.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch |err| {
                last_error = err;
                continue;
            };
        };

        return .{
            .status_code = @backingInt(response.head.status),
            .body = body,
            .content_type = response.head.content_type,
        };
    }

    return last_error orelse error.HttpRequestFailed;
}
