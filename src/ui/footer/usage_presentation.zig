//! Draws the `/usage` dashboard from a `usage.Snapshot`, one row at a time,
//! the way `df` prints: lowercase headers (table name bold, column labels
//! dim), numbers right-aligned under them, and the current model in bold
//! behind a `❯`. No color, in any theme. Tables are as wide as their content, never stretched
//! to the terminal; narrow terminals drop columns before clipping names.

const std = @import("std");
const usage = @import("../../usage/usage.zig");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const ModelRow = usage.report.ModelRow;
const Period = usage.Period;

/// Most model rows on screen at once; the window scrolls over the rest.
pub const max_model_rows: usize = 10;

pub const Projection = struct {
    active: bool = false,
    period: Period = .month,
    selected_model: usize = 0,
    model_window_start: usize = 0,
    /// The selected model's detail screen instead of the tables.
    detail: bool = false,
    snapshot: ?*const usage.Snapshot = null,
};

const Line = union(enum) {
    heading,
    blank,
    /// One line of guidance when there is nothing to tabulate.
    message,
    period_header,
    period_row: Period,
    budget_header,
    budget_row,
    model_header,
    model_row: usize,
    /// The models below the window, summed; carries the first one's index.
    more_row: usize,
    no_models,
    detail_period_header,
    detail_period_row: Period,
    tokens_header,
    tokens_row: Period,
    perf_header,
    perf_row: Period,
};

const max_lines = 40;

// ---------------------------------------------------------------- layout

fn listedModels(p: Projection) []const ModelRow {
    const s = p.snapshot orelse return &.{};
    return s.of(p.period).models;
}

fn hasBudget(p: Projection) bool {
    const s = p.snapshot orelse return false;
    return s.budget() != null;
}

/// Nothing to tabulate: not signed in, or nothing cached yet.
fn messageOnly(p: Projection) bool {
    const s = p.snapshot orelse return true;
    if (s.status == .unavailable) return true;
    for (s.views) |v| if (!v.empty()) return false;
    return s.status != .ready;
}

/// The service the numbers come from, for messages.
fn serviceName(p: Projection) []const u8 {
    _ = p;
    return "AI Gateway";
}

/// Whether there are tables to move around in; otherwise only Esc applies.
pub fn showsTables(p: Projection) bool {
    return !messageOnly(p);
}

/// Rows of the main view above the model rows.
fn tableRows(p: Projection) usize {
    // heading, blank, period header + 3 rows, blank, [budget header + row,
    // blank], model header.
    return 2 + 4 + 1 + (if (hasBudget(p)) @as(usize, 3) else 0) + 1;
}

const detail_rows: usize = 2 + 4 + 1 + 4 + 1 + 4;

pub fn desiredRowCount(p: Projection) usize {
    if (messageOnly(p)) return 3;
    if (p.detail) return detail_rows;
    const models = listedModels(p).len;
    if (models == 0) return tableRows(p) + 1;
    return tableRows(p) + @min(models, max_model_rows) + @intFromBool(models > max_model_rows);
}

/// How many model rows fit when the dashboard gets `visible_rows`, keeping
/// one row for the "N more" line when not every model fits.
pub fn visibleModelItems(p: Projection, visible_rows: u16) usize {
    const models = listedModels(p).len;
    const area = @as(usize, visible_rows) -| tableRows(p);
    if (models <= @min(area, max_model_rows)) return @max(models, 1);
    return @max(@min(area -| 1, max_model_rows), 1);
}

fn layout(p: Projection, visible_rows: usize, buf: *[max_lines]Line) []const Line {
    var n: usize = 0;
    const push = struct {
        fn f(b: *[max_lines]Line, i: *usize, line: Line) void {
            if (i.* < b.len) {
                b[i.*] = line;
                i.* += 1;
            }
        }
    }.f;
    push(buf, &n, .heading);
    push(buf, &n, .blank);
    if (messageOnly(p)) {
        push(buf, &n, .message);
        return buf[0..n];
    }
    if (p.detail) {
        push(buf, &n, .detail_period_header);
        for (Period.all) |period| push(buf, &n, .{ .detail_period_row = period });
        push(buf, &n, .blank);
        push(buf, &n, .tokens_header);
        for (Period.all) |period| push(buf, &n, .{ .tokens_row = period });
        push(buf, &n, .blank);
        push(buf, &n, .perf_header);
        for (Period.all) |period| push(buf, &n, .{ .perf_row = period });
        return buf[0..n];
    }
    push(buf, &n, .period_header);
    for (Period.all) |period| push(buf, &n, .{ .period_row = period });
    push(buf, &n, .blank);
    if (hasBudget(p)) {
        push(buf, &n, .budget_header);
        push(buf, &n, .budget_row);
        push(buf, &n, .blank);
    }
    push(buf, &n, .model_header);
    const models = listedModels(p).len;
    if (models == 0) {
        push(buf, &n, .no_models);
        return buf[0..n];
    }
    const visible = visibleModelItems(p, @intCast(@min(visible_rows, std.math.maxInt(u16))));
    const start = @min(p.model_window_start, models -| visible);
    const end = @min(start + visible, models);
    for (start..end) |index| push(buf, &n, .{ .model_row = index });
    if (end < models) push(buf, &n, .{ .more_row = end });
    return buf[0..n];
}

pub fn composeRow(alloc: Allocator, p: Projection, row_index: u16, visible_rows: u16, width: u16) !std.ArrayList(u8) {
    var buf: [max_lines]Line = undefined;
    const lines = layout(p, visible_rows, &buf);
    if (row_index >= lines.len or row_index >= visible_rows) return .empty;
    const limit: usize = width;
    return switch (lines[row_index]) {
        .heading => composeHeading(alloc, p, limit),
        .blank => .empty,
        .message => composeMessage(alloc, p, limit),
        .period_header => composeCells(alloc, &period_header, .header, "", limit),
        .period_row => |period| composePeriodRow(alloc, p, period, limit),
        .budget_header => composeBudgetHeader(alloc, limit),
        .budget_row => composeBudgetRow(alloc, p, limit),
        .model_header => composeModelHeader(alloc, p, limit),
        .model_row => |index| composeModelRow(alloc, p, index, limit),
        .more_row => |first| composeMoreRow(alloc, p, first, limit),
        .no_models => row_text.composeTextRow(alloc, noModelsText(p.period), width, ui_render.dim_style, 2),
        .detail_period_header => composeCells(alloc, &detail_period_header, .header, "", limit),
        .detail_period_row => |period| composeDetailPeriodRow(alloc, p, period, limit),
        .tokens_header => composeCells(alloc, if (limit >= wideTokensWidth()) &tokens_header_wide else &tokens_header_narrow, .header, "", limit),
        .tokens_row => |period| composeTokensRow(alloc, p, period, limit),
        .perf_header => composeCells(alloc, if (limit >= widePerfWidth()) &perf_header_wide else &perf_header_narrow, .header, "", limit),
        .perf_row => |period| composePerfRow(alloc, p, period, limit),
    };
}

