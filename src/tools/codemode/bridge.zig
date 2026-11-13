const std = @import("std");
const bindings = @import("bindings.zig");
const shell = @import("shell.zig");
const tool_runtime = @import("../../core/tooling/tool_runtime.zig");
const tool_admission = @import("../../core/tooling/tool_admission.zig");
const auto_classifier_context = @import("../../core/permissions/auto_classifier_context.zig");
const command_admission = @import("../../core/permissions/command_admission.zig");
const types = @import("../../core/shared/types.zig");
const builtin_tools = @import("../../builtins/tools.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");

// Test-only fixture imports (plan v2 groups 5-8): the minimal runtime
// context the canonicalization-failure no-record test drives call() with.
const context_contract = @import("../../core/workspace/context_contract.zig");
const command_contract = @import("../../core/execution/command_contract.zig");
const worker_runtime_mod = @import("../../core/agent/worker_runtime.zig");
const session_runtime_mod = @import("../../core/session/session.zig");

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

/// Caps nested shell runs at the script's wall-clock budget fields. A
/// stalled command is killed at the budget instead of blocking the
/// synchronous callback until it recovers on its own; the shell dispatch
/// path turns the pair into min(requested, remaining) through the ambient
/// timeout. No recorded budget (tests, direct runs) keeps the previous
/// never-times-out nesting behavior.
fn applyAmbientBudget(check: *tool_runtime.Context, state: *const tool_runtime.CodemodeHostState) void {
    const budget = state.ambient_budget_ms orelse return;
    check.command_timeout_ms = budget;
    check.command_timeout_started_ms = state.ambient_started_ms;
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
    // The duration starts before canonicalization and admission so every
    // exit records the same elapsed time, including any human permission
    // wait (plan v2 section 2).
    const started_ms = io_mod.milliTimestamp();
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
    // Cap every nested shell run at the script's remaining wall clock: a
    // stalled command is killed at the budget instead of blocking the
    // synchronous callback until it recovers on its own.
    applyAmbientBudget(&check, state);
    // Nested calls resolve against the full built-in registry, not the
    // profile-narrowed one: a codemode-only profile advertises codemode to
    // the model, while the script-facing whitelist (read_file, glob_files,
    // grep_files, run_command) stays available to the script. Each nested
    // call still passes the admission pipeline below, so narrowing the
    // model's surface never bypasses a review.
    check.tool_registry = builtin_tools.registry;
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
        state.recordNestedCall(tool.name, if (outcome.tool_failure != null) .failure else .denied, nestedDurationMs(started_ms, io_mod.milliTimestamp()));
        return deniedResult(allocator, try deniedReason(arena, tool.name, outcome));
    }

    const result = tool_runtime.executeToolCallAuthorized(check, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = nested_call,
        .authority = outcome.execution_authority orelse .ordinary,
        .current_turn_messages = ctx.current_turn_messages,
        .session_grants = ctx.session_grants,
        .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
        .classification_complete = true,
    }) catch |err| {
        state.recordNestedCall(tool.name, mapNestedOutcome(null, err), nestedDurationMs(started_ms, io_mod.milliTimestamp()));
        return err;
    };
    // The bridge consumes the output itself and never hands the delivery
    // reservation to a later interact. Commit it so a terminal entry
    // tombstones and frees its execution slot. Without this every nested
    // call leaks one live entry until ExecutionCapacityExceeded.
    if (result.result_commit) |commit| {
        commit.commit() catch |err|
            debug_trace.logf("codemode.bridge", "nested result commit failed: {s}", .{@errorName(err)});
    }

    // Wait-for-completion, then discard: a cancel that arrived during the
    // nested call must not hand the script a usable value.
    if (state.cancelled()) {
        state.recordNestedCall(tool.name, .cancelled, nestedDurationMs(started_ms, io_mod.milliTimestamp()));
        return error.Cancelled;
    }

    // F2: a normal return can carry status .failure (missing file, non-zero
    // exit) or observe cancellation; record the real outcome, not .ok.
    state.recordNestedCall(tool.name, mapNestedOutcome(result, null), nestedDurationMs(started_ms, io_mod.milliTimestamp()));
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

