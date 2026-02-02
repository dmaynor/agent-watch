const std = @import("std");
const reader_mod = @import("../store/reader.zig");
const types = @import("../data/types.zig");
const memory_leak = @import("memory_leak.zig");
const pipeline = @import("pipeline.zig");
const security = @import("security.zig");
const network = @import("network.zig");

const Allocator = std.mem.Allocator;

fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

fn printLine(comptime text: []const u8) void {
    std.fs.File.stdout().writeAll(text ++ "\n") catch {};
}

/// Generate a full offline analysis report from the database
pub fn generateReport(alloc: Allocator, reader: *reader_mod.Reader) void {
    printLine("=================================================================");
    printLine("  agent-watch: Offline Analysis Report");
    printLine("=================================================================");
    printLine("");

    // 1. Per-agent cost summary
    reportCostSummary(alloc, reader);

    // 2. Memory leak candidates
    reportMemoryLeaks(alloc, reader);

    // 3. Anomaly / alert summary
    reportAlerts(alloc, reader);

    // 4. Security findings
    reportSecurity(alloc, reader);

    // 5. Behavioral fingerprints
    reportFingerprints(alloc, reader);

    // 6. Phase distribution
    reportPhaseDistribution(alloc, reader);

    printLine("=================================================================");
    printLine("  End of Report");
    printLine("=================================================================");
}

fn reportCostSummary(alloc: Allocator, reader: *reader_mod.Reader) void {
    printLine("--- Per-Agent Cost Summary ---");
    printLine("");

    const pids = reader.getDistinctPids() catch {
        printLine("  (no data)");
        return;
    };
    defer alloc.free(pids);

    if (pids.len == 0) {
        printLine("  (no agents found)");
        printLine("");
        return;
    }

    printStdout("  {s:<8} {s:<16} {s:>10} {s:>12} {s:>10} {s:>10}\n", .{
        "PID", "COMM", "SAMPLES", "CPU*TIME", "AVG_RSS_MB", "ELAPSED",
    });

    for (pids) |pid| {
        const samples = reader.getAllSamplesForPid(pid) catch continue;
        defer alloc.free(samples);
        if (samples.len == 0) continue;

        var total_cpu: f64 = 0;
        var total_rss: f64 = 0;
        var comm: []const u8 = "-";
        var max_etimes: i64 = 0;

        for (samples) |s| {
            total_cpu += s.cpu;
            const rss_f: f64 = @floatFromInt(s.rss_kb);
            total_rss += rss_f;
            comm = s.comm;
            if (s.etimes > max_etimes) max_etimes = s.etimes;
        }

        const n: f64 = @floatFromInt(samples.len);
        const avg_rss_mb = (total_rss / n) / 1024.0;

        const comm_slice = if (comm.len > 15) comm[0..15] else comm;
        printStdout("  {d:<8} {s:<16} {d:>10} {d:>11.1} {d:>9.1} {d:>9}s\n", .{
            pid, comm_slice, samples.len, total_cpu, avg_rss_mb, max_etimes,
        });
    }
    printLine("");
}

fn reportMemoryLeaks(alloc: Allocator, reader: *reader_mod.Reader) void {
    printLine("--- Memory Leak Candidates ---");
    printLine("");

    const pids = reader.getDistinctPids() catch {
        printLine("  (no data)");
        return;
    };
    defer alloc.free(pids);

    var found_any = false;

    for (pids) |pid| {
        const samples = reader.getAllSamplesForPid(pid) catch continue;
        defer alloc.free(samples);
        if (samples.len < 10) continue;

        // Build RSS array for leak detection
        const rss_values = alloc.alloc(f64, samples.len) catch continue;
        defer alloc.free(rss_values);
        for (samples, 0..) |s, i| {
            rss_values[i] = @floatFromInt(s.rss_kb);
        }

        if (memory_leak.detectLeak(rss_values, 1.0)) |leak| {
            if (!found_any) {
                printStdout("  {s:<8} {s:>12} {s:>12} {s:>10} {s:>8}\n", .{
                    "PID", "START_KB", "END_KB", "GROWTH%", "R²",
                });
                found_any = true;
            }
            printStdout("  {d:<8} {d:>11.0} {d:>11.0} {d:>9.1} {d:>7.3}\n", .{
                pid, leak.start_rss_kb, leak.end_rss_kb, leak.growth_percent, leak.r_squared,
            });
        }
    }

    if (!found_any) {
        printLine("  No memory leaks detected.");
    }
    printLine("");
}

fn reportAlerts(alloc: Allocator, reader: *reader_mod.Reader) void {
    printLine("--- Alert Summary ---");
    printLine("");

    const alerts = reader.getRecentAlerts(200) catch {
        printLine("  (no data)");
        return;
    };
    defer types.Alert.freeSlice(alloc, alerts);

    if (alerts.len == 0) {
        printLine("  No alerts recorded.");
        printLine("");
        return;
    }

    // Count by severity
    var critical: usize = 0;
    var warning: usize = 0;
    var info: usize = 0;
    for (alerts) |a| {
        switch (a.severity) {
            .critical => critical += 1,
            .warning => warning += 1,
            .info => info += 1,
        }
    }

    printStdout("  Total: {d}  (critical: {d}, warning: {d}, info: {d})\n", .{
        alerts.len, critical, warning, info,
    });
    printLine("");

    // Show latest 20
    const show_count = @min(alerts.len, 20);
    printStdout("  Latest {d} alerts:\n", .{show_count});
    for (alerts[0..show_count]) |alert| {
        var ts_buf: [32]u8 = undefined;
        const ts_str = types.formatTimestamp(&ts_buf, alert.ts) catch "?";
        printStdout("    [{s}] pid={d} {s}: {s} ({s})\n", .{
            ts_str, alert.pid, alert.severity.toString(), alert.message, alert.category,
        });
    }
    printLine("");
}

