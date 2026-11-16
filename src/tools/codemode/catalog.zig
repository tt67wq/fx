const std = @import("std");
const bindings = @import("bindings.zig");
const bridge = @import("bridge.zig");
const builtin_tools = @import("../../builtins/tools.zig");

const Allocator = std.mem.Allocator;

/// Bytes reserved for the omitted list and hint on a triggered selection.
/// The floor is taken before entries are placed, mirroring the notification
/// floor in host.zig (options_output_floor_bytes).
pub const catalog_notice_floor_bytes: usize = 512;

/// The default budget lives in context_limits (codemode_catalog_bytes,
/// 16 KiB); tests and the selector below only see the resolved value.
pub const default_budget_bytes: usize = 16 * 1024;

/// Placement priority. Tier zero is the catalog exemption the codemode
/// contract text already names: these four tools are today's existing
/// behavior and must always be listed regardless of budget. Tier one holds
/// the mutation tools, tier two everything else (and any future dynamic
/// tool until MCP groups arrive).
pub const Tier = enum { t0, t1, t2 };

pub fn tierOf(name: []const u8) Tier {
    const t0_names = [_][]const u8{ "glob_files", "grep_files", "read_file", "run_command" };
    const t1_names = [_][]const u8{ "write_file", "edit_file" };
    for (t0_names) |t0_name| {
        if (std.mem.eql(u8, name, t0_name)) return .t0;
    }
    for (t1_names) |t1_name| {
        if (std.mem.eql(u8, name, t1_name)) return .t1;
    }
    return .t2;
}

/// One entry the selector dropped from the listing. 'oversized' marks an
/// item whose own schema exceeds the whole budget, so it could never fit.
pub const Omitted = struct {
    name: []const u8,
    bytes: usize,
    oversized: bool,
};

/// A pure selection result: indexes into the schema slice that stay
/// listed, the omitted entries in face order, and whether the byte gate
/// triggered at all. Same inputs always produce the same output.
pub const Selection = struct {
    indexes: []usize,
    omitted: []Omitted,
    triggered: bool,
};

/// A group of schemas placed together. v1 has exactly one group (the whole
/// face); the parameter exists so MCP servers can become their own groups
/// without reshaping the selector.
pub const Group = struct {
    schemas: []const bindings.ToolSchema,
};

/// Selects the catalog across one or more groups. Within a group the face
/// order rules: tier zero first, then tier one, then tier two; the first
/// item that does not fit cascades every later item in its group into
/// omitted (AlwaysLoaded semantics: no skip-large-fit-small).
pub fn selectGroups(alloc: Allocator, groups: []const Group, budget: usize) Allocator.Error!Selection {
    _ = alloc;
    _ = groups;
    _ = budget;
    // Red skeleton: selection lands with the green commit.
    return .{ .indexes = &.{}, .omitted = &.{}, .triggered = false };
}

/// One-group convenience wrapper for the whole face.
pub fn select(alloc: Allocator, schemas: []const bindings.ToolSchema, budget: usize) Allocator.Error!Selection {
    return selectGroups(alloc, &.{.{ .schemas = schemas }}, budget);
}

test "tier classification covers the three tiers in face order" {
    try std.testing.expectEqual(Tier.t0, tierOf("glob_files"));
    try std.testing.expectEqual(Tier.t0, tierOf("grep_files"));
    try std.testing.expectEqual(Tier.t0, tierOf("read_file"));
    try std.testing.expectEqual(Tier.t0, tierOf("run_command"));
    try std.testing.expectEqual(Tier.t1, tierOf("write_file"));
    try std.testing.expectEqual(Tier.t1, tierOf("edit_file"));
    try std.testing.expectEqual(Tier.t2, tierOf("web_fetch"));
    try std.testing.expectEqual(Tier.t2, tierOf("ask_user_question"));
    try std.testing.expectEqual(Tier.t2, tierOf("vision"));
    try std.testing.expectEqual(Tier.t2, tierOf("mcp_server_tool"));
}

// Synthetic schema builder: selection counts schema_json bytes only, so
// the JSON body just needs a controlled length and a NUL sentinel.
const TestSchema = struct {
    buf: [:0]u8,

    fn deinit(self: TestSchema, alloc: Allocator) void {
        alloc.free(self.buf);
    }
};

