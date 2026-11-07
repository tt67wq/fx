const std = @import("std");
const host = @import("host.zig");

test "codemode script execution stays bounded on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzCodemodeScript, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "1 + 2",
            "while (true) {}",
        }) ++ @import("fuzz_corpus").codemode_script.*),
    });
}

fn fuzzCodemodeScript(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len = smith.slice(&buffer);

    var sandbox = host.Host.init(std.testing.allocator, .{
        .memory_limit_bytes = 4 * 1024 * 1024,
        .timeout_ms = 20,
    });
    defer sandbox.deinit();

    var result = sandbox.eval(buffer[0..len]) catch |err| switch (err) {
        error.ScriptError, error.Timeout, error.MemoryLimit => return,
        else => return err,
    };
    defer result.deinit();
}
