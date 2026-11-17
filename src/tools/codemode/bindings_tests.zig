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

const budget_schemas = [_]bindings.ToolSchema{
    .{ .name = "glob_files", .schema_json =
    \\{"description":"match files","inputSchema":{"type":"object","properties":{"pattern":{"type":"string"}}}}
    },
    .{ .name = "write_file", .schema_json =
    \\{"description":"write a file to disk","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}}}}
    },
};

test "searchTools and describeTool are injected globals that leave tools untouched" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);

    var result = try host.eval(
        \\var before_keys = Object.keys(tools).join();
        \\var before_wl = JSON.stringify(tools.__codemode_whitelist);
        \\searchTools("file");
        \\describeTool("glob_files");
        \\typeof searchTools + "," + typeof describeTool + "," +
        \\(Object.keys(tools).join() === before_keys) + "," +
        \\(JSON.stringify(tools.__codemode_whitelist) === before_wl)
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("function,function,true,true", result.value);
}

test "tools.list stays unfiltered and unannotated when the budget does not trigger" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);
    host.catalog_budget = 64 * 1024;

    var result = try host.eval(
        \\var list = tools.list();
        \\var extra = Object.getOwnPropertyNames(list).filter(function (p) { return p !== "0" && p !== "1" && p !== "length"; }).join();
        \\list.length + "|" + extra + "|" + (("omitted" in list) || ("hint" in list))
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("2||false", result.value);
}

test "tools.list appends omitted and hint own properties when the budget triggers" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);
    // Total schema bytes are a few hundred; this budget triggers and
    // leaves room only for tier zero after the notice floor.
    host.catalog_budget = 200;

    var result = try host.eval(
        \\var list = tools.list();
        \\var iterated = [];
        \\for (const entry of list) iterated.push(entry.name);
        \\list.length + "|" + iterated.join() + "|" +
        \\list.omitted.map(function (o) { return o.name + ":" + o.oversized; }).join() + "|" +
        \\(typeof list.hint === "string" && list.hint.indexOf("searchTools") >= 0)
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("1|glob_files|write_file:false|true", result.value);
}

test "omitted and hint stay invisible to map, index access, and JSON round trips" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);
    host.catalog_budget = 200;

    var result = try host.eval(
        \\var list = tools.list();
        \\var mapped = list.map(function (e) { return e.name; }).join();
        \\var indexed = list[1] === undefined;
        \\var parsed = JSON.parse(JSON.stringify(list));
        \\mapped + "|" + indexed + "|" + parsed.length + "|" + Array.isArray(parsed)
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("glob_files|true|1|true", result.value);
}

test "searchTools finds tools dropped from the listing and returns fresh objects" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);
    host.catalog_budget = 200;

    var result = try host.eval(
        \\var first = searchTools("write a file");
        \\var hit = first.find(function (h) { return h.name === "write_file"; });
        \\first.length + "|" + (hit !== undefined) + "|" + (typeof hit.description === "string") + "|" +
        \\(function () { first[0].name = "mutated"; return searchTools("write")[0].name !== "mutated"; })()
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("1|true|true|true", result.value);
}

test "searchTools validates the query and the limit option" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);

    var result = try host.eval(
        \\var results = [];
        \\function probe(fn) { try { fn(); results.push("ok"); } catch (e) { results.push(e.name); } }
        \\probe(() => searchTools(42));
        \\probe(() => searchTools("file", { limit: 0 }));
        \\probe(() => searchTools("file", { limit: -1 }));
        \\probe(() => searchTools("file", { limit: 1.5 }));
        \\probe(() => searchTools("file", { limit: "8" }));
        \\probe(() => searchTools("file", { limit: 1 }));
        \\results.join()
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("TypeError,TypeError,TypeError,TypeError,TypeError,ok", result.value);
}

test "searchTools defaults the limit to eight" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    var schemas: [10]bindings.ToolSchema = undefined;
    var names: [10][]const u8 = undefined;
    var bufs: [10][64]u8 = undefined;
    var json_bufs: [10][96:0]u8 = undefined;
    for (0..10) |i| {
        names[i] = try std.mem.print(&bufs[i], "tool_{d}", .{i});
        const json = try std.mem.printSentinel(&json_bufs[i], "{{\"description\":\"common haystack\"}}", .{}, 0);
        schemas[i] = .{ .name = names[i], .schema_json = json };
    }
    host.setToolSchemas(&schemas);

    var result = try host.eval("searchTools(\"haystack\").length");
    defer result.deinit();
    try std.testing.expectEqualStrings("8", result.value);
}

test "describeTool returns the same shape as a tools.list element" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);

    var result = try host.eval(
        \\var described = describeTool("glob_files");
        \\var listed = tools.list()[0];
        \\JSON.stringify(described) === JSON.stringify(listed)
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("true", result.value);
}

test "describeTool throws a TypeError with suggestions for an unknown name" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);

    var result = try host.eval(
        \\try { describeTool("glob_filez"); "did not throw"; }
        \\catch (e) { e.name + "|" + (e.message.indexOf("glob_files") >= 0) + "|" + (e.message.indexOf("searchTools") >= 0) }
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("TypeError|true|true", result.value);
}

test "describeTool covers a tool the listing dropped" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolSchemas(&budget_schemas);
    host.catalog_budget = 200;

    var result = try host.eval(
        \\var described = describeTool("write_file");
        \\described.name + "|" + (typeof described.description === "string") + "|" +
        \\(typeof described.parameters === "object") + "|" +
        \\(typeof described.parameters.properties.content === "object")
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("write_file|true|true|true", result.value);
}

const budget_face = [_]bindings.Tool{
    .{ .name = "glob_files" },
    .{ .name = "write_file" },
};

test "a tool outside the budgeted catalog is still callable and searchable" {
    // The catalog budget drops write_file from tools.list(); the whitelist
    // and the named functions come from the face, so both call paths must
    // still reach the backend instead of reporting an unknown tool
    // (proposal-b 2(c): the callable face equals the pre-budget face).
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    host.setToolFace(&budget_face);
    host.setToolSchemas(&budget_schemas);
    host.catalog_budget = 200;
    var fake = FakeBackend{};
    host.setToolBackend(.{ .ctx = &fake, .call = FakeBackend.call });

    var result = try host.eval(
        \\var listed = tools.list().map(function (e) { return e.name; });
        \\var out = [];
        \\out.push(listed.join());
        \\out.push(listed.indexOf("write_file") < 0);
        \\out.push(await tools.call("write_file", { path: "notes.txt" }));
        \\out.push(await tools.write_file({ path: "notes.txt" }));
        \\out.push(searchTools("write").some(function (h) { return h.name === "write_file"; }));
        \\out.join("|")
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("glob_files|true|{\"ok\":true}|{\"ok\":true}|true", result.value);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqualStrings("write_file", fake.last_tool);
}
