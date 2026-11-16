const std = @import("std");
const bindings = @import("bindings.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

/// Default result cap for searchTools; the host callback applies it when
/// the caller passes no explicit limit.
pub const default_search_limit: usize = 8;

/// The hint attached to a triggered tools.list() catalog. It must only
/// name APIs that actually exist in the sandbox.
pub const catalog_hint =
    "The catalog above may be incomplete: a byte budget dropped some tools. " ++
    "searchTools(query) searches every tool on this surface by name, parameter, and description " ++
    "(an optional second argument {limit: N} caps the results, default " ++ "8" ++ "), and " ++
    "describeTool(name) returns one tool's full {name, description, parameters} schema. " ++
    "Unknown describeTool names throw with suggestions; use searchTools to discover names.";

/// Maximum did-you-mean candidates describeTool reports for an unknown name.
pub const max_describe_candidates = 5;

/// One tool's searchable corpus, extracted from its schema JSON.
pub const Doc = struct {
    name: []const u8,
    description: []const u8,
    param_names: []const []const u8,
    param_descriptions: []const []const u8,
};

/// One searchTools hit. The strings are borrowed from the schemas the
/// index was built from and live as long as they do.
pub const Hit = struct {
    name: []const u8,
    description: []const u8,
};

/// Pre-tokenized search index over the full tool face. Built once per
/// codemode call alongside the injected schemas; pure read-only after
/// build. No IO, no clock, no cross-call state.
pub const Index = struct {
    arena_state: std.heap.ArenaAllocator,
    docs: []Doc = &.{},
    name_tokens: [][]const []const u8 = &.{},
    param_tokens: [][]const []const u8 = &.{},
    description_tokens: [][]const []const u8 = &.{},
    normalized_names: [][]const u8 = &.{},

    pub fn deinit(self: *Index, alloc: Allocator) void {
        self.arena_state.deinit();
        alloc.destroy(self);
    }

    /// Scores the corpus against the query and returns the best hits in
    /// stable order. Strings in the result are borrowed, not owned.
    pub fn search(self: *const Index, alloc: Allocator, query: []const u8, limit: usize) ![]Hit {
        _ = self;
        _ = alloc;
        _ = query;
        _ = limit;
        return &.{};
    }

    /// Returns up to max_close normalized-name candidates closest to the
    /// unknown name, best first.
    pub fn suggest(self: *const Index, alloc: Allocator, name: []const u8, max_close: usize) ![]const []const u8 {
        _ = self;
        _ = alloc;
        _ = name;
        _ = max_close;
        return &.{};
    }
};

/// Builds the index over the whole face. All parsed schema data lives in
/// an arena owned by the returned Index; the caller frees it with deinit
/// before the schemas it borrowed from go away.
pub fn build(alloc: Allocator, schemas: []const bindings.ToolSchema) !*Index {
    _ = schemas;
    const index = try alloc.create(Index);
    index.* = .{ .arena_state = std.heap.ArenaAllocator.init(alloc) };
    return index;
}

/// Tokenizes text the same way queries and corpus fields are split:
/// lowercase, maximal runs of ASCII letters and digits.
pub fn tokenize(alloc: Allocator, text: []const u8) ![]const []const u8 {
    _ = alloc;
    _ = text;
    return &.{};
}

/// Folds a name for whole-name comparison: lowercase, every non-alphanumeric
/// byte becomes '_'. mcp__x__y and mcp_x_y therefore compare equal.
pub fn normalizedName(alloc: Allocator, name: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, name.len);
    for (name, 0..) |byte, index| {
        out[index] = if (std.ascii.isAlphanumeric(byte)) std.ascii.toLower(byte) else '_';
    }
    return out;
}

test "tokenize splits on non-alphanumeric bytes and lowercases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const tokens = try tokenize(arena_state.allocator(), "Glob-Files 2x__y");
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("glob", tokens[0]);
    try std.testing.expectEqualStrings("files", tokens[1]);
    try std.testing.expectEqualStrings("2x", tokens[2]);
}

