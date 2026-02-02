const std = @import("std");
const types = @import("../data/types.zig");

/// Alert thresholds
pub const Thresholds = struct {
    cpu_warning: f64 = 80.0,
    cpu_critical: f64 = 95.0,
    rss_warning_mb: f64 = 2048.0,
    rss_critical_mb: f64 = 4096.0,
    fd_warning: i32 = 1000,
    fd_critical: i32 = 5000,
    thread_warning: i32 = 100,
    thread_critical: i32 = 500,
};

pub const AlertCheck = struct {
    severity: types.Alert.Severity,
    category: []const u8,
    message: []const u8,
    value: f64,
    threshold: f64,
};

/// Evaluate a process sample against thresholds
pub fn evaluate(
    sample: types.ProcessSample,
    status: ?types.StatusRecord,
    fd_count: usize,
    thresholds: Thresholds,
) [8]?AlertCheck {
    var alerts: [8]?AlertCheck = .{ null, null, null, null, null, null, null, null };
    var idx: usize = 0;

    // CPU alerts
    if (sample.cpu >= thresholds.cpu_critical) {
        alerts[idx] = .{
            .severity = .critical,
            .category = "cpu",
            .message = "CPU usage critical",
            .value = sample.cpu,
            .threshold = thresholds.cpu_critical,
        };
        idx += 1;
    } else if (sample.cpu >= thresholds.cpu_warning) {
        alerts[idx] = .{
            .severity = .warning,
            .category = "cpu",
            .message = "CPU usage high",
            .value = sample.cpu,
            .threshold = thresholds.cpu_warning,
        };
        idx += 1;
    }

    // RSS alerts
    const rss_mb = @as(f64, @floatFromInt(sample.rss_kb)) / 1024.0;
    if (rss_mb >= thresholds.rss_critical_mb) {
        alerts[idx] = .{
            .severity = .critical,
            .category = "memory",
            .message = "RSS critical",
            .value = rss_mb,
            .threshold = thresholds.rss_critical_mb,
        };
        idx += 1;
    } else if (rss_mb >= thresholds.rss_warning_mb) {
        alerts[idx] = .{
            .severity = .warning,
            .category = "memory",
            .message = "RSS high",
            .value = rss_mb,
            .threshold = thresholds.rss_warning_mb,
        };
        idx += 1;
    }

    // FD alerts
    const fd_i32: i32 = @intCast(@min(fd_count, @as(usize, @intCast(std.math.maxInt(i32)))));
    if (fd_i32 >= thresholds.fd_critical) {
        alerts[idx] = .{
            .severity = .critical,
            .category = "fd",
            .message = "FD count critical",
            .value = @floatFromInt(fd_i32),
            .threshold = @floatFromInt(thresholds.fd_critical),
        };
        idx += 1;
    } else if (fd_i32 >= thresholds.fd_warning) {
        alerts[idx] = .{
            .severity = .warning,
            .category = "fd",
            .message = "FD count high",
            .value = @floatFromInt(fd_i32),
            .threshold = @floatFromInt(thresholds.fd_warning),
        };
        idx += 1;
    }

    // Thread alerts
    if (status) |s| {
        if (s.threads >= thresholds.thread_critical) {
            alerts[idx] = .{
                .severity = .critical,
                .category = "threads",
                .message = "Thread count critical",
                .value = @floatFromInt(s.threads),
                .threshold = @floatFromInt(thresholds.thread_critical),
            };
            idx += 1;
        } else if (s.threads >= thresholds.thread_warning) {
            alerts[idx] = .{
                .severity = .warning,
                .category = "threads",
                .message = "Thread count high",
                .value = @floatFromInt(s.threads),
                .threshold = @floatFromInt(thresholds.thread_warning),
            };
            idx += 1;
        }
    }

    return alerts;
}

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");

fn countAlerts(results: [8]?AlertCheck) usize {
    var count: usize = 0;
    for (results) |r| {
        if (r != null) count += 1;
    }
    return count;
}

test "evaluate: no alerts below thresholds" {
    const sample = helpers.makeSample(.{ .cpu = 10.0, .rss_kb = 50000 });
    const results = evaluate(sample, null, 50, .{});
    try testing.expectEqual(@as(usize, 0), countAlerts(results));
}

test "evaluate: CPU warning" {
    const sample = helpers.makeSample(.{ .cpu = 85.0, .rss_kb = 50000 });
    const results = evaluate(sample, null, 50, .{});
    try testing.expectEqual(@as(usize, 1), countAlerts(results));
    try testing.expectEqual(types.Alert.Severity.warning, results[0].?.severity);
    try testing.expectEqualStrings("cpu", results[0].?.category);
}

test "evaluate: CPU critical" {
    const sample = helpers.makeSample(.{ .cpu = 97.0, .rss_kb = 50000 });
    const results = evaluate(sample, null, 50, .{});
    try testing.expectEqual(@as(usize, 1), countAlerts(results));
    try testing.expectEqual(types.Alert.Severity.critical, results[0].?.severity);
}

test "evaluate: RSS warning" {
    // 2048 MB = 2097152 KB
    const sample = helpers.makeSample(.{ .cpu = 5.0, .rss_kb = 2200000 });
    const results = evaluate(sample, null, 50, .{});
    try testing.expectEqual(@as(usize, 1), countAlerts(results));
    try testing.expectEqualStrings("memory", results[0].?.category);
}

test "evaluate: FD warning" {
    const sample = helpers.makeSample(.{ .cpu = 5.0, .rss_kb = 50000 });
    const results = evaluate(sample, null, 1500, .{});
    try testing.expectEqual(@as(usize, 1), countAlerts(results));
    try testing.expectEqualStrings("fd", results[0].?.category);
}

test "evaluate: thread warning with status" {
    const sample = helpers.makeSample(.{ .cpu = 5.0, .rss_kb = 50000 });
    const status = helpers.makeStatus(.{ .threads = 150 });
    const results = evaluate(sample, status, 50, .{});
    try testing.expectEqual(@as(usize, 1), countAlerts(results));
    try testing.expectEqualStrings("threads", results[0].?.category);
}

test "evaluate: multiple alerts simultaneously" {
    const sample = helpers.makeSample(.{ .cpu = 97.0, .rss_kb = 5000000 });
    const status = helpers.makeStatus(.{ .threads = 600 });
    const results = evaluate(sample, status, 6000, .{});
    // CPU critical + RSS critical + FD critical + thread critical
    try testing.expectEqual(@as(usize, 4), countAlerts(results));
}

test "evaluate: thread critical" {
    const sample = helpers.makeSample(.{ .cpu = 5.0, .rss_kb = 50000 });
    const status = helpers.makeStatus(.{ .threads = 600 });
    const results = evaluate(sample, status, 50, .{});
    try testing.expectEqual(@as(usize, 1), countAlerts(results));
    try testing.expectEqual(types.Alert.Severity.critical, results[0].?.severity);
}