// ----------------------------------------------------------------- cells

const Cell = struct {
    text: []const u8,
    width: usize,
    left: bool = false,
};

const Kind = enum {
    /// A table's header row: the first cell (the table name) bold, the
    /// column labels dim.
    header,
    /// More column labels on the same header row: all dim.
    header_labels,
    data,
};

/// Appends `cells` padded to their widths, stopping before a cell that would
/// pass `limit` columns. Headers style the first cell bold and the rest dim;
/// data rows use `row_style` throughout.
fn composeCells(alloc: Allocator, cells: []const Cell, kind: Kind, row_style: []const u8, limit: usize) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (row_style.len > 0) try row.appendSlice(alloc, row_style);
    _ = try appendCells(alloc, &row, cells, kind, 0, limit);
    if (row_style.len > 0) try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendCells(alloc: Allocator, row: *std.ArrayList(u8), cells: []const Cell, kind: Kind, used_start: usize, limit: usize) !usize {
    var used = used_start;
    for (cells, 0..) |cell, i| {
        if (used + cell.width > limit) break;
        const pad = cell.width -| display_width.visibleWidth(cell.text);
        const style: []const u8 = switch (kind) {
            .header => if (i == 0) ui_render.bold_style else ui_render.dim_style,
            .header_labels => ui_render.dim_style,
            .data => "",
        };
        if (!cell.left) try row.appendNTimes(alloc, ' ', pad);
        if (style.len > 0) try row.appendSlice(alloc, style);
        try row.appendSlice(alloc, cell.text);
        if (style.len > 0) try row.appendSlice(alloc, ui_render.reset_style);
        if (cell.left) try row.appendNTimes(alloc, ' ', pad);
        used += cell.width;
    }
    return used;
}

/// Model names and labels come from the network and the credential: keep
/// them on one line, and show `?` for anything fx would escape on a terminal
/// (control bytes, C1 controls, bidi and zero-width characters, invalid
/// UTF-8). Cuts only between characters, so `buf` always holds whole ones.
fn safeText(buf: []u8, text: []const u8) []const u8 {
    var in: usize = 0;
    var out: usize = 0;
    while (in < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[in]) catch 1;
        const end = @min(in + len, text.len);
        const piece = text[in..end];
        const keep = piece.len == len and text_utils.isTerminalSafe(piece);
        const n = if (keep) piece.len else 1;
        if (out + n > buf.len) break;
        if (keep) @memcpy(buf[out..][0..n], piece) else buf[out] = '?';
        out += n;
        in = end;
    }
    return buf[0..out];
}

// ---------------------------------------------------------------- heading

/// `usage: <who>` on the left; the status ("updated 2m ago", "updating…",
/// a failure) in the right corner. A narrow terminal shortens the left part
/// first and drops the status only when even a short name would not fit.
fn composeHeading(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var left_buf: [320]u8 = undefined;
    const left = headingLeft(&left_buf, p);
    var status_buf: [96]u8 = undefined;
    const status = headingStatus(&status_buf, p);
    const prefix_width: usize = "usage: ".len;
    const min_left: usize = 12;
    const status_width = display_width.visibleWidth(status);
    const show_status = status_width > 0 and prefix_width + min_left + 2 + status_width <= limit;
    const left_room = if (show_status) limit - prefix_width - 2 - status_width else limit -| prefix_width;

    try row.print(alloc, "{s}usage:{s} ", .{ ui_render.bold_style, ui_render.reset_style });
    const left_start = row.items.len;
    try row_text.appendSingleLineMiddleEllipsized(alloc, &row, left, left_room);
    if (show_status) {
        const used = prefix_width + display_width.visibleWidth(row.items[left_start..]);
        try row.appendNTimes(alloc, ' ', limit - used - status_width);
        // A failure reads in normal weight; routine freshness stays dim.
        const failed = if (p.snapshot) |snap| snap.status == .failed else false;
        if (failed) {
            try row.appendSlice(alloc, status);
        } else {
            try row.print(alloc, "{s}{s}{s}", .{ ui_render.dim_style, status, ui_render.reset_style });
        }
    }
    return row;
}

/// Whose numbers these are, or on a detail screen which model.
fn headingLeft(buf: []u8, p: Projection) []const u8 {
    const s = p.snapshot orelse return "AI Gateway";
    if (s.status == .unavailable) return switch (s.status.unavailable) {
        .no_gateway_sign_in => "not signed in to AI Gateway",
        .no_team => "fx login has no team",
        .unsupported_provider => "this provider's usage isn't shown yet",
        .refresh_needed => "the sign-in needs a refresh",
    };
    if (p.detail) {
        const models = listedModels(p);
        if (p.selected_model < models.len) {
            var name_buf: [256]u8 = undefined;
            const name = safeText(&name_buf, models[p.selected_model].model);
            return std.mem.print(buf, "{s}, model {d} of {d}", .{ name, p.selected_model + 1, models.len }) catch name;
        }
    }
    if (s.label.len == 0) return "AI Gateway";
    return safeText(buf, s.label);
}

fn headingStatus(buf: []u8, p: Projection) []const u8 {
    const s = p.snapshot orelse return "fetching…";
    var ago_buf: [32]u8 = undefined;
    const ago: ?[]const u8 = if (s.fetchedAtMs()) |at| agoText(&ago_buf, s.now_ms - at) else null;
    return switch (s.status) {
        .fetching => if (messageOnly(p)) "fetching…" else "updating…",
        .ready => if (ago) |a| std.mem.print(buf, "updated {s}", .{a}) catch "" else "nothing fetched today",
        .failed => |f| blk: {
            var failure_buf: [64]u8 = undefined;
            const failure = failureText(&failure_buf, p, f);
            break :blk if (ago) |a|
                std.mem.print(buf, "{s}, last updated {s}", .{ failure, a }) catch failure
            else
                std.mem.print(buf, "{s}", .{failure}) catch failure;
        },
        .unavailable => "",
    };
}

