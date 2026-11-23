//! The codemode store: one script's buffered writes over the session's
//! folded map, with pi 1.5.1's caps and last-write-wins semantics
//! (pi-codemode prelude-source.js). T-13 (ISSUE-13).

const std = @import("std");
const testing = std.testing;

/// The script-facing store. Keys and JSON text are owned; load reads the
/// injected map plus this eval's writes, and writesJson reports only the
/// writes, which the caller appends to the session on success alone.
pub const Store = struct {
    allocator: std.mem.Allocator,
    /// key -> JSON text: the injected map with this eval's writes applied.
    current: std.array_hash_map.String([]u8) = .empty,
    /// key -> JSON text, or null for a delete: this eval's last write per
    /// key, in first-write order, as pi's writes Map.
    writes: std.array_hash_map.String(?[]u8) = .empty,
    /// Sum of key.len + json.len over current, as pi's storedChars. Bytes
    /// stand in for pi's UTF-16 code units; the cap only gets stricter for
    /// non-ASCII text.
    chars: usize = 0,

    pub const max_value_chars = 256 * 1024;
    pub const max_total_chars = 1024 * 1024;

    pub const SetError = error{ OutOfMemory, ValueTooLarge, StoreFull };

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.current.deinit(self.allocator);
        self.writes.deinit(self.allocator);
    }

    fn clear(self: *Store) void {
        for (self.current.keys(), self.current.values()) |key, value| {
            self.allocator.free(key);
            self.allocator.free(value);
        }
        self.current.clearRetainingCapacity();
        for (self.writes.keys(), self.writes.values()) |key, value| {
            self.allocator.free(key);
            if (value) |json| self.allocator.free(json);
        }
        self.writes.clearRetainingCapacity();
        self.chars = 0;
    }

    /// Starts an eval from the session's folded map. A malformed map starts
    /// empty, as pi's replay skips entries it cannot read.
    pub fn reset(self: *Store, initial_json: ?[]const u8) error{OutOfMemory}!void {
        self.clear();
        const raw = initial_json orelse return;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return;
        };
        if (parsed != .object) return;
        for (parsed.object.keys(), parsed.object.values()) |key, value| {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
            const json = try out.toOwnedSlice();
            errdefer self.allocator.free(json);
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            try self.current.put(self.allocator, owned_key, json);
            self.chars += key.len + json.len;
        }
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        return self.current.get(key);
    }

    /// One store() call: json null deletes the key. Caps are checked before
    /// anything changes, and a refused call leaves no write behind, as pi.
    pub fn set(self: *Store, key: []const u8, json: ?[]const u8) SetError!void {
        const previous: usize = if (self.current.get(key)) |old| key.len + old.len else 0;
        const value = json orelse {
            if (self.current.fetchOrderedRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value);
                self.chars -= previous;
            }
            try self.recordWrite(key, null);
            return;
        };
        if (value.len > max_value_chars) return error.ValueTooLarge;
        const next = self.chars - previous + key.len + value.len;
        if (next > max_total_chars) return error.StoreFull;
        if (self.current.getPtr(key)) |slot| {
            const owned = try self.allocator.dupe(u8, value);
            self.allocator.free(slot.*);
            slot.* = owned;
        } else {
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            const owned = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(owned);
            try self.current.put(self.allocator, owned_key, owned);
        }
        self.chars = next;
        try self.recordWrite(key, value);
    }

    fn recordWrite(self: *Store, key: []const u8, json: ?[]const u8) error{OutOfMemory}!void {
        const owned = if (json) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (owned) |text| self.allocator.free(text);
        if (self.writes.getPtr(key)) |slot| {
            if (slot.*) |old| self.allocator.free(old);
            slot.* = owned;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.writes.put(self.allocator, owned_key, owned);
    }

    /// This eval's writes as {"set":{...},"delete":[...]}, or null when the
    /// script wrote nothing. The caller owns the result.
    pub fn writesJson(self: *const Store, allocator: std.mem.Allocator) error{ OutOfMemory, WriteFailed }!?[]u8 {
        if (self.writes.count() == 0) return null;
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("{\"set\":{");
        var first = true;
        for (self.writes.keys(), self.writes.values()) |key, value| {
            const json = value orelse continue;
            if (!first) try out.writer.writeByte(',');
            first = false;
            try std.json.Stringify.value(key, .{}, &out.writer);
            try out.writer.writeByte(':');
            try out.writer.writeAll(json);
        }
        try out.writer.writeAll("},\"delete\":[");
        first = true;
        for (self.writes.keys(), self.writes.values()) |key, value| {
            if (value != null) continue;
            if (!first) try out.writer.writeByte(',');
            first = false;
            try std.json.Stringify.value(key, .{}, &out.writer);
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

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
    const at = try testing.allocator.alloc(u8, Store.max_value_chars - 2);
    defer testing.allocator.free(at);
    @memset(at, 'x');
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
