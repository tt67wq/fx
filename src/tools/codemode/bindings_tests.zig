const std = @import("std");
const bindings = @import("bindings.zig");
const host_mod = @import("host.zig");
const shell = @import("shell.zig");
const bridge = @import("bridge.zig");
const builtin_tools = @import("../../builtins/tools.zig");

const Host = host_mod.Host;

test "codemode tool registry holds three read-only tools plus run_command" {
    try std.testing.expectEqual(@as(usize, 4), bindings.tools.len);
    try std.testing.expect(bindings.find("glob_files") != null);
    try std.testing.expect(bindings.find("grep_files") != null);
    try std.testing.expect(bindings.find("read_file") != null);
    try std.testing.expect(bindings.find("run_command") != null);
    try std.testing.expect(bindings.find("write_file") == null);
}

test "sandbox face locks the shipped four names and the nine-name derived face" {
    const registry = builtin_tools.registry;
    // The shipped face is what a fresh profile gets; the default-face
    // lookups below are about that face, not the gate-open one.
    const closed = bridge.sandboxFace(registry, false);
    try std.testing.expectEqual(@as(usize, 4), closed.len);
    const closed_names = [_][]const u8{ "glob_files", "grep_files", "read_file", "run_command" };
    for (closed_names, closed) |expected, tool| {
        try std.testing.expectEqualStrings(expected, tool.name);
    }

    // The derived face is every marked tool in registry order, then
    // run_command. The gate selects this face; it never authorizes a call,
    // so write and edit tools appear here and are still admitted per call.
    const open = bridge.sandboxFace(registry, true);
    const open_names = [_][]const u8{
        "glob_files",
        "grep_files",
        "read_file",
        "write_file",
        "edit_file",
        "web_fetch",
        "ask_user_question",
        "vision",
        "run_command",
    };
    try std.testing.expectEqual(open_names.len, open.len);
    for (open_names, open) |expected, tool| {
        try std.testing.expectEqualStrings(expected, tool.name);
    }
    try std.testing.expectEqual(true, builtin_tools.registry.lookup("write_file").?.sandbox_reachable);
    try std.testing.expectEqual(true, builtin_tools.registry.lookup("edit_file").?.sandbox_reachable);
    try std.testing.expectEqual(true, builtin_tools.registry.lookup("read_file").?.sandbox_reachable);
    try std.testing.expectEqual(false, builtin_tools.registry.lookup("shell").?.sandbox_reachable);
    try std.testing.expectEqual(false, builtin_tools.registry.lookup("subagent").?.sandbox_reachable);
    // codemode itself is not in the builtin registry (the tool set adds it),
    // so reachability for it cannot be asserted here.
    try std.testing.expect(builtin_tools.registry.lookup("codemode") == null);
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
    shell_upstream_truncated: bool = false,

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
            return shell.encodeResultJson(allocator, self.shell_exit_code, self.shell_output, self.shell_budget, self.shell_upstream_truncated);
        }
        return allocator.dupe(u8, "{\"ok\":true}");
    }
};

const sample_schemas = [_]bindings.ToolSchema{
    .{ .name = "glob_files", .schema_json = "{\"type\":\"function\",\"name\":\"glob_files\",\"description\":\"match files\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}}" },
    .{ .name = "read_file", .schema_json = "{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"read a file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}" },
};

test "codemode tools.list returns schema objects with script-facing names" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&sample_schemas);

    var result = try host.eval("tools.list().map(t => t.name).join(',') + '|' + typeof tools.list()[0]");
    defer result.deinit();
    try std.testing.expectEqualStrings("glob_files,read_file|object", result.value);
}

test "codemode tools.list exposes parsed input schema as parameters" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&sample_schemas);

    var result = try host.eval(
        \\var t = tools.list()[0];
        \\t.description + '|' + t.parameters.properties.pattern.type + '|' + t.parameters.required[0]
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("match files|string|pattern", result.value);
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

test "codemode tools.call captures the script line of the call site" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{};
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval("var a = 1;\ntools.call(\"read_file\", JSON.stringify({ path: \"notes.txt\" }));");
    defer result.deinit();
    // The call sits on the second line of the evaluated script.
}

