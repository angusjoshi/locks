const MutexSemaphore = @This();

mtx: std.Thread.Mutex = std.Thread.Mutex{},
cond: std.Thread.Condition = std.Thread.Condition{},
permits: u32,

fn init(permits: u32) MutexSemaphore {
    return .{ .permits = permits };
}

fn acquire(self: *MutexSemaphore) void {
    self.mtx.lock();
    defer self.mtx.unlock();

    while (self.permits == 0) {
        self.cond.wait(&self.mtx);
    }

    self.permits -= 1;
}

fn release(self: *MutexSemaphore) void {
    self.mtx.lock();
    self.permits += 1;
    self.mtx.unlock();

    // not sure if this is correct.
    self.cond.signal();
}

test "basic correctness" {
    const Context = struct {
        reset: std.Thread.ResetEvent = .{},
        threadsInCriticalSection: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
        semaphore: MutexSemaphore = MutexSemaphore.init(42),
        rand: std.Random,

        fn getRand(self: *@This(), atMost: u32) u32 {
            return self.rand.uintAtMost(u32, atMost);
        }

        fn work(self: *@This()) !void {
            self.reset.wait();

            // it's somewhat important to not use acquire/release ordering on the loads/stores to
            // threadsInCriticalSection so as not to give extra synchronization beyond what the semaphore offers.
            // we do however get guarantees, since the fetchAdd load/store are on the same atomic, that
            // the effect of the fetchSub is always observed to happen after the effect of the fetchAdd.
            for (0..1_000) |_| {
                self.semaphore.acquire();
                const before = self.threadsInCriticalSection.fetchAdd(1, .monotonic);
                // sleep for at most 1ms
                std.time.sleep(self.getRand(1 * std.time.ns_per_ms));
                self.semaphore.release();
                const after = self.threadsInCriticalSection.fetchSub(1, .monotonic);

                try std.testing.expect(before >= 0 and before <= 41);
                try std.testing.expect(after >= 0 and after <= 42);
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
        semaphore: MutexSemaphore = MutexSemaphore.init(5),
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
