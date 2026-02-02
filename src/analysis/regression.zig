/// Regression detection: compare current fingerprints against baselines
const std = @import("std");
const reader_mod = @import("../store/reader.zig");

pub const RegressionFinding = struct {
    comm: []const u8,
    metric: []const u8,
    baseline_val: f64,
    current_val: f64,
    change_pct: f64,
};

/// Compare a current fingerprint against a baseline.
/// Returns findings where any metric changed by more than threshold_pct.
pub fn compareFingerprints(
    baseline: reader_mod.Reader.Baseline,
    current: reader_mod.Reader.Fingerprint,
    threshold_pct: f64,
) [6]?RegressionFinding {
    var findings: [6]?RegressionFinding = .{null} ** 6;
    var idx: usize = 0;

    const checks = [_]struct { name: []const u8, base: f64, cur: f64 }{
        .{ .name = "avg_cpu", .base = baseline.avg_cpu, .cur = current.avg_cpu },
        .{ .name = "avg_rss_kb", .base = baseline.avg_rss_kb, .cur = current.avg_rss_kb },
        .{ .name = "avg_threads", .base = baseline.avg_threads, .cur = current.avg_threads },
        .{ .name = "avg_fd_count", .base = baseline.avg_fd_count, .cur = current.avg_fd_count },
        .{ .name = "avg_net_conns", .base = baseline.avg_net_conns, .cur = current.avg_net_conns },
    };

    for (checks) |check| {
        if (idx >= findings.len) break;
        if (check.base == 0 and check.cur == 0) continue;

        var change: f64 = 0;
        if (check.base != 0) {
            change = ((check.cur - check.base) / @abs(check.base)) * 100.0;
        } else if (check.cur != 0) {
            change = 100.0; // from 0 to something is infinite change, cap at 100%
        }

        if (@abs(change) >= threshold_pct) {
            findings[idx] = .{
                .comm = baseline.comm,
                .metric = check.name,
                .baseline_val = check.base,
                .current_val = check.cur,
                .change_pct = change,
            };
            idx += 1;
        }
    }

    // Also check phase change
    if (idx < findings.len) {
        if (!std.mem.eql(u8, baseline.dominant_phase, current.dominant_phase)) {
            findings[idx] = .{
                .comm = baseline.comm,
                .metric = "dominant_phase",
                .baseline_val = 0,
                .current_val = 0,
                .change_pct = 100.0,
            };
        }
    }

    return findings;
}

const testing = std.testing;

fn countFindings(results: [6]?RegressionFinding) usize {
    var count: usize = 0;
    for (results) |r| {
        if (r != null) count += 1;
    }
    return count;
}

test "compareFingerprints: no change produces no findings" {
    const baseline = reader_mod.Reader.Baseline{
        .comm = "claude",
        .version = "1.0",
        .avg_cpu = 50.0,
        .avg_rss_kb = 100000,
        .avg_threads = 10,
        .avg_fd_count = 50,
        .avg_net_conns = 5,
        .dominant_phase = "active",
        .sample_count = 100,
        .created_at = 1000,
        .label = "test",
    };
    const current = reader_mod.Reader.Fingerprint{
        .pid = 42,
        .comm = "claude",
        .avg_cpu = 50.0,
        .avg_rss_kb = 100000,
        .avg_threads = 10,
        .avg_fd_count = 50,
        .avg_net_conns = 5,
        .dominant_phase = "active",
        .sample_count = 100,
        .updated_at = 2000,
    };
    const findings = compareFingerprints(baseline, current, 20.0);
    try testing.expectEqual(@as(usize, 0), countFindings(findings));
}

test "compareFingerprints: large CPU change detected" {
    const baseline = reader_mod.Reader.Baseline{
        .comm = "claude",
        .version = "1.0",
        .avg_cpu = 10.0,
        .avg_rss_kb = 100000,
        .avg_threads = 10,
        .avg_fd_count = 50,
        .avg_net_conns = 5,
        .dominant_phase = "active",
        .sample_count = 100,
        .created_at = 1000,
        .label = "test",
    };
    const current = reader_mod.Reader.Fingerprint{
        .pid = 42,
        .comm = "claude",
        .avg_cpu = 50.0, // 400% increase
        .avg_rss_kb = 100000,
        .avg_threads = 10,
        .avg_fd_count = 50,
        .avg_net_conns = 5,
        .dominant_phase = "active",
        .sample_count = 100,
        .updated_at = 2000,
    };
    const findings = compareFingerprints(baseline, current, 20.0);
    try testing.expect(countFindings(findings) >= 1);
    try testing.expectEqualStrings("avg_cpu", findings[0].?.metric);
}

test "compareFingerprints: phase change detected" {
    const baseline = reader_mod.Reader.Baseline{
        .comm = "claude",
        .version = "1.0",
        .avg_cpu = 50.0,
        .avg_rss_kb = 100000,
        .avg_threads = 10,
        .avg_fd_count = 50,
        .avg_net_conns = 5,
        .dominant_phase = "idle",
        .sample_count = 100,
        .created_at = 1000,
        .label = "test",
    };
    const current = reader_mod.Reader.Fingerprint{
        .pid = 42,
        .comm = "claude",
        .avg_cpu = 50.0,
        .avg_rss_kb = 100000,
        .avg_threads = 10,
        .avg_fd_count = 50,
        .avg_net_conns = 5,
        .dominant_phase = "burst",
        .sample_count = 100,
        .updated_at = 2000,
    };
    const findings = compareFingerprints(baseline, current, 20.0);
    // Should detect phase change
    var found_phase = false;
    for (findings) |f| {
        if (f) |finding| {
            if (std.mem.eql(u8, finding.metric, "dominant_phase")) found_phase = true;
        }
    }
    try testing.expect(found_phase);
}

test "compareFingerprints: both zero produces no finding" {
    const baseline = reader_mod.Reader.Baseline{
        .comm = "test",
        .version = "1.0",
        .avg_cpu = 0,
        .avg_rss_kb = 0,
        .avg_threads = 0,
        .avg_fd_count = 0,
        .avg_net_conns = 0,
        .dominant_phase = "idle",
        .sample_count = 0,
        .created_at = 0,
        .label = "test",
    };
    const current = reader_mod.Reader.Fingerprint{
        .pid = 1,
        .comm = "test",
        .avg_cpu = 0,
        .avg_rss_kb = 0,
        .avg_threads = 0,
        .avg_fd_count = 0,
        .avg_net_conns = 0,
        .dominant_phase = "idle",
        .sample_count = 0,
        .updated_at = 0,
    };
    const findings = compareFingerprints(baseline, current, 20.0);
    try testing.expectEqual(@as(usize, 0), countFindings(findings));
}