fn makeSchema(alloc: Allocator, name: []const u8, fill_len: usize) !TestSchema {
    const body = "{{\"name\":\"{s}\",\"description\":\"test tool\"";
    var head_buf: [256]u8 = undefined;
    const head = try std.mem.print(&head_buf, body, .{name});
    const total = head.len + fill_len + 3; // ,"x":N padding and closing brace
    const buf = try alloc.allocSentinel(u8, total, 0);
    @memcpy(buf[0..head.len], head);
    var written = head.len;
    buf[written] = ',';
    written += 1;
    @memset(buf[written .. total - 1], 'x');
    buf[total - 1] = '}';
    return .{ .buf = buf[0..total :0] };
}

test "catalog keeps the real nine-item derived face whole under the default budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const registry = builtin_tools.registry;
    const face = bridge.sandboxFace(registry, true);
    const schemas = try bridge.schemas(arena, registry, face);
    try std.testing.expectEqual(@as(usize, 9), schemas.len);

    // Size sentinel: the whole face must weigh under the default budget.
    // When a fatter description pushes this over, raising the budget is a
    // decision someone has to make explicitly, not silently.
    var total: usize = 0;
    for (schemas) |schema| total += schema.schema_json.len;
    try std.testing.expect(total < default_budget_bytes);

    const selection = try select(arena, schemas, default_budget_bytes);
    try std.testing.expectEqual(false, selection.triggered);
    try std.testing.expectEqual(@as(usize, 9), selection.indexes.len);
    try std.testing.expectEqual(@as(usize, 0), selection.omitted.len);
}

test "catalog does not trigger when the total equals the budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try makeSchema(arena, "write_file", 100);
    const b = try makeSchema(arena, "edit_file", 100);
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "write_file", .schema_json = a.buf },
        .{ .name = "edit_file", .schema_json = b.buf },
    };
    const total = schemas[0].schema_json.len + schemas[1].schema_json.len;
    const selection = try select(arena, &schemas, total);
    try std.testing.expectEqual(false, selection.triggered);
    try std.testing.expectEqual(@as(usize, 2), selection.indexes.len);
    try std.testing.expectEqual(@as(usize, 0), selection.omitted.len);
}

test "catalog triggers selection one byte over the budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try makeSchema(arena, "glob_files", 50);
    const b = try makeSchema(arena, "write_file", 60);
    const c = try makeSchema(arena, "vision", 70);
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "glob_files", .schema_json = a.buf },
        .{ .name = "write_file", .schema_json = b.buf },
        .{ .name = "vision", .schema_json = c.buf },
    };
    const total = schemas[0].schema_json.len + schemas[1].schema_json.len + schemas[2].schema_json.len;
    // One byte over: the byte gate opens. The notice floor then leaves no
    // room for entries, so tier zero stays and the rest go omitted.
    const selection = try select(arena, &schemas, total + 1);
    try std.testing.expectEqual(true, selection.triggered);
    try std.testing.expectEqual(@as(usize, 1), selection.indexes.len);
    try std.testing.expectEqualStrings("glob_files", schemas[selection.indexes[0]].name);
    try std.testing.expectEqual(@as(usize, 2), selection.omitted.len);
    try std.testing.expectEqualStrings("write_file", selection.omitted[0].name);
    try std.testing.expectEqualStrings("vision", selection.omitted[1].name);
}

