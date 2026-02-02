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