/// `just now`, `2m ago`, `3h ago`, `2d ago`.
fn agoText(buf: []u8, elapsed_ms: i64) []const u8 {
    const minutes = @divFloor(@max(elapsed_ms, 0), std.time.ms_per_min);
    if (minutes < 1) return "just now";
    const value: u64 = @intCast(if (minutes < 60) minutes else if (minutes < 24 * 60) @divFloor(minutes, 60) else @divFloor(minutes, 24 * 60));
    const unit: []const u8 = if (minutes < 60) "m" else if (minutes < 24 * 60) "h" else "d";
    return std.mem.print(buf, "{d}{s} ago", .{ value, unit }) catch "";
}

fn failureText(buf: []u8, p: Projection, failure: usage.Failure) []const u8 {
    const service = serviceName(p);
    return switch (failure) {
        .network => std.mem.print(buf, "couldn't reach {s}", .{service}) catch "",
        .refused => std.mem.print(buf, "{s} refused this sign-in", .{service}) catch "",
        .not_available => "usage reports aren't available for this team",
        .rate_limited => "rate limited, try again shortly",
        .server => std.mem.print(buf, "{s} error", .{service}) catch "",
        .bad_response => std.mem.print(buf, "unexpected {s} response", .{service}) catch "",
        .cache => "couldn't save the usage cache",
    };
}

fn composeMessage(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    var fetching_buf: [48]u8 = undefined;
    const text: []const u8 = blk: {
        const s = p.snapshot orelse break :blk "fetching usage from AI Gateway";
        break :blk switch (s.status) {
            .unavailable => |u| switch (u) {
                .no_gateway_sign_in => "(use /login, or set AI_GATEWAY_API_KEY)",
                .no_team => "(use /login to pick a team)",
                .unsupported_provider => "(use /provider and pick AI Gateway to see AI Gateway usage)",
                .refresh_needed => "(send a message to renew it, then reopen /usage)",
            },
            .fetching => std.mem.print(&fetching_buf, "fetching usage from {s}", .{serviceName(p)}) catch "fetching usage",
            .failed => "(press r to retry)",
            .ready => "no usage yet",
        };
    };
    return row_text.composeTextRow(alloc, text, @intCast(@min(limit, std.math.maxInt(u16))), ui_render.dim_style, 2);
}

fn noModelsText(period: Period) []const u8 {
    return switch (period) {
        .today => "no usage today (UTC)",
        .days_7 => "no usage in the last 7 days",
        .month => "no usage this month",
    };
}

// ---------------------------------------------------------------- period

const period_header = [_]Cell{
    .{ .text = "period", .width = 8, .left = true },
    .{ .text = "spent", .width = 11 },
    .{ .text = "requests", .width = 10 },
    .{ .text = "tokens", .width = 8 },
};

fn composePeriodRow(alloc: Allocator, p: Projection, period: Period, limit: usize) !std.ArrayList(u8) {
    const t = p.snapshot.?.of(period).totals;
    var spent: [32]u8 = undefined;
    var requests: [32]u8 = undefined;
    var tokens: [16]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = period.label(), .width = 8, .left = true },
        .{ .text = money(&spent, t.total_cost), .width = 11 },
        .{ .text = grouped(&requests, t.request_count), .width = 10 },
        .{ .text = compact(&tokens, t.totalTokens()), .width = 8 },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

// ---------------------------------------------------------------- budget

const BudgetColumns = enum { full, no_resets, small };

fn budgetColumns(limit: usize) BudgetColumns {
    if (limit >= 55) return .full;
    if (limit >= 47) return .no_resets;
    return .small;
}

fn composeBudgetHeader(alloc: Allocator, limit: usize) !std.ArrayList(u8) {
    const full = [_]Cell{
        .{ .text = "budget", .width = 6, .left = true },
        .{ .text = "size", .width = 12 },
        .{ .text = "used", .width = 11 },
        .{ .text = "avail", .width = 12 },
        .{ .text = "use%", .width = 6 },
        .{ .text = "", .width = 2 },
        .{ .text = "resets", .width = 6, .left = true },
    };
    const small = [_]Cell{
        .{ .text = "budget", .width = 6, .left = true },
        .{ .text = "used", .width = 11 },
        .{ .text = "avail", .width = 12 },
        .{ .text = "use%", .width = 6 },
    };
    return switch (budgetColumns(limit)) {
        .full => composeCells(alloc, &full, .header, "", limit),
        .no_resets => composeCells(alloc, full[0..5], .header, "", limit),
        .small => composeCells(alloc, &small, .header, "", limit),
    };
}

fn composeBudgetRow(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const s = p.snapshot.?;
    const b = s.budget().?;
    var size: [32]u8 = undefined;
    var used: [32]u8 = undefined;
    var avail: [32]u8 = undefined;
    var pct_buf: [16]u8 = undefined;
    var resets_buf: [16]u8 = undefined;
    const pct: u64 = if (b.limit > 0) @intFromFloat(@min(@round(b.spent / b.limit * 100), 999)) else 0;
    const resets: []const u8 = if (s.budgetResetDay()) |day| shortDay(&resets_buf, day) else "-";
    const full = [_]Cell{
        .{ .text = "user", .width = 6, .left = true },
        .{ .text = money(&size, b.limit), .width = 12 },
        .{ .text = money(&used, b.spent), .width = 11 },
        .{ .text = money(&avail, @max(b.limit - b.spent, 0)), .width = 12 },
        .{ .text = std.mem.print(&pct_buf, "{d}%", .{pct}) catch "", .width = 6 },
        .{ .text = "", .width = 2 },
        .{ .text = resets, .width = 6, .left = true },
    };
    const small = [_]Cell{ full[0], full[2], full[3], full[4] };
    return switch (budgetColumns(limit)) {
        .full => composeCells(alloc, &full, .data, "", limit),
        .no_resets => composeCells(alloc, full[0..5], .data, "", limit),
        .small => composeCells(alloc, &small, .data, "", limit),
    };
}

/// `nov 1`.
fn shortDay(buf: []u8, day: i64) []const u8 {
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    const md = usage.report.monthDay(day);
    return std.mem.print(buf, "{s} {d}", .{ months[md.month - 1], md.day }) catch "";
}

// ----------------------------------------------------------------- models

const ModelColumns = enum { full, no_share, small };

const ModelLayout = struct {
    columns: ModelColumns,
    name_width: usize,
};

const gutter: usize = 2;

fn modelColumnsWidth(columns: ModelColumns) usize {
    return switch (columns) {
        .full => 11 + 8 + 10 + 8,
        .no_share => 11 + 10 + 8,
        .small => 11 + 10,
    };
}

