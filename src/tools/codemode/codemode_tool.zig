const std = @import("std");
const sandbox_mod = @import("sandbox.zig");
const bridge = @import("bridge.zig");
const host_mod = @import("host.zig");
const io_mod = @import("../../core/shared/io.zig");
const builtin_tools = @import("../../builtins/tools.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_runtime = @import("../../core/tooling/tool_runtime.zig");

const Allocator = std.mem.Allocator;

/// Typed input for the built-in codemode tool.
pub const Input = struct {
    script: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.script);
        self.* = .{ .script = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var args: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "codemode" };
    var parsed = args.parse(args_json) catch |err| return .{ .failure = try args.takeFailure(err) };
    defer parsed.deinit();
    const object = parsed.value.object;
    const script = args.requiredString(object, "script") catch |err| return .{ .failure = try args.takeFailure(err) };

    const owned_script = try ctx.allocator.dupe(u8, script);
    errdefer ctx.allocator.free(owned_script);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .script = owned_script };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

const unavailable_message = "codemode is not available in this session.";

/// Evaluates the script on the dedicated sandbox thread. The dispatch context
/// The display head of captured output in a failure body. The 64KiB
/// capture cap stays the first limit; this head is a second,
/// presentation-only trim so one failure result cannot flood the context.
const max_failure_output_head_bytes: usize = 4 * 1024;

/// Appends the display head of captured output, with a truncation marker
/// when the captured bytes exceed it.
fn appendFailureOutputHead(out: *std.ArrayList(u8), allocator: Allocator, bytes: []const u8) Allocator.Error!void {
    const head = bytes[0..@min(bytes.len, max_failure_output_head_bytes)];
    try out.appendSlice(allocator, head);
    if (bytes.len > head.len) {
        var buf: [96]u8 = undefined;
        const marker = std.mem.print(&buf, "... output truncated ({d} more bytes)", .{bytes.len - head.len}) catch return error.OutOfMemory;
        try out.appendSlice(allocator, marker);
    }
}