/// Maps a script-facing whitelist name to the registered tool that backs
/// it. run_command is the shell tool's captured-command compatibility name
/// (see canonicalNestedCall); every other name is its own registry entry.
/// A whitelist name with no registered backer is a wiring bug, so it is an
/// error rather than a silent skip.
fn registeredName(script_name: []const u8) []const u8 {
    if (std.mem.eql(u8, script_name, "run_command")) return "shell";
    return script_name;
}

/// The script-facing names one eval may forward. Both faces are built at
/// compile time from the registry, so the runtime gate only selects a static
/// slice and nothing is concatenated per call.
///
/// The shipped face is the four names below. The derived face is every tool
/// the registry marks `sandbox_reachable`, in registry order, plus run_command: the
/// registry carries the shell tool, and run_command is its script-facing name
/// (see registeredName). Both faces only decide which names a script may
/// forward; every nested call still runs the admission pipeline in `call`.
pub fn sandboxFace(comptime registry: tool_dispatch.Registry, derived: bool) []const bindings.Tool {
    const open = comptime derivedFace(registry);
    return if (derived) open else bindings.tools[0..];
}

fn derivedFace(comptime registry: tool_dispatch.Registry) []const bindings.Tool {
    return comptime blk: {
        var face: []const bindings.Tool = &.{};
        for (registry.tools) |tool| {
            if (!tool.sandbox_reachable) continue;
            face = face ++ &[_]bindings.Tool{.{ .name = tool.name }};
        }
        break :blk face ++ &[_]bindings.Tool{.{ .name = "run_command" }};
    };
}

/// Builds one ToolSchema per whitelisted tool from the builtin registry,
/// matching the full registry the nested admission path resolves against
/// (see the tool_registry assignment in call). The returned schemas are
/// allocated with `alloc`; the caller owns them and must keep them alive
/// for every eval that borrows them.
pub fn schemas(
    alloc: std.mem.Allocator,
    registry: tool_dispatch.Registry,
    face: []const bindings.Tool,
) ![]bindings.ToolSchema {
    const out = try alloc.alloc(bindings.ToolSchema, face.len);
    for (face, 0..) |tool, index| {
        const registered = registry.lookup(registeredName(tool.name)) orelse return error.SchemaMissing;
        const json = try model_tool_schema.builtinFunctionSchemaJsonAlloc(alloc, registered.model_schema);
        // JS_ParseJSON requires a NUL-terminated buffer (quickjs.c: 'buf'
        // must be zero terminated); the writer API does not add one.
        const terminated = try alloc.alloc(u8, json.len + 1);
        @memcpy(terminated[0..json.len], json);
        terminated[json.len] = 0;
        out[index] = .{
            .name = tool.name,
            .schema_json = terminated[0..json.len :0],
        };
    }
    return out;
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

test "schemas injects one entry per whitelisted tool with script-facing names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const injected = try schemas(arena, builtin_tools.registry, &bindings.tools);
    try std.testing.expectEqual(@as(usize, bindings.tools.len), injected.len);
    for (injected, bindings.tools) |schema, tool| {
        try std.testing.expectEqualStrings(tool.name, schema.name);
    }
    // run_command resolves to the registered shell tool's schema, but every
    // entry keeps its script-facing whitelist name.
    for (injected) |schema| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, schema.schema_json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("inputSchema") != null);
        try std.testing.expect(parsed.value.object.get("description") != null);
    }
}

test "schemas errors when a whitelisted name is missing from the registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A registry without the shell tool cannot back run_command's schema.
    const partial = tool_dispatch.Registry{ .tools = builtin_tools.registry.tools[0..1] };
    try std.testing.expectError(error.SchemaMissing, schemas(arena, partial, &bindings.tools));
}

