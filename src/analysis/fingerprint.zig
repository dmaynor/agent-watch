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

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");

test "similarity: identical fingerprints score 1.0" {
    const a = Fingerprint{ .pid = 1, .comm = "test", .avg_cpu = 50.0, .avg_rss_kb = 1000, .avg_threads = 10 };
    const b = Fingerprint{ .pid = 2, .comm = "test", .avg_cpu = 50.0, .avg_rss_kb = 1000, .avg_threads = 10 };
    try helpers.expectApproxEqual(1.0, similarity(&a, &b), 0.001);
}

test "similarity: completely different fingerprints score near 0" {
    const a = Fingerprint{ .pid = 1, .comm = "test", .avg_cpu = 1.0, .avg_rss_kb = 100, .avg_threads = 1 };
    const b = Fingerprint{ .pid = 2, .comm = "test", .avg_cpu = 100.0, .avg_rss_kb = 100000, .avg_threads = 100 };
    const s = similarity(&a, &b);
    try testing.expect(s < 0.2);
}

test "similarity: all zeros returns 0" {
    const a = Fingerprint{ .pid = 1, .comm = "test" };
    const b = Fingerprint{ .pid = 2, .comm = "test" };
    try helpers.expectApproxEqual(0.0, similarity(&a, &b), 0.001);
}
