const std = @import("std");
const timeseries = @import("timeseries.zig");

/// Linear regression result
pub const RegressionResult = struct {
    slope: f64,
    intercept: f64,
    r_squared: f64,
};

/// Simple linear regression on values (index as x)
pub fn linearRegression(values: []const f64) ?RegressionResult {
    const n = values.len;
    if (n < 3) return null;

    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xy: f64 = 0;
    var sum_xx: f64 = 0;

    for (values, 0..) |y, i| {
        const x: f64 = @floatFromInt(i);
        sum_x += x;
        sum_y += y;
        sum_xy += x * y;
        sum_xx += x * x;
    }

    const nf: f64 = @floatFromInt(n);
    const denom = nf * sum_xx - sum_x * sum_x;
    if (@abs(denom) < 1e-10) return null;

    const slope = (nf * sum_xy - sum_x * sum_y) / denom;
    const intercept = (sum_y - slope * sum_x) / nf;

    // R-squared
    const mean_y = sum_y / nf;
    var ss_res: f64 = 0;
    var ss_tot: f64 = 0;
    for (values, 0..) |y, i| {
        const x: f64 = @floatFromInt(i);
        const predicted = slope * x + intercept;
        ss_res += (y - predicted) * (y - predicted);
        ss_tot += (y - mean_y) * (y - mean_y);
    }

    const r_squared = if (ss_tot > 1e-10) 1.0 - ss_res / ss_tot else 0;

    return .{
        .slope = slope,
        .intercept = intercept,
        .r_squared = r_squared,
    };
}

/// Detect memory leak: positive slope with good fit
pub fn detectLeak(rss_values: []const f64, slope_threshold_kb_per_sample: f64) ?LeakReport {
    const reg = linearRegression(rss_values) orelse return null;

    if (reg.slope > slope_threshold_kb_per_sample and reg.r_squared > 0.7) {
        const first = rss_values[0];
        const last = rss_values[rss_values.len - 1];
        const growth_pct = if (first > 0) ((last - first) / first) * 100.0 else 0;

        return .{
            .slope_kb_per_sample = reg.slope,
            .r_squared = reg.r_squared,
            .growth_percent = growth_pct,
            .start_rss_kb = first,
            .end_rss_kb = last,
        };
    }
    return null;
}

pub const LeakReport = struct {
    slope_kb_per_sample: f64,
    r_squared: f64,
    growth_percent: f64,
    start_rss_kb: f64,
    end_rss_kb: f64,
};