test "normalized names fold separators so mcp__x__y matches mcp_x_y" {
    const a = try normalizedName(std.testing.allocator, "mcp__x__y");
    defer std.testing.allocator.free(a);
    const b = try normalizedName(std.testing.allocator, "mcp_x_y");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "search ranks name hits over parameter hits over description hits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "web_fetch", .schema_json =
        \\{"description":"Reads a needle from a URL","inputSchema":{"type":"object","properties":{"url":{"type":"string"}}}}
        },
        .{ .name = "vision_needle", .schema_json =
        \\{"description":"Looks at images","inputSchema":{"type":"object","properties":{"image":{"type":"string"}}}}
        },
        .{ .name = "grep_files", .schema_json =
        \\{"description":"Search file contents","inputSchema":{"type":"object","properties":{"needle":{"type":"string"}}}}
        },
    };
    const index = try build(std.testing.allocator, &schemas);
    defer index.deinit(std.testing.allocator);

    const hits = try index.search(std.testing.allocator, "needle", 8);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    // Parameter name hit beats description hit; name hit beats both.
    try std.testing.expectEqualStrings("grep_files", hits[0].name);
    try std.testing.expectEqualStrings("vision_needle", hits[1].name);
    try std.testing.expectEqualStrings("web_fetch", hits[2].name);
}

test "search puts a whole-name match first regardless of score" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "glob_files", .schema_json =
        \\{"description":"match glob glob glob patterns","inputSchema":{"type":"object","properties":{"glob":{"type":"string"}}}}
        },
        .{ .name = "grep_files", .schema_json =
        \\{"description":"search contents","inputSchema":{"type":"object","properties":{"pattern":{"type":"string"}}}}
        },
    };
    const index = try build(std.testing.allocator, &schemas);
    defer index.deinit(std.testing.allocator);

    const hits = try index.search(std.testing.allocator, "grep_files", 8);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("grep_files", hits[0].name);
}

test "search breaks ties with face order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "alpha_tool", .schema_json = "{\"description\":\"shared word\"}" },
        .{ .name = "beta_tool", .schema_json = "{\"description\":\"shared word\"}" },
    };
    const index = try build(std.testing.allocator, &schemas);
    defer index.deinit(std.testing.allocator);

    const hits = try index.search(std.testing.allocator, "shared", 8);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("alpha_tool", hits[0].name);
    try std.testing.expectEqualStrings("beta_tool", hits[1].name);
}

test "search finds tools that the listing dropped and covers every doc" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Simulate a budgeted catalog: only glob_files is listed, but the
    // index is built over the whole face.
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "glob_files", .schema_json =
        \\{"description":"match files","inputSchema":{"type":"object","properties":{"pattern":{"type":"string"}}}}
        },
        .{ .name = "vision", .schema_json =
        \\{"description":"describe an image","inputSchema":{"type":"object","properties":{"image":{"type":"string"}}}}
        },
    };
    const index = try build(std.testing.allocator, &schemas);
    defer index.deinit(std.testing.allocator);

    const hits = try index.search(std.testing.allocator, "image", 8);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("vision", hits[0].name);
    try std.testing.expectEqualStrings("describe an image", hits[0].description);
}

test "search respects the caller limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var schemas: [10]bindings.ToolSchema = undefined;
    var names: [10][]const u8 = undefined;
    var bufs: [10][64]u8 = undefined;
    for (0..10) |i| {
        const label = try std.mem.print(&bufs[i], "tool_{d}", .{i});
        names[i] = label;
        schemas[i] = .{ .name = names[i], .schema_json = "{\"description\":\"unique haystack word\"}" };
    }
    const index = try build(std.testing.allocator, &schemas);
    defer index.deinit(std.testing.allocator);

    const hits = try index.search(std.testing.allocator, "haystack", 3);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
}

test "suggest returns close names for an unknown tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "read_file", .schema_json = "{}" },
        .{ .name = "glob_files", .schema_json = "{}" },
        .{ .name = "web_fetch", .schema_json = "{}" },
    };
    const index = try build(std.testing.allocator, &schemas);
    defer index.deinit(std.testing.allocator);

    const candidates = try index.suggest(std.testing.allocator, "read_fil", max_describe_candidates);
    defer std.testing.allocator.free(candidates);
    try std.testing.expect(candidates.len >= 1);
    try std.testing.expectEqualStrings("read_file", candidates[0]);
    try std.testing.expect(candidates.len <= max_describe_candidates);
}

test "suggest returns at most five candidates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var schemas: [8]bindings.ToolSchema = undefined;
    var names: [8][]const u8 = undefined;
    var bufs: [8][64]u8 = undefined;
    for (0..8) |i| {
        const label = try std.mem.print(&bufs[i], "read_file_{d}", .{i});
        names[i] = label;
        schemas[i] = .{ .name = names[i], .schema_json = "{}" };
    }
    schemas[7] = .{ .name = "read_file", .schema_json = "{}" };
    const index = try build(std.testing.allocator, &schemas);
    defer index.deinit(std.testing.allocator);

    const candidates = try index.suggest(std.testing.allocator, "read_file_x", max_describe_candidates);
    defer std.testing.allocator.free(candidates);
    try std.testing.expectEqual(@as(usize, max_describe_candidates), candidates.len);
}
