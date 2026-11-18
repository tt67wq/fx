const std = @import("std");
const bindings = @import("bindings.zig");
const shell = @import("shell.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
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
const host_mod = @import("host.zig");

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
    return .{ .ctx = state, .call = call, .argument_error = argumentError };
}

/// The detail of the rejection the last call returned, if that rejection
/// named one. The host reads this only when the call returned
/// error.InvalidToolArguments; the text lives in the state until the
/// next call overwrites it.
fn argumentError(raw_ctx: ?*anyopaque) ?[]const u8 {
    const state: *tool_runtime.CodemodeHostState = @ptrCast(@alignCast(raw_ctx orelse return null));
    if (state.nested_argument_error.text.len == 0) return null;
    return state.nested_argument_error.text;
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
    // File mutations require a result owner distinct from the call owner:
    // the prepared mutation keeps the call arena alive across execution, so
    // one arena for both would trip the contract's ownership check.
    var result_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer result_arena_state.deinit();

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
    // A run_script call writes fx-owned temp files (the python script
    // body, the CTX_FILE copy) before admission, so the reviewed command
    // references existing files. The per-call directory dies with the
    // call: deletion runs on every return path below and nothing
    // survives the eval.
    var script_temp_dir: ?[]const u8 = null;
    defer if (script_temp_dir) |dir_path| {
        std.Io.Dir.cwd().deleteTree(io_mod.getIo(), dir_path) catch {};
    };
    // The rejection detail describes exactly this call: a stale detail
    // from an earlier one must never annotate a later failure.
    state.nested_argument_error.clear();
    const canonical = try canonicalNestedCall(arena, tool, args_json, .{
        .workspace_root = ctx.workspace_root,
    }, &script_temp_dir, &state.nested_argument_error);
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
        .result_allocator = result_arena_state.allocator(),
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
    if (isShellBackedFaceName(tool.name)) {
        return shellResult(allocator, arena, result);
    }
    return allocator.dupe(u8, result.model_output);
}

const CanonicalCall = struct {
    name: []const u8,
    arguments_json: []const u8,
};

/// Writes the model-visible field detail for one argument rejection into
/// the caller's buffer (when it wants one) and hands back the unchanged
/// error.InvalidToolArguments. Feedback only: the error, the admission
/// decision, and everything that runs afterwards stay exactly as they
/// were.
fn rejectArgument(
    arena: std.mem.Allocator,
    error_out: ?*tool_runtime.NestedArgumentError,
    comptime fmt: []const u8,
    args: anytype,
) error{InvalidToolArguments} {
    if (error_out) |buffer| {
        if (arena.print(fmt, args)) |text| {
            buffer.set(text);
        } else |_| {}
    }
    return error.InvalidToolArguments;
}

/// Rejection for one absent required field: names the field wanted and
/// lists the fields the script actually sent, so a cmd-instead-of-command
/// mistake is self-explaining (ISSUE-24).
fn rejectMissingField(
    arena: std.mem.Allocator,
    error_out: ?*tool_runtime.NestedArgumentError,
    comptime tool_name: []const u8,
    comptime field: []const u8,
    object: std.json.ObjectMap,
) error{InvalidToolArguments} {
    if (object.count() == 0) {
        return rejectArgument(arena, error_out, tool_name ++ " requires field \"" ++ field ++ "\"; received no fields", .{});
    }
    return rejectArgument(
        arena,
        error_out,
        tool_name ++ " requires field \"" ++ field ++ "\"; received fields: {s}",
        .{fieldList(arena, object) catch ""},
    );
}

/// The object's field names, sorted so the message never depends on map
/// iteration order.
fn fieldList(arena: std.mem.Allocator, object: std.json.ObjectMap) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = object.iterator();
    while (it.next()) |entry| try names.append(arena, entry.key_ptr.*);
    sort_utils.sort([]const u8, names.items, {}, lessName);
    return std.mem.join(arena, ", ", names.items);
}

