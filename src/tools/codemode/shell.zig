const std = @import("std");

/// In-script cap for one shell result. The model-facing path keeps its own
/// 50KB truncation; this budget only bounds the host-allocated bridge string
/// that tools.call returns to a codemode script.
pub const default_script_shell_budget_bytes: usize = 1024 * 1024;

/// Encodes one completed shell result as the JSON string that
/// tools.call("run_command", ...) returns to the script.
///
/// Field names match CommandResult.toJson where they overlap: `exit_code`
/// and `truncated`. `output` is script-only: the model-facing command JSON
/// carries no body, since the body reaches the model as the <stdout> and
/// <stderr> envelope. The script needs the bytes inline, so it gets `output`.
///
/// Above `budget_bytes`, keeps the first half and last half of the output
/// joined by a marker that names the omitted byte count, and sets
/// `truncated`. At or below the budget the whole output passes through.
///
/// The returned slice is allocated with `allocator` and owned by the caller.
/// It stays bounded: one budget's worth of payload plus the marker, plus
/// JSON escaping, so this host-allocator buffer needs no separate cap.
pub fn encodeResultJson(
    allocator: std.mem.Allocator,
    exit_code: i64,
    output: []const u8,
    budget_bytes: usize,
) ![]u8 {
    const truncated = output.len > budget_bytes;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    const body = if (truncated) blk: {
        const head_len = budget_bytes / 2;
        const tail_len = budget_bytes - head_len;
        const omitted = output.len - head_len - tail_len;
        var marker_buf: [64]u8 = undefined;
        const marker = try std.mem.print(&marker_buf, "\n...[{} bytes omitted]...\n", .{omitted});
        try payload.ensureTotalCapacity(allocator, head_len + marker.len + tail_len);
        payload.appendSliceAssumeCapacity(output[0..head_len]);
        payload.appendSliceAssumeCapacity(marker);
        payload.appendSliceAssumeCapacity(output[output.len - tail_len ..]);
        break :blk payload.items;
    } else output;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"exit_code\":{d},\"output\":", .{exit_code});
    try std.json.Stringify.value(body, .{}, &out.writer);
    try out.writer.writeAll(if (truncated) ",\"truncated\":true}" else ",\"truncated\":false}");
    return try out.toOwnedSlice();
}