/// The name column is as wide as the longest listed name (or the header),
/// so the table never stretches; share, then tokens, give way first.
fn modelLayout(p: Projection, limit: usize) ModelLayout {
    var header_buf: [24]u8 = undefined;
    var name_width = display_width.visibleWidth(modelHeaderText(&header_buf, p.period));
    var safe_buf: [256]u8 = undefined;
    // Measure what is drawn: control bytes are shown as `?`.
    for (listedModels(p)) |model| name_width = @max(name_width, display_width.visibleWidth(safeText(&safe_buf, model.model)));
    const room = limit -| gutter;
    for ([_]ModelColumns{ .full, .no_share, .small }) |columns| {
        if (name_width + modelColumnsWidth(columns) <= room) return .{ .columns = columns, .name_width = name_width };
    }
    return .{ .columns = .small, .name_width = @max(room -| modelColumnsWidth(.small), 8) };
}

fn modelHeaderText(buf: []u8, period: Period) []const u8 {
    return std.mem.print(buf, "model ({s})", .{period.label()}) catch "model";
}

fn modelCells(columns: ModelColumns, spent: []const u8, share: []const u8, requests: []const u8, tokens: []const u8, out: *[4]Cell) []const Cell {
    out[0] = .{ .text = spent, .width = 11 };
    switch (columns) {
        .full => {
            out[1] = .{ .text = share, .width = 8 };
            out[2] = .{ .text = requests, .width = 10 };
            out[3] = .{ .text = tokens, .width = 8 };
            return out[0..4];
        },
        .no_share => {
            out[1] = .{ .text = requests, .width = 10 };
            out[2] = .{ .text = tokens, .width = 8 };
            return out[0..3];
        },
        .small => {
            out[1] = .{ .text = requests, .width = 10 };
            return out[0..2];
        },
    }
}

fn composeModelHeader(alloc: Allocator, p: Projection, limit: usize) !std.ArrayList(u8) {
    const l = modelLayout(p, limit);
    var header_buf: [24]u8 = undefined;
    var rest: [4]Cell = undefined;
    const numbers = modelCells(l.columns, "spent", "share", "requests", "tokens", &rest);
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendNTimes(alloc, ' ', gutter);
    const name = [_]Cell{.{ .text = modelHeaderText(&header_buf, p.period), .width = l.name_width, .left = true }};
    const used = try appendCells(alloc, &row, &name, .header, gutter, limit);
    _ = try appendCells(alloc, &row, numbers, .header_labels, used, limit);
    return row;
}

