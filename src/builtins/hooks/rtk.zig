const std = @import("std");
const hooks = @import("../../core/hooks/hooks.zig");
const json_decode = @import("../../core/shared/json_decode.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

/// Rewrites a shell command through rtk. Returns null when rtk offers no
/// rewrite (unknown command, failure, timeout, empty output). The production
/// implementation shells out to `rtk rewrite <command>`; tests inject fakes.
pub const Rewriter = *const fn (alloc: Allocator, command: []const u8) ?[]const u8;

pub const Context = struct {
    rewriter: Rewriter,
    arena_state: *std.heap.ArenaAllocator,
};

fn preToolUse(
    ctx: *anyopaque,
    input: hooks.PreToolUseInput,
) hooks.HandlerError!hooks.PreToolUseAction {
    const context: *Context = @ptrCast(@alignCast(ctx));
    return handle(context, input) catch return .continue_;
}

fn handle(
    context: *Context,
    input: hooks.PreToolUseInput,
) Allocator.Error!hooks.PreToolUseAction {
    if (!std.mem.eql(u8, input.tool_name, "shell")) return .continue_;
    const parsed_arguments = parseArguments(input.arguments_json) orelse return .continue_;
    if (!std.mem.eql(u8, parsed_arguments.action, "run")) return .continue_;
    if (std.mem.startsWith(u8, parsed_arguments.command, "rtk ")) return .continue_;
    const alloc = context.arena_state.allocator();
    const rewritten = context.rewriter(alloc, parsed_arguments.command) orelse return .continue_;
    if (rewritten.len == 0) return .continue_;
    if (std.mem.eql(u8, rewritten, parsed_arguments.command)) return .continue_;
    return .{ .rewrite_arguments = try withCommand(alloc, input.arguments_json, rewritten) };
}

const ParsedArguments = struct { action: []const u8, command: []const u8 };

fn parseArguments(arguments_json: []const u8) ?ParsedArguments {
    const scratch = scratchArena();
    const parsed = json_decode.parseFromSliceLeaky(
        ParsedArguments,
        scratch,
        arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    if (parsed.action.len == 0 or parsed.command.len == 0) return null;
    return parsed;
}

var scratch_arena_state: ?std.heap.ArenaAllocator = null;

fn scratchArena() Allocator {
    if (scratch_arena_state == null) {
        scratch_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    const arena = &scratch_arena_state.?;
    _ = arena.reset(.retain_capacity);
    return arena.allocator();
}

fn withCommand(
    alloc: Allocator,
    arguments_json: []const u8,
    command: []const u8,
) Allocator.Error![]u8 {
    const scratch = scratchArena();
    var value = json_decode.parseFromSliceLeaky(
        std.json.Value,
        scratch,
        arguments_json,
        .{},
    ) catch return error.OutOfMemory;
    if (value != .object) return error.OutOfMemory;
    if (value.object.getPtr("command")) |slot| {
        slot.* = .{ .string = command };
    } else {
        value.object.put(scratch, "command", .{ .string = command }) catch return error.OutOfMemory;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Per-app hook state and registration. The gate reads experimental.rtk;
/// the PATH probe runs once; registration happens before the lifecycle
/// runtime freezes (src/main.zig configureNotifications).
pub const State = struct {
    arena_state: std.heap.ArenaAllocator = undefined,
    arena_initialized: bool = false,
    context: Context = undefined,
};

fn rtkOnPath() bool {
    const search_path = io_mod.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, search_path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const io = io_mod.getIo();
        var probe = std.Io.Dir.openDirAbsolute(io, dir, .{}) catch continue;
        defer probe.close(io);
        _ = probe.statFile(io, "rtk", .{}) catch continue;
        return true;
    }
    return false;
}

/// Production rewriter: `rtk rewrite <command>` with a 1s deadline. Any
/// failure (missing binary, non-zero exit, empty output, timeout) returns
/// null and the original command runs unchanged.
fn rtkRewrite(alloc: Allocator, command: []const u8) ?[]const u8 {
    const io = io_mod.getIo();
    const argv = [_][]const u8{ "rtk", "rewrite", command };
    const result = std.process.run(alloc, io, .{
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } },
        .argv = &argv,
        // Inherit the full environment: rtk is the user's own tool and may
        // need config, cache, or XDG variables to locate its rules.
        .environ_map = null,
    }) catch return null;
    // rtk rewrite exit codes: 0 and 3 both print a rewrite (3 defers
    // approval to the host), 1 means no rewrite, 2 is a deny, which fx
    // ignores so the original command faces its own permission checks.
    const accepted = switch (result.term) {
        .exited => |code| code == 0 or code == 3,
        else => false,
    };
    if (!accepted) {
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        return null;
    }
    defer alloc.free(result.stderr);
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        alloc.free(result.stdout);
        return null;
    }
    const copy = alloc.dupe(u8, trimmed) catch {
        alloc.free(result.stdout);
        return null;
    };
    alloc.free(result.stdout);
    return copy;
}

/// Resolves the gate, probes PATH once, and registers the PreToolUse hook.
/// A closed gate, a missing rtk binary, or any setup failure keeps fx
/// behavior unchanged (spec F: rtk absence is invisible).
pub fn register(app: anytype) !void {
    if (!app_rtkGate(app)) return;
    try registerIn(app.alloc, &app.lifecycle_runtime, &app.rtk_hook);
}

/// Shared registration used by every entry mode (TUI app and ask context).
pub fn registerIn(
    alloc: Allocator,
    lifecycle_runtime: *hooks.Runtime,
    state: *State,
) !void {
    if (!rtkOnPath()) return;
    if (!state.arena_initialized) {
        state.arena_state = std.heap.ArenaAllocator.init(alloc);
        state.arena_initialized = true;
    }
    state.context = .{ .rewriter = rtkRewrite, .arena_state = &state.arena_state };
    try lifecycle_runtime.registerPreToolUse(.{
        .name = "fx.rtk.rewrite",
        .ctx = &state.context,
        .run = preToolUse,
    });
}

/// Reads experimental.rtk through the app cached settings, mirroring the
/// codemode gate lookup shape.
fn app_rtkGate(app: anytype) bool {
    return app.rtk_gate orelse false;
}

// === tests (RED) ===
const testing = std.testing;

fn fakeRewriter(alloc: Allocator, command: []const u8) ?[]const u8 {
    _ = alloc;
    if (std.mem.eql(u8, command, "git status")) return "rtk git status";
    if (std.mem.eql(u8, command, "same")) return "same";
    if (std.mem.eql(u8, command, "empty")) return "";
    return null;
}

fn contextWith(rewriter: Rewriter) !struct { context: Context, arena: *std.heap.ArenaAllocator } {
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    return .{ .context = .{ .rewriter = rewriter, .arena_state = arena }, .arena = arena };
}

test "handle rewrites run command and keeps other fields" {
    var fixture = try contextWith(fakeRewriter);
    defer {
        fixture.arena.deinit();
        testing.allocator.destroy(fixture.arena);
    }
    const input = hooks.PreToolUseInput{
        .invocation = undefined,
        .step_index = 0,
        .call_id = "c1",
        .tool_name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"git status\",\"cwd\":\"/tmp\"}",
    };
    const action = try handle(&fixture.context, input);
    try testing.expect(action == .rewrite_arguments);
    const rewritten = action.rewrite_arguments;
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"command\":\"rtk git status\"") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"cwd\":\"/tmp\"") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"action\":\"run\"") != null);
}