fn lessName(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Maps the script-facing "run_command" and "run_script" names onto the
/// registered "shell" tool's "action: run" form. run_script normalization
/// lives in canonicalRunScript below; run_command and every other face name
/// keep the behavior they had before T-20.
fn canonicalNestedCall(
    arena: std.mem.Allocator,
    tool: bindings.Tool,
    args_json: []const u8,
    env: RunScriptEnv,
    temp_dir_out: ?*?[]const u8,
    /// Where a rejection writes the model-visible field detail, described
    /// on tool_runtime.NestedArgumentError. Null keeps the bare error.
    error_out: ?*tool_runtime.NestedArgumentError,
) !CanonicalCall {
    if (std.mem.eql(u8, tool.name, "run_command")) {
        return canonicalRunCommand(arena, args_json, error_out);
    }
    if (std.mem.eql(u8, tool.name, "run_script")) {
        return canonicalRunScript(arena, args_json, env, temp_dir_out, error_out);
    }
    return .{ .name = tool.name, .arguments_json = args_json };
}

/// Inputs canonicalNestedCall needs only for run_script: the workspace
/// root the `file` argument resolves against, and the base directory for
/// the fx-written temp files. Tests inject temp_base; production leaves it
/// empty and the TMPDIR environment decides.
pub const RunScriptEnv = struct {
    workspace_root: []const u8 = "",
    temp_base: []const u8 = "",
};

/// The v1 language enum. The interpreter token below is the only source of
/// that argv token: model text never names it, and a language outside this
/// enum is rejected before anything executes.
const RunScriptLanguage = enum { shell, python };

fn parseRunScriptLanguage(value: []const u8) ?RunScriptLanguage {
    if (std.mem.eql(u8, value, "shell")) return .shell;
    if (std.mem.eql(u8, value, "python")) return .python;
    return null;
}

/// Cap for the CTX_FILE source read. The copy never enters the model
/// context, but the bridge still bounds its own memory: 1MiB matches the
/// script shell budget in shell.zig.
pub const run_script_max_ctx_file_bytes: usize = 1024 * 1024;

const run_script_temp_prefix = "fx-run-script-";

/// Quotes one fx-generated path for the shell command line. Fx-controlled
/// bytes stay bare; anything else is single-quoted with the standard
/// escape, so an odd TMPDIR value cannot break the argv shape.
fn quoteShellPath(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-";
    for (path) |byte| {
        if (std.mem.findScalar(u8, safe, byte) == null) {
            var out: std.Io.Writer.Allocating = .init(alloc);
            try out.writer.writeByte('\'');
            for (path) |c| {
                if (c == '\'') {
                    try out.writer.writeAll("'\\''");
                } else {
                    try out.writer.writeByte(c);
                }
            }
            try out.writer.writeByte('\'');
            return out.toOwnedSlice();
        }
    }
    return alloc.dupe(u8, path);
}

/// Creates the per-call temp directory that holds the fx-written script
/// file and the CTX_FILE copy. The caller owns cleanup: call() records the
/// path through temp_dir_out and deleteTree's it on every return path.
fn makeRunScriptTempDir(arena: std.mem.Allocator, temp_base: []const u8) ![]const u8 {
    var suffix: [8]u8 = undefined;
    io_mod.getIo().random(&suffix);
    const hex = std.fmt.bytesToHex(suffix, .lower);
    const base = if (temp_base.len > 0) temp_base else io_mod.getenv("TMPDIR") orelse "/tmp";
    const dir_path = try std.Io.Dir.path.join(arena, &.{ base, try arena.print("{s}{s}", .{ run_script_temp_prefix, &hex }) });
    std.Io.Dir.cwd().createDir(io_mod.getIo(), dir_path, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => return error.RunScriptTempUnavailable,
        else => return err,
    };
    return dir_path;
}

/// Writes one fx-owned file into the per-call temp directory. The host
/// writes files directly; no process is started here.
fn writeRunScriptFile(
    arena: std.mem.Allocator,
    dir_path: []const u8,
    name: []const u8,
    content: []const u8,
) !void {
    const path = try std.Io.Dir.path.join(arena, &.{ dir_path, name });
    var file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

/// Resolves the run_script `file` argument against the workspace root and
/// refuses anything that resolves outside it, so a script cannot be pointed
/// at an arbitrary host path through a traversal escape. The script reads
/// the fx-written copy through CTX_FILE, never the model context.
fn resolveRunScriptFile(
    arena: std.mem.Allocator,
    env: RunScriptEnv,
    file_param: []const u8,
    error_out: ?*tool_runtime.NestedArgumentError,
) ![]const u8 {
    if (env.workspace_root.len == 0) {
        return rejectArgument(arena, error_out, "run_script field \"file\" has no workspace to resolve against", .{});
    }
    const root_real = io_mod.realpathAlloc(arena, env.workspace_root) catch
        return rejectArgument(arena, error_out, "run_script field \"file\" has no readable workspace root", .{});
    const candidate = std.Io.Dir.path.resolveAlloc(arena, &.{ root_real, file_param }) catch
        return rejectArgument(arena, error_out, "run_script field \"file\" does not name a readable workspace file", .{});
    const real = io_mod.realpathAlloc(arena, candidate) catch
        return rejectArgument(arena, error_out, "run_script field \"file\" does not name a readable workspace file", .{});
    const inside = std.mem.eql(u8, real, root_real) or
        (real.len > root_real.len and real[root_real.len] == '/' and std.mem.startsWith(u8, real, root_real));
    if (!inside) return rejectArgument(arena, error_out, "run_script field \"file\" must stay inside the workspace", .{});
    return real;
}

/// Reads the resolved workspace file, bounded by run_script_max_ctx_file_bytes.
fn readRunScriptFile(
    arena: std.mem.Allocator,
    real_path: []const u8,
    error_out: ?*tool_runtime.NestedArgumentError,
) ![]const u8 {
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), real_path, .{}) catch
        return rejectArgument(arena, error_out, "run_script field \"file\" does not name a readable workspace file", .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(arena, &file, run_script_max_ctx_file_bytes) catch |err| switch (err) {
        error.StreamTooLong => rejectArgument(
            arena,
            error_out,
            "run_script field \"file\" is larger than the {d}-byte CTX_FILE limit",
            .{run_script_max_ctx_file_bytes},
        ),
        else => err,
    };
}

/// Clamps a run_script timeout_ms into the host options range
/// (host.min_options_timeout_ms .. host.max_options_timeout_ms). A nested
/// run is additionally capped by the script's own ambient budget.
fn clampRunScriptTimeout(requested: i64) u64 {
    const min: i64 = @intCast(host_mod.min_options_timeout_ms);
    const max: i64 = @intCast(host_mod.max_options_timeout_ms);
    return @intCast(std.math.clamp(requested, min, max));
}

/// Normalizes one run_script call onto the registered shell tool's
/// `action:"run"` form. The interpreter token comes from the language enum
/// above, the python script body and any CTX_FILE copy are written by fx
/// into a per-call temp directory, and the command is the fixed argv shape
/// `python3 <fx temp path>` (shell forwards the command line itself, which
/// keeps the command_effect word-form guard in charge). Model text never
/// becomes an interpreter option token: fields beyond the five below would
/// be the only carriers for one, and unknown fields are rejected here at
/// the normalization layer, before admission and before the shell decode.
/// The action goes first so the bytes match a direct model call that names
/// the same action and command.
fn canonicalRunScript(
    arena: std.mem.Allocator,
    args_json: []const u8,
    env: RunScriptEnv,
    temp_dir_out: ?*?[]const u8,
    error_out: ?*tool_runtime.NestedArgumentError,
) !CanonicalCall {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch
        return rejectArgument(arena, error_out, "run_script arguments must be a JSON object", .{});
    if (parsed != .object) return rejectArgument(arena, error_out, "run_script arguments must be a JSON object", .{});
    const object = parsed.object;

    const allowed_fields = [_][]const u8{ "language", "code", "file", "intent", "timeout_ms" };
    var fields = object.iterator();
    while (fields.next()) |entry| {
        var known = false;
        for (allowed_fields) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) {
            return rejectArgument(
                arena,
                error_out,
                "run_script unknown field \"{s}\"; expected fields: language, code, file, intent, timeout_ms",
                .{entry.key_ptr.*},
            );
        }
    }

    const language_value = object.get("language") orelse
        return rejectMissingField(arena, error_out, "run_script", "language", object);
    if (language_value != .string) return rejectArgument(arena, error_out, "run_script field \"language\" must be a string", .{});
    const language = parseRunScriptLanguage(language_value.string) orelse
        return rejectArgument(
            arena,
            error_out,
            "run_script field \"language\" must be \"shell\" or \"python\"; received \"{s}\"",
            .{language_value.string},
        );

    const code_value = object.get("code") orelse
        return rejectMissingField(arena, error_out, "run_script", "code", object);
    if (code_value != .string) return rejectArgument(arena, error_out, "run_script field \"code\" must be a string", .{});

    // A dash-prefixed file path is a path-like token that would be misread
    // as an option; it is rejected outright.
    var ctx_file_source: ?[]const u8 = null;
    if (object.get("file")) |value| {
        if (value != .string) return rejectArgument(arena, error_out, "run_script field \"file\" must be a string", .{});
        if (value.string.len == 0 or value.string[0] == '-') return rejectArgument(arena, error_out, "run_script field \"file\" must be a plain path", .{});
        ctx_file_source = try resolveRunScriptFile(arena, env, value.string, error_out);
    }

    // intent is accepted for the transcript context and never executed.
    if (object.get("intent")) |value| {
        if (value != .string) return rejectArgument(arena, error_out, "run_script field \"intent\" must be a string", .{});
    }

    var timeout_ms: ?u64 = null;
    if (object.get("timeout_ms")) |value| {
        if (value != .integer) return rejectArgument(arena, error_out, "run_script field \"timeout_ms\" must be an integer", .{});
        timeout_ms = clampRunScriptTimeout(value.integer);
    }

    var temp_dir: ?[]const u8 = null;
    var ctx_path: ?[]const u8 = null;
    if (ctx_file_source) |source| {
        temp_dir = try makeRunScriptTempDir(arena, env.temp_base);
        // Registered before the copy: a rejected source (oversized,
        // unreadable) must still reach the caller's cleanup defer, or the
        // dir leaks in TMPDIR.
        if (temp_dir_out) |out| out.* = temp_dir.?;
        try writeRunScriptFile(arena, temp_dir.?, "ctx_file", try readRunScriptFile(arena, source, error_out));
        ctx_path = try std.Io.Dir.path.join(arena, &.{ temp_dir.?, "ctx_file" });
    }

    var command: []const u8 = undefined;
    switch (language) {
        .shell => command = if (ctx_path) |path|
            try arena.print("CTX_FILE={s} {s}", .{ try quoteShellPath(arena, path), code_value.string })
        else
            code_value.string,
        .python => {
            // One per-call directory serves both the script body and the
            // CTX_FILE copy.
            if (temp_dir == null) {
                temp_dir = try makeRunScriptTempDir(arena, env.temp_base);
                if (temp_dir_out) |out| out.* = temp_dir.?;
            }
            try writeRunScriptFile(arena, temp_dir.?, "script.py", code_value.string);
            const script_path = try std.Io.Dir.path.join(arena, &.{ temp_dir.?, "script.py" });
            command = if (ctx_path) |path|
                try arena.print("CTX_FILE={s} python3 {s}", .{ try quoteShellPath(arena, path), try quoteShellPath(arena, script_path) })
            else
                try arena.print("python3 {s}", .{try quoteShellPath(arena, script_path)});
        },
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"action\":\"run\",\"command\":");
    try std.json.Stringify.value(command, .{}, &out.writer);
    if (timeout_ms) |value| {
        try out.writer.print(",\"timeout_ms\":{d}", .{value});
    }
    try out.writer.writeByte('}');
    return .{ .name = "shell", .arguments_json = try out.toOwnedSlice() };
}

