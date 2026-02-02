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
