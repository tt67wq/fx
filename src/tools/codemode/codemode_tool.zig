const std = @import("std");
const sandbox_mod = @import("sandbox.zig");
const bridge = @import("bridge.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");

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
/// carries the script call's execution frame, including the runtime context
/// the nested admission path shares and the worker cancel flag the sandbox
/// interrupt handler polls.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const state = ctx.codemode_host orelse return .{
        .failure = try ctx.allocator.dupe(u8, unavailable_message),
    };
    const input = erased.as(Input);

    var sandbox = sandbox_mod.Sandbox.init(ctx.allocator, .{});
    defer sandbox.deinit();
    // ISSUE-8: the sandbox has no cancel source of its own. The interrupt
    // handler polls the same atomic the worker cancel path sets.
    sandbox.cancel_flag = &state.runtime.worker.worker_cancel_requested;
    sandbox.host.setToolBackend(bridge.backend(state));

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
        else => {
            return .{ .failure = try ctx.allocator.print("codemode script failed: {s}", .{@errorName(err)}) };
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
