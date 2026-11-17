const std = @import("std");
const bindings = @import("bindings.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

/// Default result cap for searchTools; the host callback applies it when
/// the caller passes no explicit limit.
pub const default_search_limit: usize = 8;

/// Hard cap for an explicit searchTools limit; the host rejects anything
/// above it with its own message, distinct from the shape error.
pub const max_search_limit: usize = 65536;

/// The hint attached to a triggered tools.list() catalog. It must only
/// name APIs that actually exist in the sandbox.
pub const catalog_hint =
    "The catalog above may be incomplete: a byte budget dropped some tools. " ++
    "searchTools(query) searches every tool on this surface by name, parameter, and description " ++
    "(an optional second argument {limit: N} caps the results, default 8), and " ++
    "describeTool(name) returns one tool's full {name, description, parameters} schema. " ++
    "Unknown describeTool names throw with suggestions; use searchTools to discover names.";

/// Budget notice appended to the tail of the catalog hint when the byte
/// gate opens. Shape follows the tool_search limit notice in
/// src/core/mcp/tool_search.zig: observed / effective / source / override.
pub const catalog_budget_clause =
    " Budget: observed={d} bytes effective={d} bytes source={s}; " ++
    "override with --context-limit codemode_catalog_bytes=BYTES|off.";

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
    /// stable order. Strings in the result are borrowed, not owned; the
    /// caller frees the hit slice itself.
    pub fn search(self: *const Index, alloc: Allocator, query: []const u8, limit: usize) ![]Hit {
        // Temporaries (query tokens, scoring table) share one short-lived
        // arena so the caller only frees the returned slice.
        var tmp_state = std.heap.ArenaAllocator.init(alloc);
        defer tmp_state.deinit();
        const tmp = tmp_state.allocator();

        const query_tokens = try tokenize(tmp, query);
        const query_normalized = try normalizedName(tmp, query);

        const scored = try tmp.alloc(ScoredEntry, self.docs.len);
        for (self.docs, 0..) |_, index| {
            var score: usize = 0;
            for (query_tokens) |query_token| {
                if (hasToken(self.name_tokens[index], query_token)) score += 3;
                if (hasToken(self.param_tokens[index], query_token)) score += 2;
                if (hasToken(self.description_tokens[index], query_token)) score += 1;
            }
            scored[index] = .{
                .index = index,
                .whole = std.mem.eql(u8, self.normalized_names[index], query_normalized),
                .score = score,
            };
        }
        sort_utils.sort(ScoredEntry, scored, {}, scoredLessThanFn);

        var count: usize = 0;
        for (scored) |entry| {
            if (entry.score == 0) break;
            if (count == limit) break;
            count += 1;
        }
        const hits = try alloc.alloc(Hit, count);
        for (scored[0..count], 0..) |entry, i| {
            hits[i] = .{
                .name = self.docs[entry.index].name,
                .description = self.docs[entry.index].description,
            };
        }
        return hits;
    }

    /// Returns up to max_close name candidates closest to the unknown
    /// name, best first, ties in face order. The strings are borrowed.
    pub fn suggest(self: *const Index, alloc: Allocator, name: []const u8, max_close: usize) ![]const []const u8 {
        var tmp_state = std.heap.ArenaAllocator.init(alloc);
        defer tmp_state.deinit();
        const tmp = tmp_state.allocator();

        const target = try normalizedName(tmp, name);
        const candidates = try tmp.alloc(CandidateEntry, self.docs.len);
        for (self.normalized_names, 0..) |normalized, index| {
            candidates[index] = .{
                .index = index,
                .distance = try editDistance(tmp, target, normalized),
            };
        }
        sort_utils.sort(CandidateEntry, candidates, {}, candidateLessThanFn);

        const count = @min(max_close, candidates.len);
        const out = try alloc.alloc([]const u8, count);
        for (candidates[0..count], 0..) |candidate, i| {
            out[i] = self.docs[candidate.index].name;
        }
        return out;
    }
};

const ScoredEntry = struct { index: usize, whole: bool, score: usize };
const CandidateEntry = struct { index: usize, distance: usize };

fn scoredLessThanFn(_: void, lhs: ScoredEntry, rhs: ScoredEntry) bool {
    // Whole-name matches top the list ahead of coverage scores; ties
    // fall back to face order so the output is deterministic.
    if (lhs.whole != rhs.whole) return lhs.whole;
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    return lhs.index < rhs.index;
}

fn candidateLessThanFn(_: void, lhs: CandidateEntry, rhs: CandidateEntry) bool {
    if (lhs.distance != rhs.distance) return lhs.distance < rhs.distance;
    return lhs.index < rhs.index;
}