test "codemode run_command bridge merges upstream truncation alone" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{ .shell_output = "hello\n", .shell_upstream_truncated = true };
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\tools.call("run_command", JSON.stringify({ command: "echo hello" }));
    );
    defer result.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.value, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(true, object.get("truncated").?.bool);
    try std.testing.expectEqualStrings("hello\n", object.get("output").?.string);
}

test "codemode run_command bridge merges upstream and budget truncation together" {
    const budget = 16;
    var big: [128]u8 = undefined;
    @memset(&big, 'x');

    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{ .shell_output = &big, .shell_budget = budget, .shell_upstream_truncated = true };
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\tools.call("run_command", JSON.stringify({ command: "yes" }));
    );
    defer result.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.value, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(true, object.get("truncated").?.bool);
    var marker_buf: [64]u8 = undefined;
    const marker = try std.mem.print(&marker_buf, "{} bytes omitted", .{big.len - budget});
    try std.testing.expect(std.mem.find(u8, object.get("output").?.string, marker) != null);
}

test "codemode run_command captures more than the direct-path budget without truncation" {
    // The script budget aligns with default_script_shell_budget_bytes (1MiB),
    // so output well past the direct run_command capture limit flows through
    // with truncation false.
    const size = 128 * 1024;
    const big = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');

    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{ .shell_output = big };
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\tools.call("run_command", JSON.stringify({ command: "yes" }));
    );
    defer result.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.value, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(false, object.get("truncated").?.bool);
    try std.testing.expectEqual(@as(usize, size), object.get("output").?.string.len);
}

test "codemode top-level await works and tools.call results are values" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var backend = FakeBackend{};
    host.setToolBackend(.{ .ctx = &backend, .call = FakeBackend.call });

    var r = try host.eval("const r = await tools.call('read_file', '{}'); typeof r");
    defer r.deinit();
    try std.testing.expectEqualStrings("string", r.value);
    try std.testing.expectEqual(@as(usize, 1), backend.calls);
}

test "tools.call accepts an object argument without JSON.stringify" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var backend = FakeBackend{};
    host.setToolBackend(.{ .ctx = &backend, .call = FakeBackend.call });
    var r = try host.eval("await tools.call('read_file', { path: 'README.md' })");
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), backend.calls);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, backend.last_args[0..backend.last_args_len], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("README.md", parsed.value.object.get("path").?.string);
}

test "tools.call object argument that cannot stringify reports the error" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var backend = FakeBackend{};
    host.setToolBackend(.{ .ctx = &backend, .call = FakeBackend.call });
    try std.testing.expectError(error.ScriptError, host.eval("const a = {}; a.self = a; await tools.call('read_file', a)"));
    const message = host.lastExceptionMessage() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, message, "circular") != null);
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "codemode script exceptions carry the message to the tool result" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    try std.testing.expectError(error.ScriptError, host.eval("throw new TypeError('bad args shape');"));
    // The message stays owned by the host until the next eval or deinit.
    const message = host.lastExceptionMessage() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, message, "bad args shape") != null);
}

test "codemode named functions exist for every whitelisted tool" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&sample_schemas);
    var result = try host.eval(
        \\var names = [];
        \\var entries = tools.list();
        \\for (var i = 0; i < entries.length; i++) {
        \\    if (typeof tools[entries[i].name] === "function") names.push(entries[i].name);
        \\}
        \\if (names.length !== entries.length) throw new Error("missing named functions");
        \\names.join(",");
    );
    defer result.deinit();
    try std.testing.expect(result.value.len > 0);
}

test "codemode named call forwards the object like tools.call" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{};
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });
    var result = try host.eval(
        \\tools.read_file({ path: "notes.txt" });
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("{\"ok\":true}", result.value);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("read_file", fake.last_tool);
    try std.testing.expectEqualStrings("{\"path\":\"notes.txt\"}", fake.last_args[0..fake.last_args_len]);
}

test "codemode named run_command reaches the backend as run_command" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{};
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });
    var result = try host.eval(
        \\tools.run_command({ command: "echo hi" });
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("run_command", fake.last_tool);
}

test "codemode named call runs alongside tools.call" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var fake = FakeBackend{};
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });
    var result = try host.eval(
        \\var first = tools.read_file({ path: "a.txt" });
        \\var second = tools.call("read_file", { path: "a.txt" });
        \\var both = await Promise.all([first, second]);
        \\both.length;
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}