fn composeModelRow(alloc: Allocator, p: Projection, index: usize, limit: usize) !std.ArrayList(u8) {
    const models = listedModels(p);
    const model = models[index];
    const total = p.snapshot.?.of(p.period).totals.total_cost;
    const l = modelLayout(p, limit);
    var spent: [32]u8 = undefined;
    var share: [16]u8 = undefined;
    var requests: [32]u8 = undefined;
    var tokens: [16]u8 = undefined;
    var rest: [4]Cell = undefined;
    const numbers = modelCells(
        l.columns,
        money(&spent, model.totals.total_cost),
        percent(&share, shareOf(model.totals.total_cost, total)),
        grouped(&requests, model.totals.request_count),
        compact(&tokens, model.totals.totalTokens()),
        &rest,
    );
    const selected = index == p.selected_model;
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (selected) {
        try row.print(alloc, "{s}❯ ", .{ui_render.bold_style});
    } else {
        try row.appendNTimes(alloc, ' ', gutter);
    }
    try appendName(alloc, &row, model.model, l.name_width);
    _ = try appendCells(alloc, &row, numbers, .data, gutter + l.name_width, limit);
    if (selected) try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendName(alloc: Allocator, row: *std.ArrayList(u8), name: []const u8, name_width: usize) !void {
    var safe_buf: [256]u8 = undefined;
    const safe = safeText(&safe_buf, name);
    const start = row.items.len;
    try row_text.appendSingleLineMiddleEllipsized(alloc, row, safe, name_width);
    const shown = display_width.visibleWidth(row.items[start..]);
    try row.appendNTimes(alloc, ' ', name_width -| shown);
}

fn composeMoreRow(alloc: Allocator, p: Projection, first: usize, limit: usize) !std.ArrayList(u8) {
    const models = listedModels(p);
    var sum: usage.report.Totals = .{};
    for (models[first..]) |model| sum.add(model.totals);
    const total = p.snapshot.?.of(p.period).totals.total_cost;
    const l = modelLayout(p, limit);
    var label_buf: [32]u8 = undefined;
    var spent: [32]u8 = undefined;
    var share: [16]u8 = undefined;
    var requests: [32]u8 = undefined;
    var tokens: [16]u8 = undefined;
    var rest: [4]Cell = undefined;
    const numbers = modelCells(
        l.columns,
        money(&spent, sum.total_cost),
        percent(&share, shareOf(sum.total_cost, total)),
        grouped(&requests, sum.request_count),
        compact(&tokens, sum.totalTokens()),
        &rest,
    );
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendNTimes(alloc, ' ', gutter);
    try appendName(alloc, &row, std.mem.print(&label_buf, "{d} more", .{models.len - first}) catch "more", l.name_width);
    _ = try appendCells(alloc, &row, numbers, .data, gutter + l.name_width, limit);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

// ----------------------------------------------------------------- detail

fn selectedName(p: Projection) ?[]const u8 {
    const models = listedModels(p);
    return if (p.selected_model < models.len) models[p.selected_model].model else null;
}

/// The selected model's row for `period`, or null when it had no usage then.
fn detailRow(p: Projection, period: Period) ?ModelRow {
    const name = selectedName(p) orelse return null;
    for (p.snapshot.?.of(period).models) |model| {
        if (std.mem.eql(u8, model.model, name)) return model;
    }
    return null;
}

const detail_period_header = [_]Cell{
    .{ .text = "period", .width = 8, .left = true },
    .{ .text = "spent", .width = 11 },
    .{ .text = "share", .width = 8 },
    .{ .text = "requests", .width = 10 },
    .{ .text = "tokens", .width = 8 },
};

fn composeDetailPeriodRow(alloc: Allocator, p: Projection, period: Period, limit: usize) !std.ArrayList(u8) {
    const row = detailRow(p, period);
    const total = p.snapshot.?.of(period).totals.total_cost;
    var spent: [32]u8 = undefined;
    var share: [16]u8 = undefined;
    var requests: [32]u8 = undefined;
    var tokens: [16]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = period.label(), .width = 8, .left = true },
        .{ .text = if (row) |r| money(&spent, r.totals.total_cost) else "-", .width = 11 },
        .{ .text = if (row) |r| percent(&share, shareOf(r.totals.total_cost, total)) else "-", .width = 8 },
        .{ .text = if (row) |r| grouped(&requests, r.totals.request_count) else "-", .width = 10 },
        .{ .text = if (row) |r| compact(&tokens, r.totals.totalTokens()) else "-", .width = 8 },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

const tokens_header_wide = [_]Cell{
    .{ .text = "tokens", .width = 8, .left = true },
    .{ .text = "input", .width = 9 },
    .{ .text = "output", .width = 9 },
    .{ .text = "reasoning", .width = 11 },
    .{ .text = "cache read", .width = 12 },
    .{ .text = "cache write", .width = 13 },
};

const tokens_header_narrow = [_]Cell{
    .{ .text = "tokens", .width = 6, .left = true },
    .{ .text = "in", .width = 7 },
    .{ .text = "out", .width = 7 },
    .{ .text = "reason", .width = 8 },
    .{ .text = "cache rd", .width = 10 },
    .{ .text = "cache wr", .width = 10 },
};

fn cellsWidth(cells: []const Cell) usize {
    var w: usize = 0;
    for (cells) |cell| w += cell.width;
    return w;
}

fn wideTokensWidth() usize {
    return cellsWidth(&tokens_header_wide);
}

fn composeTokensRow(alloc: Allocator, p: Projection, period: Period, limit: usize) !std.ArrayList(u8) {
    const header: []const Cell = if (limit >= wideTokensWidth()) &tokens_header_wide else &tokens_header_narrow;
    const row = detailRow(p, period);
    var bufs: [5][16]u8 = undefined;
    const values = if (row) |r| [5]u64{
        r.totals.input_tokens,
        r.totals.output_tokens,
        r.totals.reasoning_tokens,
        r.totals.cache_read_tokens,
        r.totals.cache_write_tokens,
    } else null;
    var cells: [6]Cell = undefined;
    cells[0] = .{ .text = period.label(), .width = header[0].width, .left = true };
    for (1..6) |i| {
        cells[i] = .{
            .text = if (values) |v| compact(&bufs[i - 1], v[i - 1]) else "-",
            .width = header[i].width,
        };
    }
    return composeCells(alloc, &cells, .data, "", limit);
}

const perf_header_wide = [_]Cell{
    .{ .text = "perf", .width = 8, .left = true },
    .{ .text = "cache hit", .width = 11 },
    .{ .text = "p90 ttft", .width = 10 },
    .{ .text = "p90 tok/s", .width = 11 },
    .{ .text = "errors", .width = 8 },
};

/// 38 columns, so every perf column shows down to 40-column terminals.
const perf_header_narrow = [_]Cell{
    .{ .text = "perf", .width = 5, .left = true },
    .{ .text = "cache hit", .width = 10 },
    .{ .text = "p90 ttft", .width = 9 },
    .{ .text = "tok/s", .width = 7 },
    .{ .text = "errors", .width = 7 },
};

fn widePerfWidth() usize {
    return cellsWidth(&perf_header_wide);
}

fn composePerfRow(alloc: Allocator, p: Projection, period: Period, limit: usize) !std.ArrayList(u8) {
    const header: []const Cell = if (limit >= widePerfWidth()) &perf_header_wide else &perf_header_narrow;
    const t: ?usage.report.Totals = if (detailRow(p, period)) |r| r.totals else null;
    var hit: [16]u8 = undefined;
    var ttft: [16]u8 = undefined;
    var tps: [16]u8 = undefined;
    var errors: [16]u8 = undefined;
    const cells = [_]Cell{
        .{ .text = period.label(), .width = header[0].width, .left = true },
        .{ .text = optionalPercent(&hit, if (t) |v| v.cacheHitPct() else null), .width = header[1].width },
        .{ .text = duration(&ttft, if (t) |v| v.p90TtftMs() else null), .width = header[2].width },
        .{ .text = if (t) |v| (if (v.p90Tps()) |x| std.mem.print(&tps, "{d:.0}", .{x}) catch "-" else "-") else "-", .width = header[3].width },
        .{ .text = optionalPercent(&errors, if (t) |v| v.errorPct() else null), .width = header[4].width },
    };
    return composeCells(alloc, &cells, .data, "", limit);
}

// ----------------------------------------------------------------- format

fn shareOf(part: f64, whole: f64) ?f64 {
    if (whole <= 0) return null;
    return part / whole * 100;
}

fn percent(buf: []u8, value: ?f64) []const u8 {
    return optionalPercent(buf, value);
}

fn optionalPercent(buf: []u8, value: ?f64) []const u8 {
    const v = value orelse return "-";
    return std.mem.print(buf, "{d:.1}%", .{v}) catch "-";
}

/// `850ms`, `2.1s`.
fn duration(buf: []u8, ms: ?f64) []const u8 {
    const v = ms orelse return "-";
    if (v < 1000) return std.mem.print(buf, "{d:.0}ms", .{v}) catch "-";
    return std.mem.print(buf, "{d:.1}s", .{v / 1000}) catch "-";
}

/// `$1,234.56`, or four decimals below one dollar.
fn money(buf: *[32]u8, value: f64) []const u8 {
    if (value < 1) return std.mem.print(buf, "${d:.4}", .{value}) catch "";
    const cents: u64 = @intFromFloat(@round(value * 100));
    var whole: [24]u8 = undefined;
    const dollars = grouped(&whole, cents / 100);
    return std.mem.print(buf, "${s}.{d:0>2}", .{ dollars, cents % 100 }) catch "";
}

/// `3,665`.
fn grouped(buf: []u8, value: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const raw = std.mem.print(&digits, "{d}", .{value}) catch return "";
    var len: usize = 0;
    for (raw, 0..) |c, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) {
            buf[len] = ',';
            len += 1;
        }
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

/// `950`, `12K`, `6.9M`, `1.2B`.
fn compact(buf: *[16]u8, value: u64) []const u8 {
    const units = [_]struct { div: u64, suffix: []const u8 }{
        .{ .div = 1_000_000_000_000, .suffix = "T" },
        .{ .div = 1_000_000_000, .suffix = "B" },
        .{ .div = 1_000_000, .suffix = "M" },
        .{ .div = 1_000, .suffix = "K" },
    };
    for (units) |u| {
        if (value >= u.div) {
            const scaled = @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(u.div));
            return if (scaled < 10)
                std.mem.print(buf, "{d:.1}{s}", .{ scaled, u.suffix }) catch ""
            else
                std.mem.print(buf, "{d:.0}{s}", .{ scaled, u.suffix }) catch "";
        }
    }
    return std.mem.print(buf, "{d}", .{value}) catch "";
}

// ---------------------------------------------------------------------------
// Tests: every layout is drawn through the VT emulator at terminal widths
// from 40 to 240 columns and read back from the grid.

const testing = std.testing;
const vt_emulator = @import("../../core/terminal/engine.zig");

const test_now: i64 = 20737 * std.time.ms_per_day + 8 * std.time.ms_per_hour + 16 * std.time.ms_per_min;
const test_widths = [_]u16{ 40, 48, 56, 64, 80, 100, 120, 180, 240 };

fn testRow(model: []const u8, cost: f64, requests: u64, tokens: u64) ModelRow {
    return .{ .model = model, .totals = .{
        .request_count = requests,
        .input_tokens = tokens / 100,
        .output_tokens = tokens / 50,
        .reasoning_tokens = tokens / 60,
        .cache_read_tokens = tokens - tokens / 100 - tokens / 50 - tokens / 20,
        .cache_write_tokens = tokens / 20,
        .total_cost = cost,
        .cache_hit_requests = @as(f64, @floatFromInt(requests)) * 0.954,
        .failed_requests = @as(f64, @floatFromInt(requests)) * 0.004,
        .ttft_weighted = 2100 * @as(f64, @floatFromInt(requests)),
        .ttft_requests = requests,
        .tps_weighted = 58 * @as(f64, @floatFromInt(requests)),
        .tps_requests = requests,
    } };
}

const month_models = [_]ModelRow{
    testRow("anthropic/claude-opus-5.5", 6551.12, 43312, 14_500_000_000),
    testRow("openai/gpt-5.6-luna", 14.10, 5396, 41_000_000),
    testRow("openai/gpt-6.1-sol", 11.02, 640, 29_000_000),
    testRow("google/gemini-3.1-flash-lite-image-preview", 9.80, 212, 3_900_000),
    testRow("anthropic/claude-haiku-4.5", 6.12, 363, 9_100_000),
};

fn sumOf(rows: []const ModelRow) usage.report.Totals {
    var t: usage.report.Totals = .{};
    for (rows) |r| t.add(r.totals);
    return t;
}

fn testView(period: Period, rows: []const ModelRow, budget: bool) !usage.View {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    // Allocate before the arena is copied into the result.
    const models = try arena.allocator().dupe(ModelRow, rows);
    return .{
        .arena = arena,
        .period = period,
        .models = models,
        .totals = sumOf(rows),
        .today_current = true,
        .finished_current = true,
        .fetched_at_ms = test_now - 2 * std.time.ms_per_min,
        .budget = if (budget) .{ .limit = 31600, .spent = 6596.55, .period = .monthly } else null,
    };
}

fn testSnapshot(status: usage.Status, budget: bool, month: []const ModelRow) !usage.Snapshot {
    return .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .views = .{
            try testView(.today, month[0..@min(month.len, 3)], budget),
            try testView(.days_7, month[0..@min(month.len, 4)], budget),
            try testView(.month, month, budget),
        },
        .status = status,
        .label = "acme-design-tools-platform (fx login)",
        .now_ms = test_now,
    };
}

