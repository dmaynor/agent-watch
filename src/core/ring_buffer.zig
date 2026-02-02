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
