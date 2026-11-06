const std = @import("std");
const agents = @import("../agents/agents.zig");
const session_codec = @import("../session/session_codec.zig");
const builtin = @import("builtin");
const model_provider = @import("../config/model_provider.zig");
const configured_provider = @import("../config/configured_provider.zig");
const http_pool = @import("../shared/http_pool.zig");

const Allocator = std.mem.Allocator;

/// One-line startup warning when the active model on a configured connection
/// cannot reach the automatic compaction threshold because nothing declares
/// its context window. Covers both a declared model missing `context_window`
/// and a model with no `model_metadata` entry at all. Caller owns the
/// returned text; null for the gateway provider, an unresolvable connection,
/// or a declared window.
pub fn missingContextWindowNotice(
    alloc: Allocator,
    provider_id: model_provider.ProviderId,
    definitions: configured_provider.Registry,
    model_id: []const u8,
) ?[]u8 {
    if (provider_id != .configured) return null;
    const definition = definitions.get(provider_id.label()) orelse return null;
    const metadata = definition.model(model_id) orelse
        return alloc.print(
            "model \"{s}\" on connection \"{s}\" has no model_metadata entry; fx assumes no capabilities, and automatic compaction stays off until the server rejects an oversized request. Declare the model under model_metadata to describe it",
            .{ model_id, provider_id.label() },
        ) catch null;
    if (metadata.context_window != null) return null;
    return alloc.print(
        "model \"{s}\" on connection \"{s}\" declares no context_window; automatic compaction stays off until the server rejects an oversized request. Set model_metadata \"{s}\" context_window to enable it",
        .{ model_id, provider_id.label(), model_id },
    ) catch null;
}

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    active_provider: model_provider.ProviderId = .gateway,
    model: std.ArrayList(u8) = .empty,
    definitions: configured_provider.Registry = .{},
    model_requests_blocked: bool = false,
    /// Process-long pooled HTTP client for gateway chat traffic. Heap-allocated
    /// so the pointer stays stable when this Runtime is copied by value; null
    /// when allocation failed (requests then dial per attempt, as before).
    gateway_http_pool: ?*http_pool.HttpPool = null,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    /// Creates the gateway pool once. Safe to call repeatedly. Allocation
    /// failure leaves the pool absent rather than failing the caller.
    pub fn ensureGatewayHttpPool(self: *Self) void {
        if (self.gateway_http_pool != null) return;
        const pool = self.alloc.create(http_pool.HttpPool) catch return;
        pool.* = http_pool.HttpPool.init(self.alloc);
        self.gateway_http_pool = pool;
    }

    pub fn deinit(self: *Self) void {
        if (self.gateway_http_pool) |pool| {
            if (pool.deinit() == .destroyed) self.alloc.destroy(pool);
        }
        self.model.deinit(self.alloc);
        self.definitions.deinit(self.alloc);
        self.* = undefined;
    }

    /// The returned model slice is borrowed until the next mutation or deinit.
    pub fn selection(self: *const Self) model_provider.ProviderSelection {
        return .{
            .provider = self.active_provider,
            .model = self.model.items,
        };
    }

    pub fn replaceModel(self: *Self, value: []const u8) !void {
        var owned = try self.alloc.dupe(u8, value);
        self.adoptOwned(self.active_provider, &owned);
    }

    pub fn replaceSelection(
        self: *Self,
        target_provider: model_provider.ProviderId,
        model_value: []const u8,
    ) !void {
        const bound = try target_provider.bind(self.definitions);
        var owned = try self.alloc.dupe(u8, model_value);
        self.adoptOwned(bound, &owned);
    }

    /// Transfers `owned_model` into the runtime. All fallible preparation must
    /// finish before this no-fail publication boundary.
    pub fn adoptOwned(
        self: *Self,
        target_provider: model_provider.ProviderId,
        owned_model: *[]u8,
    ) void {
        self.model.deinit(self.alloc);
        self.model = .fromOwnedSlice(owned_model.*);
        owned_model.* = &.{};
        self.active_provider = target_provider;
    }
};

pub fn supported(comptime App: type) bool {
    return @hasField(App, "provider_selection") or
        (builtin.is_test and @hasField(App, "selected_model"));
}

/// The model of the agent on screen, for main-loop screen code.
pub fn model(app: anytype) []const u8 {
    return modelOf(app, screenAgentIfTracked(app));
}

/// `agent`'s model: a subagent's own choice, else the app's selection.
pub fn modelOf(app: anytype, agent: anytype) []const u8 {
    const App = @TypeOf(app.*);
    if (subagentPreferences(app, agent)) |preferences| return preferences.model;
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().model;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return app.selected_model.items;
    }
    @compileError("app must own provider_selection");
}

/// Whether `App` runs subagents whose model choice is their own.
fn tracksSubagentPreferences(comptime App: type) bool {
    if (!@hasField(App, "main_agent") or !@hasField(App, "screen_owner")) return false;
    const Agent = @FieldType(App, "main_agent");
    if (!@hasField(Agent, "session_persistence")) return false;
    return @hasField(@FieldType(Agent, "session_persistence"), "session_preferences");
}

