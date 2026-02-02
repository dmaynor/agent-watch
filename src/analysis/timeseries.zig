const std = @import("std");

/// Rolling statistics over a configurable window
pub const RollingStats = struct {
    values: []f64,
    capacity: usize,
    count: usize = 0,
    head: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, window_size: usize) !RollingStats {
        const values = try alloc.alloc(f64, window_size);
        @memset(values, 0);
        return .{
            .values = values,
            .capacity = window_size,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *RollingStats) void {
        self.alloc.free(self.values);
    }

    pub fn push(self: *RollingStats, val: f64) void {
        self.values[self.head] = val;
        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) self.count += 1;
    }

    pub fn min(self: *const RollingStats) f64 {
        if (self.count == 0) return 0;
        var m: f64 = std.math.inf(f64);
        for (0..self.count) |i| {
            if (self.values[i] < m) m = self.values[i];
        }
        return m;
    }

    pub fn max(self: *const RollingStats) f64 {
        if (self.count == 0) return 0;
        var m: f64 = -std.math.inf(f64);
        for (0..self.count) |i| {
            if (self.values[i] > m) m = self.values[i];
        }
        return m;
    }

    pub fn avg(self: *const RollingStats) f64 {
        if (self.count == 0) return 0;
        var sum: f64 = 0;
        for (0..self.count) |i| {
            sum += self.values[i];
        }
        return sum / @as(f64, @floatFromInt(self.count));
    }

    pub fn stddev(self: *const RollingStats) f64 {
        if (self.count < 2) return 0;
        const mean = self.avg();
        var sum_sq: f64 = 0;
        for (0..self.count) |i| {
            const diff = self.values[i] - mean;
            sum_sq += diff * diff;
        }
        return @sqrt(sum_sq / @as(f64, @floatFromInt(self.count - 1)));
    }

    /// Percentile (0-100). Uses nearest-rank method.
    pub fn percentile(self: *const RollingStats, p: f64) f64 {
        if (self.count == 0) return 0;

        // Copy values and sort
        var sorted: [1024]f64 = undefined;
        const n = @min(self.count, 1024);
        @memcpy(sorted[0..n], self.values[0..n]);
        std.mem.sort(f64, sorted[0..n], {}, std.sort.asc(f64));

        const rank = @as(usize, @intFromFloat(@ceil(p / 100.0 * @as(f64, @floatFromInt(n)))));
        return sorted[@min(rank, n) - 1];
    }

    /// Get the last N values (most recent first)
    pub fn recentValues(self: *const RollingStats, buf: []f64) []f64 {
        const n = @min(buf.len, self.count);
        for (0..n) |i| {
            const idx = if (self.head >= i + 1) self.head - i - 1 else self.capacity - (i + 1 - self.head);
            buf[i] = self.values[idx];
        }
        return buf[0..n];
    }
};

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");

test "RollingStats: init and deinit" {
    var rs = try RollingStats.init(testing.allocator, 10);
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 0), rs.count);
}

test "RollingStats: push and count" {
    var rs = try RollingStats.init(testing.allocator, 5);
    defer rs.deinit();
    rs.push(1.0);
    rs.push(2.0);
    rs.push(3.0);
    try testing.expectEqual(@as(usize, 3), rs.count);
}

test "RollingStats: mean" {
    var rs = try RollingStats.init(testing.allocator, 10);
    defer rs.deinit();
    rs.push(2.0);
    rs.push(4.0);
    rs.push(6.0);
    try helpers.expectApproxEqual(4.0, rs.avg(), 0.001);
}

test "RollingStats: stddev" {
    var rs = try RollingStats.init(testing.allocator, 10);
    defer rs.deinit();
    const vals = [_]f64{ 2, 4, 4, 4, 5, 5, 7, 9 };
    for (vals) |v| rs.push(v);
    const sd = rs.stddev();
    try helpers.expectApproxEqual(2.138, sd, 0.01);
}

test "RollingStats: min and max" {
    var rs = try RollingStats.init(testing.allocator, 10);
    defer rs.deinit();
    rs.push(5.0);
    rs.push(1.0);
    rs.push(9.0);
    rs.push(3.0);
    try helpers.expectApproxEqual(1.0, rs.min(), 0.001);
    try helpers.expectApproxEqual(9.0, rs.max(), 0.001);
}

test "RollingStats: empty stats return zero" {
    var rs = try RollingStats.init(testing.allocator, 10);
    defer rs.deinit();
    try helpers.expectApproxEqual(0.0, rs.avg(), 0.001);
    try helpers.expectApproxEqual(0.0, rs.min(), 0.001);
    try helpers.expectApproxEqual(0.0, rs.max(), 0.001);
    try helpers.expectApproxEqual(0.0, rs.stddev(), 0.001);
}

test "RollingStats: percentile" {
    var rs = try RollingStats.init(testing.allocator, 10);
    defer rs.deinit();
    for (1..11) |i| rs.push(@floatFromInt(i));
    const p50 = rs.percentile(50);
    try helpers.expectApproxEqual(5.0, p50, 0.5);
    const p90 = rs.percentile(90);
    try helpers.expectApproxEqual(9.0, p90, 0.5);
}

test "RollingStats: buffer wrap around" {
    var rs = try RollingStats.init(testing.allocator, 3);
    defer rs.deinit();
    rs.push(1.0);
    rs.push(2.0);
    rs.push(3.0);
    rs.push(4.0); // wraps, buffer now: [4, 2, 3] logically [2, 3, 4]
    try testing.expectEqual(@as(usize, 3), rs.count);
    try helpers.expectApproxEqual(3.0, rs.avg(), 0.001);
    try helpers.expectApproxEqual(2.0, rs.min(), 0.001);
    try helpers.expectApproxEqual(4.0, rs.max(), 0.001);
}

test "RollingStats: recentValues" {
    var rs = try RollingStats.init(testing.allocator, 5);
    defer rs.deinit();
    rs.push(10.0);
    rs.push(20.0);
    rs.push(30.0);
    var buf: [5]f64 = undefined;
    const recent = rs.recentValues(&buf);
    try testing.expectEqual(@as(usize, 3), recent.len);
    try helpers.expectApproxEqual(30.0, recent[0], 0.001);
    try helpers.expectApproxEqual(20.0, recent[1], 0.001);
    try helpers.expectApproxEqual(10.0, recent[2], 0.001);
}