/// Assembles the failure body: the headline, plus the captured partial
/// output and the nested call summary when there is anything to show.
/// With neither, the body is byte-identical to the headline. Allocation
/// for the added sections degrades to the headline: a failure report
/// must not fail.
fn formatFailureBody(
    allocator: Allocator,
    headline: []const u8,
    partial: ?host_mod.PartialOutput,
    nested_calls: []const tool_runtime.NestedCallRecord,
    nested_overflow: bool,
) Allocator.Error![]u8 {
    const has_text = partial != null and partial.?.text.len > 0;
    const has_console = partial != null and partial.?.console.len > 0;
    if (!has_text and !has_console and nested_calls.len == 0 and !nested_overflow) {
        return allocator.dupe(u8, headline);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    blk: {
        out.appendSlice(allocator, headline) catch break :blk;
        if (has_text) {
            out.appendSlice(allocator, "\n\nPartial output before failure:\n") catch break :blk;
            appendFailureOutputHead(&out, allocator, partial.?.text) catch break :blk;
        }
        if (has_console) {
            out.appendSlice(allocator, "\n\nConsole output before failure:\n") catch break :blk;
            appendFailureOutputHead(&out, allocator, partial.?.console) catch break :blk;
        }
        if (nested_calls.len > 0 or nested_overflow) {
            out.appendSlice(allocator, "\n\nNested tool calls before failure (not undone):\n") catch break :blk;
            for (nested_calls) |record| {
                var line_buf: [128]u8 = undefined;
                const line = std.mem.print(&line_buf, "- {s}: {s}\n", .{ record.name, @tagName(record.outcome) }) catch break :blk;
                out.appendSlice(allocator, line) catch break :blk;
            }
            if (nested_overflow) {
                out.appendSlice(allocator, "- ... additional calls not recorded\n") catch break :blk;
            }
        }
        return out.toOwnedSlice(allocator) catch break :blk;
    }
    return allocator.dupe(u8, headline);
}

/// Formats the failure body around the already-allocated headline and
/// never fails: when the added sections cannot be allocated the body
/// degrades to the plain headline. The headline ownership transfers to
/// the returned body.
fn failureBody(
    allocator: Allocator,
    headline: []u8,
    partial: host_mod.PartialOutput,
    nested_calls: []const tool_runtime.NestedCallRecord,
    nested_overflow: bool,
) []u8 {
    const body = formatFailureBody(allocator, headline, partial, nested_calls, nested_overflow) catch headline;
    if (body.ptr != headline.ptr) allocator.free(headline);
    return body;
}

/// carries the script call's execution frame, including the runtime context
/// the nested admission path shares and the worker cancel flag the sandbox
/// interrupt handler polls.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const state = ctx.codemode_host orelse return .{
        .failure = try ctx.allocator.dupe(u8, unavailable_message),
    };
    // Record the script budget once per call so every nested shell run can be
    // capped at the remaining script wall clock instead of running unbounded.
    state.ambient_budget_ms = host_mod.default_timeout_ms;
    state.ambient_started_ms = io_mod.milliTimestamp();
    const input = erased.as(Input);

    // The schema JSON strings live in this arena: they must outlive every
    // eval the sandbox runs and are freed when the call ends. The host
    // borrows the slices and never frees them.
    var schema_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer schema_arena_state.deinit();
    const tool_schemas = bridge.schemas(schema_arena_state.allocator(), builtin_tools.registry) catch |err| {
        return .{ .failure = try ctx.allocator.print("codemode schema injection failed: {s}", .{@errorName(err)}) };
    };

    var sandbox = sandbox_mod.Sandbox.init(ctx.allocator, .{});
    defer sandbox.deinit();
    // ISSUE-8: the sandbox has no cancel source of its own. The interrupt
    // handler polls the same atomic the worker cancel path sets.
    sandbox.cancel_flag = &state.runtime.worker.worker_cancel_requested;
    sandbox.host.setToolBackend(bridge.backend(state));
    sandbox.host.setToolSchemas(tool_schemas);

    sandbox.start() catch |err| {
        return .{ .failure = try ctx.allocator.print("codemode script failed: {s}", .{@errorName(err)}) };
    };
    const outcome = sandbox.eval(input.script) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => {
            // Wait-for-completion happened inside eval; discard the value and
            // report the cancel through the standard cancelled disposition.
            return error.Cancelled;
        },
        error.ScriptError => {
            // The engine keeps the script-visible exception text so the model
            // can correct the script instead of retrying blind.
            const partial = sandbox.host.takePartialOutput();
            defer ctx.allocator.free(partial.text);
            defer ctx.allocator.free(partial.console);
            const headline = if (sandbox.host.lastExceptionMessage()) |message|
                try ctx.allocator.print("codemode script failed: ScriptError: {s}", .{message})
            else
                try ctx.allocator.dupe(u8, "codemode script failed: ScriptError");
            return .{ .failure = failureBody(ctx.allocator, headline, partial, state.nested_calls[0..state.nested_call_count], state.nested_call_overflow) };
        },
        else => {
            const partial = sandbox.host.takePartialOutput();
            defer ctx.allocator.free(partial.text);
            defer ctx.allocator.free(partial.console);
            const headline = try ctx.allocator.print("codemode script failed: {s}", .{@errorName(err)});
            return .{ .failure = failureBody(ctx.allocator, headline, partial, state.nested_calls[0..state.nested_call_count], state.nested_call_overflow) };
        },
    };
    var result = outcome;
    defer result.deinit();

    if (state.cancelled()) return error.Cancelled;

    var text: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer text.deinit();
    text.writer.writeAll(result.console) catch return error.OutOfMemory;
    if (result.console.len > 0 and !std.mem.endsWith(u8, result.console, "\n")) {
        text.writer.writeAll("\n") catch return error.OutOfMemory;
    }
    text.writer.writeAll(result.text) catch return error.OutOfMemory;
    if (result.text.len > 0 and !std.mem.endsWith(u8, result.text, "\n")) {
        text.writer.writeAll("\n") catch return error.OutOfMemory;
    }
    // A script completion value is the result when the script called
    // neither text() nor console.log: "1 + 1" must answer "2", not an
    // empty output the model reads as silence and retries against.
    if (text.written().len == 0 and result.value.len > 0 and
        !std.mem.eql(u8, result.value, "undefined"))
    {
        text.writer.writeAll(result.value) catch return error.OutOfMemory;
        text.writer.writeAll("\n") catch return error.OutOfMemory;
    }
    return .{ .success = text.toOwnedSlice() catch return error.OutOfMemory };
}

