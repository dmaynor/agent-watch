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
