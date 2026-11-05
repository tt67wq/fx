const std = @import("std");

pub const Profile = struct {
    cooperative_agent: bool,
    durable_sessions: bool,
    profile_usage: bool,
    native_auth: bool,
    file_index: bool,
    mcp: bool,
    subagents: bool,
    auto_upgrade: bool,
    skills: bool,
    clipboard: bool,
    url_opening: bool,
    web_search: bool,
    tools: bool,
};

pub const Capability = std.meta.FieldEnum(Profile);

/// Reports whether the app's host profile enables a capability. A profile that
/// leaves a capability out inherits the native value.
pub fn allows(comptime App: type, comptime capability: Capability) bool {
    if (!@hasDecl(App, "host_profile")) return @field(native, @tagName(capability));
    const profile = App.host_profile;
    if (@TypeOf(profile) == type) {
        // A profile given as a type names only the capabilities it sets.
        if (!@hasDecl(profile, @tagName(capability))) return @field(native, @tagName(capability));
        return @field(profile, @tagName(capability));
    }
    if (!@hasField(@TypeOf(profile), @tagName(capability))) return @field(native, @tagName(capability));
    return @field(profile, @tagName(capability));
}

pub const native = Profile{
    .cooperative_agent = false,
    .durable_sessions = true,
    .profile_usage = true,
    .native_auth = true,
    .file_index = true,
    .mcp = true,
    .subagents = true,
    .auto_upgrade = true,
    .skills = true,
    .clipboard = true,
    .url_opening = true,
    .web_search = true,
    .tools = true,
};

test "apps without a host profile retain native capabilities" {
    const App = struct {};
    try std.testing.expect(allows(App, .durable_sessions));
    try std.testing.expect(!allows(App, .cooperative_agent));
}

test "host profile capabilities are selected by field" {
    const App = struct {
        pub const host_profile = struct {
            pub const durable_sessions = false;
        };
    };
    try std.testing.expect(!allows(App, .durable_sessions));
    try std.testing.expect(allows(App, .file_index));
}

test "native profile enables the terminal agent capabilities" {
    try std.testing.expect(native.native_auth);
    try std.testing.expect(native.url_opening);
    try std.testing.expect(native.tools);
    try std.testing.expect(!native.cooperative_agent);
}
