const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const result_store = @import("../../core/session/result_store.zig");
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

test "sandbox keeps a 200KiB capture whole and the stored preview spans head and tail" {
    var sandbox = Sandbox.init(std.testing.allocator, .{ .timeout_ms = 30_000 });
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    defer sandbox.deinit();
    try sandbox.start();

    var result = try sandbox.eval(
        \\text("CODEMODE-HEAD|" + "x".repeat(200 * 1024) + "|CODEMODE-TAIL");
        \\1;
    );
    defer result.deinit();
    const head_sentinel = "CODEMODE-HEAD|";
    const tail_sentinel = "|CODEMODE-TAIL";
    // The 1MiB capture cap keeps all 200KiB+ bytes whole.
    try std.testing.expectEqual(@as(usize, 0), result.text_dropped_bytes);
    try std.testing.expectEqual(@as(usize, head_sentinel.len + 200 * 1024 + tail_sentinel.len), result.text.len);
    try std.testing.expect(std.mem.startsWith(u8, result.text, head_sentinel));
    try std.testing.expect(std.mem.endsWith(u8, result.text, tail_sentinel));

    // The shared session layer stores the whole text and previews head and
    // tail; the handle reads the untouched middle back byte for byte.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const prepared = try result_store.prepare(alloc, dir, "call/1", "codemode", result.text.len, result.text, 64 * 1024);
    defer alloc.free(prepared.model_output);
    defer alloc.free(@constCast(prepared.memory.output_handle.?));
    defer alloc.free(@constCast(prepared.memory.preview.?));

    try std.testing.expect(std.mem.find(u8, prepared.model_output, head_sentinel) != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, tail_sentinel) != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, " bytes omitted]...") != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "<tool_result_handle>") != null);

    const handle_open = "<tool_result_handle>";
    const handle_start = std.mem.find(u8, prepared.model_output, handle_open).? + handle_open.len;
    const handle_end = std.mem.findPos(u8, prepared.model_output, handle_start, "</tool_result_handle>").?;
    const handle = prepared.model_output[handle_start..handle_end];

    // The middle byte range matches the original capture exactly.
    const range_len = 64;
    const mid_index = head_sentinel.len + 100 * 1024;
    const stored = try result_store.readByRange(alloc, dir, handle, mid_index + 1, range_len);
    defer alloc.free(stored);
    const body_open = std.mem.find(u8, stored, ">\n").? + 2;
    const stored_body = stored[body_open .. stored.len - "\n</tool_result>".len];
    try std.testing.expectEqualStrings(result.text[mid_index .. mid_index + range_len], stored_body);
}

test "sandbox eval before start reports shutdown" {
    var sandbox = Sandbox.init(std.testing.allocator, .{});
    var cancel_flag = std.atomic.Value(bool).init(false);
    sandbox.cancel_flag = &cancel_flag;
    defer sandbox.deinit();
    try std.testing.expectError(error.Shutdown, sandbox.eval("1"));
}
