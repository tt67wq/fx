const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const host_mod = @import("host.zig");

const Allocator = std.mem.Allocator;
const Host = host_mod.Host;
const Result = host_mod.Result;

/// Drives one QuickJS host on a dedicated thread.
///
/// The runtime, its context, and every engine call live on the sandbox
/// thread only; callers never touch the engine from their own thread. The
/// cross-thread surface is one request slot, one outcome slot, and one
/// shared cancel atomic. The cancel atomic is supplied by the owner and is
/// meant to be the same one the worker path sets (worker_cancel_requested),
/// so Escape and every other cancel route reach the interrupt handler
/// through a single source; the sandbox adds no second cancel state.
///
/// Cancellation disposition follows the existing dispatch contract
/// (tool_dispatch.zig): a cancelled eval is interrupted by the QuickJS
/// interrupt handler, the sandbox waits for the engine call to actually
/// unwind, and the value is discarded rather than returned. A sub-call that
/// already finished keeps its side effects; the sandbox never pretends the
/// script succeeded.
///
/// Do not move or copy a Sandbox after start(): the sandbox thread and the
/// interrupt handler keep pointers into it.
pub const Sandbox = struct {
    allocator: Allocator,
    host: Host,
    /// Written by any thread through cancel(); read by the host interrupt
    /// handler on the sandbox thread. Phase 3 wires this to the same
    /// worker_cancel_requested atomic instead of a second source.
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    mutex: std.Io.Mutex = .init,
    work_available: std.Io.Condition = .init,
    outcome_available: std.Io.Condition = .init,

    request: ?[]const u8 = null,
    outcome: ?Outcome = null,
    busy: bool = false,
    shutdown_requested: bool = false,
    thread: ?std.Thread = null,
    eval_thread_id: ?std.Thread.Id = null,

    pub const Outcome = struct {
        pub const Kind = enum { completed, failed };
        pub const Error = host_mod.EvalError || Allocator.Error;

        kind: Kind,
        value: ?Result = null,
        error_value: Error = undefined,
    };

    pub const EvalError = error{
        Shutdown,
        ThreadSpawnFailed,
    } || Outcome.Error;

    /// The host is created lazily by the first eval on the sandbox thread,
    /// matching the host's own lazy startup.
    pub fn init(allocator: Allocator, options: host_mod.Options) Sandbox {
        return .{
            .allocator = allocator,
            .host = Host.init(allocator, options),
        };
    }

    pub fn start(self: *Sandbox) EvalError!void {
        if (self.thread != null) return;
        self.host.cancel_flag = &self.cancel_flag;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return error.ThreadSpawnFailed;
    }

    /// Submits the script and blocks until the sandbox thread stored an
    /// outcome. On cancel that wait is the wait-for-completion half of the
    /// disposition: the interrupt handler stops the script, the engine call
    /// unwinds, and the interrupted value is discarded (error.Cancelled is
    /// returned, never a partial value).
    pub fn eval(self: *Sandbox, script: []const u8) EvalError!Result {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.thread == null) return error.Shutdown;
        while (self.busy) {
            // One eval at a time; a second caller waits for the engine to
            // unwind instead of queueing a script behind the running one.
            self.outcome_available.wait(io, &self.mutex) catch return error.Shutdown;
        }
        if (self.shutdown_requested) return error.Shutdown;
        self.busy = true;
        self.request = script;
        self.work_available.signal(io);
        while (self.outcome == null) {
            self.outcome_available.wait(io, &self.mutex) catch return error.Shutdown;
        }
        const outcome = self.outcome.?;
        self.outcome = null;
        self.busy = false;
        self.outcome_available.broadcast(io);
        return switch (outcome.kind) {
            .completed => outcome.value.?,
            .failed => outcome.error_value,
        };
    }

    /// Requests cancellation. Cooperative: the interrupt handler stops the
    /// script at its next check and eval returns once the engine unwound.
    /// Callers waiting in eval keep blocking until then.
    pub fn cancel(self: *Sandbox) void {
        self.cancel_flag.store(true, .seq_cst);
    }

    /// Clears the cancel flag so the sandbox can be reused after a cancel.
    pub fn resetCancel(self: *Sandbox) void {
        self.cancel_flag.store(false, .seq_cst);
    }

    pub fn cancelRequested(self: *const Sandbox) bool {
        return self.cancel_flag.load(.seq_cst);
    }

    /// True while a script is mid-flight on the sandbox thread.
    pub fn isBusy(self: *Sandbox) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.busy;
    }

    pub fn runtimeCreated(self: *Sandbox) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.host.runtimeCreated();
    }

    pub fn deinit(self: *Sandbox) void {
        if (self.thread) |thread| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.shutdown_requested = true;
            self.work_available.broadcast(io_mod.getIo());
            self.mutex.unlock(io_mod.getIo());
            // The sandbox thread exits only while no script is mid-flight,
            // so joining here waits for an in-flight eval to unwind.
            thread.join();
            self.thread = null;
        }
        self.host.deinit();
        if (self.outcome) |*outcome| {
            // A completed result nobody consumed still owns memory.
            if (outcome.value) |*result| result.deinit();
            self.outcome = null;
        }
    }

    fn run(self: *Sandbox) void {
        const io = io_mod.getIo();
        self.eval_thread_id = std.Thread.getCurrentId();
        self.mutex.lockUncancelable(io);
        while (true) {
            while (self.request == null and !self.shutdown_requested) {
                self.work_available.wait(io, &self.mutex) catch {
                    self.mutex.unlock(io);
                    return;
                };
            }
            const script = self.request orelse {
                self.mutex.unlock(io);
                return;
            };
            self.request = null;
            self.mutex.unlock(io);

            // The caller's slice stays valid for the whole eval because the
            // caller blocks in eval until the outcome lands; duplicate so
            // the engine holds its own copy regardless.
            const owned = self.allocator.dupe(u8, script) catch |err| {
                self.mutex.lockUncancelable(io);
                self.outcome = .{ .kind = .failed, .error_value = err };
                self.outcome_available.signal(io);
                continue;
            };
            // host.eval copies what it keeps, so the duplicate is the
            // sandbox's to free on every path.
            defer self.allocator.free(owned);
            const outcome: Outcome = blk: {
                if (self.host.eval(owned)) |result| {
                    break :blk .{ .kind = .completed, .value = result };
                } else |err| {
                    break :blk .{ .kind = .failed, .error_value = err };
                }
            };
            self.mutex.lockUncancelable(io);
            self.outcome = outcome;
            self.outcome_available.signal(io);
        }
    }
};

test {
    _ = @import("sandbox_tests.zig");
}
