const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const bindings = @import("bindings.zig");

// Zig 0.17 removed @cImport; build.zig translates the vendored public header
// into this module.
const c = @import("quickjs");

const Allocator = std.mem.Allocator;

// translate-c's JS_MKVAL constants trip over extern unions at comptime, so
// the values the host returns are built directly.
const js_undefined: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_UNDEFINED };
const js_false: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_BOOL };
const js_exception: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_EXCEPTION };

pub const default_memory_limit_bytes: usize = 64 * 1024 * 1024;
pub const default_timeout_ms: u64 = 30_000;
pub const default_output_buffer_bytes: usize = 64 * 1024;

pub const Options = struct {
    memory_limit_bytes: usize = default_memory_limit_bytes,
    timeout_ms: u64 = default_timeout_ms,
    output_buffer_bytes: usize = default_output_buffer_bytes,
};

pub const EvalError = error{
    RuntimeInitFailed,
    ContextInitFailed,
    BindingFailed,
    ScriptError,
    Timeout,
    MemoryLimit,
    Cancelled,
};

pub const Result = struct {
    value: []u8,
    text: []u8,
    console: []u8,
    allocator: Allocator,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.value);
        self.allocator.free(self.text);
        self.allocator.free(self.console);
        self.* = undefined;
    }
};