/// The script-facing schema behind tools.list's run_script entry. The tool
/// has no registry entry (it is script-facing only and canonicalizes onto
/// the shell tool), so its schema is defined here and rendered directly by
/// schemas(). The field set matches canonicalRunScript exactly.
const run_script_language_enum = [_][]const u8{ "shell", "python" };
const run_script_language_shape: model_tool_schema.PropertyShape = .{ .enum_values = &run_script_language_enum };
const run_script_timeout_bounds: model_tool_schema.PropertyBounds = .{
    .minimum = host_mod.min_options_timeout_ms,
    .maximum = host_mod.max_options_timeout_ms,
};
const run_script_properties = [_]model_tool_schema.Property{
    .{
        .name = "language",
        .json_type = .string,
        .description = "shell or python.",
        .shape = &run_script_language_shape,
    },
    .{
        .name = "code",
        .json_type = .string,
        .description = "python: script body. shell: command line.",
    },
    .{
        .name = "file",
        .json_type = .string,
        .description = "Exposed as CTX_FILE.",
    },
    .{
        .name = "intent",
        .json_type = .string,
    },
    .{
        .name = "timeout_ms",
        .json_type = .integer,
        .description = "Clamped to 1000-120000.",
        .bounds = &run_script_timeout_bounds,
    },
};
pub const run_script_model_schema = model_tool_schema.FunctionSchema{
    .name = "run_script",
    .description = "Run code with an fx-picked interpreter. python: fx temp file run via python3. shell: the command line.",
    .input_schema = .{
        .properties = &run_script_properties,
        .required = &.{ "language", "code" },
        .additional_properties = false,
    },
};

