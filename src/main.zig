pub fn main() !void {}

const AtomicOrder = std.builtin.AtomicOrder;

const SpinLockMtx = struct {
    const Self = @This();

    // true if and only if a thread holds the lock
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *Self) void {
        while (self.flag.cmpxchgWeak(false, true, AtomicOrder.acq_rel, AtomicOrder.acquire) != null) {
            std.atomic.spinLoopHint();
        }
    }

    // undefined behaviour if called when not holding the lock
    fn unlock(self: *Self) void {
        self.flag.store(false, AtomicOrder.release);
    }
};

const FutexMutex = struct {
    const Self = @This();
    const Futex = std.Thread.Futex;

    // 0 means unlocked, 1 means locked.
    flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *Self) void {
        while (self.flag.cmpxchgWeak(0, 1, AtomicOrder.acq_rel, AtomicOrder.monotonic) != null) {
            // flag can only hold the value 0 or 1. if it was not 0, then it was 1.
            // note that using cpmxchgWeak is fine here, because Futex.wait will not block
            // if the flag is not read as 1.
            Futex.wait(&self.flag, 1);
        }
    }

    fn unlock(self: *Self) void {
        self.flag.store(0, AtomicOrder.release);
        Futex.wake(&self.flag, 1);
    }
};

const SpinnyFutexMutex = struct {
    const Self = @This();
    const Futex = std.Thread.Futex;

    // 0 means unlocked, 1 means locked.
    flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *Self) void {
        var i: u8 = 0;

        while (i < 10 and self.flag.cmpxchgWeak(0, 1, AtomicOrder.acq_rel, AtomicOrder.monotonic) != null) : (i += 1) {}
    }

    fn unlock(self: *Self) void {
        self.flag.store(0, AtomicOrder.release);
        Futex.wake(&self.flag, 1);
    }
};

const Lock = union(enum) {
    const Self = @This();

    spin: SpinLockMtx,
    ftx: FutexMutex,

    fn lock(self: *Self) void {
        switch (self.*) {
            inline else => |*mtx| mtx.lock(),
        }
    }

    fn unlock(self: *Self) void {
        switch (self.*) {
            inline else => |*mtx| mtx.unlock(),
        }
    }
};

fn work(goptr: *std.atomic.Value(bool), toIncPtr: *u64, mtxptr: *Lock) void {
    while (!goptr.load(AtomicOrder.acquire)) {
        std.atomic.spinLoopHint();
    }

    for (0..1000) |_| {
        mtxptr.lock();
        toIncPtr.* += 1;
        mtxptr.unlock();
    }
}

test "spinlock multithreaded increment" {
    var go = std.atomic.Value(bool).init(false);
    var toIncrement: u64 = 0;
    const spinlock = SpinLockMtx{};
    var mtx = Lock{ .spin = spinlock };

    var threads: [1000]std.Thread = undefined;
    for (0..1000) |i| {
        threads[i] = try std.Thread.spawn(.{}, work, .{ &go, &toIncrement, &mtx });
    }

    const startTime = std.time.nanoTimestamp();
    go.store(true, AtomicOrder.release);
    for (threads) |thread| {
        thread.join();
    }
    const endTime = std.time.nanoTimestamp();

    std.debug.print("spinlock difference was {}\n", .{endTime - startTime});

    try std.testing.expectEqual(1000 * 1000, toIncrement);
}

test "ftxlock multithreaded increment" {
    var go = std.atomic.Value(bool).init(false);
    var toIncrement: u64 = 0;
    const futexlock = FutexMutex{};
    var mtx = Lock{ .ftx = futexlock };

    var threads: [1000]std.Thread = undefined;
    for (0..1000) |i| {
        threads[i] = try std.Thread.spawn(.{}, work, .{ &go, &toIncrement, &mtx });
    }

    const startTime = std.time.nanoTimestamp();
    go.store(true, AtomicOrder.release);
    for (threads) |thread| {
        thread.join();
    }
    const endTime = std.time.nanoTimestamp();
    std.debug.print("ftexlock difference was {}\n", .{endTime - startTime});

    try std.testing.expectEqual(1000 * 1000, toIncrement);
}

const std = @import("std");
