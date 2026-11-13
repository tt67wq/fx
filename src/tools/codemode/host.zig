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

/// Lower bound for a script-declared @options timeout.
pub const min_options_timeout_ms: u64 = 1_000;
/// Hard cap for a script-declared @options timeout: 2 minutes.
pub const max_options_timeout_ms: u64 = 120_000;
/// Hard cap for script-declared max_output_tokens: 64KiB / 4 bytes per token.
pub const max_options_output_tokens: u64 = 16_384;
/// Floor for a script-declared output buffer in bytes.
pub const options_output_floor_bytes: usize = 1_024;

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

/// The captured script-facing output moved out of the host buffers.
/// The caller owns both slices and frees them with the host allocator.
pub const PartialOutput = struct {
    text: []const u8 = "",
    console: []const u8 = "",
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
    last_script_error: ?[]u8 = null,
    /// Cancel source shared with the caller, typically
    /// &worker.worker_cancel_requested. Read only from the interrupt handler
    /// and eval, both on the host's own thread; the writer is any thread.
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    /// The injected owner of real tool execution; the host only forwards
    /// JSON text across the bridge.
    tool_backend: ?bindings.Backend = null,
    /// The injected model-facing schemas behind tools.list. Borrowed: the
    /// injector owns the slices and keeps them alive for every eval.
    tool_schemas: ?[]const bindings.ToolSchema = null,
    /// The script-facing surface this eval may forward, injected by the
    /// bridge. The shipped set unless the gate selected the derived face.
    /// Borrowed: the bridge owns it for the life of the eval.
    tool_face: []const bindings.Tool = &bindings.tools,
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
        if (self.last_script_error) |message| self.allocator.free(message);
        self.last_script_error = null;
    }

    /// Moves the captured text and console buffers to the caller and empties
    /// them, the same post-eval read the exception message uses. A second
    /// take yields empty slices, so deinit never double frees. On allocation
    /// failure the buffer stays behind for deinit and the slice is empty.
    pub fn takePartialOutput(self: *Host) PartialOutput {
        const text = self.text_buf.toOwnedSlice(self.allocator) catch "";
        const console = self.console_buf.toOwnedSlice(self.allocator) catch "";
        return .{ .text = text, .console = console };
    }

    /// The script-visible message of the last ScriptError, for the tool result.
    /// Borrowed view of the last script-visible exception text; owned by the
    /// host until the next eval or deinit, so callers must not free it.
    pub fn lastExceptionMessage(self: *const Host) ?[]const u8 {
        return self.last_script_error;
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

    pub fn setToolSchemas(self: *Host, schemas: []const bindings.ToolSchema) void {
        self.tool_schemas = schemas;
    }

    pub fn setToolFace(self: *Host, face: []const bindings.Tool) void {
        self.tool_face = face;
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
        if (self.last_script_error) |message| {
            self.allocator.free(message);
            self.last_script_error = null;
        }
        const timeout_ms: i64 = std.math.cast(i64, self.options.timeout_ms) orelse std.math.maxInt(i64);
        self.deadline_ms = io_mod.milliTimestamp() +| timeout_ms;
        const source = try self.allocator.dupeSentinel(u8, script, 0);
        defer self.allocator.free(source);
        // Global mode with the async flag: the script keeps its completion
        // value as the result, and the top-level await the tool contract
        // advertises works; eval returns a promise the drain below settles.
        const value = c.JS_Eval(ctx, source.ptr, script.len, "codemode.js", c.JS_EVAL_TYPE_GLOBAL | c.JS_EVAL_FLAG_ASYNC);
        defer c.JS_FreeValue(ctx, value);
        if (c.JS_IsException(value)) return self.takeExceptionError(ctx);
        // Drain the microtask queue while the eval promise is pending, up
        // to the deadline or a cancel. A top-level throw rejects the
        // promise; quickjs-ng's JS_PromiseResult returns the reason as a
        // plain value (not a JS exception), so the rejected state drives
        // the error mapping, not JS_IsException.
        while (true) {
            if (c.JS_PromiseState(ctx, value) != c.JS_PROMISE_PENDING) break;
            var job_ctx: ?*c.JSContext = null;
            const pending = c.JS_ExecutePendingJob(self.runtime.?, &job_ctx);
            if (pending == 0) return error.Timeout;
            if (self.cancelRequested()) return error.Cancelled;
            if (io_mod.milliTimestamp() >= self.deadline_ms) {
                self.timed_out = true;
                return error.Timeout;
            }
        }
        const settled = c.JS_PromiseResult(ctx, value);
        defer c.JS_FreeValue(ctx, settled);
        if (c.JS_PromiseState(ctx, value) == c.JS_PROMISE_REJECTED) {
            if (self.cancelRequested()) return error.Cancelled;
            if (self.timed_out) return error.Timeout;
            if (isOutOfMemory(self, ctx, settled)) return error.MemoryLimit;
            self.captureExceptionMessage(ctx, settled);
            return error.ScriptError;
        }
        // With the async flag the engine wraps the program's completion
        // value in a fresh {value: ...} object before resolving the eval
        // promise (js_parse_program emits OP_object/OP_put_field for
        // JS_FUNC_ASYNC), so unwrap it to recover the script result.
        var current = if (c.JS_VALUE_GET_TAG(settled) == c.JS_TAG_OBJECT)
            c.JS_GetPropertyStr(ctx, settled, "value")
        else
            settled;
        var current_owned = c.JS_VALUE_GET_TAG(settled) == c.JS_TAG_OBJECT;
        defer if (current_owned) c.JS_FreeValue(ctx, current);

        // A script that ends by returning its own promise - main() or an
        // async IIFE the script did not await - leaves that inner promise as
        // the completion value. Drain it like the eval promise: without
        // this the model sees "{}", the JSON of a promise object. The
        // {value: ...} wrapper is an eval-only artifact, so a resolved
        // inner value passes through unchanged.
        while (c.JS_PromiseState(ctx, current) != c.JS_PROMISE_NOT_A_PROMISE) {
            while (c.JS_PromiseState(ctx, current) == c.JS_PROMISE_PENDING) {
                var job_ctx: ?*c.JSContext = null;
                const pending = c.JS_ExecutePendingJob(self.runtime.?, &job_ctx);
                if (pending == 0) return error.Timeout;
                if (self.cancelRequested()) return error.Cancelled;
                if (io_mod.milliTimestamp() >= self.deadline_ms) {
                    self.timed_out = true;
                    return error.Timeout;
                }
            }
            const inner = c.JS_PromiseResult(ctx, current);
            if (c.JS_PromiseState(ctx, current) == c.JS_PROMISE_REJECTED) {
                if (self.cancelRequested()) {
                    c.JS_FreeValue(ctx, inner);
                    return error.Cancelled;
                }
                if (self.timed_out) {
                    c.JS_FreeValue(ctx, inner);
                    return error.Timeout;
                }
                if (isOutOfMemory(self, ctx, inner)) {
                    return error.MemoryLimit;
                }
                self.captureExceptionMessage(ctx, inner);
                c.JS_FreeValue(ctx, inner);
                return error.ScriptError;
            }
            if (current_owned) c.JS_FreeValue(ctx, current);
            current = inner;
            current_owned = true;
        }

        const rendered = try self.stringify(ctx, current);
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

        try installBindings(ctx, self.tool_face);
        // The interrupt handler is installed after the bindings: the shim
        // install below evaluates JS while deadline_ms is still 0, and a
        // handler would see every check as past the deadline.
        c.JS_SetInterruptHandler(rt, interruptHandler, self);

        self.runtime = rt;
        self.context = ctx;
    }

    fn installBindings(ctx: *c.JSContext, face: []const bindings.Tool) EvalError!void {
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
        const call_fn = c.JS_NewCFunction(ctx, toolsCallCallback, "__codemode_native_call", 3);
        if (c.JS_IsException(call_fn)) {
            c.JS_FreeValue(ctx, tools_obj);
            return error.BindingFailed;
        }
        if (c.JS_SetPropertyStr(ctx, tools_obj, "__codemode_native_call", call_fn) < 0) {
            c.JS_FreeValue(ctx, tools_obj);
            return error.BindingFailed;
        }
        // The visible tools.call is a shim that captures the script line the
        // call was made from and forwards it to the native entry. Line
        // numbers travel in a separate argument, never inside the review
        // origin or the call id. The shim reads the global tools object, so
        // it must be installed on the global first.
        if (c.JS_SetPropertyStr(ctx, global, "tools", tools_obj) < 0) {
            c.JS_FreeValue(ctx, tools_obj);
            return error.BindingFailed;
        }
        if (installCallShim(ctx, tools_obj, face) != 0) return error.BindingFailed;
    }

    /// Evaluates the tools.call shim against `tools_obj` and returns 0 on
    /// success. The shim throws from inside itself to read Error.stack, skips
    /// its own frames, and takes the first user-script frame's line number.
    fn installCallShim(ctx: *c.JSContext, tools_obj: c.JSValue, face: []const bindings.Tool) c_int {
        // The shim installs one named function per tool on the selected face.
        // The names come from the face rather than tools.list(): a tool stays
        // callable through tools.call even when the bridge has not injected
        // its schema, so its named function must exist too (see the "named
        // functions exist for every whitelisted tool" test in
        // bindings_tests.zig).
        //
        // Why the names are injected at runtime instead of as a compile-time
        // literal: two faces now exist and the binary selects one per eval at
        // runtime, so a single literal cannot describe both. Building the
        // array here keeps QuickJS owning its own copies of the names, so no
        // Zig slice outlives this call and no string is concatenated.
        //
        // This shim only decides which names the script can write down. It is
        // not an authorization point: toolsCallCallback checks the same face
        // after the interrupt and deadline checks, and the only execution
        // path past it is the bridge's nested admission, which resolves
        // against the full built-in registry on every call. Adding a name
        // here never makes a call review-free.
        const whitelist = c.JS_NewArray(ctx);
        if (c.JS_IsException(whitelist)) return -1;
        for (face, 0..) |tool, index| {
            const tool_name = c.JS_NewStringLen(ctx, tool.name.ptr, tool.name.len);
            if (c.JS_IsException(tool_name)) {
                c.JS_FreeValue(ctx, whitelist);
                return -1;
            }
            // JS_SetPropertyUint32 consumes tool_name whether it succeeds or
            // fails (quickjs.c JS_SetPropertyValue and add_fast_array_element, via JS_SetPropertyUint32), so the failure
            // branch frees only the array it still owns.
            if (c.JS_SetPropertyUint32(ctx, whitelist, @intCast(index), tool_name) < 0) {
                c.JS_FreeValue(ctx, whitelist);
                return -1;
            }
        }
        // JS_SetPropertyStr consumes whitelist on both outcomes, so a failed
        // write leaves nothing to free here.
        if (c.JS_SetPropertyStr(ctx, tools_obj, "__codemode_whitelist", whitelist) < 0) {
            return -1;
        }
        const shim =
            \\(function (tools, native, whitelist) {
            \\    "use strict";
            \\    function call(name, args) {
            \\        var line = "";
            \\        try {
            \\            null.x();
            \\        } catch (e) {
            \\            var frames = String(e.stack || "").split("\n");
            \\            for (var i = 0; i < frames.length; i++) {
            \\                if (frames[i].indexOf("codemode-shim") >= 0) continue;
            \\                var m = frames[i].match(/:(\d+)(?::\d+)?\)?\s*$/);
            \\                if (m) {
            \\                    line = m[1];
            \\                    break;
            \\                }
            \\            }
            \\        }
            \\        return native(name, args, line);
            \\    }
            \\    tools.call = call;
            \\    for (var i = 0; i < whitelist.length; i++) {
            \\        (function (name) {
            \\            if (name === "call" || name === "list") return;
            \\            tools[name] = function (args) { return call(name, args); };
            \\        })(whitelist[i]);
            \\    }
            \\})(tools, tools.__codemode_native_call, tools.__codemode_whitelist)
        ;
        const script_len: usize = shim.len;
        const result = c.JS_Eval(
            ctx,
            shim.ptr,
            script_len,
            "codemode-shim",
            c.JS_EVAL_TYPE_GLOBAL,
        );
        if (c.JS_IsException(result)) {
            c.JS_FreeValue(ctx, result);
            return -1;
        }
        c.JS_FreeValue(ctx, result);
        // Drop the native entry so scripts cannot bypass the line capture.
        const native_atom = c.JS_NewAtomLen(ctx, "__codemode_native_call", "__codemode_native_call".len);
        if (native_atom == c.JS_ATOM_NULL) return -1;
        defer c.JS_FreeAtom(ctx, native_atom);
        if (c.JS_DeleteProperty(ctx, tools_obj, native_atom, 0) < 0) return -1;
        return 0;
    }

    /// Renders a completion value for the tool result: objects come out as
    /// JSON so the model can read a nested tool result without calling
    /// JSON.stringify itself. Serialization that fails, such as a circular
    /// reference, clears the pending exception and falls back to the plain
    /// string form so the engine stays healthy for later evals.
    fn stringify(self: *Host, ctx: *c.JSContext, value: c.JSValueConst) (EvalError || Allocator.Error)![]u8 {
        var len: usize = 0;
        const ptr = renderCValue(self, ctx, value, &len) orelse return self.takeExceptionError(ctx);
        defer c.JS_FreeCString(ctx, ptr);
        return self.allocator.dupe(u8, ptr[0..len]);
    }

    fn takeExceptionError(self: *Host, ctx: *c.JSContext) EvalError {
        const exception = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, exception);
        if (self.cancelled_flag) return error.Cancelled;
        if (self.timed_out) return error.Timeout;
        if (isOutOfMemory(self, ctx, exception)) return error.MemoryLimit;
        self.captureExceptionMessage(ctx, exception);
        return error.ScriptError;
    }

    /// Keeps the script-visible exception text for the tool result; a bare
    /// ScriptError name gives the model nothing to correct.
    fn captureExceptionMessage(self: *Host, ctx: *c.JSContext, exception: c.JSValue) void {
        if (self.last_script_error) |old_message| self.allocator.free(old_message);
        self.last_script_error = null;
        var len: usize = 0;
        const ptr = c.JS_ToCStringLen(ctx, &len, exception) orelse return;
        defer c.JS_FreeCString(ctx, ptr);
        self.last_script_error = self.allocator.dupe(u8, ptr[0..len]) catch null;
    }
};