/// Maps the script's `run_command` call onto the registered `shell` tool's
/// `action: "run"` form, keeping the pre-T-20 behavior byte for byte: the
/// action goes first, every other script field keeps its original order.
fn canonicalRunCommand(
    arena: std.mem.Allocator,
    args_json: []const u8,
    error_out: ?*tool_runtime.NestedArgumentError,
) !CanonicalCall {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch
        return rejectArgument(arena, error_out, "run_command arguments must be a JSON object", .{});
    if (parsed != .object) return rejectArgument(arena, error_out, "run_command arguments must be a JSON object", .{});
    const object = parsed.object;

    if (object.get("action")) |action| {
        if (action != .string or !std.mem.eql(u8, action.string, "run")) {
            if (action == .string) {
                return rejectArgument(arena, error_out, "run_command field \"action\" must be \"run\"; received \"{s}\"", .{action.string});
            }
            return rejectArgument(arena, error_out, "run_command field \"action\" must be the string \"run\"", .{});
        }
    }
    const command = object.get("command") orelse
        return rejectMissingField(arena, error_out, "run_command", "command", object);
    if (command != .string) return rejectArgument(arena, error_out, "run_command field \"command\" must be a string", .{});

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
        .{},
        null,
        null,
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
        .{},
        null,
        null,
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
            .{},
            null,
            null,
        ),
    );
}

test "run_command canonicalization requires an object with a string command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_command" }, "[]", .{}, null, null),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_command" }, "{}", .{}, null, null),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_command" }, "{\"command\":5}", .{}, null, null),
    );
}

