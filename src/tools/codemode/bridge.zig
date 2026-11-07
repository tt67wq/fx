const std = @import("std");
const bindings = @import("bindings.zig");
const shell = @import("shell.zig");
const tool_runtime = @import("../../core/tooling/tool_runtime.zig");
const tool_admission = @import("../../core/tooling/tool_admission.zig");
const auto_classifier_context = @import("../../core/permissions/auto_classifier_context.zig");
const types = @import("../../core/shared/types.zig");

/// Runs whitelisted tools for a codemode script through the same admission
/// pipeline a direct tool call takes. Every nested call builds its own
/// admission input from the script call's execution context, carries the
/// .codemode review origin with the script line kept in the host state's
/// separate location field, and on allow executes through the public tool
/// execution entry with the granted authority. There is no path from a
/// script to tool execution that skips admission.
///
/// Runs on the dedicated sandbox thread. Admission may block on the
/// permission prompter (cross-thread condvar wait) and on tool execution;
/// the calling worker is inside Sandbox.eval for the whole time, so nothing
/// else touches the runtime context concurrently.
pub const deny_json_prefix = "{\"denied\":true,\"reason\":";

/// The backend a CodemodeHostState hands to Host.setToolBackend.
pub fn backend(state: *tool_runtime.CodemodeHostState) bindings.Backend {
    return .{ .ctx = state, .call = call };
}

fn call(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    tool: bindings.Tool,
    args_json: []const u8,
    location: []const u8,
) anyerror![]u8 {
    const state: *tool_runtime.CodemodeHostState = @ptrCast(@alignCast(raw_ctx orelse return error.CodemodeBridgeClosed));
    const ctx = state.runtime;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The script line stays out of the call id (ids key the ledger and saved
    // rules) and out of the review origin string; it travels in this field
    // for the admission path to report. The raw slice is valid for the whole
    // backend call, which covers admission and execution below. The line is
    // reported as L<n> when the shim captured one; the raw digits stay out of
    // the call id (ids key the ledger and saved rules).
    if (location.len > 0) {
        state.script_location = try allocator.print("L{s}", .{location});
    } else {
        state.script_location = location;
    }
    defer state.script_location = "";

    state.call_sequence += 1;
    var id_buf: [64]u8 = undefined;
    const nested_id = try std.mem.print(&id_buf, "codemode-nested-{d}", .{state.call_sequence});

    const nested_call: types.ToolCall = .{
        .id = nested_id,
        .name = tool.name,
        .arguments_json = args_json,
    };

    var check = ctx;
    // In-script capture shares the shell result budget so one script cannot
    // hold more command output than one direct run_command call reports.
    check.max_command_output_bytes = shell.default_script_shell_budget_bytes;
    check.permission_review_turn = .{
        .observer = ctx.observer,
        .model = ctx.model,
        .pending_assistant = .{
            .role = .assistant,
            .tool_calls = try arena.dupe(types.ToolCall, &.{nested_call}),
        },
        .target_call_id = nested_id,
        .origin = .codemode,
        .trusted_root_context = auto_classifier_context.rootUserRequestContext(ctx.root_user_intent_context) orelse "",
        .current_turn_untrusted_messages = ctx.current_turn_messages,
    };

    const outcome = try tool_admission.requestPermissionOutcome(
        check.admissionInput(),
        arena,
        nested_call,
        check.permission_mode,
        check.session_grants,
    );
    if (outcome.decision.isDenied() or outcome.tool_failure != null) {
        return deniedResult(allocator, outcome.feedback orelse outcome.tool_failure orelse
            try arena.print("Permission to run {s} was not granted ({s}).", .{ tool.name, @tagName(outcome.decision) }));
    }

    const result = try tool_runtime.executeToolCallAuthorized(check, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = nested_call,
        .authority = outcome.execution_authority orelse .ordinary,
        .current_turn_messages = ctx.current_turn_messages,
        .session_grants = ctx.session_grants,
        .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
        .classification_complete = true,
    });

    // Wait-for-completion, then discard: a cancel that arrived during the
    // nested call must not hand the script a usable value.
    if (state.cancelled()) return error.Cancelled;

    if (std.mem.eql(u8, tool.name, "run_command")) {
        return shellResult(allocator, arena, result);
    }
    return allocator.dupe(u8, result.model_output);
}

/// Encodes one nested run_command result for the script: exit code and
/// truncation come from the command result JSON, output is the model-facing
/// stdout/stderr envelope.
fn shellResult(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    result: tool_runtime.ToolExecutionResult,
) ![]u8 {
    var exit_code: i64 = 0;
    var upstream_truncated = false;
    if (result.command_result_json) |json| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch null;
        if (parsed) |value| {
            if (value == .object) {
                if (value.object.get("exit_code")) |code| {
                    if (code == .integer) exit_code = code.integer;
                }
                if (value.object.get("truncated")) |truncated| {
                    if (truncated == .bool) upstream_truncated = truncated.bool;
                }
            }
        }
    }
    return shell.encodeResultJson(
        allocator,
        exit_code,
        result.model_output,
        shell.default_script_shell_budget_bytes,
        upstream_truncated,
    );
}

/// A denied nested call is a script-visible result, not an exception: the
/// script can branch on it. The reason text is untrusted-content safe: it
/// comes from the permission pipeline, never from tool output.
fn deniedResult(allocator: std.mem.Allocator, reason: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(deny_json_prefix);
    try std.json.Stringify.value(reason, .{}, &out.writer);
    try out.writer.writeAll("}");
    return try out.toOwnedSlice();
}

test "denied result json carries the reason as a script value" {
    const allocator = std.testing.allocator;
    const encoded = try deniedResult(allocator, "not allowed");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("{\"denied\":true,\"reason\":\"not allowed\"}", encoded);
}
