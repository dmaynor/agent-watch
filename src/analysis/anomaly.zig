const std = @import("std");
const timeseries = @import("timeseries.zig");

/// Z-score based anomaly detection
pub fn zScoreAnomaly(stats: *const timeseries.RollingStats, value: f64, threshold: f64) bool {
    const sd = stats.stddev();
    if (sd < 0.001) return false; // too little variance
    const z = @abs(value - stats.avg()) / sd;
    return z > threshold;
}

/// IQR-based outlier detection
pub fn iqrOutlier(stats: *const timeseries.RollingStats, value: f64, multiplier: f64) bool {
    const q1 = stats.percentile(25);
    const q3 = stats.percentile(75);
    const iqr = q3 - q1;
    if (iqr < 0.001) return false;
    return value < (q1 - multiplier * iqr) or value > (q3 + multiplier * iqr);
}

const testing = std.testing;

test "zScoreAnomaly: normal value not anomalous" {
    var stats = try timeseries.RollingStats.init(testing.allocator, 20);
    defer stats.deinit();
    for (0..20) |_| stats.push(50.0 + @as(f64, @floatFromInt(@mod(std.crypto.random.int(u8), 5))) - 2.5);
    // A value near the mean should not be anomalous
    try testing.expect(!zScoreAnomaly(&stats, stats.avg(), 3.0));
}

test "zScoreAnomaly: extreme value is anomalous" {
    var stats = try timeseries.RollingStats.init(testing.allocator, 20);
    defer stats.deinit();
    for (0..20) |_| stats.push(50.0);
    stats.push(51.0); // add slight variance
    // A value very far from mean should be anomalous
    try testing.expect(zScoreAnomaly(&stats, 200.0, 3.0));
}

test "zScoreAnomaly: zero stddev returns false" {
    var stats = try timeseries.RollingStats.init(testing.allocator, 10);
    defer stats.deinit();
    for (0..10) |_| stats.push(50.0);
    try testing.expect(!zScoreAnomaly(&stats, 100.0, 3.0));
}

test "iqrOutlier: value within IQR not outlier" {
    var stats = try timeseries.RollingStats.init(testing.allocator, 20);
    defer stats.deinit();
    for (1..21) |i| stats.push(@floatFromInt(i));
    try testing.expect(!iqrOutlier(&stats, 10.0, 1.5));
}

test "iqrOutlier: extreme value is outlier" {
    var stats = try timeseries.RollingStats.init(testing.allocator, 20);
    defer stats.deinit();
    for (1..21) |i| stats.push(@floatFromInt(i));
    try testing.expect(iqrOutlier(&stats, 100.0, 1.5));
}
