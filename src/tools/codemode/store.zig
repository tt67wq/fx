//! The codemode store: one script's buffered writes over the session's
//! folded map, with pi 1.5.1's caps and last-write-wins semantics
//! (pi-codemode prelude-source.js). T-13 (ISSUE-13).

const std = @import("std");
const testing = std.testing;

test "store reset parses the injected map and get returns raw JSON values" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.reset("{\"a\":1,\"b\":{\"x\":[2]}}");
    try testing.expectEqualStrings("1", s.get("a").?);
    try testing.expectEqualStrings("{\"x\":[2]}", s.get("b").?);
    try testing.expect(s.get("missing") == null);
}

test "store set overwrites, delete removes, and a delete of a missing key is still recorded" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.reset(null);
    try s.set("k", "1");
    try testing.expectEqualStrings("1", s.get("k").?);
    try s.set("k", "2");
    try testing.expectEqualStrings("2", s.get("k").?);
    try s.set("k", null);
    try testing.expect(s.get("k") == null);
    try s.set("ghost", null);
    const writes = (try s.writesJson(testing.allocator)).?;
    defer testing.allocator.free(writes);
    try testing.expectEqualStrings("{\"set\":{},\"delete\":[\"k\",\"ghost\"]}", writes);
}

test "store writes keep the last write per key in first-write order" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.reset(null);
    try s.set("x", "1");
    try s.set("x", "2");
    try s.set("y", "3");
    try s.set("y", null);
    const writes = (try s.writesJson(testing.allocator)).?;
    defer testing.allocator.free(writes);
    try testing.expectEqualStrings("{\"set\":{\"x\":2},\"delete\":[\"y\"]}", writes);
}

test "store with no writes reports none, and reset clears buffered writes" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.reset(null);
    try testing.expect((try s.writesJson(testing.allocator)) == null);
    try s.set("k", "1");
    try s.reset("{\"a\":9}");
    try testing.expect((try s.writesJson(testing.allocator)) == null);
    try testing.expect(s.get("k") == null);
    try testing.expectEqualStrings("9", s.get("a").?);
}

test "store enforces pi's value and total caps, and delete frees quota" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.reset(null);
    // One value over the per-value cap is refused and changes nothing.
    const over = try testing.allocator.alloc(u8, Store.max_value_chars + 1);
    defer testing.allocator.free(over);
    @memset(over, 'x');
    over[0] = '"';
    over[over.len - 1] = '"';
    try testing.expectError(error.ValueTooLarge, s.set("big", over));
    try testing.expect(s.get("big") == null);
    try testing.expect((try s.writesJson(testing.allocator)) == null);
    // Four values at the cap plus their keys exceed the total cap.
    const at = over[1 .. over.len - 1];
    const json = try std.mem.concat(testing.allocator, u8, &.{ "\"", at, "\"" });
    defer testing.allocator.free(json);
    try testing.expectEqual(Store.max_value_chars, json.len);
    try s.set("k0", json);
    try s.set("k1", json);
    try s.set("k2", json);
    try testing.expectError(error.StoreFull, s.set("k3", json));
    try s.set("k0", null);
    try s.set("k3", json);
    try testing.expectEqualStrings(json, s.get("k3").?);
}

test "store reset treats a malformed injected map as empty" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.reset("not json");
    try testing.expect(s.get("a") == null);
    try s.reset("[1,2]");
    try testing.expect(s.get("a") == null);
    try s.set("a", "1");
    try testing.expectEqualStrings("1", s.get("a").?);
}
