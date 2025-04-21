const SpinMutex = @This();

// true if and only if a thread holds the lock
flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

fn lock(self: *SpinMutex) void {
    while (self.flag.cmpxchgWeak(false, true, .acq_rel, .acquire) != null) {
        std.atomic.spinLoopHint();
    }
}

// undefined behaviour if called when not holding the lock
fn unlock(self: *SpinMutex) void {
    self.flag.store(false, .release);
}

test "better incrementing" {
    const Context = struct {
        mtx: SpinMutex = .{},
        reset: std.Thread.ResetEvent = .{},
        counter: u32 = 0,

        fn work(self: *@This()) void {
            self.reset.wait();

            for (0..1000) |_| {
                self.mtx.lock();
                self.counter += 1;
                self.mtx.unlock();
            }
        }
    };

    var context = Context{};
    var threads: [10]std.Thread = undefined;
    for (0..10) |i| {
        threads[i] = try std.Thread.spawn(.{}, Context.work, .{&context});
    }
    context.reset.set();
    for (0..10) |i| {
        threads[i].join();
    }

    try std.testing.expectEqual(1000 * 10, context.counter);
}

const std = @import("std");