test "bridge caps nested commands with the script budget fields" {
    var state: tool_runtime.CodemodeHostState = undefined;
    state.ambient_budget_ms = 30_000;
    state.ambient_started_ms = 1_000;
    var check: tool_runtime.Context = undefined;
    check.command_timeout_ms = null;
    check.command_timeout_started_ms = null;
    applyAmbientBudget(&check, &state);
    try std.testing.expectEqual(@as(?usize, 30_000), check.command_timeout_ms);
    try std.testing.expectEqual(@as(?i64, 1_000), check.command_timeout_started_ms);

    // Without a recorded budget the fields stay untouched.
    var unbudgeted: tool_runtime.CodemodeHostState = undefined;
    unbudgeted.ambient_budget_ms = null;
    unbudgeted.ambient_started_ms = null;
    check.command_timeout_ms = null;
    check.command_timeout_started_ms = null;
    applyAmbientBudget(&check, &unbudgeted);
    try std.testing.expectEqual(@as(?usize, null), check.command_timeout_ms);
    try std.testing.expectEqual(@as(?i64, null), check.command_timeout_started_ms);
}

// ---------------------------------------------------------------------------
// ISSUE-11 tests (plan v2 groups 5-8).
// ---------------------------------------------------------------------------

/// Maps a nested call exit to its recorded outcome (plan v2 section 1):
/// a returned status failure is a failure, cancellation - observed on the
/// result or caught as error.Cancelled - is cancelled, and only a plain
/// success is ok. Admission denial records .denied at its own exit.
fn mapNestedOutcome(
    result: ?tool_runtime.ToolExecutionResult,
    err: ?anyerror,
) tool_runtime.NestedCallOutcome {
    if (err) |e| {
        if (e == error.Cancelled) return .cancelled;
        return .failure;
    }
    if (result) |r| {
        if (r.cancelled) return .cancelled;
        if (r.status == .failure) return .failure;
    }
    return .ok;
}

/// Wall-clock milliseconds between the bridge entry timestamp and an
/// exit, clamped so a rolled-back .real clock records 0ms instead of
/// panicking on the u64 cast or wrapping to a huge value (plan v2
/// section 2, review F3).
fn nestedDurationMs(start_ms: i64, end_ms: i64) u64 {
    const elapsed = end_ms - start_ms;
    if (elapsed <= 0) return 0;
    return @intCast(elapsed);
}

// Plan v2 group 5 (review F2): the exit mapping records returned failures
// and cancellations accurately instead of labeling them ok or failure.
test "nested outcome mapping records returned failures and cancellations" {
    // A normal return with status .failure (missing file, non-zero exit)
    // records .failure, not .ok.
    try std.testing.expectEqual(
        tool_runtime.NestedCallOutcome.failure,
        mapNestedOutcome(.{ .model_output = "", .status = .failure }, null),
    );
    // error.Cancelled from dispatch records .cancelled, not .failure.
    try std.testing.expectEqual(
        tool_runtime.NestedCallOutcome.cancelled,
        mapNestedOutcome(.{ .model_output = "" }, error.Cancelled),
    );
    // A returned result that observed cancellation records .cancelled.
    try std.testing.expectEqual(
        tool_runtime.NestedCallOutcome.cancelled,
        mapNestedOutcome(.{ .model_output = "", .cancelled = true }, null),
    );
    // A plain success records .ok.
    try std.testing.expectEqual(
        tool_runtime.NestedCallOutcome.ok,
        mapNestedOutcome(.{ .model_output = "" }, null),
    );
}

