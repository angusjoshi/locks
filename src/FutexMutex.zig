// basic mutex with futex waiting.
//

const FutexMutex = @This();
const Futex = std.Thread.Futex;

// 0 means unlocked, 1 means locked.
flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

fn lock(self: *FutexMutex) void {
    while (self.flag.cmpxchgWeak(0, 1, .acq_rel, .monotonic) != null) {
        // flag can only hold the value 0 or 1. if it was not 0, then it was 1.
        // note that using cpmxchgWeak is fine here, because Futex.wait will not block
        // if the flag is not read as 1.
        Futex.wait(&self.flag, 1);
    }
}

fn unlock(self: *FutexMutex) void {
    self.flag.store(0, .release);
    Futex.wake(&self.flag, 1);
}

test "better incrementing" {
    const Context = struct {
        mtx: FutexMutex = .{},
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