test "catalog exempts tier zero and cascades later omissions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Tier zero first and last in face order; a small tier-one item fits,
    // a big tier-two item does not, and the small item after it must not
    // skip past the cascade.
    const a = try makeSchema(arena, "read_file", 40);
    const b = try makeSchema(arena, "write_file", 30);
    const c = try makeSchema(arena, "web_fetch", 200);
    const d = try makeSchema(arena, "vision", 10);
    const e = try makeSchema(arena, "run_command", 40);
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "read_file", .schema_json = a.buf },
        .{ .name = "write_file", .schema_json = b.buf },
        .{ .name = "web_fetch", .schema_json = c.buf },
        .{ .name = "vision", .schema_json = d.buf },
        .{ .name = "run_command", .schema_json = e.buf },
    };
    // Budget: enough for tier zero plus write_file plus the floor, but
    // not web_fetch. Without the cascade vision would fit in the slack.
    const used_after_fit = schemas[0].schema_json.len + schemas[1].schema_json.len;
    const budget = used_after_fit + catalog_notice_floor_bytes + 20;
    const selection = try select(arena, &schemas, budget);
    try std.testing.expectEqual(true, selection.triggered);
    try std.testing.expectEqual(@as(usize, 3), selection.indexes.len);
    try std.testing.expectEqualStrings("read_file", schemas[selection.indexes[0]].name);
    try std.testing.expectEqualStrings("write_file", schemas[selection.indexes[1]].name);
    try std.testing.expectEqualStrings("run_command", schemas[selection.indexes[2]].name);
    try std.testing.expectEqual(@as(usize, 2), selection.omitted.len);
    try std.testing.expectEqualStrings("web_fetch", selection.omitted[0].name);
    try std.testing.expectEqual(false, selection.omitted[0].oversized);
    try std.testing.expectEqualStrings("vision", selection.omitted[1].name);
    try std.testing.expectEqual(false, selection.omitted[1].oversized);
}

test "catalog marks a single item larger than the whole budget as oversized" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try makeSchema(arena, "read_file", 20);
    const big = try makeSchema(arena, "vision", 5000);
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "read_file", .schema_json = a.buf },
        .{ .name = "vision", .schema_json = big.buf },
    };
    const budget: usize = 1000;
    const selection = try select(arena, &schemas, budget);
    try std.testing.expectEqual(true, selection.triggered);
    try std.testing.expectEqual(@as(usize, 1), selection.indexes.len);
    try std.testing.expectEqual(@as(usize, 1), selection.omitted.len);
    try std.testing.expectEqualStrings("vision", selection.omitted[0].name);
    try std.testing.expectEqual(true, selection.omitted[0].oversized);
    try std.testing.expectEqual(big.buf.len, selection.omitted[0].bytes);
}

test "catalog reserves the notice floor before placing entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try makeSchema(arena, "read_file", 100);
    const b = try makeSchema(arena, "write_file", 400);
    const c = try makeSchema(arena, "web_fetch", 100);
    const d = try makeSchema(arena, "vision", 50);
    const e = try makeSchema(arena, "ask_user_question", 60);
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "read_file", .schema_json = a.buf },
        .{ .name = "write_file", .schema_json = b.buf },
        .{ .name = "web_fetch", .schema_json = c.buf },
        .{ .name = "vision", .schema_json = d.buf },
        .{ .name = "ask_user_question", .schema_json = e.buf },
    };
    // Total is a few bytes over the budget, so the byte gate opens. With
    // the floor reserved, write_file no longer fits; without it every
    // entry except the last would place.
    var total: usize = 0;
    for (schemas) |schema| total += schema.schema_json.len;
    const budget = total - 5;
    const selection = try select(arena, &schemas, budget);
    try std.testing.expectEqual(true, selection.triggered);
    try std.testing.expectEqual(@as(usize, 1), selection.indexes.len);
    try std.testing.expectEqualStrings("read_file", schemas[selection.indexes[0]].name);
    try std.testing.expectEqual(@as(usize, 4), selection.omitted.len);
}

test "catalog selection is deterministic for identical inputs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try makeSchema(arena, "glob_files", 80);
    const b = try makeSchema(arena, "write_file", 120);
    const c = try makeSchema(arena, "vision", 200);
    const schemas = [_]bindings.ToolSchema{
        .{ .name = "glob_files", .schema_json = a.buf },
        .{ .name = "write_file", .schema_json = b.buf },
        .{ .name = "vision", .schema_json = c.buf },
    };
    var total: usize = 0;
    for (schemas) |schema| total += schema.schema_json.len;
    const budget = total - 10;
    const first = try select(arena, &schemas, budget);
    const second = try select(arena, &schemas, budget);
    try std.testing.expectEqual(first.triggered, second.triggered);
    try std.testing.expectEqual(first.indexes.len, second.indexes.len);
    for (first.indexes, second.indexes) |x, y| {
        try std.testing.expectEqual(x, y);
    }
    try std.testing.expectEqual(first.omitted.len, second.omitted.len);
    for (first.omitted, second.omitted) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqual(x.bytes, y.bytes);
        try std.testing.expectEqual(x.oversized, y.oversized);
    }
}
