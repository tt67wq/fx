// T-6 spike: pins how old fx reads a hypothetical codemode_store session-log event.
//
// Facts under test (session log = src/core/session_manager/):
//   1. schema.SetKey has no codemode_store variant (schema.zig:111).
//   2. Parsing a .set line whose key is unknown fails with error.BadBody
//      (schema.zig:270, f.req(SetKey, "key") -> opt -> json parse fail -> BadBody).
//   3. The fold loop maps any parseBody failure on a KNOWN kind to error.Corrupt
//      (session_manager/session.zig:1371), which aborts openResume -> resume
//      fails with InvalidSessionFormat (session_adapter.zig:4981).
//   4. Contrast: a line with an UNKNOWN kind is skipped, not corrupting
//      (session_manager/session.zig:1366-1370); schema.zig already carries a
//      built-in test "unknown kinds parse with a null kind" for the parse half.
//
// How to run (the file lives outside the src/ module root, and schema.zig
// imports the build-generated build_options module, so a plain
// "zig test <file>" fails twice over). From the repo root:
//
//   sed 's|../../src/core/session_manager/schema.zig|src/core/session_manager/schema.zig|' \
//     .agents/tasks/T-6/codemode_store_corrupt_test.zig > .t6_test_tmp.zig
//   printf 'pub const fuzz_corpus_session_schema_header: []const []const u8 = &.{};\n' \
//     > /tmp/t6_build_options.zig
//   zig test --dep build_options -Mroot=.t6_test_tmp.zig \
//     -Mbuild_options=/tmp/t6_build_options.zig
//   rm .t6_test_tmp.zig
//
// Verified on this branch: all 14 tests pass (3 here + 11 in schema.zig).

const std = @import("std");
const schema = @import("../../src/core/session_manager/schema.zig");

test "SetKey has no codemode_store variant" {
    try std.testing.expectEqual(
        @as(?schema.SetKey, null),
        std.meta.stringToEnum(schema.SetKey, "codemode_store"),
    );
}

test "old fx fails a set line with key codemode_store as BadBody" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Body fields as appendBody writes them: comma-leading JSON object fields
    // (schema.zig:300-305). A new fx would write a codemode_store note as a
    // .set line with a new key value.
    const fields = "," ++
        "\"key\":\"codemode_store\"," ++
        "\"value\":\"{\\\"records\\\":[]}\"";
    try std.testing.expectError(error.BadBody, schema.parseBody(arena, .set, fields));

    // Control: the same shape with a known key parses fine.
    const known = "," ++ "\"key\":\"title\"," ++ "\"value\":\"\\\"hi\\\"\"";
    const body = try schema.parseBody(arena, .set, known);
    try std.testing.expectEqual(schema.SetKey.title, body.set.key);
}

test "unknown kind name is not a schema Kind either (fold skips it, session.zig:1366)" {
    // Kind at schema.zig (session_manager) is the line-kind enum; an unknown
    // kind name cannot resolve, so header.kind is null and the fold loop skips
    // the line instead of failing. Cited: session.zig:1366-1370.
    const kind_names = [_][]const u8{
        "session_created", "turn_started", "turn_committed",
        "item",            "compacted",    "turn_interrupted",
        "set",             "child_spawned",
    };
    for (kind_names) |name| {
        try std.testing.expect(std.meta.stringToEnum(schema.Kind, name) != null);
    }
    try std.testing.expectEqual(
        @as(?schema.Kind, null),
        std.meta.stringToEnum(schema.Kind, "codemode_store_set"),
    );
}
