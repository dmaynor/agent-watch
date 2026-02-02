const std = @import("std");

/// Generic bounded ring buffer for time-series data
pub fn RingBuffer(comptime T: type) type {
    return struct {
        items: []T,
        capacity: usize,
        head: usize = 0,
        count: usize = 0,
        alloc: std.mem.Allocator,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, capacity: usize) !Self {
            const items = try alloc.alloc(T, capacity);
            return .{
                .items = items,
                .capacity = capacity,
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.items);
        }

        pub fn push(self: *Self, item: T) void {
            self.items[self.head] = item;
            self.head = (self.head + 1) % self.capacity;
            if (self.count < self.capacity) self.count += 1;
        }

        pub fn latest(self: *const Self) ?T {
            if (self.count == 0) return null;
            const idx = if (self.head > 0) self.head - 1 else self.capacity - 1;
            return self.items[idx];
        }

        pub fn get(self: *const Self, age: usize) ?T {
            if (age >= self.count) return null;
            const idx = if (self.head > age) self.head - age - 1 else self.capacity - (age + 1 - self.head);
            return self.items[idx];
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn toSlice(self: *const Self, buf: []T) []T {
            const n = @min(buf.len, self.count);
            for (0..n) |i| {
                const age = n - 1 - i;
                buf[i] = self.get(age).?;
            }
            return buf[0..n];
        }
    };
}

const testing = std.testing;

test "RingBuffer: init and deinit" {
    var rb = try RingBuffer(i32).init(testing.allocator, 5);
    defer rb.deinit();
    try testing.expectEqual(@as(usize, 0), rb.len());
}

test "RingBuffer: push and latest" {
    var rb = try RingBuffer(i32).init(testing.allocator, 5);
    defer rb.deinit();
    rb.push(10);
    rb.push(20);
    try testing.expectEqual(@as(i32, 20), rb.latest().?);
    try testing.expectEqual(@as(usize, 2), rb.len());
}

test "RingBuffer: empty latest returns null" {
    var rb = try RingBuffer(i32).init(testing.allocator, 5);
    defer rb.deinit();
    try testing.expect(rb.latest() == null);
}

test "RingBuffer: wrap around" {
    var rb = try RingBuffer(i32).init(testing.allocator, 3);
    defer rb.deinit();
    rb.push(1);
    rb.push(2);
    rb.push(3);
    rb.push(4); // wraps, oldest (1) replaced
    try testing.expectEqual(@as(usize, 3), rb.len());
    try testing.expectEqual(@as(i32, 4), rb.latest().?);
}

test "RingBuffer: get by age" {
    var rb = try RingBuffer(i32).init(testing.allocator, 5);
    defer rb.deinit();
    rb.push(10);
    rb.push(20);
    rb.push(30);
    try testing.expectEqual(@as(i32, 30), rb.get(0).?); // most recent
    try testing.expectEqual(@as(i32, 20), rb.get(1).?);
    try testing.expectEqual(@as(i32, 10), rb.get(2).?);
    try testing.expect(rb.get(3) == null); // beyond count
}

test "RingBuffer: toSlice" {
    var rb = try RingBuffer(i32).init(testing.allocator, 5);
    defer rb.deinit();
    rb.push(1);
    rb.push(2);
    rb.push(3);
    var buf: [5]i32 = undefined;
    const slice = rb.toSlice(&buf);
    try testing.expectEqual(@as(usize, 3), slice.len);
    try testing.expectEqual(@as(i32, 1), slice[0]); // oldest first
    try testing.expectEqual(@as(i32, 2), slice[1]);
    try testing.expectEqual(@as(i32, 3), slice[2]);
}

test "RingBuffer: single element" {
    var rb = try RingBuffer(f64).init(testing.allocator, 1);
    defer rb.deinit();
    rb.push(42.0);
    try testing.expectEqual(@as(f64, 42.0), rb.latest().?);
    rb.push(99.0); // replaces
    try testing.expectEqual(@as(f64, 99.0), rb.latest().?);
    try testing.expectEqual(@as(usize, 1), rb.len());
}