/// Reports that codemode is not itself a read-only observer: it runs
/// whitelisted tools through the admission pipeline and can mutate.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Reports that a script may take irreversible actions through nested calls.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

test "decode requires a script string" {
    const allocator = std.testing.allocator;
    const decoded = try decode(.{ .allocator = allocator }, "{\"script\":\"1+1\"}");
    switch (decoded) {
        .input => |input| {
            defer input.deinit(allocator);
            const script_input: *Input = input.as(Input);
            try std.testing.expectEqualStrings("1+1", script_input.script);
        },
        .failure => |body| {
            defer allocator.free(body);
            return error.TestUnexpectedResult;
        },
    }
}

test "decode reports a missing script as a failure body" {
    const allocator = std.testing.allocator;
    const decoded = try decode(.{ .allocator = allocator }, "{}");
    switch (decoded) {
        .input => |input| {
            defer input.deinit(allocator);
            return error.TestUnexpectedResult;
        },
        .failure => |body| {
            defer allocator.free(body);
            try std.testing.expect(body.len > 0);
        },
    }
}

test "failure body without output or calls matches the plain one-liner" {
    const body = try formatFailureBody(std.testing.allocator, "codemode script failed: ScriptError: boom", null, &.{}, false);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("codemode script failed: ScriptError: boom", body);
}

test "failure body appends partial output and nested call summary" {
    const text = try std.testing.allocator.dupe(u8, "found 3 files");
    const console = try std.testing.allocator.dupe(u8, "logged line");
    const records = [_]tool_runtime.NestedCallRecord{
        .{ .name = "read_file", .outcome = .ok },
        .{ .name = "run_command", .outcome = .denied },
    };
    const body = try formatFailureBody(std.testing.allocator, "codemode script failed: ScriptError: boom", .{ .text = text, .console = console }, &records, false);
    defer std.testing.allocator.free(text);
    defer std.testing.allocator.free(console);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "Partial output before failure:") != null);
    try std.testing.expect(std.mem.find(u8, body, "found 3 files") != null);
    try std.testing.expect(std.mem.find(u8, body, "Console output before failure:") != null);
    try std.testing.expect(std.mem.find(u8, body, "logged line") != null);
    try std.testing.expect(std.mem.find(u8, body, "Nested tool calls before failure (not undone):") != null);
    try std.testing.expect(std.mem.find(u8, body, "- read_file: ok") != null);
    try std.testing.expect(std.mem.find(u8, body, "- run_command: denied") != null);
}

test "failure body truncates oversized output and flags summary overflow" {
    const big = try std.testing.allocator.alloc(u8, 10_000);
    @memset(big, 'x');
    defer std.testing.allocator.free(big);
    const empty = try std.testing.allocator.dupe(u8, "");
    defer std.testing.allocator.free(empty);
    const body = try formatFailureBody(std.testing.allocator, "codemode script failed: Timeout", .{ .text = big, .console = empty }, &.{}, true);
    defer std.testing.allocator.free(body);
    // The body keeps only the display head of the captured output and marks
    // the truncation; the overflow flag surfaces as an explicit note.
    try std.testing.expect(std.mem.find(u8, body, "truncated") != null);
    try std.testing.expect(body.len < 8192);
    try std.testing.expect(std.mem.find(u8, body, "additional calls") != null);
}