/// Builds the index over the whole face. All parsed schema data lives in
/// an arena owned by the returned Index; the caller frees it with deinit
/// before the schemas it borrowed from go away.
pub fn build(alloc: Allocator, schemas: []const bindings.ToolSchema) !*Index {
    const index = try alloc.create(Index);
    errdefer alloc.destroy(index);
    index.* = .{ .arena_state = std.heap.ArenaAllocator.init(alloc) };
    errdefer index.arena_state.deinit();
    const arena = index.arena_state.allocator();

    var docs = std.ArrayList(Doc).empty;
    var name_tokens = std.ArrayList([]const []const u8).empty;
    var param_tokens = std.ArrayList([]const []const u8).empty;
    var description_tokens = std.ArrayList([]const []const u8).empty;
    var normalized_names = std.ArrayList([]const u8).empty;
    for (schemas) |schema| {
        var doc = Doc{ .name = schema.name, .description = "", .param_names = &.{}, .param_descriptions = &.{} };
        // A schema this tool itself produced always parses; an unparseable
        // entry still stays searchable by name, just without corpus text.
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, schema.schema_json, .{})) |value| {
            if (value == .object) {
                if (value.object.get("description")) |description| {
                    if (description == .string) doc.description = description.string;
                }
                if (value.object.get("inputSchema")) |input_schema| {
                    if (input_schema == .object) {
                        if (input_schema.object.get("properties")) |properties| {
                            if (properties == .object) {
                                var param_names = std.ArrayList([]const u8).empty;
                                var param_descriptions = std.ArrayList([]const u8).empty;
                                var iterator = properties.object.iterator();
                                while (iterator.next()) |entry| {
                                    try param_names.append(arena, entry.key_ptr.*);
                                    if (entry.value_ptr.* == .object) {
                                        if (entry.value_ptr.object.get("description")) |param_description| {
                                            if (param_description == .string) {
                                                try param_descriptions.append(arena, param_description.string);
                                            }
                                        }
                                    }
                                }
                                doc.param_names = try param_names.toOwnedSlice(arena);
                                doc.param_descriptions = try param_descriptions.toOwnedSlice(arena);
                            }
                        }
                    }
                }
            }
        } else |_| {}
        try docs.append(arena, doc);
        try name_tokens.append(arena, try tokenize(arena, schema.name));
        var parameter_tokens = std.ArrayList([]const u8).empty;
        for (doc.param_names) |param_name| {
            try parameter_tokens.appendSlice(arena, try tokenize(arena, param_name));
        }
        try param_tokens.append(arena, try parameter_tokens.toOwnedSlice(arena));
        var corpus_tokens = std.ArrayList([]const u8).empty;
        try corpus_tokens.appendSlice(arena, try tokenize(arena, doc.description));
        for (doc.param_descriptions) |param_description| {
            try corpus_tokens.appendSlice(arena, try tokenize(arena, param_description));
        }
        try description_tokens.append(arena, try corpus_tokens.toOwnedSlice(arena));
        try normalized_names.append(arena, try normalizedName(arena, schema.name));
    }
    index.docs = try docs.toOwnedSlice(arena);
    index.name_tokens = try name_tokens.toOwnedSlice(arena);
    index.param_tokens = try param_tokens.toOwnedSlice(arena);
    index.description_tokens = try description_tokens.toOwnedSlice(arena);
    index.normalized_names = try normalized_names.toOwnedSlice(arena);
    return index;
}

/// Tokenizes text the same way queries and corpus fields are split:
/// lowercase, maximal runs of ASCII letters and digits.
pub fn tokenize(alloc: Allocator, text: []const u8) ![]const []const u8 {
    var tokens = std.ArrayList([]const u8).empty;
    var start: ?usize = null;
    for (text, 0..) |byte, index| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (start == null) start = index;
        } else {
            if (start) |from| {
                try tokens.append(alloc, try lowered(alloc, text[from..index]));
                start = null;
            }
        }
    }
    if (start) |from| {
        try tokens.append(alloc, try lowered(alloc, text[from..]));
    }
    return tokens.toOwnedSlice(alloc);
}

fn lowered(alloc: Allocator, slice: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, slice.len);
    for (slice, 0..) |byte, index| {
        out[index] = std.ascii.toLower(byte);
    }
    return out;
}

fn hasToken(tokens: []const []const u8, token: []const u8) bool {
    for (tokens) |candidate| {
        if (std.mem.eql(u8, candidate, token)) return true;
    }
    return false;
}

/// Two-row Levenshtein distance on bytes. Tool names are short, so no
/// banding is needed.
fn editDistance(alloc: Allocator, a: []const u8, b: []const u8) !usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    const cols = b.len + 1;
    const previous = try alloc.alloc(usize, cols);
    const current = try alloc.alloc(usize, cols);
    for (0..cols) |j| previous[j] = j;
    for (a, 1..) |a_byte, i| {
        current[0] = i;
        for (b, 1..) |b_byte, j| {
            const substitution = previous[j - 1] + @as(usize, if (a_byte == b_byte) 0 else 1);
            const deletion = previous[j] + 1;
            const insertion = current[j - 1] + 1;
            current[j] = @min(substitution, @min(deletion, insertion));
        }
        @memcpy(previous, current);
    }
    return previous[cols - 1];
}

/// Folds a name for whole-name comparison: lowercase, every non-alphanumeric
/// byte becomes '_'. mcp__x__y and mcp_x_y therefore compare equal.
pub fn normalizedName(alloc: Allocator, name: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, name.len);
    var out_len: usize = 0;
    var pending_separator = false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (pending_separator and out_len > 0) {
                out[out_len] = '_';
                out_len += 1;
            }
            pending_separator = false;
            out[out_len] = std.ascii.toLower(byte);
            out_len += 1;
        } else {
            pending_separator = true;
        }
    }
    // Leading or trailing separators fold away entirely.
    return out[0..out_len];
}

test "tokenize splits on non-alphanumeric bytes and lowercases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const tokens = try tokenize(arena_state.allocator(), "Glob-Files 2x__y");
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("glob", tokens[0]);
    try std.testing.expectEqualStrings("files", tokens[1]);
    try std.testing.expectEqualStrings("2x", tokens[2]);
    try std.testing.expectEqualStrings("y", tokens[3]);
}

test "normalized names fold separators so mcp__x__y matches mcp_x_y" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try normalizedName(arena, "mcp__x__y");
    const b = try normalizedName(arena, "mcp_x_y");
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
    // Name hit beats parameter hit, which beats description hit.
    try std.testing.expectEqualStrings("vision_needle", hits[0].name);
    try std.testing.expectEqualStrings("grep_files", hits[1].name);
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