/// Draws the whole dashboard into a VT grid of `width` columns and returns
/// every row's trimmed text, one string per row.
const Screen = struct {
    lines: [max_lines][]u8 = undefined,
    count: usize = 0,

    fn deinit(self: *Screen) void {
        for (self.lines[0..self.count]) |line| testing.allocator.free(line);
    }

    fn row(self: *const Screen, index: usize) []const u8 {
        return self.lines[index];
    }

    fn find(self: *const Screen, needle: []const u8) ?usize {
        for (self.lines[0..self.count], 0..) |line, i| {
            if (std.mem.find(u8, line, needle) != null) return i;
        }
        return null;
    }

    fn widest(self: *const Screen) usize {
        return self.widestFrom(0);
    }

    fn widestFrom(self: *const Screen, first: usize) usize {
        var w: usize = 0;
        for (self.lines[first..self.count]) |line| w = @max(w, display_width.visibleWidth(line));
        return w;
    }
};

fn draw(p: Projection, width: u16, visible_rows: u16) !Screen {
    const alloc = testing.allocator;
    const rows: u16 = @intCast(@min(desiredRowCount(p), visible_rows));
    var grid = try vt_emulator.Grid.init(alloc, width, rows);
    defer grid.deinit();
    var index: u16 = 0;
    while (index < rows) : (index += 1) {
        var r = try composeRow(alloc, p, index, rows, width);
        defer r.deinit(alloc);
        // A row never passes the terminal width, or the VT would wrap it.
        try testing.expect(display_width.visibleWidthIgnoringAnsi(r.items) <= width);
        var cursor_buf: [32]u8 = undefined;
        try grid.feed(try std.mem.print(&cursor_buf, "\x1b[{d};1H", .{index + 1}));
        try grid.feed(r.items);
    }
    var screen: Screen = .{};
    errdefer screen.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    index = 0;
    while (index < rows) : (index += 1) {
        text.clearRetainingCapacity();
        try grid.rowTextTrimmed(index + 1, &text);
        screen.lines[screen.count] = try alloc.dupe(u8, text.items);
        screen.count += 1;
    }
    return screen;
}

/// The column where `needle` ends in `line`, for right-edge alignment.
fn endColumn(line: []const u8, needle: []const u8) ?usize {
    const at = std.mem.find(u8, line, needle) orelse return null;
    return display_width.visibleWidth(line[0 .. at + needle.len]);
}