// ISSUE-24: a rejected nested tools.call must name the field that is
// wrong and the fields that were expected, not just the Zig error name.
// These tests pin the detail text the model reads inside
// "codemode tool <name> failed: InvalidToolArguments: <detail>".
test "run_command argument rejections name the fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { args: []const u8, detail: []const u8 };
    const cases = [_]Case{
        .{ .args = "[]", .detail = "run_command arguments must be a JSON object" },
        .{ .args = "{\"action\":\"interact\",\"command\":\"true\"}", .detail = "run_command field \"action\" must be \"run\"; received \"interact\"" },
        .{ .args = "{\"cmd\":\"ls\"}", .detail = "run_command requires field \"command\"; received fields: cmd" },
        .{ .args = "{}", .detail = "run_command requires field \"command\"; received no fields" },
        .{ .args = "{\"command\":5}", .detail = "run_command field \"command\" must be a string" },
    };
    for (cases) |case| {
        var detail: tool_runtime.NestedArgumentError = .{};
        try std.testing.expectError(
            error.InvalidToolArguments,
            canonicalNestedCall(arena, .{ .name = "run_command" }, case.args, .{}, null, &detail),
        );
        try std.testing.expectEqualStrings(case.detail, detail.text);
    }
}

test "run_script argument rejections name the fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { args: []const u8, detail: []const u8 };
    const cases = [_]Case{
        .{ .args = "{\"language\":\"python\",\"code\":\"1\",\"args\":[\"-c\"]}", .detail = "run_script unknown field \"args\"; expected fields: language, code, file, intent, timeout_ms" },
        .{ .args = "{\"code\":\"1\"}", .detail = "run_script requires field \"language\"; received fields: code" },
        .{ .args = "{\"language\":\"python\"}", .detail = "run_script requires field \"code\"; received fields: language" },
        .{ .args = "{\"language\":5,\"code\":\"1\"}", .detail = "run_script field \"language\" must be a string" },
        .{ .args = "{\"language\":\"js\",\"code\":\"1\"}", .detail = "run_script field \"language\" must be \"shell\" or \"python\"; received \"js\"" },
        .{ .args = "{\"language\":\"python\",\"code\":1}", .detail = "run_script field \"code\" must be a string" },
        .{ .args = "{\"language\":\"python\",\"code\":\"1\",\"file\":5}", .detail = "run_script field \"file\" must be a string" },
        .{ .args = "{\"language\":\"python\",\"code\":\"1\",\"file\":\"-x\"}", .detail = "run_script field \"file\" must be a plain path" },
        .{ .args = "{\"language\":\"python\",\"code\":\"1\",\"intent\":5}", .detail = "run_script field \"intent\" must be a string" },
        .{ .args = "{\"language\":\"python\",\"code\":\"1\",\"timeout_ms\":\"x\"}", .detail = "run_script field \"timeout_ms\" must be an integer" },
    };
    for (cases) |case| {
        var detail: tool_runtime.NestedArgumentError = .{};
        try std.testing.expectError(
            error.InvalidToolArguments,
            canonicalNestedCall(arena, .{ .name = "run_script" }, case.args, .{}, null, &detail),
        );
        try std.testing.expectEqualStrings(case.detail, detail.text);
    }
}

test "run_script file rejections name the constraint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ws_root = try arena.print("/tmp/fx-run-script-detail-ws-{d}", .{io_mod.nanoTimestamp()});
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), ws_root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), ws_root) catch {};
    const env = RunScriptEnv{ .workspace_root = ws_root, .temp_base = ws_root };

    var outside: tool_runtime.NestedArgumentError = .{};
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(
            arena,
            .{ .name = "run_script" },
            "{\"language\":\"python\",\"code\":\"1\",\"file\":\"../../../../etc/hosts\"}",
            env,
            null,
            &outside,
        ),
    );
    try std.testing.expectEqualStrings("run_script field \"file\" must stay inside the workspace", outside.text);

    var missing: tool_runtime.NestedArgumentError = .{};
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(
            arena,
            .{ .name = "run_script" },
            "{\"language\":\"python\",\"code\":\"1\",\"file\":\"missing.txt\"}",
            env,
            null,
            &missing,
        ),
    );
    try std.testing.expectEqualStrings("run_script field \"file\" does not name a readable workspace file", missing.text);
}

test "other whitelisted tools keep their exact arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical = try canonicalNestedCall(
        arena_state.allocator(),
        .{ .name = "read_file" },
        "{\"path\":\"notes.txt\"}",
        .{},
        null,
        null,
    );
    try std.testing.expectEqualStrings("read_file", canonical.name);
    try std.testing.expectEqualStrings("{\"path\":\"notes.txt\"}", canonical.arguments_json);
}

// --- run_script tests (T-20) ---

