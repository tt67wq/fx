const std = @import("std");
const bindings = @import("bindings.zig");
const shell = @import("shell.zig");
const tool_runtime = @import("../../core/tooling/tool_runtime.zig");
const tool_admission = @import("../../core/tooling/tool_admission.zig");
const auto_classifier_context = @import("../../core/permissions/auto_classifier_context.zig");
const command_admission = @import("../../core/permissions/command_admission.zig");
const types = @import("../../core/shared/types.zig");

/// Runs whitelisted tools for a codemode script through the same admission
/// pipeline a direct tool call takes. Every nested call builds its own
/// admission input from the script call's execution context, carries the
/// .codemode review origin, and on allow executes through the public tool
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
) anyerror![]u8 {
    const state: *tool_runtime.CodemodeHostState = @ptrCast(@alignCast(raw_ctx orelse return error.CodemodeBridgeClosed));
    const ctx = state.runtime;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    state.call_sequence += 1;
    var id_buf: [64]u8 = undefined;
    const nested_id = try std.mem.print(&id_buf, "codemode-nested-{d}", .{state.call_sequence});

    // The script-facing name `run_command` is the shell tool's
    // captured-command compatibility name; the registered tool the model
    // calls directly is `shell` with action "run". Canonicalizing here makes
    // both paths build the same admission payload and execute the same tool.
    // Without it the nested call reaches admission and dispatch under a name
    // no registered tool carries.
    const canonical = try canonicalNestedCall(arena, tool, args_json);
    const nested_call: types.ToolCall = .{
        .id = nested_id,
        .name = canonical.name,
        .arguments_json = canonical.arguments_json,
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
        return deniedResult(allocator, try deniedReason(arena, tool.name, outcome));
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

const CanonicalCall = struct {
    name: []const u8,
    arguments_json: []const u8,
};

/// Maps the script's `run_command` call onto the registered `shell` tool's
/// `action: "run"` form. The action goes first so the bytes match a direct
/// model call that names the same action and command; every other script
/// field keeps its original order. Other whitelisted tools pass through.
fn canonicalNestedCall(
    arena: std.mem.Allocator,
    tool: bindings.Tool,
    args_json: []const u8,
) !CanonicalCall {
    if (!std.mem.eql(u8, tool.name, "run_command")) {
        return .{ .name = tool.name, .arguments_json = args_json };
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch
        return error.InvalidToolArguments;
    if (parsed != .object) return error.InvalidToolArguments;
    const object = parsed.object;

    if (object.get("action")) |action| {
        if (action != .string or !std.mem.eql(u8, action.string, "run")) {
            return error.InvalidToolArguments;
        }
    }
    const command = object.get("command") orelse return error.InvalidToolArguments;
    if (command != .string) return error.InvalidToolArguments;

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"action\":\"run\"");
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "action")) continue;
        try out.writer.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, &out.writer);
        try out.writer.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return .{
        .name = "shell",
        .arguments_json = try out.toOwnedSlice(),
    };
}

/// A denied nested call reports the permission pipeline's specific reason,
/// matching the direct tool result's `reason` value when one exists, and
/// falls back to the decision name for paths that carry no denial reason.
fn deniedReason(
    arena: std.mem.Allocator,
    tool_name: []const u8,
    outcome: command_admission.PermissionOutcome,
) ![]const u8 {
    if (outcome.feedback) |feedback| return feedback;
    if (outcome.tool_failure) |failure| return failure;
    const reason = if (outcome.denial_reason) |reason|
        @tagName(reason)
    else
        @tagName(outcome.decision);
    return arena.print("Permission to run {s} was not granted ({s}).", .{ tool_name, reason });
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

test "run_command canonicalizes to the registered shell run call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical = try canonicalNestedCall(
        arena_state.allocator(),
        .{ .name = "run_command" },
        "{\"command\":\"./parity-probe.sh\"}",
    );
    try std.testing.expectEqualStrings("shell", canonical.name);
    try std.testing.expectEqualStrings(
        "{\"action\":\"run\",\"command\":\"./parity-probe.sh\"}",
        canonical.arguments_json,
    );
}

test "run_command canonicalization keeps field order and an explicit run action" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical = try canonicalNestedCall(
        arena_state.allocator(),
        .{ .name = "run_command" },
        "{\"action\":\"run\",\"command\":\"make\",\"cwd\":\"src\",\"timeout_ms\":600000}",
    );
    try std.testing.expectEqualStrings(
        "{\"action\":\"run\",\"command\":\"make\",\"cwd\":\"src\",\"timeout_ms\":600000}",
        canonical.arguments_json,
    );
}

test "run_command canonicalization refuses another shell action" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(
            arena_state.allocator(),
            .{ .name = "run_command" },
            "{\"action\":\"interact\",\"command\":\"true\"}",
        ),
    );
}

test "run_command canonicalization requires an object with a string command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_command" }, "[]"),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_command" }, "{}"),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_command" }, "{\"command\":5}"),
    );
}

test "other whitelisted tools keep their exact arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical = try canonicalNestedCall(
        arena_state.allocator(),
        .{ .name = "read_file" },
        "{\"path\":\"notes.txt\"}",
    );
    try std.testing.expectEqualStrings("read_file", canonical.name);
    try std.testing.expectEqualStrings("{\"path\":\"notes.txt\"}", canonical.arguments_json);
}

test "denied reason prefers the permission pipeline's specific denial" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("human feedback", try deniedReason(arena, "run_command", .{
        .decision = .deny,
        .denial_reason = .user_denied,
        .feedback = "human feedback",
    }));
    try std.testing.expectEqualStrings(
        "Permission to run run_command was not granted (user_denied).",
        try deniedReason(arena, "run_command", .{
            .decision = .deny,
            .denial_reason = .user_denied,
        }),
    );
    try std.testing.expectEqualStrings(
        "Permission to run run_command was not granted (review_caution).",
        try deniedReason(arena, "run_command", .{
            .decision = .deny,
            .denial_reason = .review_caution,
        }),
    );
    try std.testing.expectEqualStrings(
        "Permission to run run_command was not granted (permission_required).",
        try deniedReason(arena, "run_command", .{ .decision = .permission_required }),
    );
}