test "the df view lines its numbers up under the headers at every width" {
    var snapshot = try testSnapshot(.ready, true, &month_models);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    for (test_widths) |width| {
        var screen = try draw(p, width, 40);
        defer screen.deinit();
        // The label on the left, the freshness in the right corner.
        try testing.expect(std.mem.startsWith(u8, screen.row(0), "usage: acme-de"));
        try testing.expect(std.mem.endsWith(u8, screen.row(0), "updated 2m ago"));
        try testing.expectEqual(@as(usize, width), display_width.visibleWidth(screen.row(0)));
        try testing.expectEqual(width >= 61, std.mem.find(u8, screen.row(0), "acme-design-tools-platform (fx login)") != null);

        // Period table: numbers end where their headers end.
        try testing.expectEqualStrings("period        spent  requests  tokens", screen.row(2));
        const spent_end = endColumn(screen.row(2), "spent").?;
        try testing.expectEqual(spent_end, endColumn(screen.row(3), "$6,576.24").?);
        try testing.expectEqual(spent_end, endColumn(screen.row(5), "$6,592.16").?);
        try testing.expectEqual(endColumn(screen.row(2), "requests").?, endColumn(screen.row(5), "49,923").?);
        try testing.expect(std.mem.startsWith(u8, screen.row(4), "7d "));

        // Budget table, with fewer columns as the terminal narrows.
        const budget = screen.find("budget").?;
        try testing.expectEqual(endColumn(screen.row(budget), "use%").?, endColumn(screen.row(budget + 1), "21%").?);
        try testing.expectEqual(width >= 55, std.mem.find(u8, screen.row(budget + 1), "nov 1") != null);
        try testing.expectEqual(width >= 47, std.mem.find(u8, screen.row(budget), "size") != null);

        // Model table: the current model carries the marker.
        const header = screen.find("model (month)").?;
        try testing.expect(std.mem.startsWith(u8, screen.row(header + 1), "❯ anthropi"));
        try testing.expect(std.mem.startsWith(u8, screen.row(header + 2), "  openai/g"));
        // Names stay whole once the longest fits beside spent and requests.
        try testing.expectEqual(width >= gutter + 42 + modelColumnsWidth(.small), screen.find("google/gemini-3.1-flash-lite-image-preview") != null);
        const model_spent = endColumn(screen.row(header), "spent").?;
        try testing.expectEqual(model_spent, endColumn(screen.row(header + 1), "$6,551.12").?);
        try testing.expectEqual(model_spent, endColumn(screen.row(header + 2), "$14.10").?);
    }
}

test "the df view stays content-sized on wide terminals and drops columns on narrow ones" {
    var snapshot = try testSnapshot(.ready, true, &month_models);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };

    // The longest name (42 columns) plus the four number columns.
    const content_width = gutter + 42 + modelColumnsWidth(.full);
    var at_100 = try draw(p, 100, 40);
    defer at_100.deinit();
    var at_240 = try draw(p, 240, 40);
    defer at_240.deinit();
    // Only the heading spans the terminal, to put the status in the corner.
    try testing.expectEqual(content_width, at_100.widestFrom(1));
    try testing.expectEqual(content_width, at_240.widestFrom(1));
    for (1..at_100.count) |i| try testing.expectEqualStrings(at_100.row(i), at_240.row(i));
    try testing.expect(std.mem.endsWith(u8, at_240.row(0), "updated 2m ago"));
    try testing.expectEqual(@as(usize, 240), display_width.visibleWidth(at_240.row(0)));

    // 80 columns: no room for share beside a 42-column name. 72: tokens go
    // too. The names stay whole in both.
    var at_80 = try draw(p, 80, 40);
    defer at_80.deinit();
    const h80 = at_80.row(at_80.find("model (month)").?);
    try testing.expect(std.mem.find(u8, h80, "share") == null and std.mem.find(u8, h80, "tokens") != null);
    try testing.expect(at_80.find("google/gemini-3.1-flash-lite-image-preview") != null);
    var at_72 = try draw(p, 72, 40);
    defer at_72.deinit();
    const h72 = at_72.row(at_72.find("model (month)").?);
    try testing.expect(std.mem.find(u8, h72, "tokens") == null and std.mem.find(u8, h72, "requests") != null);
    try testing.expect(at_72.find("google/gemini-3.1-flash-lite-image-preview") != null);
    // 40 columns: the long name is clipped in the middle, never wrapped.
    var at_40 = try draw(p, 40, 40);
    defer at_40.deinit();
    try testing.expect(at_40.find("google/gemini-3.1-flash-lite-image-preview") == null);
    try testing.expect(at_40.find("google") != null);
    try testing.expect(at_40.widest() <= 40);
}

test "the detail screen shows one model across today, 7d and month" {
    var snapshot = try testSnapshot(.ready, true, &month_models);
    defer snapshot.deinit();
    // gpt-6.1-sol is listed today; gemini only in 7d and month.
    const p: Projection = .{ .active = true, .snapshot = &snapshot, .detail = true, .selected_model = 3 };
    for (test_widths) |width| {
        var screen = try draw(p, width, 40);
        defer screen.deinit();
        try testing.expectEqual(@as(usize, detail_rows), screen.count);
        try testing.expect(std.mem.find(u8, screen.row(0), "model 4 of 5") != null or width < 80);
        try testing.expect(std.mem.endsWith(u8, screen.row(0), "updated 2m ago"));
        if (width >= cellsWidth(&detail_period_header)) {
            try testing.expectEqualStrings("period        spent   share  requests  tokens", screen.row(2));
        } else {
            try testing.expect(std.mem.startsWith(u8, screen.row(2), "period        spent   share  requests"));
        }
        // Not used today: dashes, aligned under the headers.
        try testing.expect(std.mem.startsWith(u8, screen.row(3), "today"));
        try testing.expectEqual(endColumn(screen.row(2), "spent").?, endColumn(screen.row(3), "-").?);
        try testing.expectEqual(endColumn(screen.row(2), "spent").?, endColumn(screen.row(5), "$9.80").?);

        const tokens = screen.find("tokens ").?;
        const wide = width >= 62;
        try testing.expectEqual(wide, std.mem.find(u8, screen.row(tokens), "cache write") != null);
        // The narrow token table needs 48 columns for its last column.
        try testing.expectEqual(!wide and width >= cellsWidth(&tokens_header_narrow), std.mem.find(u8, screen.row(tokens), "cache wr") != null and std.mem.find(u8, screen.row(tokens), "cache write") == null);
        const perf = screen.find("perf").?;
        try testing.expectEqual(endColumn(screen.row(perf), "cache hit").?, endColumn(screen.row(perf + 3), "95.4%").?);
        try testing.expect(std.mem.find(u8, screen.row(perf + 3), "2.1s") != null);
        try testing.expect(std.mem.find(u8, screen.row(perf + 3), "0.4%") != null);
        try testing.expect(screen.widest() <= width);
    }
}

