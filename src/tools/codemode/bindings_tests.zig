const std = @import("std");
const bindings = @import("bindings.zig");
const host_mod = @import("host.zig");
const shell = @import("shell.zig");

const Host = host_mod.Host;

test "codemode tool registry holds three read-only tools plus run_command" {
    try std.testing.expectEqual(@as(usize, 4), bindings.tools.len);
    try std.testing.expect(bindings.find("glob_files") != null);
    try std.testing.expect(bindings.find("grep_files") != null);
    try std.testing.expect(bindings.find("read_file") != null);
    try std.testing.expect(bindings.find("run_command") != null);
    try std.testing.expect(bindings.find("write_file") == null);
}

const FakeBackend = struct {
    calls: usize = 0,
    last_tool: []const u8 = "",
    last_args: [256]u8 = undefined,
    last_args_len: usize = 0,
    fail: bool = false,
    request_cancel: ?*std.atomic.Value(bool) = null,
    shell_exit_code: i64 = 0,
    shell_output: []const u8 = "ok\n",
    shell_budget: usize = shell.default_script_shell_budget_bytes,

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
        if (std.mem.eql(u8, tool.name, "run_command")) {
            return shell.encodeResultJson(allocator, self.shell_exit_code, self.shell_output, self.shell_budget);
        }
        return allocator.dupe(u8, "{\"ok\":true}");
    }
};

test "codemode tools.list reports three read-only tools plus run_command" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval("tools.list().join(',')");
    defer result.deinit();
    try std.testing.expectEqualStrings("glob_files,grep_files,read_file,run_command", result.value);
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

test "codemode run_command bridge passes small output through" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{ .shell_exit_code = 7, .shell_output = "hello\n" };
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\tools.call("run_command", JSON.stringify({ command: "printf hello" }));
    );
    defer result.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.value, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 7), object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings("hello\n", object.get("output").?.string);
    try std.testing.expectEqual(false, object.get("truncated").?.bool);
    try std.testing.expectEqualStrings("run_command", fake.last_tool);
    try std.testing.expectEqualStrings("{\"command\":\"printf hello\"}", fake.last_args[0..fake.last_args_len]);
}

test "codemode run_command bridge keeps output exactly at the budget" {
    const budget = 16;
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{ .shell_output = "abcdefghijklmnop", .shell_budget = budget };
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\tools.call("run_command", JSON.stringify({ command: "echo" }));
    );
    defer result.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.value, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("abcdefghijklmnop", object.get("output").?.string);
    try std.testing.expectEqual(false, object.get("truncated").?.bool);
}

test "codemode run_command bridge keeps the head and tail over the budget" {
    const budget = 16;
    const head = "HEAD----";
    const tail = "----TAIL";
    var big: [128]u8 = undefined;
    @memset(&big, 'x');
    @memcpy(big[0..head.len], head);
    @memcpy(big[big.len - tail.len ..], tail);
    const omitted = big.len - budget;

    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{ .shell_exit_code = 3, .shell_output = &big, .shell_budget = budget };
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\tools.call("run_command", JSON.stringify({ command: "yes" }));
    );
    defer result.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.value, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const output = object.get("output").?.string;
    try std.testing.expectEqual(@as(i64, 3), object.get("exit_code").?.integer);
    try std.testing.expectEqual(true, object.get("truncated").?.bool);
    try std.testing.expect(std.mem.startsWith(u8, output, head));
    try std.testing.expect(std.mem.endsWith(u8, output, tail));
    var marker_buf: [64]u8 = undefined;
    const marker = try std.mem.print(&marker_buf, "{} bytes omitted", .{omitted});
    try std.testing.expect(std.mem.find(u8, output, marker) != null);
}
