const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const host_mod = @import("host.zig");
const sandbox_mod = @import("sandbox.zig");

const Sandbox = sandbox_mod.Sandbox;

test "sandbox runs evals to completion on the dedicated thread" {
    var sandbox = Sandbox.init(std.testing.allocator, .{ .timeout_ms = 5_000 });
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    defer sandbox.deinit();
    try sandbox.start();

    const caller_thread = std.Thread.getCurrentId();
    var result = try sandbox.eval("1 + 2");
    defer result.deinit();
    try std.testing.expectEqualStrings("3", result.value);
    try std.testing.expect(sandbox.runtimeCreated());
    try std.testing.expect(sandbox.eval_thread_id != null);
    // The engine ran on the sandbox thread, never the caller's.
    try std.testing.expect(sandbox.eval_thread_id.? != caller_thread);

    const thread_id_after_first = sandbox.eval_thread_id.?;
    // Sequential evals reuse the same runtime on the same thread.
    var second = try sandbox.eval("40 + 2");
    defer second.deinit();
    try std.testing.expectEqualStrings("42", second.value);
    try std.testing.expectEqual(thread_id_after_first, sandbox.eval_thread_id.?);
}

test "sandbox cancel interrupts a tight loop and discards the value" {
    var sandbox = Sandbox.init(std.testing.allocator, .{ .timeout_ms = 60_000 });
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    defer sandbox.deinit();
    try sandbox.start();

    // Start an endless script, let it get mid-flight, then cancel.
    const Evaluator = struct {
        fn run(sb: *Sandbox, done: *std.atomic.Value(bool)) void {
            _ = sb.eval("while (true) {}") catch {};
            done.store(true, .seq_cst);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Evaluator.run, .{ &sandbox, &done });
    defer thread.join();

    var waited: usize = 0;
    while (!sandbox.isBusy() and waited < 5_000) {
        io_mod.sleep(1 * std.time.ns_per_ms);
        waited += 1;
    }
    try std.testing.expect(sandbox.isBusy());

    // Cooperative cancel: the caller keeps waiting until the engine unwound.
    sandbox.cancel();
    var settled: usize = 0;
    while (!done.load(.seq_cst) and settled < 5_000) {
        io_mod.sleep(1 * std.time.ns_per_ms);
        settled += 1;
    }
    try std.testing.expect(done.load(.seq_cst));
    try std.testing.expect(!sandbox.isBusy());
    try std.testing.expect(sandbox.cancelRequested());
}

test "sandbox cancel flows through the worker cancel atomic, not a second source" {
    var sandbox = Sandbox.init(std.testing.allocator, .{ .timeout_ms = 60_000 });
    // Stands in for the owning worker's worker_cancel_requested: the sandbox
    // holds a pointer to it and never owns the storage.
    var worker_cancel_requested = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &worker_cancel_requested;
    defer sandbox.deinit();
    try sandbox.start();

    const Evaluator = struct {
        fn run(sb: *Sandbox, done: *std.atomic.Value(bool)) void {
            _ = sb.eval("while (true) {}") catch {};
            done.store(true, .seq_cst);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Evaluator.run, .{ &sandbox, &done });
    defer thread.join();

    var waited: usize = 0;
    while (!sandbox.isBusy() and waited < 5_000) {
        io_mod.sleep(1 * std.time.ns_per_ms);
        waited += 1;
    }
    try std.testing.expect(sandbox.isBusy());

    // The worker path writes its own atomic; the sandbox interrupt handler
    // observes it with no sandbox.cancel() call in between.
    worker_cancel_requested.store(true, .seq_cst);
    var settled: usize = 0;
    while (!done.load(.seq_cst) and settled < 5_000) {
        io_mod.sleep(1 * std.time.ns_per_ms);
        settled += 1;
    }
    try std.testing.expect(done.load(.seq_cst));
    try std.testing.expect(sandbox.cancelRequested());
}

test "sandbox cancelled eval returns error.Cancelled and never a value" {
    var sandbox = Sandbox.init(std.testing.allocator, .{ .timeout_ms = 60_000 });
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    defer sandbox.deinit();
    try sandbox.start();

    // Cancel before submitting; the interrupt handler stops the script at
    // its first check and the value never reaches the caller.
    sandbox.cancel();
    try std.testing.expectError(error.Cancelled, sandbox.eval("while (true) {}"));
    try std.testing.expect(!sandbox.isBusy());

    // No reset API: a cancelled sandbox stays cancelled by design. The host
    // that needs further work creates a fresh sandbox with a fresh flag.
    try std.testing.expect(sandbox.cancelRequested());
}

test "sandbox timeout still returns error.Timeout distinct from cancellation" {
    var sandbox = Sandbox.init(std.testing.allocator, .{ .timeout_ms = 50 });
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    defer sandbox.deinit();
    try sandbox.start();

    try std.testing.expectError(error.Timeout, sandbox.eval("while (true) {}"));
    try std.testing.expect(!sandbox.cancelRequested());

    var result = try sandbox.eval("6 * 7");
    defer result.deinit();
    try std.testing.expectEqualStrings("42", result.value);
}

test "sandbox deinit waits for an in-flight eval to unwind" {
    var sandbox = Sandbox.init(std.testing.allocator, .{ .timeout_ms = 60_000 });
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    try sandbox.start();

    const Evaluator = struct {
        fn run(sb: *Sandbox, done: *std.atomic.Value(bool)) void {
            _ = sb.eval("while (true) {}") catch {};
            done.store(true, .seq_cst);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Evaluator.run, .{ &sandbox, &done });
    defer thread.join();

    var waited: usize = 0;
    while (!sandbox.isBusy() and waited < 5_000) {
        io_mod.sleep(1 * std.time.ns_per_ms);
        waited += 1;
    }
    sandbox.cancel();
    // deinit joins the sandbox thread; the in-flight script must unwind
    // through the interrupt handler before deinit returns.
    sandbox.deinit();
    // The evaluator thread stores done right after eval returns, which can
    // land a moment after the sandbox thread join completes.
    var settled: usize = 0;
    while (!done.load(.seq_cst) and settled < 5_000) {
        io_mod.sleep(1 * std.time.ns_per_ms);
        settled += 1;
    }
    try std.testing.expect(done.load(.seq_cst));
}

test "sandbox host cancel flag reads through to host.cancelled" {
    var sandbox = Sandbox.init(std.testing.allocator, .{ .timeout_ms = 60_000 });
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    defer sandbox.deinit();
    try sandbox.start();
    try std.testing.expect(!sandbox.cancelRequested());
    sandbox.cancel();
    try std.testing.expect(sandbox.cancelRequested());
}

test "sandbox eval before start reports shutdown" {
    var sandbox = Sandbox.init(std.testing.allocator, .{});
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    defer sandbox.deinit();
    try std.testing.expectError(error.Shutdown, sandbox.eval("1"));
}
