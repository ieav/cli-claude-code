/// Web search integration — queries external search APIs for knowledge.
/// Supports multiple backends: Brave, SearXNG, DuckDuckGo (HTML fallback).
/// Uses std.http.Client for real HTTP requests (Zig 0.16 API).
const std = @import("std");
const math = @import("../math/mod.zig");

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
    relevance: f64, // 0-1

    pub fn clone(self: SearchResult, allocator: std.mem.Allocator) !SearchResult {
        return .{
            .title = try allocator.dupe(u8, self.title),
            .url = try allocator.dupe(u8, self.url),
            .snippet = try allocator.dupe(u8, self.snippet),
            .relevance = self.relevance,
        };
    }

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.snippet);
    }
};

pub const SearchBackend = enum {
    brave,
    searxng,
    duckduckgo,
};

pub const WebSearch = struct {
    allocator: std.mem.Allocator,
    backend: SearchBackend,
    api_key: ?[]const u8,
    base_url: []const u8,
    http_client: std.http.Client,
    total_searches: std.atomic.Value(usize),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, backend: SearchBackend, api_key: ?[]const u8) Self {
        const env = @import("../util/env.zig");
        const base_url: []const u8 = switch (backend) {
            .brave => env.get("ZIV_BRAVE_URL") orelse "https://api.search.brave.com/res/v1/web/search",
            .searxng => env.get("ZIV_SEARXNG_URL") orelse "http://localhost:8888/search",
            // ZIV_DDGO_URL exists so tests can point the keyless backend at a mock.
            .duckduckgo => env.get("ZIV_DDGO_URL") orelse "https://html.duckduckgo.com/html/",
        };
        return .{
            .allocator = allocator,
            .backend = backend,
            .api_key = api_key,
            .base_url = base_url,
            .http_client = .{ .allocator = allocator, .io = io },
            .total_searches = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.api_key) |k| self.allocator.free(k);
        self.http_client.deinit();
    }

    /// Search the web for a query. Returns owned slice of results.
    pub fn search(self: *Self, query: []const u8, max_results: usize) ![]SearchResult {
        _ = self.total_searches.fetchAdd(1, .monotonic);

        return self.searchOnce(query, max_results) catch |err| {
            // Back off once on rate limiting instead of failing outright.
            if (err != error.RateLimited) return err;
            var req: std.c.timespec = .{ .sec = 1, .nsec = 0 };
            _ = std.c.nanosleep(&req, null);
            return self.searchOnce(query, max_results);
        };
    }

    fn searchOnce(self: *Self, query: []const u8, max_results: usize) ![]SearchResult {
        return switch (self.backend) {
            .brave => try self.searchBrave(query, max_results),
            .searxng => try self.searchSearXNG(query, max_results),
            .duckduckgo => try self.searchDuckDuckGo(query, max_results),
        };
    }

    /// Search using Brave Search API.
    /// Requires API key set in self.api_key.
    fn searchBrave(self: *Self, query: []const u8, max_results: usize) ![]SearchResult {
        const api_key = self.api_key orelse return error.ApiKeyRequired;

        const encoded_query = try self.urlEncode(query);
        defer self.allocator.free(encoded_query);

        const url = try self.allocator.print(
            "{s}?q={s}&count={d}",
            .{ self.base_url, encoded_query, max_results },
        );
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        const auth_value = try self.allocator.print("Bearer {s}", .{api_key});
        defer self.allocator.free(auth_value);

        var req = try self.http_client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "authorization", .value = auth_value },
            },
        });
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status == .too_many_requests) return error.RateLimited;
        if (response.head.status.class() != .success) {
            return error.SearchRequestFailed;
        }

        const response_body = try self.readResponseBody(&response);
        defer self.allocator.free(response_body);

        return self.parseBraveResults(response_body, max_results);
    }

    /// Parse Brave Search API JSON response.
    fn parseBraveResults(self: *Self, body: []const u8, max_results: usize) ![]SearchResult {
        // parseFromSlice (not Leaky): the DOM lives in its own arena and is
        // freed below — Leaky on the long-lived allocator leaked the whole
        // tree on every search (up to the 4 MB body cap).
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch
            return &.{};
        defer parsed.deinit();
        const web_results = parsed.value.object.get("web") orelse return &.{};
        const results_array = web_results.object.get("results") orelse return &.{};

        var output = std.ArrayList(SearchResult).empty;
        // Any `try` below (OOM) must not leak the entries already built.
        errdefer {
            for (output.items) |*r| r.deinit(self.allocator);
        }
        const count = @min(results_array.array.items.len, max_results);

        for (results_array.array.items[0..count], 0..) |item, i| {
            // Validate tags BEFORE duping anything: the old order duped the
            // title first and `continue`d on a missing/非字符串 url, leaking
            // it on every malformed item.
            const title_val = item.object.get("title") orelse continue;
            if (title_val != .string) continue;
            const url_field = item.object.get("url") orelse continue;
            if (url_field != .string) continue;
            const title = try self.allocator.dupe(u8, title_val.string);
            const url_val = try self.allocator.dupe(u8, url_field.string);
            const snippet = if (item.object.get("description")) |d|
                if (d == .string) try self.allocator.dupe(u8, d.string) else try self.allocator.dupe(u8, "")
            else
                try self.allocator.dupe(u8, "");

            const relevance = 1.0 - @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(count, 1)));

            try output.append(self.allocator, .{
                .title = title,
                .url = url_val,
                .snippet = snippet,
                .relevance = relevance,
            });
        }

        return output.toOwnedSlice(self.allocator);
    }

    /// Search using SearXNG instance (self-hosted metasearch).
    fn searchSearXNG(self: *Self, query: []const u8, max_results: usize) ![]SearchResult {
        const encoded_query = try self.urlEncode(query);
        defer self.allocator.free(encoded_query);

        const url = try self.allocator.print(
            "{s}?q={s}&format=json&categories=general",
            .{ self.base_url, encoded_query },
        );
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);

        var req = try self.http_client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
            },
        });
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status == .too_many_requests) return error.RateLimited;
        if (response.head.status.class() != .success) {
            return error.SearchRequestFailed;
        }

        const response_body = try self.readResponseBody(&response);
        defer self.allocator.free(response_body);

        return self.parseSearXNGResults(response_body, max_results);
    }

    /// Parse SearXNG JSON response.
    fn parseSearXNGResults(self: *Self, body: []const u8, max_results: usize) ![]SearchResult {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch
            return &.{};
        defer parsed.deinit();
        const results_array = parsed.value.object.get("results") orelse return &.{};

        var output = std.ArrayList(SearchResult).empty;
        // Any `try` below (OOM) must not leak the entries already built.
        errdefer {
            for (output.items) |*r| r.deinit(self.allocator);
        }
        const count = @min(results_array.array.items.len, max_results);

        for (results_array.array.items[0..count], 0..) |item, i| {
            // Validate tags BEFORE duping anything — same leak as the Brave
            // parser: a duped title was abandoned by the url `continue`.
            const title_val = item.object.get("title") orelse continue;
            if (title_val != .string) continue;
            const url_field = item.object.get("url") orelse continue;
            if (url_field != .string) continue;
            const title = try self.allocator.dupe(u8, title_val.string);
            const url_val = try self.allocator.dupe(u8, url_field.string);
            const snippet = if (item.object.get("content")) |c|
                if (c == .string) try self.allocator.dupe(u8, c.string) else try self.allocator.dupe(u8, "")
            else
                try self.allocator.dupe(u8, "");

            const relevance = 1.0 - @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(count, 1)));

            try output.append(self.allocator, .{
                .title = title,
                .url = url_val,
                .snippet = snippet,
                .relevance = relevance,
            });
        }

        return output.toOwnedSlice(self.allocator);
    }

    /// Search using DuckDuckGo HTML endpoint (no API key needed).
    fn searchDuckDuckGo(self: *Self, query: []const u8, max_results: usize) ![]SearchResult {
        const encoded_query = try self.urlEncode(query);
        defer self.allocator.free(encoded_query);

        const post_body = try self.allocator.print("q={s}", .{encoded_query});
        defer self.allocator.free(post_body);

        const uri = try std.Uri.parse(self.base_url);

        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
                .{ .name = "user-agent", .value = "ZageAgent/1.0" },
            },
        });
        defer req.deinit();

        // Send POST body
        req.transfer_encoding = .{ .content_length = post_body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(post_body);
        try body_writer.end();
        try req.connection.?.flush();

        var redirect_buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status == .too_many_requests) return error.RateLimited;
        if (response.head.status.class() != .success) {
            return error.SearchRequestFailed;
        }

        const response_body = try self.readResponseBody(&response);
        defer self.allocator.free(response_body);

        return self.parseDuckDuckGoHTML(response_body, max_results);
    }

    /// Read the full response body into an allocated buffer.
    fn readResponseBody(self: *Self, response: *std.http.Client.Response) ![]u8 {
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const raw = try readAllCapped(reader, self.allocator);
        errdefer self.allocator.free(raw);

        // Decompress transparently. Some servers (DDG over HTTP/1.1) send
        // gzip bodies WITHOUT a Content-Encoding header, so sniff the magic
        // bytes in addition to trusting the header.
        const container: ?std.compress.flate.Container = if (response.head.content_encoding == .gzip or
            (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b))
            .gzip
        else if (response.head.content_encoding == .deflate)
            .zlib
        else
            null;

        if (container) |c| {
            defer self.allocator.free(raw);
            var in_reader = std.Io.Reader.fixed(raw);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var d = std.compress.flate.Decompress.init(&in_reader, c, &window);
            return readAllCapped(&d.reader, self.allocator);
        }
        return raw;
    }

    /// Read a body chunk-by-chunk instead of allocRemaining: some servers
    /// (DDG) close the stream without the standard chunked terminator, which
    /// makes allocRemaining fail even though the body arrived intact.
    /// Keep whatever was read; cap at 4 MB.
    fn readAllCapped(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        var chunk: [8192]u8 = undefined;
        while (list.items.len < 4 * 1024 * 1024) {
            const n = reader.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try list.appendSlice(allocator, chunk[0..n]);
        }
        return list.toOwnedSlice(allocator);
    }

    /// Parse DuckDuckGo HTML response to extract results.
    /// DDG HTML uses <a class="result__a" href="...">Title</a> and <a class="result__snippet">...
    fn parseDuckDuckGoHTML(self: *Self, html: []const u8, max_results: usize) ![]SearchResult {
        var results = std.ArrayList(SearchResult).empty;
        var pos: usize = 0;

        while (pos < html.len and results.items.len < max_results) {
            // DDG renders result links as <a rel="nofollow" class="result__a" href="…">
            // — attribute order varies, so match on the class alone.
            const class_marker = "class=\"result__a\"";
            const title_start = std.mem.indexOfPos(u8, html, pos, class_marker) orelse break;
            const href_start = std.mem.indexOfPos(u8, html, title_start, "href=\"") orelse break;
            const href_begin = href_start + 6;
            const href_end = std.mem.indexOfScalar(u8, html[href_begin..], '"') orelse break;
            const url = html[href_begin .. href_begin + href_end];

            const tag_end = std.mem.indexOfScalar(u8, html[title_start..], '>') orelse break;
            const title_begin = title_start + tag_end + 1;
            const title_end = std.mem.indexOfScalar(u8, html[title_begin..], '<') orelse break;
            const title = html[title_begin .. title_begin + title_end];

            var snippet: []const u8 = "";
            const snippet_marker = "result__snippet";
            if (std.mem.indexOfPos(u8, html, title_begin, snippet_marker)) |snip_pos| {
                const snip_tag_end = std.mem.indexOfScalar(u8, html[snip_pos..], '>') orelse {
                    pos = title_begin + 1;
                    continue;
                };
                const snip_begin = snip_pos + snip_tag_end + 1;
                const snip_end = std.mem.indexOfScalar(u8, html[snip_begin..], '<') orelse {
                    pos = title_begin + 1;
                    continue;
                };
                snippet = html[snip_begin .. snip_begin + snip_end];
            }

            const idx = results.items.len;
            const relevance = 1.0 - @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(@max(max_results, 1)));

            try results.append(self.allocator, .{
                .title = try self.allocator.dupe(u8, title),
                .url = try self.allocator.dupe(u8, url),
                .snippet = try self.allocator.dupe(u8, snippet),
                .relevance = relevance,
            });

            pos = title_begin + 1;
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// URL-encode a query string for use in search URLs.
    pub fn urlEncode(self: *Self, input: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        for (input) |c| {
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                    try writer.writeByte(c);
                },
                ' ' => {
                    try writer.writeAll("+");
                },
                else => {
                    try writer.print("%{X:0>2}", .{c});
                },
            }
        }
        var list = aw.toArrayList();
        return list.toOwnedSlice(self.allocator);
    }

    /// Generate search keywords from a user query using φ condensation.
    /// Extracts the most important words/phrases and condenses using golden ratio.
    pub fn generateSearchKeywords(self: *Self, query: []const u8) ![]const u8 {
        var keywords = std.ArrayList(u8).empty;
        defer keywords.deinit(self.allocator);

        // Simple keyword extraction: split on whitespace, take significant words
        var words = std.mem.splitSequence(u8, query, " ");
        var word_list = std.ArrayList([]const u8).empty;
        defer word_list.deinit(self.allocator);

        while (words.next()) |word| {
            if (word.len > 3) { // Skip short words
                try word_list.append(self.allocator, word);
            }
        }

        // Apply φ condensation: keep top 61.8% of words
        const target = math.condensationTarget(word_list.items.len);
        const count = @min(target, word_list.items.len);

        for (word_list.items[0..count], 0..) |word, i| {
            if (i > 0) try keywords.appendSlice(self.allocator, "+");
            try keywords.appendSlice(self.allocator, word);
        }

        return keywords.toOwnedSlice(self.allocator);
    }

    /// Free a slice of search results.
    pub fn freeResults(self: *Self, results: []SearchResult) void {
        for (results) |*r| {
            r.deinit(self.allocator);
        }
        self.allocator.free(results);
    }

    pub fn searchCount(self: *const Self) usize {
        return self.total_searches.load(.monotonic);
    }
};