fn reportSecurity(alloc: Allocator, reader: *reader_mod.Reader) void {
    printLine("--- Security Findings ---");
    printLine("");

    const pids = reader.getDistinctPids() catch {
        printLine("  (no data)");
        return;
    };
    defer alloc.free(pids);

    var total_fd_findings: usize = 0;
    var total_conn_findings: usize = 0;

    for (pids) |pid| {
        // Audit FDs
        const fds = reader.getLatestFdsForPid(pid) catch continue;
        defer types.FdRecord.freeSlice(alloc, fds);
        if (fds.len > 0) {
            const fd_findings = security.auditFds(fds);
            for (fd_findings) |finding_opt| {
                const finding = finding_opt orelse break;
                printStdout("  [FD]  pid={d} [{s}] {s}: {s}\n", .{
                    pid, finding.severity.toString(), finding.category, finding.message,
                });
                total_fd_findings += 1;
            }
        }

        // Audit connections
        const conns = reader.getLatestConnectionsForPid(pid) catch continue;
        defer types.NetConnection.freeSlice(alloc, conns);
        if (conns.len > 0) {
            const conn_findings = security.auditConnections(conns);
            for (conn_findings) |finding_opt| {
                const finding = finding_opt orelse break;
                printStdout("  [NET] pid={d} [{s}] {s}: {s}\n", .{
                    pid, finding.severity.toString(), finding.category, finding.message,
                });
                total_conn_findings += 1;
            }
        }
    }

    if (total_fd_findings == 0 and total_conn_findings == 0) {
        printLine("  No security findings.");
    } else {
        printStdout("\n  Total: {d} FD findings, {d} network findings\n", .{ total_fd_findings, total_conn_findings });
    }
    printLine("");
}

fn reportFingerprints(alloc: Allocator, reader: *reader_mod.Reader) void {
    printLine("--- Behavioral Fingerprints ---");
    printLine("");

    const fingerprints = reader.getFingerprints() catch {
        printLine("  (no data)");
        return;
    };
    defer reader_mod.Reader.Fingerprint.freeSlice(alloc, fingerprints);

    if (fingerprints.len == 0) {
        printLine("  No fingerprints generated yet.");
        printLine("");
        return;
    }

    printStdout("  {s:<8} {s:<14} {s:>8} {s:>10} {s:>8} {s:>6} {s:>6} {s:<8} {s:>7}\n", .{
        "PID", "COMM", "AVG_CPU", "AVG_RSS_MB", "THREADS", "FDS", "CONNS", "PHASE", "SAMPLES",
    });

    for (fingerprints) |fp| {
        const comm_slice = if (fp.comm.len > 13) fp.comm[0..13] else fp.comm;
        const rss_mb = fp.avg_rss_kb / 1024.0;
        printStdout("  {d:<8} {s:<14} {d:>7.1} {d:>9.1} {d:>7.0} {d:>5.0} {d:>5.0} {s:<8} {d:>7}\n", .{
            fp.pid, comm_slice, fp.avg_cpu, rss_mb, fp.avg_threads, fp.avg_fd_count, fp.avg_net_conns,
            if (fp.dominant_phase.len > 7) fp.dominant_phase[0..7] else fp.dominant_phase,
            fp.sample_count,
        });
    }
    printLine("");
}

fn reportPhaseDistribution(alloc: Allocator, reader: *reader_mod.Reader) void {
    printLine("--- Phase Distribution ---");
    printLine("");

    const pids = reader.getDistinctPids() catch {
        printLine("  (no data)");
        return;
    };
    defer alloc.free(pids);

    if (pids.len == 0) {
        printLine("  (no agents found)");
        printLine("");
        return;
    }

    printStdout("  {s:<8} {s:<16} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{
        "PID", "COMM", "IDLE%", "ACTIVE%", "BURST%", "SAMPLES",
    });

    for (pids) |pid| {
        const samples = reader.getAllSamplesForPid(pid) catch continue;
        defer alloc.free(samples);
        if (samples.len == 0) continue;

        var idle: usize = 0;
        var active: usize = 0;
        var burst: usize = 0;
        var comm: []const u8 = "-";

        for (samples) |s| {
            const phase = pipeline.detectPhase(s.cpu, s.stat);
            switch (phase) {
                .idle => idle += 1,
                .active => active += 1,
                .burst => burst += 1,
            }
            comm = s.comm;
        }

        const n: f64 = @floatFromInt(samples.len);
        const idle_pct = @as(f64, @floatFromInt(idle)) / n * 100.0;
        const active_pct = @as(f64, @floatFromInt(active)) / n * 100.0;
        const burst_pct = @as(f64, @floatFromInt(burst)) / n * 100.0;

        const comm_slice = if (comm.len > 15) comm[0..15] else comm;
        printStdout("  {d:<8} {s:<16} {d:>7.1} {d:>7.1} {d:>7.1} {d:>8}\n", .{
            pid, comm_slice, idle_pct, active_pct, burst_pct, samples.len,
        });
    }
    printLine("");
}
