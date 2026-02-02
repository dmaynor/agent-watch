const std = @import("std");

/// Behavioral fingerprint for an agent process
pub const Fingerprint = struct {
    pid: i32,
    comm: []const u8,
    avg_cpu: f64 = 0,
    avg_rss_kb: f64 = 0,
    avg_threads: f64 = 0,
    avg_fd_count: f64 = 0,
    avg_net_conns: f64 = 0,
    dominant_state: []const u8 = "?",
    sample_count: u32 = 0,
};

/// Compare two fingerprints and return a similarity score (0-1)
pub fn similarity(a: *const Fingerprint, b: *const Fingerprint) f64 {
    var score: f64 = 0;
    var factors: f64 = 0;

    // CPU similarity
    if (a.avg_cpu > 0 or b.avg_cpu > 0) {
        const max_cpu = @max(a.avg_cpu, b.avg_cpu);
        if (max_cpu > 0) {
            score += 1.0 - @abs(a.avg_cpu - b.avg_cpu) / max_cpu;
            factors += 1;
        }
    }

    // RSS similarity
    if (a.avg_rss_kb > 0 or b.avg_rss_kb > 0) {
        const max_rss: f64 = @floatFromInt(@max(@as(i64, @intFromFloat(a.avg_rss_kb)), @as(i64, @intFromFloat(b.avg_rss_kb))));
        if (max_rss > 0) {
            score += 1.0 - @abs(a.avg_rss_kb - b.avg_rss_kb) / max_rss;
            factors += 1;
        }
    }

    // Thread count similarity
    if (a.avg_threads > 0 or b.avg_threads > 0) {
        const max_threads = @max(a.avg_threads, b.avg_threads);
        if (max_threads > 0) {
            score += 1.0 - @abs(a.avg_threads - b.avg_threads) / max_threads;
            factors += 1;
        }
    }

    if (factors == 0) return 0;
    return score / factors;
}
