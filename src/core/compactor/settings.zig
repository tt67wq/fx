//! The `auto_compact_percent` setting: how full a request gets before
//! fx-compactor runs on its own.

const std = @import("std");

/// Automatic compaction starts once a request reaches this share of the
/// model's usable input window.
pub const default_percent: u8 = 80;
pub const min_percent: u8 = 10;
pub const max_percent: u8 = 80;

/// The smallest absolute token cap a user may set: anything lower would
/// starve the budget a summary keeps for retained context. 0 stays the unset
/// sentinel and never reaches this check.
pub const min_tokens: usize = 50_000;

pub fn isValidTokens(value: usize) bool {
    return value >= min_tokens;
}

pub fn isValidPercent(value: u64) bool {
    return value >= min_percent and value <= max_percent;
}

/// Parses a process override. Invalid or out-of-range values are ignored.
pub fn parsePercent(raw: ?[]const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(u8, trimmed, 10) catch return null;
    return if (isValidPercent(value)) value else null;
}

pub fn resolvePercent(configured: ?u8, process_override: ?[]const u8) u8 {
    return parsePercent(process_override) orelse configured orelse default_percent;
}

/// The absolute token cap: where automatic compaction starts regardless of
/// the window percentage. Invalid or overflowing values are ignored; 0 means
/// unset.
pub fn parseTokens(raw: ?[]const u8) ?usize {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
    return if (value == 0) null else value;
}

/// The cap resolves like the percent does, except a parsed 0 unsets instead
/// of falling through and there is no default.
pub fn resolveTokens(configured: ?usize, process_override: ?[]const u8) ?usize {
    const raw = process_override orelse return configured;
    if (std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10)) |value| {
        return if (value == 0) null else value;
    } else |_| {
        return configured;
    }
}

test "auto compaction percent accepts only the supported range" {
    try std.testing.expect(!isValidPercent(9));
    try std.testing.expect(isValidPercent(10));
    try std.testing.expect(isValidPercent(80));
    try std.testing.expect(!isValidPercent(81));
    try std.testing.expectEqual(@as(?u8, 50), parsePercent(" 50\n"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("5"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("90"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("half"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent(""));
}

test "auto compact tokens has a floor like the percent does" {
    try std.testing.expectEqual(@as(usize, 50_000), min_tokens);
    try std.testing.expect(!isValidTokens(49_999));
    try std.testing.expect(isValidTokens(50_000));
    try std.testing.expect(isValidTokens(300_000));
}

test "auto compact tokens parses a whole token count, zero and junk mean unset" {
    try std.testing.expectEqual(@as(?usize, 300_000), parseTokens("300000"));
    try std.testing.expectEqual(@as(?usize, 300_000), parseTokens(" 300000\n"));
    try std.testing.expectEqual(@as(?usize, null), parseTokens("0"));
    try std.testing.expectEqual(@as(?usize, null), parseTokens("-5"));
    try std.testing.expectEqual(@as(?usize, null), parseTokens("many"));
    try std.testing.expectEqual(@as(?usize, null), parseTokens(""));
    try std.testing.expectEqual(@as(?usize, null), parseTokens(null));
    try std.testing.expectEqual(@as(?usize, null), parseTokens("99999999999999999999999999"));
}

test "auto compact tokens resolves override, then setting, then unset" {
    try std.testing.expectEqual(@as(?usize, null), resolveTokens(null, null));
    try std.testing.expectEqual(@as(?usize, 400_000), resolveTokens(400_000, null));
    try std.testing.expectEqual(@as(?usize, 250_000), resolveTokens(400_000, "250000"));
    try std.testing.expectEqual(@as(?usize, 400_000), resolveTokens(400_000, "junk"));
    try std.testing.expectEqual(@as(?usize, null), resolveTokens(400_000, "0"));
}

test "auto compaction percent resolves override, then setting, then default" {
    try std.testing.expectEqual(default_percent, resolvePercent(null, null));
    try std.testing.expectEqual(@as(u8, 40), resolvePercent(40, null));
    try std.testing.expectEqual(@as(u8, 25), resolvePercent(40, "25"));
    try std.testing.expectEqual(@as(u8, 40), resolvePercent(40, "95"));
}
