const std = @import("std");

/// Context switch rate analysis
pub const CtxSwitchRate = struct {
    voluntary_rate: f64 = 0, // per second
    involuntary_rate: f64 = 0,
    scheduling_pressure: f64 = 0, // involuntary / (voluntary + involuntary)
};

/// Calculate context switch rates from two status samples
pub fn calculateRate(
    vol_prev: i64,
    nvol_prev: i64,
    vol_curr: i64,
    nvol_curr: i64,
    interval_secs: f64,
) CtxSwitchRate {
    if (interval_secs <= 0) return .{};

    const vol_delta: f64 = @floatFromInt(@max(vol_curr - vol_prev, 0));
    const nvol_delta: f64 = @floatFromInt(@max(nvol_curr - nvol_prev, 0));
    const total = vol_delta + nvol_delta;

    return .{
        .voluntary_rate = vol_delta / interval_secs,
        .involuntary_rate = nvol_delta / interval_secs,
        .scheduling_pressure = if (total > 0) nvol_delta / total else 0,
    };
}

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");

test "calculateRate: basic rates" {
    const rate = calculateRate(100, 10, 200, 30, 5.0);
    try helpers.expectApproxEqual(20.0, rate.voluntary_rate, 0.01); // 100 delta / 5 secs
    try helpers.expectApproxEqual(4.0, rate.involuntary_rate, 0.01); // 20 delta / 5 secs
}

test "calculateRate: scheduling pressure" {
    const rate = calculateRate(0, 0, 50, 50, 1.0);
    try helpers.expectApproxEqual(0.5, rate.scheduling_pressure, 0.01); // 50/50 split
}

test "calculateRate: zero interval returns zeros" {
    const rate = calculateRate(100, 10, 200, 30, 0.0);
    try helpers.expectApproxEqual(0.0, rate.voluntary_rate, 0.001);
    try helpers.expectApproxEqual(0.0, rate.involuntary_rate, 0.001);
}

test "calculateRate: no delta returns zero pressure" {
    const rate = calculateRate(100, 10, 100, 10, 5.0);
    try helpers.expectApproxEqual(0.0, rate.scheduling_pressure, 0.001);
}