// Plan v2 group 7 (review F3): a rolled-back wall clock clamps to 0ms
// instead of panicking on the u64 cast or wrapping to a huge value.
test "nested duration clamps a rolled-back wall clock" {
    // Normal elapsed time survives intact.
    try std.testing.expectEqual(@as(u64, 123), nestedDurationMs(1_000, 1_123));
    // A rollback records 0ms.
    try std.testing.expectEqual(@as(u64, 0), nestedDurationMs(5_000, 3_000));
    // Equal timestamps record 0ms.
    try std.testing.expectEqual(@as(u64, 0), nestedDurationMs(7_000, 7_000));
}

// Plan v2 group 8: duration is a non-negative, sane bound. Millisecond
// resolution makes 0ms legal for a fast path, so nothing asserts > 0;
// non-zero values are locked by the formatter goldens instead.
test "nested duration never wraps to a huge value" {
    // A rollback clamps to 0 rather than wrapping near u64 max.
    try std.testing.expect(nestedDurationMs(9_000, 8_999) < 4_096);
    // A full day of elapsed time still fits.
    try std.testing.expectEqual(@as(u64, 86_400_000), nestedDurationMs(0, 86_400_000));
}

// Plan v2 group 6 (review F7): a nested call that never takes effect
// records nothing. canonicalNestedCall errors return before admission and
// before recordNestedCall, matching the ISSUE-9 review note.
test "a nested call that fails canonicalization records nothing" {
    const allocator = std.testing.allocator;
    var fixture = TestCodemodeRuntime{};
    defer fixture.deinit(allocator);
    var state = tool_runtime.CodemodeHostState{
        .runtime = fixture.context(),
        .script_call = .{
            .id = "codemode-call",
            .name = "codemode",
            .arguments_json = "{}",
        },
    };
    const result = call(
        &state,
        allocator,
        .{ .name = "run_command" },
        "{\"action\":\"interact\",\"command\":\"true\"}",
    );
    try std.testing.expectError(error.InvalidToolArguments, result);
    try std.testing.expectEqual(@as(usize, 0), state.nestedCallCount());
    // The sequence still advances: the call id was minted before the
    // canonicalization error, but no record exists.
    try std.testing.expectEqual(@as(usize, 1), state.call_sequence);
}

fn gatherNoopBridgeContext(_: std.mem.Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopBridgeStaticContext(_: context_contract.StaticContextInput, _: std.mem.Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopBridgeTransientContext(_: context_contract.TransientContextInput, _: std.mem.Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn noopBridgeOutputChunk(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_contract.CommandOutputStream, _: []const u8) anyerror!void {}

/// Minimal runtime fixture for bridge-level behavior tests. Only the
/// canonicalization-failure path is driven, which touches no ctx field
/// before returning, so every field holds a harmless placeholder.
const TestCodemodeRuntime = struct {
    worker: worker_runtime_mod.WorkerRuntime = .{},
    session: session_runtime_mod.SessionRuntime = .{ .max_history_turns = 8 },

    fn deinit(self: *TestCodemodeRuntime, alloc: std.mem.Allocator) void {
        self.worker.deinit(alloc);
        self.session.deinit(alloc);
    }

    fn context(self: *TestCodemodeRuntime) tool_runtime.Context {
        return .{
            .workspace_root = "/tmp",
            .ignored_list_entries = &.{},
            .max_list_entries = 100,
            .max_read_file_bytes = 64 * 1024,
            .max_read_file_lines = 400,
            .max_read_file_line_len = 2000,
            .max_command_output_bytes = 64 * 1024,
            .api_key = "",
            .model = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 0,
            .permission_mode = .ask,
            .permission_grants = &.{},
            .permission_rules = .{},
            .worker = &self.worker,
            .session = &self.session,
            .context_registry = .{ .default_provider = .{
                .id = "test.codemode_bridge_context",
                .gather_project_context_fn = gatherNoopBridgeContext,
                .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
                .append_static_fn = appendNoopBridgeStaticContext,
                .append_transient_fn = appendNoopBridgeTransientContext,
            } },
            .output_chunk_ctx = undefined,
            .on_output_chunk = noopBridgeOutputChunk,
        };
    }
};
