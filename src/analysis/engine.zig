const std = @import("std");
const types = @import("../data/types.zig");
const writer_mod = @import("../store/writer.zig");
const reader_mod = @import("../store/reader.zig");
const timeseries = @import("timeseries.zig");
const anomaly = @import("anomaly.zig");
const memory_leak = @import("memory_leak.zig");
const pipeline = @import("pipeline.zig");
const context_switch = @import("context_switch.zig");
const alerts_mod = @import("alerts.zig");
const regression = @import("regression.zig");

const Allocator = std.mem.Allocator;

/// Per-PID analysis state accumulated across collection ticks
const PidState = struct {
    cpu_stats: timeseries.RollingStats,
    rss_stats: timeseries.RollingStats,
    rss_history: std.ArrayList(f64),
    prev_vol_ctx: i64 = 0,
    prev_nvol_ctx: i64 = 0,
    prev_ts: i64 = 0,
    // Running fingerprint accumulators
    cpu_sum: f64 = 0,
    rss_sum: f64 = 0,
    thread_sum: f64 = 0,
    fd_sum: f64 = 0,
    net_sum: f64 = 0,
    sample_count: u32 = 0,
    phase_idle: u32 = 0,
    phase_active: u32 = 0,
    phase_burst: u32 = 0,
    comm: []const u8 = "",

    fn deinit(self: *PidState, alloc: Allocator) void {
        self.cpu_stats.deinit();
        self.rss_stats.deinit();
        self.rss_history.deinit(alloc);
        if (self.comm.len > 0) alloc.free(self.comm);
    }
};