fn interruptHandler(_: ?*c.JSContext, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const host: *Host = @ptrCast(@alignCast(opaque_ptr orelse return 0));
    // A zero deadline means no eval is in flight (bindings still installing);
    // only the cancel source may interrupt then.
    if (host.deadline_ms != 0 and io_mod.milliTimestamp() >= host.deadline_ms) {
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
        const ptr = renderCValue(host, context, argv[0], &len) orelse return js_exception;
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
        const ptr = renderCValue(host, context, argv[@intCast(index)], &len) orelse return js_exception;
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

/// Each entry is {name, description, parameters} where parameters is the
/// tool's inputSchema parsed into a real JS object, so scripts never call
/// JSON.parse on introspection data. The schema JSON itself is produced by
/// builtinFunctionSchemaJsonAlloc ({"type":"function",...,"inputSchema":{...}});
/// only description and inputSchema are borrowed from the parsed value, and
/// name comes from the ToolSchema entry, which carries the script-facing
/// whitelist name (run_command, not the registered shell). Ownership note:
/// every JSValue created here is owned by the array once stored; the errdefer
/// paths free the ones that never made it in.
fn toolsListCallback(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    const context = ctx orelse return js_exception;
    const host: *Host = @ptrCast(@alignCast(c.JS_GetContextOpaque(context) orelse return js_exception));
    const schemas = host.tool_schemas orelse &.{};
    const array = c.JS_NewArray(context);
    if (c.JS_IsException(array)) return array;
    for (schemas, 0..) |tool_schema, index| {
        const parsed = c.JS_ParseJSON(context, tool_schema.schema_json.ptr, tool_schema.schema_json.len, "<tools.list schema>");
        if (c.JS_IsException(parsed)) {
            c.JS_FreeValue(context, array);
            return parsed;
        }
        const description = c.JS_GetPropertyStr(context, parsed, "description");
        const input_schema = c.JS_GetPropertyStr(context, parsed, "inputSchema");
        // The parsed wrapper is dropped after its two properties move out.
        // A moved-out property is a plain string/object value, not a
        // reference into the wrapper, so freeing it here is safe.
        c.JS_FreeValue(context, parsed);
        if (c.JS_IsException(description) or c.JS_IsException(input_schema)) {
            c.JS_FreeValue(context, description);
            c.JS_FreeValue(context, input_schema);
            c.JS_FreeValue(context, array);
            return js_exception;
        }

        const entry = c.JS_NewObject(context);
        if (c.JS_IsException(entry)) {
            c.JS_FreeValue(context, description);
            c.JS_FreeValue(context, input_schema);
            c.JS_FreeValue(context, array);
            return entry;
        }
        const name = c.JS_NewStringLen(context, tool_schema.name.ptr, tool_schema.name.len);
        if (c.JS_IsException(name)) {
            c.JS_FreeValue(context, entry);
            c.JS_FreeValue(context, description);
            c.JS_FreeValue(context, input_schema);
            c.JS_FreeValue(context, array);
            return name;
        }
        // From here each JS_SetPropertyStr failure frees the value it was
        // handed (the property write does not take ownership on failure),
        // plus every value not yet stored. This closes the leak the old
        // name-only loop had on its JS_SetPropertyUint32 path.
        if (c.JS_SetPropertyStr(context, entry, "name", name) < 0) {
            c.JS_FreeValue(context, entry);
            c.JS_FreeValue(context, description);
            c.JS_FreeValue(context, input_schema);
            c.JS_FreeValue(context, array);
            return js_exception;
        }
        if (c.JS_SetPropertyStr(context, entry, "description", description) < 0) {
            c.JS_FreeValue(context, entry);
            c.JS_FreeValue(context, input_schema);
            c.JS_FreeValue(context, array);
            return js_exception;
        }
        if (c.JS_SetPropertyStr(context, entry, "parameters", input_schema) < 0) {
            c.JS_FreeValue(context, entry);
            c.JS_FreeValue(context, array);
            return js_exception;
        }
        // A failed array store leaves ownership of entry with the caller,
        // so it is freed here like every value the writes rejected.
        if (c.JS_SetPropertyUint32(context, array, @intCast(index), entry) < 0) {
            c.JS_FreeValue(context, entry);
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
    const tool = bindings.findIn(host.tool_face, name) orelse {
        var message_buf: [256]u8 = undefined;
        const message: [:0]const u8 = std.mem.printSentinel(&message_buf, "unknown codemode tool: {s}", .{name}, 0) catch
            "unknown codemode tool";
        return c.JS_ThrowTypeError(context, "%s", message.ptr);
    };

    // The schema shows an object argument; stringify objects here so the
    // model does not need to remember JSON.stringify for every call.
    // JS_JSONStringify uses the real JSON implementation, so a script
    // cannot shadow it, and the single defer owns the one held value.
    var args_value = argv[1];
    var args_from_object = false;
    if (c.JS_IsObject(argv[1])) {
        args_value = c.JS_JSONStringify(context, argv[1], js_undefined, js_undefined);
        if (c.JS_IsException(args_value)) return js_exception;
        args_from_object = true;
    }
    defer if (args_from_object) c.JS_FreeValue(context, args_value);
    var args_len: usize = 0;
    const args_ptr = c.JS_ToCStringLen(context, &args_len, args_value) orelse
        return js_exception;
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

/// Renders one script value for text(), console.log, or the completion
/// value: objects are JSON-stringified first so the model reads real
/// content instead of "[object Object]". JS_JSONStringify uses the real
/// JSON implementation, so a script cannot shadow it. The returned c-string
/// view stays valid until the caller calls JS_FreeCString; on the fallback
/// path it is the plain ToCString form. Returns null only when the value
/// itself failed to convert, which means an exception is pending and the
/// caller reports it through its own error path.
fn renderCValue(host: *Host, ctx: *c.JSContext, value: c.JSValueConst, len: *usize) ?[*:0]const u8 {
    if (c.JS_IsObject(value)) {
        const json = c.JS_JSONStringify(ctx, value, js_undefined, js_undefined);
        if (!c.JS_IsException(json)) {
            defer c.JS_FreeValue(ctx, json);
            const ptr = c.JS_ToCStringLen(ctx, len, json);
            return ptr;
        }
        // The value cannot be JSON, typically a circular reference or a
        // BigInt: drop the pending exception so it cannot leak into a later
        // eval, then fall back to the plain string form. At the memory limit
        // the fallback would fail too, so the exception goes back to the
        // engine instead and the caller's error path keeps the MemoryLimit
        // classification that a plain ScriptError would lose.
        const pending = c.JS_GetException(ctx);
        if (isOutOfMemory(host, ctx, pending)) {
            _ = c.JS_Throw(ctx, pending);
            return null;
        }
        c.JS_FreeValue(ctx, pending);
    }
    return c.JS_ToCStringLen(ctx, len, value);
}

fn isOutOfMemory(host: *Host, ctx: *c.JSContext, exception: c.JSValue) bool {
    if (c.JS_IsUninitialized(exception)) return memoryLimitReached(host);
    // quickjs-ng throws JS_NULL when the heap is too full to build the error
    // object itself (vendor/quickjs/quickjs.c JS_ThrowError2: "out of memory:
    // throw JS_NULL to avoid recursing"), so a null exception near the cap is
    // the missing "out of memory" message. The tradeoff: a script's own
    // `throw null` while the heap sits within 64KiB of the cap is also
    // reported as MemoryLimit, because memoryLimitReached fires at
    // malloc_limit - 65536 and the JS_ToCStringLen failure path below calls
    // it too. The slack recognizes the engine null-OOM signal without
    // moving the cap.
    if (c.JS_IsNull(exception)) return memoryLimitReached(host);
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
    // The script's own failed allocation also leaves the heap short of the
    // cap: a 64KiB "x".repeat push lands tens of kilobytes below it, too
    // little for the engine to build the error object, so it throws null
    // (vendor/quickjs/quickjs.c JS_ThrowError2). One 64KiB allocation of
    // slack covers that gap without moving the cap itself.
    return usage.malloc_limit > 0 and
        usage.malloc_size >= usage.malloc_limit - 65536;
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

test "codemode text renders object arguments as JSON" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\text({a: 1});
        \\"done";
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.value);
    try std.testing.expectEqualStrings("{\"a\":1}", result.text);
}

test "codemode text renders a circular reference as its fallback form" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\const o = {};
        \\o.self = o;
        \\text(o);
        \\"recovered";
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("recovered", result.value);
    try std.testing.expectEqualStrings("[object Object]", result.text);
}

test "codemode console.log renders object arguments as JSON" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\console.log({a: 1});
        \\console.log(1, {a: 1});
        \\"ok";
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("ok", result.value);
    try std.testing.expectEqualStrings("{\"a\":1}\n1 {\"a\":1}\n", result.console);
}

test "codemode console.log renders a circular reference as its fallback form" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\const o = {};
        \\o.self = o;
        \\console.log(o);
        \\"recovered";
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("recovered", result.value);
    try std.testing.expectEqualStrings("[object Object]\n", result.console);
}

test "codemode renders an object completion value as JSON" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval("({a: 1, nested: {b: \"x\"}})");
    defer result.deinit();
    try std.testing.expectEqualStrings("{\"a\":1,\"nested\":{\"b\":\"x\"}}", result.value);
}