/// The agent on screen when `app` runs subagents with their own model
/// choices, else nothing to ask about.
fn screenAgentIfTracked(app: anytype) if (tracksSubagentPreferences(@TypeOf(app.*))) @TypeOf(&app.main_agent) else void {
    if (comptime !tracksSubagentPreferences(@TypeOf(app.*))) return {};
    return agents.screenAgentOf(app);
}

/// A subagent's own model choice, kept in its own session's preferences:
/// set when `agent` is a subagent with its session attached. Main's
/// is the app's selection.
fn subagentPreferences(app: anytype, agent: anytype) ?*const session_codec.DurableSessionPreferences {
    if (comptime !tracksSubagentPreferences(@TypeOf(app.*))) return null;
    if (agent == &app.main_agent) return null;
    if (agent.session_persistence.session_preferences) |*preferences| return preferences;
    return null;
}

fn subagentPreferencesMut(app: anytype, agent: anytype) ?*session_codec.DurableSessionPreferences {
    if (comptime !tracksSubagentPreferences(@TypeOf(app.*))) return null;
    if (agent == &app.main_agent) return null;
    if (agent.session_persistence.session_preferences) |*preferences| return preferences;
    return null;
}

/// The provider of the agent on screen, for main-loop screen code.
pub fn provider(app: anytype) model_provider.ProviderId {
    return providerOf(app, screenAgentIfTracked(app));
}

/// `agent`'s provider: a subagent's own choice, else the app's.
pub fn providerOf(app: anytype, agent: anytype) model_provider.ProviderId {
    const App = @TypeOf(app.*);
    if (subagentPreferences(app, agent)) |preferences| return preferences.provider;
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.selection().provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_provider")) {
        return app.selected_provider;
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        return .gateway;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceModel(app: anytype, value: []const u8) !void {
    const App = @TypeOf(app.*);
    if (subagentPreferencesMut(app, screenAgentIfTracked(app))) |preferences| {
        const owned = try app.alloc.dupe(u8, value);
        app.alloc.free(preferences.model);
        preferences.model = owned;
        return;
    }
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceModel(value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        const stable = try app.alloc.dupe(u8, value);
        defer app.alloc.free(stable);
        try app.selected_model.ensureTotalCapacity(app.alloc, stable.len);
        app.selected_model.clearRetainingCapacity();
        app.selected_model.appendSliceAssumeCapacity(stable);
        return;
    }
    @compileError("app must own provider_selection");
}

pub fn replaceSelection(
    app: anytype,
    selected_provider: model_provider.ProviderId,
    value: []const u8,
) !void {
    const App = @TypeOf(app.*);
    if (subagentPreferencesMut(app, screenAgentIfTracked(app))) |preferences| {
        try replaceModel(app, value);
        preferences.provider = selected_provider;
        return;
    }
    if (comptime @hasField(App, "provider_selection")) {
        return app.provider_selection.replaceSelection(selected_provider, value);
    }
    if (comptime builtin.is_test and @hasField(App, "selected_model")) {
        if (@hasField(App, "selected_provider")) app.selected_provider = selected_provider;
        return replaceModel(app, value);
    }
    @compileError("app must own provider_selection");
}

test "provider runtime adopts an owned selection without a fallible publication" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();

    var gateway_model = try alloc.dupe(u8, "gateway/model");
    runtime.adoptOwned(.gateway, &gateway_model);
    try std.testing.expectEqual(@as(usize, 0), gateway_model.len);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, runtime.selection().provider);
    try std.testing.expectEqualStrings("gateway/model", runtime.selection().model);

    var local_model = try alloc.dupe(u8, "gpt-model");
    const local = model_provider.parse("local").?;
    runtime.adoptOwned(local, &local_model);
    try std.testing.expectEqual(@as(usize, 0), local_model.len);
    try std.testing.expect(runtime.selection().provider.eql(local));
    try std.testing.expectEqualStrings("gpt-model", runtime.selection().model);
}

test "missing context window notice covers declared and undeclared models" {
    const alloc = std.testing.allocator;
    var registry = try configured_provider.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:11434/v1","auth":{"type":"none"},"model_metadata":{"windowed":{"context_window":8192},"windowless":{"max_output_tokens":512}}}}
    );
    defer registry.deinit(alloc);
    const local = model_provider.parse("local").?;

    try std.testing.expect(missingContextWindowNotice(alloc, .gateway, registry, "windowless") == null);
    try std.testing.expect(missingContextWindowNotice(alloc, local, registry, "windowed") == null);
    try std.testing.expect(missingContextWindowNotice(alloc, model_provider.parse("missing").?, registry, "windowless") == null);

    const declared = missingContextWindowNotice(alloc, local, registry, "windowless").?;
    defer alloc.free(declared);
    try std.testing.expect(std.mem.find(u8, declared, "windowless") != null);
    try std.testing.expect(std.mem.find(u8, declared, "declares no context_window") != null);
    try std.testing.expect(std.mem.find(u8, declared, "connection \"local\"") != null);

    const undeclared = missingContextWindowNotice(alloc, local, registry, "unknown-model").?;
    defer alloc.free(undeclared);
    try std.testing.expect(std.mem.find(u8, undeclared, "unknown-model") != null);
    try std.testing.expect(std.mem.find(u8, undeclared, "no model_metadata entry") != null);
}
