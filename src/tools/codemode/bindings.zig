const std = @import("std");

/// One tool the sandbox may reach through `tools.call`. The registry is the
/// whitelist: a name that is not listed here cannot be called.
pub const Tool = struct {
    name: []const u8,
};

/// The model-facing schema of one whitelisted tool, injected by the bridge.
/// `schema_json` is the tool's full function schema as produced by
/// builtinFunctionSchemaJsonAlloc; the host borrows both slices and the
/// injector owns them. The name here is the script-facing whitelist name,
/// which for run_command differs from the registered tool name (shell).
pub const ToolSchema = struct {
    name: []const u8,
    schema_json: []const u8,
};

/// Three read-only tools first, then run_command, which is not read-only:
/// its admission and permission review are wired in 3.3. The registry only
/// decides which names the sandbox may forward to the injected Backend.
pub const tools = [_]Tool{
    .{ .name = "glob_files" },
    .{ .name = "grep_files" },
    .{ .name = "read_file" },
    .{ .name = "run_command" },
};

pub fn find(name: []const u8) ?Tool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

/// Runs one whitelisted tool. The host injects the implementation; direct
/// tool execution never lives in the sandbox. The returned slice is allocated
/// with `allocator` and owned by the caller.
pub const Backend = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        tool: Tool,
        args_json: []const u8,
    ) anyerror![]u8,
};