/// A single-threaded QuickJS host. The runtime is created on the first eval so
/// startup never pays for the engine. Do not move a host after its first eval:
/// the interrupt handler keeps a pointer to it.
pub const Host = struct {
    allocator: Allocator,
    options: Options,
    runtime: ?*c.JSRuntime = null,
    context: ?*c.JSContext = null,
    deadline_ms: i64 = 0,
    timed_out: bool = false,
    cancelled_flag: bool = false,
    /// Cancel source shared with the caller, typically
    /// &worker.worker_cancel_requested. Read only from the interrupt handler
    /// and eval, both on the host's own thread; the writer is any thread.
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    /// The injected owner of real tool execution; the host only forwards
    /// JSON text across the bridge.
    tool_backend: ?bindings.Backend = null,
    text_buf: std.ArrayList(u8) = .empty,
    console_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator, options: Options) Host {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Host) void {
        if (self.context) |ctx| {
            c.JS_FreeContext(ctx);
            self.context = null;
        }
        if (self.runtime) |rt| {
            c.JS_FreeRuntime(rt);
            self.runtime = null;
        }
        self.text_buf.deinit(self.allocator);
        self.console_buf.deinit(self.allocator);
    }

    pub fn runtimeCreated(self: Host) bool {
        return self.runtime != null;
    }

    /// True when the last eval stopped because the cancel flag was set.
    pub fn cancelled(self: Host) bool {
        return self.cancelled_flag;
    }

    pub fn setToolBackend(self: *Host, backend: bindings.Backend) void {
        self.tool_backend = backend;
    }

    fn cancelRequested(self: Host) bool {
        const flag = self.cancel_flag orelse return self.cancelled_flag;
        return flag.load(.seq_cst);
    }

    pub fn eval(self: *Host, script: []const u8) (EvalError || Allocator.Error)!Result {
        try self.ensureRuntime();
        const ctx = self.context.?;

        self.text_buf.clearRetainingCapacity();
        self.console_buf.clearRetainingCapacity();
        self.timed_out = false;
        self.cancelled_flag = false;
        const timeout_ms: i64 = std.math.cast(i64, self.options.timeout_ms) orelse std.math.maxInt(i64);
        self.deadline_ms = io_mod.milliTimestamp() +| timeout_ms;

        const source = try self.allocator.dupeSentinel(u8, script, 0);
        defer self.allocator.free(source);

        // Global mode: the script's last expression is the result, and no
        // module loader is installed.
        const value = c.JS_Eval(ctx, source.ptr, script.len, "codemode.js", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(ctx, value);

        if (c.JS_IsException(value)) return self.takeExceptionError(ctx);

        const rendered = try self.stringify(ctx, value);
        errdefer self.allocator.free(rendered);
        const text = try self.text_buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(text);
        const console = try self.console_buf.toOwnedSlice(self.allocator);

        return .{
            .value = rendered,
            .text = text,
            .console = console,
            .allocator = self.allocator,
        };
    }

    fn ensureRuntime(self: *Host) (EvalError || Allocator.Error)!void {
        if (self.runtime != null) return;

        const rt = c.JS_NewRuntime() orelse return error.RuntimeInitFailed;
        errdefer c.JS_FreeRuntime(rt);
        c.JS_SetMemoryLimit(rt, self.options.memory_limit_bytes);

        const ctx = c.JS_NewContext(rt) orelse return error.ContextInitFailed;
        errdefer c.JS_FreeContext(ctx);
        c.JS_SetContextOpaque(ctx, self);
        c.JS_SetInterruptHandler(rt, interruptHandler, self);

        try installBindings(ctx);

        self.runtime = rt;
        self.context = ctx;
    }

    fn installBindings(ctx: *c.JSContext) EvalError!void {
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);

        const text_fn = c.JS_NewCFunction(ctx, textCallback, "text", 1);
        if (c.JS_IsException(text_fn)) return error.BindingFailed;
        if (c.JS_SetPropertyStr(ctx, global, "text", text_fn) < 0) return error.BindingFailed;

        const console_obj = c.JS_NewObject(ctx);
        if (c.JS_IsException(console_obj)) return error.BindingFailed;
        const log_fn = c.JS_NewCFunction(ctx, consoleLogCallback, "log", 1);
        if (c.JS_IsException(log_fn)) {
            c.JS_FreeValue(ctx, console_obj);
            return error.BindingFailed;
        }
        if (c.JS_SetPropertyStr(ctx, console_obj, "log", log_fn) < 0) {
            c.JS_FreeValue(ctx, console_obj);
            return error.BindingFailed;
        }
        if (c.JS_SetPropertyStr(ctx, global, "console", console_obj) < 0) return error.BindingFailed;

        const tools_obj = c.JS_NewObject(ctx);
        if (c.JS_IsException(tools_obj)) return error.BindingFailed;
        const list_fn = c.JS_NewCFunction(ctx, toolsListCallback, "list", 0);
        if (c.JS_IsException(list_fn)) {
            c.JS_FreeValue(ctx, tools_obj);
            return error.BindingFailed;
        }
        if (c.JS_SetPropertyStr(ctx, tools_obj, "list", list_fn) < 0) {
            c.JS_FreeValue(ctx, tools_obj);
            return error.BindingFailed;
        }
        const call_fn = c.JS_NewCFunction(ctx, toolsCallCallback, "call", 2);
        if (c.JS_IsException(call_fn)) {
            c.JS_FreeValue(ctx, tools_obj);
            return error.BindingFailed;
        }
        if (c.JS_SetPropertyStr(ctx, tools_obj, "call", call_fn) < 0) {
            c.JS_FreeValue(ctx, tools_obj);
            return error.BindingFailed;
        }
        if (c.JS_SetPropertyStr(ctx, global, "tools", tools_obj) < 0) return error.BindingFailed;
    }

    fn stringify(self: *Host, ctx: *c.JSContext, value: c.JSValueConst) (EvalError || Allocator.Error)![]u8 {
        var len: usize = 0;
        const ptr = c.JS_ToCStringLen(ctx, &len, value) orelse return self.takeExceptionError(ctx);
        defer c.JS_FreeCString(ctx, ptr);
        return self.allocator.dupe(u8, ptr[0..len]);
    }

    fn takeExceptionError(self: *Host, ctx: *c.JSContext) EvalError {
        const exception = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, exception);
        if (self.cancelled_flag) return error.Cancelled;
        if (self.timed_out) return error.Timeout;
        if (isOutOfMemory(self, ctx, exception)) return error.MemoryLimit;
        return error.ScriptError;
    }
};

fn interruptHandler(_: ?*c.JSContext, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(opaque_ptr orelse return 0));
    if (io_mod.milliTimestamp() >= host.deadline_ms) {
        host.timed_out = true;
        return 1;
    }
    // The cancel flag is the same atomic the worker path sets, so Escape and
    // every other cancel route stop the script through one source.
    if (host.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) {
            host.cancelled_flag = true;
            return 1;
        }
    }
    return 0;
}

fn textCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const context = ctx orelse return js_exception;
    const host: *Host = @ptrCast(@alignCast(c.JS_GetContextOpaque(context) orelse return js_exception));
    if (argc > 0) {
        var len: usize = 0;
        const ptr = c.JS_ToCStringLen(context, &len, argv[0]) orelse return js_exception;
        defer c.JS_FreeCString(context, ptr);
        switch (appendCapped(host, &host.text_buf, ptr[0..len])) {
            .complete => {},
            .truncated => return js_false,
            .out_of_memory => return c.JS_ThrowOutOfMemory(context),
        }
    }
    return js_undefined;
}