test "codemode renders a circular completion value as its fallback form and keeps the engine healthy" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\const o = {};
        \\o.self = o;
        \\o;
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("[object Object]", result.value);

    // The pending exception from the failed stringify must not leak into a
    // later eval.
    var next = try host.eval("1 + 1");
    defer next.deinit();
    try std.testing.expectEqualStrings("2", next.value);
}
test "codemode text renders a BigInt as its plain string form" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();

    var result = try host.eval(
        \\text(1n);
        \\"recovered";
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("recovered", result.value);
    // JSON.stringify rejects BigInt, and the ToCString fallback renders
    // it as its digits, so the model still reads a usable value.
    try std.testing.expectEqualStrings("1", result.text);
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

test "takePartialOutput moves captured buffers to the caller" {
    var host = Host.init(std.testing.allocator, .{});
    defer host.deinit();
    _ = appendCapped(&host, &host.text_buf, "partial text");
    _ = appendCapped(&host, &host.console_buf, "console line\n");

    const partial = host.takePartialOutput();
    defer host.allocator.free(partial.text);
    defer host.allocator.free(partial.console);
    try std.testing.expectEqualStrings("partial text", partial.text);
    try std.testing.expectEqualStrings("console line\n", partial.console);

    // The buffers are emptied: a later take yields empty slices, and deinit
    // must not double free what the caller now owns.
    const empty = host.takePartialOutput();
    defer host.allocator.free(empty.text);
    defer host.allocator.free(empty.console);
    try std.testing.expectEqualStrings("", empty.text);
    try std.testing.expectEqualStrings("", empty.console);
}
