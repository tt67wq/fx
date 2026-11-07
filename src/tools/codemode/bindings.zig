const std = @import("std");

/// One tool the sandbox may reach through `tools.call`. The registry is the
/// whitelist: a name that is not listed here cannot be called.
pub const Tool = struct {
    name: []const u8,
};

/// Read-only trio first. Later stages append shell and other tools here.
pub const tools = [_]Tool{
    .{ .name = "glob_files" },
    .{ .name = "grep_files" },
    .{ .name = "read_file" },
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