/// Central analysis orchestrator: runs all analysis after each collection tick
pub const AnalysisEngine = struct {
    alloc: Allocator,
    per_pid: std.AutoHashMap(i32, PidState),
    thresholds: alerts_mod.Thresholds,
    writer: *writer_mod.Writer,
    baselines: []reader_mod.Reader.Baseline,

    pub fn init(alloc: Allocator, writer: *writer_mod.Writer) AnalysisEngine {
        return .{
            .alloc = alloc,
            .per_pid = std.AutoHashMap(i32, PidState).init(alloc),
            .thresholds = .{},
            .writer = writer,
            .baselines = &.{},
        };
    }

    /// Load baselines from database for live regression detection
    pub fn loadBaselines(self: *AnalysisEngine, reader: *reader_mod.Reader) void {
        if (self.baselines.len > 0) reader_mod.Reader.Baseline.freeSlice(self.alloc, self.baselines);
        self.baselines = reader.getBaselines() catch &.{};
    }

    pub fn deinit(self: *AnalysisEngine) void {
        var iter = self.per_pid.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.per_pid.deinit();
        if (self.baselines.len > 0) reader_mod.Reader.Baseline.freeSlice(self.alloc, self.baselines);
    }

    /// Process data from one collection tick
    pub fn processTickData(
        self: *AnalysisEngine,
        samples: []const types.ProcessSample,
        statuses: []const types.StatusRecord,
        fd_counts: []const FdCount,
        conn_counts: []const ConnCount,
        timestamp: i64,
    ) void {
        for (samples) |sample| {
            const state = self.getOrCreatePidState(sample.pid, sample.comm) orelse continue;

            // Find matching status and counts for this PID
            const status = findStatus(statuses, sample.pid);
            const fd_count = findFdCount(fd_counts, sample.pid);
            const conn_count = findConnCount(conn_counts, sample.pid);

            // 1. Threshold alerts
            const alert_checks = alerts_mod.evaluate(sample, status, fd_count, self.thresholds);
            for (alert_checks) |check_opt| {
                const check = check_opt orelse break;
                self.writer.writeAlert(.{
                    .ts = timestamp,
                    .pid = sample.pid,
                    .severity = check.severity,
                    .category = check.category,
                    .message = check.message,
                    .value = check.value,
                    .threshold = check.threshold,
                }) catch {};
            }

            // 2. Push to rolling stats
            state.cpu_stats.push(sample.cpu);
            const rss_f: f64 = @floatFromInt(sample.rss_kb);
            state.rss_stats.push(rss_f);

            // 3. Z-score anomaly detection on CPU
            if (state.cpu_stats.count >= 10 and anomaly.zScoreAnomaly(&state.cpu_stats, sample.cpu, 3.0)) {
                self.writer.writeAlert(.{
                    .ts = timestamp,
                    .pid = sample.pid,
                    .severity = .warning,
                    .category = "anomaly:cpu",
                    .message = "CPU z-score anomaly detected",
                    .value = sample.cpu,
                    .threshold = state.cpu_stats.avg() + 3.0 * state.cpu_stats.stddev(),
                }) catch {};
            }

            // 4. Memory leak detection (requires >= 30 samples)
            state.rss_history.append(self.alloc, rss_f) catch {};
            if (state.rss_history.items.len >= 30) {
                if (memory_leak.detectLeak(state.rss_history.items, 10.0)) |leak| {
                    self.writer.writeAlert(.{
                        .ts = timestamp,
                        .pid = sample.pid,
                        .severity = .warning,
                        .category = "memory_leak",
                        .message = "Potential memory leak detected",
                        .value = leak.slope_kb_per_sample,
                        .threshold = 10.0,
                    }) catch {};
                }
            }

            // 5. Phase detection
            const phase = pipeline.detectPhase(sample.cpu, sample.stat);
            switch (phase) {
                .idle => state.phase_idle += 1,
                .active => state.phase_active += 1,
                .burst => state.phase_burst += 1,
            }

            // 6. Context switch rate
            if (status) |s| {
                if (state.prev_ts > 0) {
                    const interval: f64 = @floatFromInt(timestamp - state.prev_ts);
                    if (interval > 0) {
                        const rate = context_switch.calculateRate(
                            state.prev_vol_ctx,
                            state.prev_nvol_ctx,
                            s.voluntary_ctxt_switches,
                            s.nonvoluntary_ctxt_switches,
                            interval,
                        );
                        // Alert on high scheduling pressure
                        if (rate.scheduling_pressure > 0.5) {
                            self.writer.writeAlert(.{
                                .ts = timestamp,
                                .pid = sample.pid,
                                .severity = .info,
                                .category = "scheduling",
                                .message = "High involuntary context switch ratio",
                                .value = rate.scheduling_pressure,
                                .threshold = 0.5,
                            }) catch {};
                        }
                    }
                }
                state.prev_vol_ctx = s.voluntary_ctxt_switches;
                state.prev_nvol_ctx = s.nonvoluntary_ctxt_switches;
            }
            state.prev_ts = timestamp;

            // 7. Update fingerprint running averages
            state.cpu_sum += sample.cpu;
            state.rss_sum += rss_f;
            if (status) |s| {
                state.thread_sum += @floatFromInt(s.threads);
            }
            state.fd_sum += @floatFromInt(fd_count);
            state.net_sum += @floatFromInt(conn_count);
            state.sample_count += 1;

            // Write updated fingerprint to DB periodically (every 10 samples)
            if (state.sample_count % 10 == 0) {
                self.writeFingerprint(sample.pid, state);
            }
        }
    }

    fn getOrCreatePidState(self: *AnalysisEngine, pid: i32, comm: []const u8) ?*PidState {
        if (self.per_pid.getPtr(pid)) |existing| return existing;

        var cpu_stats = timeseries.RollingStats.init(self.alloc, 120) catch return null;
        const rss_stats = timeseries.RollingStats.init(self.alloc, 120) catch {
            cpu_stats.deinit();
            return null;
        };

        const comm_copy = self.alloc.dupe(u8, comm) catch return null;

        self.per_pid.put(pid, .{
            .cpu_stats = cpu_stats,
            .rss_stats = rss_stats,
            .rss_history = .empty,
            .comm = comm_copy,
        }) catch return null;

        return self.per_pid.getPtr(pid);
    }

    fn writeFingerprint(self: *AnalysisEngine, pid: i32, state: *const PidState) void {
        if (state.sample_count == 0) return;
        const n: f64 = @floatFromInt(state.sample_count);
        const dominant = dominantPhase(state);
        const fp = reader_mod.Reader.Fingerprint{
            .pid = pid,
            .comm = state.comm,
            .avg_cpu = state.cpu_sum / n,
            .avg_rss_kb = state.rss_sum / n,
            .avg_threads = state.thread_sum / n,
            .avg_fd_count = state.fd_sum / n,
            .avg_net_conns = state.net_sum / n,
            .dominant_phase = dominant,
            .sample_count = @intCast(state.sample_count),
            .updated_at = std.time.timestamp(),
        };
        self.writer.writeFingerprint(.{
            .pid = fp.pid,
            .comm = fp.comm,
            .avg_cpu = fp.avg_cpu,
            .avg_rss_kb = fp.avg_rss_kb,
            .avg_threads = fp.avg_threads,
            .avg_fd_count = fp.avg_fd_count,
            .avg_net_conns = fp.avg_net_conns,
            .dominant_phase = fp.dominant_phase,
            .sample_count = state.sample_count,
            .updated_at = fp.updated_at,
        }) catch {};

        // Live regression detection against baselines
        self.checkRegression(pid, fp);
    }

    fn checkRegression(self: *AnalysisEngine, pid: i32, fp: reader_mod.Reader.Fingerprint) void {
        if (self.baselines.len == 0) return;

        for (self.baselines) |baseline| {
            if (!std.mem.eql(u8, baseline.comm, fp.comm)) continue;

            const findings = regression.compareFingerprints(baseline, fp, 20.0);
            for (findings) |finding_opt| {
                const finding = finding_opt orelse break;
                self.writer.writeAlert(.{
                    .ts = std.time.timestamp(),
                    .pid = pid,
                    .severity = if (@abs(finding.change_pct) >= 50.0) .warning else .info,
                    .category = "regression",
                    .message = finding.metric,
                    .value = finding.current_val,
                    .threshold = finding.baseline_val,
                }) catch {};
            }
        }
    }

    fn dominantPhase(state: *const PidState) []const u8 {
        if (state.phase_burst >= state.phase_active and state.phase_burst >= state.phase_idle) return "burst";
        if (state.phase_active >= state.phase_idle) return "active";
        return "idle";
    }

    fn findStatus(statuses: []const types.StatusRecord, pid: i32) ?types.StatusRecord {
        for (statuses) |s| {
            if (s.pid == pid) return s;
        }
        return null;
    }

    fn findFdCount(counts: []const FdCount, pid: i32) usize {
        for (counts) |c| {
            if (c.pid == pid) return c.count;
        }
        return 0;
    }

    fn findConnCount(counts: []const ConnCount, pid: i32) usize {
        for (counts) |c| {
            if (c.pid == pid) return c.count;
        }
        return 0;
    }
};