test "the model list scrolls and sums what is below the window" {
    var many: [25]ModelRow = undefined;
    var names: [25][16]u8 = undefined;
    for (&many, 0..) |*row, i| {
        row.* = testRow(std.mem.print(&names[i], "provider/m{d:0>2}", .{i}) catch unreachable, @floatFromInt(100 - i), 10, 1000);
    }
    var snapshot = try testSnapshot(.ready, false, &many);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    try testing.expectEqual(tableRows(p) + max_model_rows + 1, desiredRowCount(p));
    var screen = try draw(p, 80, 40);
    defer screen.deinit();
    try testing.expect(screen.find("provider/m09") != null);
    try testing.expect(screen.find("provider/m10") == null);
    // m10 through m24: 15 models, $90 down to $76.
    const more = screen.row(screen.find("15 more").?);
    try testing.expect(std.mem.find(u8, more, "$1,245.00") != null);

    // Fewer rows than wanted: the window shrinks, the "more" line stays.
    var short = try draw(p, 80, @intCast(tableRows(p) + 4));
    defer short.deinit();
    try testing.expect(short.find("provider/m02") != null and short.find("provider/m03") == null);
    try testing.expect(short.find("22 more") != null);
}

test "states without numbers say so in one line" {
    var unavailable = try testSnapshot(.{ .unavailable = .no_gateway_sign_in }, false, &.{});
    defer unavailable.deinit();
    var screen = try draw(.{ .active = true, .snapshot = &unavailable }, 80, 40);
    defer screen.deinit();
    try testing.expectEqualStrings("usage: not signed in to AI Gateway", screen.row(0));
    try testing.expectEqualStrings("  (use /login, or set AI_GATEWAY_API_KEY)", screen.row(2));

    var other = try testSnapshot(.{ .unavailable = .unsupported_provider }, false, &.{});
    defer other.deinit();
    var other_screen = try draw(.{ .active = true, .snapshot = &other }, 80, 40);
    defer other_screen.deinit();
    try testing.expectEqualStrings("usage: this provider's usage isn't shown yet", other_screen.row(0));
    try testing.expectEqualStrings("  (use /provider and pick AI Gateway to see AI Gateway usage)", other_screen.row(2));

    var fetching = try testSnapshot(.fetching, false, &.{});
    defer fetching.deinit();
    for (&fetching.views) |*v| {
        v.today_current = false;
        v.finished_current = false;
    }
    var first = try draw(.{ .active = true, .snapshot = &fetching }, 80, 40);
    defer first.deinit();
    try testing.expect(std.mem.startsWith(u8, first.row(0), "usage: acme-design-tools-platform (fx login)  "));
    try testing.expect(std.mem.endsWith(u8, first.row(0), "fetching…"));
    try testing.expectEqual(@as(usize, 80), display_width.visibleWidth(first.row(0)));

    // Signed in, numbers fetched, nothing used today.
    var empty_today = try testSnapshot(.ready, false, &month_models);
    defer empty_today.deinit();
    empty_today.views[0].deinit();
    empty_today.views[0] = try testView(.today, &.{}, false);
    var today = try draw(.{ .active = true, .snapshot = &empty_today, .period = .today }, 80, 40);
    defer today.deinit();
    try testing.expect(today.find("no usage today (UTC)") != null);
    try testing.expect(std.mem.startsWith(u8, today.row(3), "today       $0.0000"));
}

test "the current model is bold and colorless in every theme" {
    var snapshot = try testSnapshot(.ready, false, &month_models);
    defer snapshot.deinit();
    const p: Projection = .{ .active = true, .snapshot = &snapshot };
    const alloc = testing.allocator;
    var row = try composeRow(alloc, p, @intCast(tableRows(p)), 40, 120);
    defer row.deinit(alloc);
    try testing.expect(std.mem.startsWith(u8, row.items, ui_render.bold_style ++ "❯ "));
    // No foreground or background color code anywhere in the row.
    try testing.expect(std.mem.find(u8, row.items, "[3") == null);
    try testing.expect(std.mem.find(u8, row.items, "[4") == null);
    try testing.expect(std.mem.find(u8, row.items, ";3") == null);
}

test "network text cannot inject terminal controls" {
    const evil = [_]ModelRow{testRow("evil/\x1b[2Jmodel", 1, 1, 1)};
    var snapshot = try testSnapshot(.ready, false, &evil);
    defer snapshot.deinit();
    const alloc = testing.allocator;
    var row = try composeRow(alloc, .{ .active = true, .snapshot = &snapshot }, @intCast(tableRows(.{ .active = true, .snapshot = &snapshot })), 40, 80);
    defer row.deinit(alloc);
    try testing.expect(std.mem.find(u8, row.items, "\x1b[2J") == null);
    try testing.expect(std.mem.find(u8, row.items, "evil/?[2Jmodel") != null);
}

test "network text cannot reorder or hide characters on the terminal" {
    const alloc = testing.allocator;
    const names = [_][]const u8{ "evil/\u{9b}31mred", "evil/\u{202e}edoc", "evil/\u{200b}hidden", "evil/\xff\xfebad" };
    for (names) |name| {
        const rows = [_]ModelRow{testRow(name, 1, 1, 1)};
        var snapshot = try testSnapshot(.ready, false, &rows);
        defer snapshot.deinit();
        const p: Projection = .{ .active = true, .snapshot = &snapshot };
        var row = try composeRow(alloc, p, @intCast(tableRows(p)), 40, 80);
        defer row.deinit(alloc);
        for ([_][]const u8{ "\u{9b}", "\u{202e}", "\u{200b}", "\xff", "\xfe" }) |raw| {
            try testing.expect(std.mem.find(u8, row.items, raw) == null);
        }
        try testing.expect(std.mem.find(u8, row.items, "evil/?") != null);
    }
}

test "safe text cuts only between characters" {
    var three: [3]u8 = undefined;
    try testing.expectEqualStrings("ab", safeText(&three, "ab\u{e9}"));
    var four: [4]u8 = undefined;
    try testing.expectEqualStrings("ab\u{e9}", safeText(&four, "ab\u{e9}"));
    try testing.expectEqualStrings("a?b", safeText(&four, "a\u{202e}b"));
}

test "relative times" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("just now", agoText(&buf, 59 * std.time.ms_per_s));
    try testing.expectEqualStrings("2m ago", agoText(&buf, 2 * std.time.ms_per_min));
    try testing.expectEqualStrings("3h ago", agoText(&buf, 3 * std.time.ms_per_hour + 5));
    try testing.expectEqualStrings("2d ago", agoText(&buf, 2 * std.time.ms_per_day));
    try testing.expectEqualStrings("just now", agoText(&buf, -5));
}