test "run_script python canonicalizes to a fixed python3 argv through a fx temp script" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const temp_base = try arena.print("/tmp/fx-run-script-test-{d}", .{io_mod.nanoTimestamp()});
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), temp_base);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), temp_base) catch {};
    var temp_dir: ?[]const u8 = null;
    const canonical = try canonicalNestedCall(
        arena,
        .{ .name = "run_script" },
        "{\"language\":\"python\",\"code\":\"print('hi')\"}",
        .{ .workspace_root = temp_base, .temp_base = temp_base },
        &temp_dir,
        null,
    );
    try std.testing.expectEqualStrings("shell", canonical.name);
    // argv is always exactly python3 plus the fx-written temp script path;
    // model text never becomes an argv token.
    try std.testing.expect(std.mem.startsWith(u8, canonical.arguments_json, "{\"action\":\"run\",\"command\":\"python3 "));
    try std.testing.expect(std.mem.endsWith(u8, canonical.arguments_json, "/script.py\"}"));
    // The temp dir is recorded for the caller's cleanup, and the fx-written
    // script file carries the code verbatim.
    const dir = temp_dir.?;
    try std.testing.expect(std.mem.startsWith(u8, dir, temp_base));
    const script_path = try std.Io.Dir.path.join(arena, &.{ dir, "script.py" });
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), script_path, .{});
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(arena, &file, 4096);
    try std.testing.expectEqualStrings("print('hi')", content);
}

test "run_script file param copies a workspace file and prefixes CTX_FILE" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ws_root = try arena.print("/tmp/fx-run-script-ws-{d}", .{io_mod.nanoTimestamp()});
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), ws_root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), ws_root) catch {};
    const temp_base = try std.Io.Dir.path.join(arena, &.{ ws_root, "tmp" });
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), temp_base);
    const data_path = try std.Io.Dir.path.join(arena, &.{ ws_root, "data.txt" });
    {
        var data = try std.Io.Dir.cwd().createFile(io_mod.getIo(), data_path, .{ .truncate = true });
        defer data.close(io_mod.getIo());
        try data.writeStreamingAll(io_mod.getIo(), "hello-ctx-5521");
    }
    var temp_dir: ?[]const u8 = null;
    const canonical = try canonicalNestedCall(
        arena,
        .{ .name = "run_script" },
        "{\"language\":\"python\",\"code\":\"1\",\"file\":\"data.txt\"}",
        .{ .workspace_root = ws_root, .temp_base = temp_base },
        &temp_dir,
        null,
    );
    try std.testing.expectEqualStrings("shell", canonical.name);
    try std.testing.expect(std.mem.startsWith(u8, canonical.arguments_json, "{\"action\":\"run\",\"command\":\"CTX_FILE="));
    try std.testing.expect(std.mem.indexOf(u8, canonical.arguments_json, " python3 ") != null);
    try std.testing.expect(std.mem.endsWith(u8, canonical.arguments_json, "/script.py\"}"));
    // The copy carries the workspace file's content; the source path never
    // appears in the command.
    const ctx_path = try std.Io.Dir.path.join(arena, &.{ temp_dir.?, "ctx_file" });
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), ctx_path, .{});
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(arena, &file, 4096);
    try std.testing.expectEqualStrings("hello-ctx-5521", content);
    try std.testing.expect(std.mem.indexOf(u8, canonical.arguments_json, data_path) == null);
}

test "run_script file param refuses traversal outside the workspace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ws_root = try arena.print("/tmp/fx-run-script-trav-{d}", .{io_mod.nanoTimestamp()});
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), ws_root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), ws_root) catch {};
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(
            arena,
            .{ .name = "run_script" },
            "{\"language\":\"python\",\"code\":\"1\",\"file\":\"../../../../etc/hosts\"}",
            .{ .workspace_root = ws_root, .temp_base = ws_root },
            null,
            null,
        ),
    );
}

test "run_script file param refuses a missing file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ws_root = try arena.print("/tmp/fx-run-script-missing-{d}", .{io_mod.nanoTimestamp()});
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), ws_root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), ws_root) catch {};
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(
            arena,
            .{ .name = "run_script" },
            "{\"language\":\"python\",\"code\":\"1\",\"file\":\"missing.txt\"}",
            .{ .workspace_root = ws_root, .temp_base = ws_root },
            null,
            null,
        ),
    );
}