pub const FdCount = struct {
    pid: i32,
    count: usize,
};

pub const ConnCount = struct {
    pid: i32,
    count: usize,
};

const testing = std.testing;
const db_mod = @import("../store/db.zig");
const helpers = @import("../testing/helpers.zig");

test "findStatus: found" {
    const statuses = [_]types.StatusRecord{
        helpers.makeStatus(.{ .pid = 10 }),
        helpers.makeStatus(.{ .pid = 42, .threads = 8 }),
    };
    const result = AnalysisEngine.findStatus(&statuses, 42);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 8), result.?.threads);
}

test "findStatus: not found" {
    const statuses = [_]types.StatusRecord{helpers.makeStatus(.{ .pid = 10 })};
    try testing.expectEqual(@as(?types.StatusRecord, null), AnalysisEngine.findStatus(&statuses, 99));
}

test "findFdCount: found" {
    const counts = [_]FdCount{ .{ .pid = 42, .count = 15 }, .{ .pid = 10, .count = 3 } };
    try testing.expectEqual(@as(usize, 15), AnalysisEngine.findFdCount(&counts, 42));
}

test "findFdCount: not found returns 0" {
    const counts = [_]FdCount{.{ .pid = 10, .count = 3 }};
    try testing.expectEqual(@as(usize, 0), AnalysisEngine.findFdCount(&counts, 99));
}

