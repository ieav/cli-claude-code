/// Web search integration — queries external search APIs for knowledge.
/// Supports multiple backends: Brave, SearXNG, DuckDuckGo (HTML fallback).
/// Uses std.http.Client for real HTTP requests.

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

    pub fn init(allocator: std.mem.Allocator, backend: SearchBackend, api_key: ?[]const u8) Self {
        const base_url: []const u8 = switch (backend) {
            .brave => "https://api.search.brave.com/res/v1/web/search",
            .searxng => "http://localhost:8888/search",
            .duckduckgo => "https://html.duckduckgo.com/html/",
        };
        return .{
            .allocator = allocator,
            .backend = backend,
            .api_key = api_key,
            .base_url = base_url,
            .http_client = .{ .allocator = allocator },
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

        const body = switch (self.backend) {
            .brave => try self.searchBrave(query, max_results),
            .searxng => try self.searchSearXNG(query, max_results),
            .duckduckgo => try self.searchDuckDuckGo(query, max_results),
        };
        return body;
    }

    /// Search using Brave Search API.
    /// Requires API key set in self.api_key.
    fn searchBrave(self: *Self, query: []const u8, max_results: usize) ![]SearchResult {
        const api_key = self.api_key orelse return error.ApiKeyRequired;

        // Build URL with query parameters
        const encoded_query = try self.urlEncode(query);
        defer self.allocator.free(encoded_query);

        const url = try std.fmt.allocPrint(self.allocator,
            "{s}?q={s}&count={d}",
            .{ self.base_url, encoded_query, max_results },
        );
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
        defer self.allocator.free(auth_header);

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("accept", "application/json");
        try headers.append("authorization", auth_header);

        var req = try self.http_client.open(.GET, uri, .{ .headers = headers });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();

        if (req.response.status.class() != .success) {
            return error.SearchRequestFailed;
        }

        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(response_body);

        return self.parseBraveResults(response_body, max_results);
    }

    /// Parse Brave Search API JSON response.
    fn parseBraveResults(self: *Self, body: []const u8, max_results: usize) ![]SearchResult {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, body) catch
            return &.{};

        const web_results = parsed.object.get("web") orelse return &.{};
        const results_array = web_results.object.get("results") orelse return &.{};

        var output = std.ArrayList(SearchResult).init(self.allocator);
        const count = @min(results_array.array.items.len, max_results);

        for (results_array.array.items[0..count], 0..) |item, i| {
            const title = if (item.object.get("title")) |t|
                if (t == .string) try self.allocator.dupe(u8, t.string) else continue
            else
                continue;
            const url_val = if (item.object.get("url")) |u|
                if (u == .string) try self.allocator.dupe(u8, u.string) else continue
            else
                continue;
            const snippet = if (item.object.get("description")) |d|
                if (d == .string) try self.allocator.dupe(u8, d.string) else try self.allocator.dupe(u8, "")
            else
                try self.allocator.dupe(u8, "");

            // Rank-based relevance: first results are more relevant
            const relevance = 1.0 - @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(count, 1)));

            try output.append(.{
                .title = title,
                .url = url_val,
                .snippet = snippet,
                .relevance = relevance,
            });
        }

        return output.toOwnedSlice();
    }

    /// Search using SearXNG instance (self-hosted metasearch).
    fn searchSearXNG(self: *Self, query: []const u8, max_results: usize) ![]SearchResult {
        const encoded_query = try self.urlEncode(query);
        defer self.allocator.free(encoded_query);

        const url = try std.fmt.allocPrint(self.allocator,
            "{s}?q={s}&format=json&categories=general",
            .{ self.base_url, encoded_query },
        );
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("accept", "application/json");

        var req = try self.http_client.open(.GET, uri, .{ .headers = headers });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();

        if (req.response.status.class() != .success) {
            return error.SearchRequestFailed;
        }

        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(response_body);

        return self.parseSearXNGResults(response_body, max_results);
    }

    /// Parse SearXNG JSON response.
    fn parseSearXNGResults(self: *Self, body: []const u8, max_results: usize) ![]SearchResult {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, body) catch
            return &.{};

        const results_array = parsed.object.get("results") orelse return &.{};

        var output = std.ArrayList(SearchResult).init(self.allocator);
        const count = @min(results_array.array.items.len, max_results);

        for (results_array.array.items[0..count], 0..) |item, i| {
            const title = if (item.object.get("title")) |t|
                if (t == .string) try self.allocator.dupe(u8, t.string) else continue
            else
                continue;
            const url_val = if (item.object.get("url")) |u|
                if (u == .string) try self.allocator.dupe(u8, u.string) else continue
            else
                continue;
            const snippet = if (item.object.get("content")) |c|
                if (c == .string) try self.allocator.dupe(u8, c.string) else try self.allocator.dupe(u8, "")
            else
                try self.allocator.dupe(u8, "");

            const relevance = 1.0 - @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(count, 1)));

            try output.append(.{
                .title = title,
                .url = url_val,
                .snippet = snippet,
                .relevance = relevance,
            });
        }

        return output.toOwnedSlice();
    }

    /// Search using DuckDuckGo HTML endpoint (no API key needed).
    fn searchDuckDuckGo(self: *Self, query: []const u8, max_results: usize) ![]SearchResult {
        // DuckDuckGo HTML search via POST
        const post_body = try std.fmt.allocPrint(self.allocator, "q={s}", .{query});
        defer self.allocator.free(post_body);

        const uri = try std.Uri.parse(self.base_url);

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("content-type", "application/x-www-form-urlencoded");
        try headers.append("user-agent", "ZageAgent/1.0");

        var req = try self.http_client.open(.POST, uri, .{ .headers = headers });
        defer req.deinit();
        req.transfer_type = .chunked;

        try req.send();
        try req.writer().writeAll(post_body);
        try req.finish();
        try req.wait();

        if (req.response.status.class() != .success) {
            return error.SearchRequestFailed;
        }

        const response_body = try req.reader().readAllAlloc(self.allocator, 2 * 1024 * 1024);
        defer self.allocator.free(response_body);

        return self.parseDuckDuckGoHTML(response_body, max_results);
    }

    /// Parse DuckDuckGo HTML response to extract results.
    /// DDG HTML uses <a class="result__a" href="...">Title</a> and <a class="result__snippet">...
    fn parseDuckDuckGoHTML(self: *Self, html: []const u8, max_results: usize) ![]SearchResult {
        var results = std.ArrayList(SearchResult).init(self.allocator);
        var pos: usize = 0;

        while (pos < html.len and results.items.len < max_results) {
            // Find result title: <a class="result__a"
            const title_marker = "<a class=\"result__a\"";
            const title_start = std.mem.indexOfPos(u8, html, pos, title_marker) orelse break;
            const href_start = std.mem.indexOfPos(u8, html, title_start, "href=\"") orelse break;
            const href_begin = href_start + 6;
            const href_end = std.mem.indexOfScalar(u8, html[href_begin..], '"') orelse break;
            const url = html[href_begin .. href_begin + href_end];

            // Extract title text
            const tag_end = std.mem.indexOfScalar(u8, html[title_start..], '>') orelse break;
            const title_begin = title_start + tag_end + 1;
            const title_end = std.mem.indexOfScalar(u8, html[title_begin..], '<') orelse break;
            const title = html[title_begin .. title_begin + title_end];

            // Find snippet: <a class="result__snippet"
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

            try results.append(.{
                .title = try self.allocator.dupe(u8, title),
                .url = try self.allocator.dupe(u8, url),
                .snippet = try self.allocator.dupe(u8, snippet),
                .relevance = relevance,
            });

            pos = title_begin + 1;
        }

        return results.toOwnedSlice();
    }

    /// URL-encode a query string for use in search URLs.
    pub fn urlEncode(self: *Self, input: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

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
        return buf.toOwnedSlice();
    }

    /// Generate search keywords from a user query using φ condensation.
    /// Extracts the most important words/phrases and condenses using golden ratio.
    pub fn generateSearchKeywords(self: *Self, query: []const u8) ![]const u8 {
        var keywords = std.ArrayList(u8).init(self.allocator);
        defer keywords.deinit();

        // Simple keyword extraction: split on whitespace, take significant words
        var words = std.mem.splitSequence(u8, query, " ");
        var word_list = std.ArrayList([]const u8).init(self.allocator);
        defer word_list.deinit();

        while (words.next()) |word| {
            if (word.len > 3) { // Skip short words
                try word_list.append(word);
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
    var ws = WebSearch.init(std.testing.allocator, .duckduckgo, null);
    defer ws.deinit();

    const encoded = try ws.urlEncode("hello world & test");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("hello+world+%26+test", encoded);
}

test "WebSearch generateSearchKeywords" {
    var ws = WebSearch.init(std.testing.allocator, .duckduckgo, null);
    defer ws.deinit();

    const keywords = try ws.generateSearchKeywords("how to optimize vector search performance");
    defer std.testing.allocator.free(keywords);

    try std.testing.expect(keywords.len > 0);
}

test "WebSearch parseDuckDuckGoHTML" {
    var ws = WebSearch.init(std.testing.allocator, .duckduckgo, null);
    defer ws.deinit();

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
