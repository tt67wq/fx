const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");

// Zig 0.17 removed @cImport; build.zig translates the vendored public header
// into this module.
const c = @import("quickjs");

const Allocator = std.mem.Allocator;

// translate-c's JS_MKVAL constants trip over extern unions at comptime, so
// the two values the host returns are built directly.
const js_undefined: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_UNDEFINED };
const js_exception: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_EXCEPTION };

pub const default_memory_limit_bytes: usize = 64 * 1024 * 1024;
pub const default_timeout_ms: u64 = 30_000;

pub const Options = struct {
    memory_limit_bytes: usize = default_memory_limit_bytes,
    timeout_ms: u64 = default_timeout_ms,
};

pub const EvalError = error{
    RuntimeInitFailed,
    ContextInitFailed,
    BindingFailed,
    ScriptError,
    Timeout,
    MemoryLimit,
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

    pub fn eval(self: *Host, script: []const u8) (EvalError || Allocator.Error)!Result {
        try self.ensureRuntime();
        const ctx = self.context.?;

        self.text_buf.clearRetainingCapacity();
        self.console_buf.clearRetainingCapacity();
        self.timed_out = false;
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
    return 0;
}

fn textCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const context = ctx orelse return js_exception;
    const host: *Host = @ptrCast(@alignCast(c.JS_GetContextOpaque(context) orelse return js_exception));
    if (argc > 0) {
        const appended = appendValue(host, context, &host.text_buf, argv[0]);
        if (c.JS_IsException(appended)) return appended;
    }
    return js_undefined;
}

fn consoleLogCallback(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const context = ctx orelse return js_exception;
    const host: *Host = @ptrCast(@alignCast(c.JS_GetContextOpaque(context) orelse return js_exception));
    var index: c_int = 0;
    while (index < argc) : (index += 1) {
        if (index > 0) {
            host.console_buf.append(host.allocator, ' ') catch return c.JS_ThrowOutOfMemory(context);
        }
        const appended = appendValue(host, context, &host.console_buf, argv[@intCast(index)]);
        if (c.JS_IsException(appended)) return appended;
    }
    host.console_buf.append(host.allocator, '\n') catch return c.JS_ThrowOutOfMemory(context);
    return js_undefined;
}

fn appendValue(
    host: *Host,
    ctx: *c.JSContext,
    out: *std.ArrayList(u8),
    value: c.JSValue,
) c.JSValue {
    var len: usize = 0;
    const ptr = c.JS_ToCStringLen(ctx, &len, value) orelse return js_exception;
    defer c.JS_FreeCString(ctx, ptr);
    out.appendSlice(host.allocator, ptr[0..len]) catch return c.JS_ThrowOutOfMemory(ctx);
    return js_undefined;
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

test "codemode exposes no host globals" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\[typeof std, typeof os, typeof require, typeof process].join(",");
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("undefined,undefined,undefined,undefined", result.value);
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