test "findConnCount: found" {
    const counts = [_]ConnCount{ .{ .pid = 42, .count = 5 } };
    try testing.expectEqual(@as(usize, 5), AnalysisEngine.findConnCount(&counts, 42));
}

test "dominantPhase: idle" {
    const state = PidState{
        .cpu_stats = undefined,
        .rss_stats = undefined,
        .rss_history = .empty,
        .phase_idle = 10,
        .phase_active = 3,
        .phase_burst = 2,
    };
    try testing.expectEqualStrings("idle", AnalysisEngine.dominantPhase(&state));
}

test "dominantPhase: burst" {
    const state = PidState{
        .cpu_stats = undefined,
        .rss_stats = undefined,
        .rss_history = .empty,
        .phase_idle = 2,
        .phase_active = 3,
        .phase_burst = 10,
    };
    try testing.expectEqualStrings("burst", AnalysisEngine.dominantPhase(&state));
}

test "dominantPhase: active" {
    const state = PidState{
        .cpu_stats = undefined,
        .rss_stats = undefined,
        .rss_history = .empty,
        .phase_idle = 2,
        .phase_active = 10,
        .phase_burst = 3,
    };
    try testing.expectEqualStrings("active", AnalysisEngine.dominantPhase(&state));
}

test "AnalysisEngine: init and deinit" {
    var db = try db_mod.Db.open(":memory:");
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var engine = AnalysisEngine.init(testing.allocator, &writer);
    defer engine.deinit();
}

test "AnalysisEngine: processTickData creates PidState" {
    var db = try db_mod.Db.open(":memory:");
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var engine = AnalysisEngine.init(testing.allocator, &writer);
    defer engine.deinit();

    const samples = [_]types.ProcessSample{helpers.makeSample(.{ .pid = 42, .cpu = 25.0 })};
    const statuses = [_]types.StatusRecord{helpers.makeStatus(.{ .pid = 42 })};
    const fd_counts = [_]FdCount{.{ .pid = 42, .count = 10 }};
    const conn_counts = [_]ConnCount{.{ .pid = 42, .count = 2 }};

    engine.processTickData(&samples, &statuses, &fd_counts, &conn_counts, 1000);

    // PidState should now exist for pid 42
    const state = engine.per_pid.getPtr(42);
    try testing.expect(state != null);
    try testing.expectEqual(@as(u32, 1), state.?.sample_count);
}

test "AnalysisEngine: multiple ticks accumulate" {
    var db = try db_mod.Db.open(":memory:");
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var engine = AnalysisEngine.init(testing.allocator, &writer);
    defer engine.deinit();

    const samples = [_]types.ProcessSample{helpers.makeSample(.{ .pid = 42, .cpu = 10.0 })};
    const empty_statuses = [_]types.StatusRecord{};
    const empty_fds = [_]FdCount{};
    const empty_conns = [_]ConnCount{};

    engine.processTickData(&samples, &empty_statuses, &empty_fds, &empty_conns, 1000);
    engine.processTickData(&samples, &empty_statuses, &empty_fds, &empty_conns, 1005);
    engine.processTickData(&samples, &empty_statuses, &empty_fds, &empty_conns, 1010);

    const state = engine.per_pid.getPtr(42).?;
    try testing.expectEqual(@as(u32, 3), state.sample_count);
    try testing.expectEqual(@as(usize, 3), state.cpu_stats.count);
}