test "run_script oversized ctx file registers the temp dir for caller cleanup" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const temp_base = try std.Io.Dir.path.join(arena, &.{ ws_root, "tmp" });
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), temp_base);
    const big_path = try std.Io.Dir.path.join(arena, &.{ ws_root, "big.txt" });
    {
        var big = try std.Io.Dir.cwd().createFile(io_mod.getIo(), big_path, .{ .truncate = true });
        defer big.close(io_mod.getIo());
        const chunk: [4096]u8 = @splat('x');
        var written: usize = 0;
        while (written <= run_script_max_ctx_file_bytes) : (written += chunk.len) {
            try big.writeStreamingAll(io_mod.getIo(), &chunk);
        }
    }
    var temp_dir: ?[]const u8 = null;
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(
            arena,
            .{ .name = "run_script" },
            "{\"language\":\"python\",\"code\":\"1\",\"file\":\"big.txt\"}",
            .{ .workspace_root = ws_root, .temp_base = temp_base },
            &temp_dir,
            null,
        ),
    );
    // The dir must be registered the moment it exists: an unregistered dir
    // here is the ISSUE-20 orphan the caller's cleanup defer cannot reach.
    try std.testing.expect(temp_dir != null);
    if (temp_dir) |dir_path| {
        std.Io.Dir.cwd().deleteTree(io_mod.getIo(), dir_path) catch {};
    }
    var scan = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), temp_base, .{ .iterate = true });
    defer scan.close(io_mod.getIo());
    var iter = scan.iterate();
    while (try iter.next(io_mod.getIo())) |entry| {
        try std.testing.expect(std.mem.startsWith(u8, entry.name, run_script_temp_prefix) == false);
    }
}

test "a failed run_script call leaves no temp dir behind" {
    const allocator = std.testing.allocator;
    var fixture = TestCodemodeRuntime{};
    defer fixture.deinit(allocator);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const big_path = try std.Io.Dir.path.join(arena, &.{ ws_root, "big.txt" });
    {
        var big = try std.Io.Dir.cwd().createFile(io_mod.getIo(), big_path, .{ .truncate = true });
        defer big.close(io_mod.getIo());
        const chunk: [4096]u8 = @splat('x');
        var written: usize = 0;
        while (written <= run_script_max_ctx_file_bytes) : (written += chunk.len) {
            try big.writeStreamingAll(io_mod.getIo(), &chunk);
        }
    }
    // call() leaves temp_base empty in production, so the base is the same
    // one makeRunScriptTempDir resolves: TMPDIR or /tmp.
    const temp_base = if (io_mod.getenv("TMPDIR")) |t| (if (t.len > 0) t else "/tmp") else "/tmp";
    var before: std.StringHashMap(void) = .init(allocator);
    defer {
        var key_it = before.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        before.deinit();
    }
    try collectRunScriptTempNames(temp_base, &before);
    var ctx = fixture.context();
    ctx.workspace_root = ws_root;
    var state = tool_runtime.CodemodeHostState{
        .runtime = ctx,
        .script_call = .{ .id = "codemode-call", .name = "codemode", .arguments_json = "{}" },
    };
    try std.testing.expectError(
        error.InvalidToolArguments,
        call(
            &state,
            allocator,
            .{ .name = "run_script" },
            "{\"language\":\"python\",\"code\":\"1\",\"file\":\"big.txt\"}",
        ),
    );
    var after: std.StringHashMap(void) = .init(allocator);
    defer {
        var key_it = after.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        after.deinit();
    }
    try collectRunScriptTempNames(temp_base, &after);
    var it = after.keyIterator();
    while (it.next()) |key| {
        try std.testing.expect(before.contains(key.*));
    }
}

/// Collects the fx-run-script-* directory names under one base dir. The
/// map owns its keys; the caller frees them with the map.
fn collectRunScriptTempNames(
    temp_base: []const u8,
    names: *std.StringHashMap(void),
) !void {
    var scan = std.Io.Dir.openDirAbsolute(io_mod.getIo(), temp_base, .{ .iterate = true }) catch return;
    defer scan.close(io_mod.getIo());
    var iter = scan.iterate();
    while (try iter.next(io_mod.getIo())) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, run_script_temp_prefix)) continue;
        const owned = try names.allocator.dupe(u8, entry.name);
        try names.put(owned, {});
    }
}
test "run_script shell forwards the code as the shell command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical = try canonicalNestedCall(
        arena_state.allocator(),
        .{ .name = "run_script" },
        "{\"language\":\"shell\",\"code\":\"echo hi\"}",
        .{},
        null,
        null,
    );
    try std.testing.expectEqualStrings("shell", canonical.name);
    try std.testing.expectEqualStrings(
        "{\"action\":\"run\",\"command\":\"echo hi\"}",
        canonical.arguments_json,
    );
}

test "run_script rejects a language outside the v1 enum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // v1 whitelist: shell + python. Neither python3 nor node may smuggle in
    // through the language field; the interpreter token comes from the enum.
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "{\"language\":\"node\",\"code\":\"1\"}", .{}, null, null),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "{\"language\":\"python3\",\"code\":\"1\"}", .{}, null, null),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "{\"language\":\"-python\",\"code\":\"1\"}", .{}, null, null),
    );
}

test "run_script rejects interpreter option fields at normalization" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Any field that would carry interpreter tokens (args, interpreter, ...)
    // is an unknown field and is rejected here, in canonicalNestedCall,
    // before admission or the shell decode layer ever sees it.
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "{\"language\":\"python\",\"code\":\"1\",\"args\":[\"-c\",\"evil\"]}", .{}, null, null),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "{\"language\":\"python\",\"code\":\"1\",\"interpreter\":\"-c\"}", .{}, null, null),
    );
}

