const std = @import("std");
const bindings = @import("bindings.zig");
const host_mod = @import("host.zig");

const Host = host_mod.Host;

test "codemode tool registry holds only the read-only trio" {
    try std.testing.expectEqual(@as(usize, 3), bindings.tools.len);
    try std.testing.expect(bindings.find("glob_files") != null);
    try std.testing.expect(bindings.find("grep_files") != null);
    try std.testing.expect(bindings.find("read_file") != null);
    try std.testing.expect(bindings.find("write_file") == null);
}

const FakeBackend = struct {
    calls: usize = 0,
    last_tool: []const u8 = "",
    last_args: [256]u8 = undefined,
    last_args_len: usize = 0,
    fail: bool = false,
    request_cancel: ?*std.atomic.Value(bool) = null,

    fn call(
        raw_ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        tool: bindings.Tool,
        args_json: []const u8,
    ) anyerror![]u8 {
        const self: *FakeBackend = @ptrCast(@alignCast(raw_ctx.?));
        self.calls += 1;
        self.last_tool = tool.name;
        self.last_args_len = @min(args_json.len, self.last_args.len);
        @memcpy(self.last_args[0..self.last_args_len], args_json[0..self.last_args_len]);
        if (self.request_cancel) |flag| flag.store(true, .seq_cst);
        if (self.fail) return error.FakeToolFailure;

        // The bridge carries JSON text; parsing proves the script sent JSON.
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
        defer parsed.deinit();
        return allocator.dupe(u8, "{\"ok\":true}");
    }
};

test "codemode tools.list reports only the read-only trio" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval("tools.list().join(',')");
    defer result.deinit();
    try std.testing.expectEqualStrings("glob_files,grep_files,read_file", result.value);
}

test "codemode tools.call forwards JSON to the injected backend" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{};
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\tools.call("read_file", JSON.stringify({ path: "notes.txt" }));
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("{\"ok\":true}", result.value);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("read_file", fake.last_tool);
    try std.testing.expectEqualStrings("{\"path\":\"notes.txt\"}", fake.last_args[0..fake.last_args_len]);
}

test "codemode tools.call throws for a tool outside the whitelist" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{};
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\try { tools.call("write_file", "{}"); "did not throw"; }
        \\catch (e) { e.message; }
    );
    defer result.deinit();
    try std.testing.expect(std.mem.find(u8, result.value, "write_file") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "codemode tools.call throws with the tool name when the backend fails" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{ .fail = true };
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\try { tools.call("grep_files", "{}"); "did not throw"; }
        \\catch (e) { e.message; }
    );
    defer result.deinit();
    try std.testing.expect(std.mem.find(u8, result.value, "grep_files") != null);
    try std.testing.expect(std.mem.find(u8, result.value, "FakeToolFailure") != null);
}

test "codemode tools.call stops before the backend when cancellation is requested" {
    var host = Host.init(std.testing.allocator, .{ .timeout_ms = 60_000 });
    defer host.deinit();
    var cancel = std.atomic.Value(bool).init(true);
    host.cancel_flag = &cancel;
    var fake = FakeBackend{};
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    try std.testing.expectError(error.Cancelled, host.eval("tools.call('read_file', '{}')"));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(host.cancelled());
}

test "codemode tools.call cancellation during the backend stops the script" {
    var host = Host.init(std.testing.allocator, .{ .timeout_ms = 10_000 });
    defer host.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    host.cancel_flag = &cancel;
    var fake = FakeBackend{ .request_cancel = &cancel };
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    try std.testing.expectError(error.Cancelled, host.eval(
        \\tools.call("read_file", "{}");
        \\while (true) {}
    ));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
