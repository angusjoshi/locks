const WaitFreeFutexSemaphore = @This();
const Futex = std.Thread.Futex;

permits: std.atomic.Value(i32),

fn init(permits: i32) WaitFreeFutexSemaphore {
    return .{ .permits = std.atomic.Value(i32).init(permits) };
}

fn acquire(self: *WaitFreeFutexSemaphore) void {
    while (true) {
        const was = self.permits.fetchSub(1, .acq_rel);

        if (was <= 0) {
            // oops. there actually weren't any permits left.
            _ = self.permits.fetchAdd(1, .monotonic);
            std.atomic.spinLoopHint();
            continue;
        }

        return;
    }
}

fn release(self: *WaitFreeFutexSemaphore) void {
    _ = self.permits.fetchAdd(1, .acq_rel);
}

test "ref" {
    std.testing.refAllDecls(WaitFreeFutexSemaphore);
}

test "basic correctness" {
    const Context = struct {
        reset: std.Thread.ResetEvent = .{},
        threadsInCriticalSection: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
        semaphore: WaitFreeFutexSemaphore = WaitFreeFutexSemaphore.init(42),
        rand: std.Random,

        fn getRand(self: *@This(), atMost: u32) u32 {
            return self.rand.uintAtMost(u32, atMost);
        }

        fn work(self: *@This()) !void {
            self.reset.wait();

            for (0..1_000) |_| {
                self.semaphore.acquire();
                const before = self.threadsInCriticalSection.fetchAdd(1, .monotonic);
                std.time.sleep(self.getRand(1 * std.time.ns_per_ms));
                const after = self.threadsInCriticalSection.fetchSub(1, .monotonic);
                self.semaphore.release();

                std.debug.assert(before >= 0 and before <= 41);
                std.debug.assert(after >= 1 and after <= 42);
            }
        }
    };

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var context = Context{ .rand = rand };
    const nThreads = 100;

    var threads: [nThreads]std.Thread = undefined;
    for (0..nThreads) |i| {
        threads[i] = try std.Thread.spawn(.{}, Context.work, .{&context});
    }

    context.reset.set();

    for (0..nThreads) |i| {
        threads[i].join();
    }
}

test "other correctness" {
    const Context = struct {
        semaphore: WaitFreeFutexSemaphore = WaitFreeFutexSemaphore.init(5),
        reset: std.Thread.ResetEvent = .{},
        flags: [10]bool = undefined,

        fn work(self: *@This(), threadIdx: usize) void {
            self.reset.wait();

            self.semaphore.acquire();
            self.flags[threadIdx] = true;
            std.time.sleep(50 * std.time.ns_per_ms);
            self.semaphore.release();
        }
    };

    var context = Context{};
    var threads: [10]std.Thread = undefined;
    for (0..threads.len) |i| {
        threads[i] = try std.Thread.spawn(.{}, Context.work, .{ &context, i });
        context.flags[i] = false;
    }

    context.reset.set();

    // TODO these sleep durations can be smaller probably.
    std.time.sleep(10 * std.time.ns_per_ms);

    var flagsTrue: u32 = 0;
    for (0..threads.len) |i| {
        if (context.flags[i]) {
            flagsTrue += 1;
        }
    }

    try std.testing.expect(flagsTrue == 5);

    for (0..threads.len) |i| {
        threads[i].join();
    }
}
const std = @import("std");