test "run_script rejects a dash-prefixed file path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(
            arena_state.allocator(),
            .{ .name = "run_script" },
            "{\"language\":\"python\",\"code\":\"1\",\"file\":\"-rf\"}",
            .{},
            null,
            null,
        ),
    );
}

test "run_script requires a string code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "{\"language\":\"python\"}", .{}, null, null),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "{\"language\":\"python\",\"code\":5}", .{}, null, null),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "[]", .{}, null, null),
    );
}

test "run_script clamps timeout_ms into the host options range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const low = try canonicalNestedCall(
        arena,
        .{ .name = "run_script" },
        "{\"language\":\"shell\",\"code\":\"true\",\"timeout_ms\":5}",
        .{},
        null,
        null,
    );
    try std.testing.expectEqualStrings(
        "{\"action\":\"run\",\"command\":\"true\",\"timeout_ms\":1000}",
        low.arguments_json,
    );
    const high = try canonicalNestedCall(
        arena,
        .{ .name = "run_script" },
        "{\"language\":\"shell\",\"code\":\"true\",\"timeout_ms\":500000}",
        .{},
        null,
        null,
    );
    try std.testing.expectEqualStrings(
        "{\"action\":\"run\",\"command\":\"true\",\"timeout_ms\":120000}",
        high.arguments_json,
    );
    // A non-integer timeout is a malformed argument, not a default.
    try std.testing.expectError(
        error.InvalidToolArguments,
        canonicalNestedCall(arena, .{ .name = "run_script" }, "{\"language\":\"shell\",\"code\":\"true\",\"timeout_ms\":\"soon\"}", .{}, null, null),
    );
}

test "schemas renders the run_script schema on the derived face" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const face = sandboxFace(builtin_tools.registry, true);
    const injected = try schemas(arena, builtin_tools.registry, face);
    var found = false;
    for (injected) |schema| {
        if (!std.mem.eql(u8, schema.name, "run_script")) continue;
        found = true;
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, schema.schema_json, .{});
        defer parsed.deinit();
        const props = parsed.value.object.get("inputSchema").?.object.get("properties").?.object;
        try std.testing.expect(props.get("language") != null);
        try std.testing.expect(props.get("code") != null);
        const language = props.get("language").?.object.get("enum").?.array;
        try std.testing.expectEqual(@as(usize, 2), language.items.len);
        try std.testing.expectEqualStrings("shell", language.items[0].string);
        try std.testing.expectEqualStrings("python", language.items[1].string);
        const required = parsed.value.object.get("inputSchema").?.object.get("required").?.array;
        try std.testing.expectEqual(@as(usize, 2), required.items.len);
        // Plan question 4: the run_script schema stays negligible against
        // the 16KiB catalog budget. Measured 629 bytes (the plan's 300-500
        // estimate ran slightly under the five descriptions); the bounds
        // pin that band so a fatter description is a deliberate change.
        try std.testing.expectEqual(true, schema.schema_json.len >= 300);
        try std.testing.expectEqual(true, schema.schema_json.len <= 768);
    }
    try std.testing.expect(found);
}

/// Maps a script-facing whitelist name to the registered tool that backs
/// it. run_command is the shell tool's captured-command compatibility name
/// (see canonicalNestedCall); every other name is its own registry entry.
/// run_script is the one further exception: it has no registry backer and
/// schemas() renders its static schema before this lookup runs. A
/// whitelist name with no registered backer and no static schema is a
/// wiring bug, so it is an error rather than a silent skip.
/// The script-facing names whose nested result encodes through
/// shell.encodeResultJson. Both canonicalize onto the registered shell
/// tool's run action, so both get the same exit_code/output shape.
fn isShellBackedFaceName(name: []const u8) bool {
    return std.mem.eql(u8, name, "run_command") or std.mem.eql(u8, name, "run_script");
}

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
        // run_command and run_script are both script-facing names backed
        // by the registered shell tool; neither is a registry entry.
        face = face ++ &[_]bindings.Tool{.{ .name = "run_command" }};
        face = face ++ &[_]bindings.Tool{.{ .name = "run_script" }};
        break :blk face;
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
        // run_script is script-facing only: it has no registry entry, so
        // its static schema (see run_script_model_schema) renders here.
        const json = if (std.mem.eql(u8, tool.name, "run_script"))
            try model_tool_schema.builtinFunctionSchemaJsonAlloc(alloc, run_script_model_schema)
        else blk: {
            const registered = registry.lookup(registeredName(tool.name)) orelse return error.SchemaMissing;
            break :blk try model_tool_schema.builtinFunctionSchemaJsonAlloc(alloc, registered.model_schema);
        };
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