test "WebSearch URL encoding" {
    var ws = WebSearch.init(std.testing.allocator, undefined, .duckduckgo, null);
    // Only testing urlEncode, no HTTP calls needed

    const encoded = try ws.urlEncode("hello world & test");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("hello+world+%26+test", encoded);
}

test "WebSearch generateSearchKeywords" {
    var ws = WebSearch.init(std.testing.allocator, undefined, .duckduckgo, null);

    const keywords = try ws.generateSearchKeywords("how to optimize vector search performance");
    defer std.testing.allocator.free(keywords);

    try std.testing.expect(keywords.len > 0);
}

test "WebSearch parseDuckDuckGoHTML" {
    var ws = WebSearch.init(std.testing.allocator, undefined, .duckduckgo, null);

    const html =
        \\<div><a class="result__a" href="https://example.com/zig">Zig Programming Language</a></div>
        \\<div><a class="result__snippet">A systems programming language</a></div>
        \\<div><a class="result__a" href="https://example.com/rust">Rust Programming</a></div>
    ;
    const results = try ws.parseDuckDuckGoHTML(html, 5);
    defer ws.freeResults(results);

    try std.testing.expect(results.len >= 1);
    if (results.len > 0) {
        try std.testing.expectEqualStrings("Zig Programming Language", results[0].title);
        try std.testing.expectEqualStrings("https://example.com/zig", results[0].url);
    }
}