fn consoleLogCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const context = ctx orelse return js_exception;
    const host: *Host = @ptrCast(@alignCast(c.JS_GetContextOpaque(context) orelse return js_exception));
    var truncated = false;
    var index: c_int = 0;
    while (index < argc) : (index += 1) {
        if (index > 0) {
            switch (appendCapped(host, &host.console_buf, " ")) {
                .complete => {},
                .truncated => truncated = true,
                .out_of_memory => return c.JS_ThrowOutOfMemory(context),
            }
        }
        var len: usize = 0;
        const ptr = c.JS_ToCStringLen(context, &len, argv[@intCast(index)]) orelse return js_exception;
        defer c.JS_FreeCString(context, ptr);
        switch (appendCapped(host, &host.console_buf, ptr[0..len])) {
            .complete => {},
            .truncated => truncated = true,
            .out_of_memory => return c.JS_ThrowOutOfMemory(context),
        }
    }
    switch (appendCapped(host, &host.console_buf, "\n")) {
        .complete => {},
        .truncated => truncated = true,
        .out_of_memory => return c.JS_ThrowOutOfMemory(context),
    }
    return if (truncated) js_false else js_undefined;
}

fn toolsListCallback(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    const context = ctx orelse return js_exception;
    const array = c.JS_NewArray(context);
    if (c.JS_IsException(array)) return array;
    for (bindings.tools, 0..) |tool, index| {
        const name = c.JS_NewStringLen(context, tool.name.ptr, tool.name.len);
        if (c.JS_IsException(name)) {
            c.JS_FreeValue(context, array);
            return name;
        }
        if (c.JS_SetPropertyUint32(context, array, @intCast(index), name) < 0) {
            c.JS_FreeValue(context, array);
            return js_exception;
        }
    }
    return array;
}

fn toolsCallCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const context = ctx orelse return js_exception;
    const host: *Host = @ptrCast(@alignCast(c.JS_GetContextOpaque(context) orelse return js_exception));

    // A cancelled script must not start another tool call. The interrupt
    // handler covers code between calls; this covers the call entry itself.
    if (host.cancelRequested()) {
        host.cancelled_flag = true;
        return c.JS_ThrowPlainError(context, "codemode cancelled");
    }
    if (io_mod.milliTimestamp() >= host.deadline_ms) {
        host.timed_out = true;
        return c.JS_ThrowPlainError(context, "codemode timed out");
    }
    if (argc < 2) {
        return c.JS_ThrowTypeError(context, "tools.call requires a tool name and a JSON string");
    }

    var name_len: usize = 0;
    const name_ptr = c.JS_ToCStringLen(context, &name_len, argv[0]) orelse return js_exception;
    defer c.JS_FreeCString(context, name_ptr);
    const name = name_ptr[0..name_len];
    const tool = bindings.find(name) orelse {
        var message_buf: [256]u8 = undefined;
        const message: [:0]const u8 = std.mem.printSentinel(&message_buf, "unknown codemode tool: {s}", .{name}, 0) catch
            "unknown codemode tool";
        return c.JS_ThrowTypeError(context, "%s", message.ptr);
    };

    var args_len: usize = 0;
    const args_ptr = c.JS_ToCStringLen(context, &args_len, argv[1]) orelse return js_exception;
    defer c.JS_FreeCString(context, args_ptr);

    const backend = host.tool_backend orelse {
        var message_buf: [256]u8 = undefined;
        const message: [:0]const u8 = std.mem.printSentinel(
            &message_buf,
            "codemode tool {s} has no backend",
            .{tool.name},
            0,
        ) catch "codemode tool has no backend";
        return c.JS_ThrowPlainError(context, "%s", message.ptr);
    };
    const result = backend.call(backend.ctx, host.allocator, tool, args_ptr[0..args_len]) catch |err| {
        var message_buf: [256]u8 = undefined;
        const message: [:0]const u8 = std.mem.printSentinel(
            &message_buf,
            "codemode tool {s} failed: {s}",
            .{ tool.name, @errorName(err) },
            0,
        ) catch "codemode tool call failed";
        return c.JS_ThrowPlainError(context, "%s", message.ptr);
    };
    defer host.allocator.free(result);
    return c.JS_NewStringLen(context, result.ptr, result.len);
}

const AppendOutcome = enum { complete, truncated, out_of_memory };

/// Appends what fits under the output cap and reports dropped bytes.
/// text and console.log return false in that case so a script can notice
/// truncation without the eval failing. These buffers live on the host
/// allocator, so JS_SetMemoryLimit does not bound them.
fn appendCapped(host: *Host, out: *std.ArrayList(u8), bytes: []const u8) AppendOutcome {
    if (bytes.len == 0) return .complete;
    const remaining = host.options.output_buffer_bytes -| out.items.len;
    if (remaining == 0) return .truncated;
    const take = @min(bytes.len, remaining);
    out.appendSlice(host.allocator, bytes[0..take]) catch return .out_of_memory;
    return if (take < bytes.len) .truncated else .complete;
}