test "handle never returns block and passes through non run actions" {
    var fixture = try contextWith(fakeRewriter);
    defer {
        fixture.arena.deinit();
        testing.allocator.destroy(fixture.arena);
    }
    const mk = struct {
        fn input(arguments_json: []const u8) hooks.PreToolUseInput {
            return .{
                .invocation = undefined,
                .step_index = 0,
                .call_id = "c",
                .tool_name = "shell",
                .arguments_json = arguments_json,
            };
        }
    }.input;
    const cases = [_][]const u8{
        "{\"action\":\"interact\",\"session_id\":\"s\"}",
        "{\"action\":\"stop\",\"session_id\":\"s\"}",
        "{\"action\":\"run\",\"command\":\"rtk git status\"}",
        "{\"action\":\"run\",\"command\":\"same\"}",
        "{\"action\":\"run\",\"command\":\"empty\"}",
        "not json",
        "{}",
    };
    for (cases) |case| {
        const action = try handle(&fixture.context, mk(case));
        try testing.expect(action == .continue_);
    }
}

test "handle ignores non shell tools and missing command" {
    var fixture = try contextWith(fakeRewriter);
    defer {
        fixture.arena.deinit();
        testing.allocator.destroy(fixture.arena);
    }
    const input = hooks.PreToolUseInput{
        .invocation = undefined,
        .step_index = 0,
        .call_id = "c",
        .tool_name = "read_file",
        .arguments_json = "{\"path\":\"x\"}",
    };
    const action = try handle(&fixture.context, input);
    try testing.expect(action == .continue_);
}