fn isOutOfMemory(host: *Host, ctx: *c.JSContext, exception: c.JSValue) bool {
    if (c.JS_IsUninitialized(exception)) return memoryLimitReached(host);
    var len: usize = 0;
    const ptr = c.JS_ToCStringLen(ctx, &len, exception) orelse {
        const pending = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, pending);
        return memoryLimitReached(host);
    };
    defer c.JS_FreeCString(ctx, ptr);
    if (std.mem.find(u8, ptr[0..len], "out of memory") != null) return true;
    return false;
}

/// A cap this close leaves no room for the error object's own allocation, so
/// the exception message is lost; the usage numbers still identify the cause.
fn memoryLimitReached(host: *Host) bool {
    var usage: c.JSMemoryUsage = undefined;
    c.JS_ComputeMemoryUsage(host.runtime.?, &usage);
    return usage.malloc_limit > 0 and usage.malloc_size >= usage.malloc_limit - 1;
}

test "codemode host creates its runtime lazily" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    try std.testing.expect(!host.runtimeCreated());

    var result = try host.eval("1 + 2");
    defer result.deinit();
    try std.testing.expect(host.runtimeCreated());
    try std.testing.expectEqualStrings("3", result.value);
}

test "codemode host returns the script value" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval("40 + 2");
    defer result.deinit();
    try std.testing.expectEqualStrings("42", result.value);
    try std.testing.expectEqualStrings("", result.text);
    try std.testing.expectEqualStrings("", result.console);
}

test "codemode text collects output" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\text("hello ");
        \\text(42);
        \\"done";
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.value);
    try std.testing.expectEqualStrings("hello 42", result.text);
    try std.testing.expectEqualStrings("", result.console);
}

test "codemode console.log captures every argument" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\console.log("a", 1, true);
        \\console.log();
        \\"ok";
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("ok", result.value);
    try std.testing.expectEqualStrings("a 1 true\n\n", result.console);
    try std.testing.expectEqualStrings("", result.text);
}

test "codemode text stops at the output buffer cap" {
    var host = Host.init(std.testing.allocator, .{ .output_buffer_bytes = 32 });
    defer host.deinit();

    var result = try host.eval(
        \\let drops = 0;
        \\for (let i = 0; i < 3; i++) if (text("x".repeat(100)) === false) drops++;
        \\drops;
    );
    defer result.deinit();
    // text reports truncation, but the script still finishes normally.
    try std.testing.expectEqualStrings("3", result.value);
    try std.testing.expectEqual(@as(usize, 32), result.text.len);
    for (result.text) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
}

test "codemode console.log stops at the output buffer cap" {
    var host = Host.init(std.testing.allocator, .{ .output_buffer_bytes = 32 });
    defer host.deinit();

    var result = try host.eval(
        \\let drops = 0;
        \\for (let i = 0; i < 3; i++) if (console.log("x".repeat(100)) === false) drops++;
        \\drops;
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("3", result.value);
    try std.testing.expectEqual(@as(usize, 32), result.console.len);
    for (result.console) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
}

test "codemode exposes no host globals" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\[typeof std, typeof os, typeof require, typeof process, typeof tools, typeof tools.list, typeof tools.call].join(",");
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("undefined,undefined,undefined,undefined,object,function,function", result.value);
}

test "codemode reports script exceptions" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    try std.testing.expectError(error.ScriptError, host.eval("throw new Error('boom')"));
}

test "codemode memory cap stops runaway allocation" {
    var host = Host.init(std.testing.allocator, .{
        .memory_limit_bytes = 4 * 1024 * 1024,
        .timeout_ms = 10_000,
    });
    defer host.deinit();

    try std.testing.expectError(error.MemoryLimit, host.eval(
        \\let parts = [];
        \\for (;;) parts.push("x".repeat(65536));
    ));
}

test "codemode timeout interrupts a tight loop" {
    var host = Host.init(std.testing.allocator, .{ .timeout_ms = 50 });
    defer host.deinit();

    try std.testing.expectError(error.Timeout, host.eval("while (true) {}"));

    var result = try host.eval("1 + 1");
    defer result.deinit();
    try std.testing.expectEqualStrings("2", result.value);
}

test {
    // Pull the sandbox thread model and the tool bridge tests into every
    // test build.
    _ = @import("bindings_tests.zig");
    _ = @import("sandbox.zig");
}
