const std = @import("std");
const db_mod = @import("db.zig");
const types = @import("../data/types.zig");

const Db = db_mod.Db;
const Statement = db_mod.Statement;
const Allocator = std.mem.Allocator;

pub const Reader = struct {
    db: *Db,
    alloc: Allocator,

    pub fn init(db: *Db, alloc: Allocator) Reader {
        return .{ .db = db, .alloc = alloc };
    }

    /// Get all currently-alive agents
    pub fn getAliveAgents(self: *Reader) ![]types.Agent {
        var stmt = try self.db.prepare("SELECT id, pid, comm, args, first_seen, last_seen, alive FROM agent WHERE alive = 1 ORDER BY pid LIMIT 500");
        defer stmt.deinit();

        var agents: std.ArrayList(types.Agent) = .empty;
        errdefer agents.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try agents.append(self.alloc, .{
                .id = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .comm = try self.alloc.dupe(u8, stmt.columnText(2)),
                .args = try self.alloc.dupe(u8, stmt.columnText(3)),
                .first_seen = stmt.columnI64(4),
                .last_seen = stmt.columnI64(5),
                .alive = stmt.columnI32(6) != 0,
            });
        }
        return agents.toOwnedSlice(self.alloc);
    }

    /// Get recent process samples for a PID within time range
    pub fn getSamples(self: *Reader, pid: i32, from_ts: types.Timestamp, to_ts: types.Timestamp) ![]types.ProcessSample {
        var stmt = try self.db.prepare(
            "SELECT ts, pid, user, cpu, mem, rss_kb, stat, etimes, comm, args " ++
                "FROM process_sample WHERE pid = ?1 AND ts >= ?2 AND ts <= ?3 ORDER BY ts",
        );
        defer stmt.deinit();

        try stmt.bindI32(1, pid);
        try stmt.bindI64(2, from_ts);
        try stmt.bindI64(3, to_ts);

        var samples: std.ArrayList(types.ProcessSample) = .empty;
        errdefer samples.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try samples.append(self.alloc, .{
                .ts = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .user = try self.alloc.dupe(u8, stmt.columnText(2)),
                .cpu = stmt.columnF64(3),
                .mem = stmt.columnF64(4),
                .rss_kb = stmt.columnI64(5),
                .stat = try self.alloc.dupe(u8, stmt.columnText(6)),
                .etimes = stmt.columnI64(7),
                .comm = try self.alloc.dupe(u8, stmt.columnText(8)),
                .args = try self.alloc.dupe(u8, stmt.columnText(9)),
            });
        }
        return samples.toOwnedSlice(self.alloc);
    }

    /// Get latest sample per alive agent (for overview table)
    pub fn getLatestSamplesPerAgent(self: *Reader) ![]types.ProcessSample {
        var stmt = try self.db.prepare(
            "SELECT ps.ts, ps.pid, ps.user, ps.cpu, ps.mem, ps.rss_kb, ps.stat, ps.etimes, ps.comm, ps.args " ++
                "FROM process_sample ps INNER JOIN (" ++
                "  SELECT pid, MAX(ts) as max_ts FROM process_sample GROUP BY pid" ++
                ") latest ON ps.pid = latest.pid AND ps.ts = latest.max_ts " ++
                "ORDER BY ps.cpu DESC LIMIT 200",
        );
        defer stmt.deinit();

        var samples: std.ArrayList(types.ProcessSample) = .empty;
        errdefer samples.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try samples.append(self.alloc, .{
                .ts = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .user = try self.alloc.dupe(u8, stmt.columnText(2)),
                .cpu = stmt.columnF64(3),
                .mem = stmt.columnF64(4),
                .rss_kb = stmt.columnI64(5),
                .stat = try self.alloc.dupe(u8, stmt.columnText(6)),
                .etimes = stmt.columnI64(7),
                .comm = try self.alloc.dupe(u8, stmt.columnText(8)),
                .args = try self.alloc.dupe(u8, stmt.columnText(9)),
            });
        }
        return samples.toOwnedSlice(self.alloc);
    }

    /// Get total sample count
    pub fn getSampleCount(self: *Reader) !i64 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM process_sample");
        defer stmt.deinit();
        const result = try stmt.step();
        if (result == .row) return stmt.columnI64(0);
        return 0;
    }

    /// Get recent alerts
    pub fn getRecentAlerts(self: *Reader, limit: i32) ![]types.Alert {
        var stmt = try self.db.prepare(
            "SELECT id, ts, pid, severity, category, message, value, threshold " ++
                "FROM alert ORDER BY ts DESC LIMIT ?1",
        );
        defer stmt.deinit();
        try stmt.bindI32(1, limit);

        var alerts: std.ArrayList(types.Alert) = .empty;
        errdefer alerts.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;

            const sev_str = stmt.columnText(3);
            const severity: types.Alert.Severity = if (std.mem.eql(u8, sev_str, "critical"))
                .critical
            else if (std.mem.eql(u8, sev_str, "warning"))
                .warning
            else
                .info;

            try alerts.append(self.alloc, .{
                .id = stmt.columnI64(0),
                .ts = stmt.columnI64(1),
                .pid = stmt.columnI32(2),
                .severity = severity,
                .category = try self.alloc.dupe(u8, stmt.columnText(4)),
                .message = try self.alloc.dupe(u8, stmt.columnText(5)),
                .value = stmt.columnF64(6),
                .threshold = stmt.columnF64(7),
            });
        }
        return alerts.toOwnedSlice(self.alloc);
    }

    /// Get distinct PIDs from process_sample
    pub fn getDistinctPids(self: *Reader) ![]i32 {
        var stmt = try self.db.prepare("SELECT DISTINCT pid FROM process_sample ORDER BY pid LIMIT 10000");
        defer stmt.deinit();

        var pids: std.ArrayList(i32) = .empty;
        errdefer pids.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try pids.append(self.alloc, stmt.columnI32(0));
        }
        return pids.toOwnedSlice(self.alloc);
    }

    /// Get latest connections per agent
    pub fn getLatestConnectionsPerAgent(self: *Reader) ![]types.NetConnection {
        var stmt = try self.db.prepare(
            "SELECT nc.ts, nc.pid, nc.protocol, nc.local_addr, nc.local_port, nc.remote_addr, nc.remote_port, nc.state " ++
                "FROM net_connection nc INNER JOIN (" ++
                "  SELECT pid, MAX(ts) as max_ts FROM net_connection GROUP BY pid" ++
                ") latest ON nc.pid = latest.pid AND nc.ts = latest.max_ts " ++
                "ORDER BY nc.pid",
        );
        defer stmt.deinit();

        var conns: std.ArrayList(types.NetConnection) = .empty;
        errdefer conns.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try conns.append(self.alloc, .{
                .ts = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .protocol = types.NetConnection.Protocol.fromString(stmt.columnText(2)),
                .local_addr = try self.alloc.dupe(u8, stmt.columnText(3)),
                .local_port = @intCast(stmt.columnI32(4)),
                .remote_addr = try self.alloc.dupe(u8, stmt.columnText(5)),
                .remote_port = @intCast(stmt.columnI32(6)),
                .state = try self.alloc.dupe(u8, stmt.columnText(7)),
            });
        }
        return conns.toOwnedSlice(self.alloc);
    }

    /// Get fingerprints from database
    pub fn getFingerprints(self: *Reader) ![]Fingerprint {
        var stmt = try self.db.prepare(
            "SELECT pid, comm, avg_cpu, avg_rss_kb, avg_threads, avg_fd_count, avg_net_conns, dominant_phase, sample_count, updated_at " ++
                "FROM fingerprint ORDER BY pid",
        );
        defer stmt.deinit();

        var fps: std.ArrayList(Fingerprint) = .empty;
        errdefer fps.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try fps.append(self.alloc, .{
                .pid = stmt.columnI32(0),
                .comm = try self.alloc.dupe(u8, stmt.columnText(1)),
                .avg_cpu = stmt.columnF64(2),
                .avg_rss_kb = stmt.columnF64(3),
                .avg_threads = stmt.columnF64(4),
                .avg_fd_count = stmt.columnF64(5),
                .avg_net_conns = stmt.columnF64(6),
                .dominant_phase = try self.alloc.dupe(u8, stmt.columnText(7)),
                .sample_count = stmt.columnI64(8),
                .updated_at = stmt.columnI64(9),
            });
        }
        return fps.toOwnedSlice(self.alloc);
    }

    /// Get all samples for a PID (for analysis)
    pub fn getAllSamplesForPid(self: *Reader, pid: i32) ![]types.ProcessSample {
        var stmt = try self.db.prepare(
            "SELECT ts, pid, user, cpu, mem, rss_kb, stat, etimes, comm, args " ++
                "FROM process_sample WHERE pid = ?1 ORDER BY ts",
        );
        defer stmt.deinit();
        try stmt.bindI32(1, pid);

        var samples: std.ArrayList(types.ProcessSample) = .empty;
        errdefer samples.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try samples.append(self.alloc, .{
                .ts = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .user = try self.alloc.dupe(u8, stmt.columnText(2)),
                .cpu = stmt.columnF64(3),
                .mem = stmt.columnF64(4),
                .rss_kb = stmt.columnI64(5),
                .stat = try self.alloc.dupe(u8, stmt.columnText(6)),
                .etimes = stmt.columnI64(7),
                .comm = try self.alloc.dupe(u8, stmt.columnText(8)),
                .args = try self.alloc.dupe(u8, stmt.columnText(9)),
            });
        }
        return samples.toOwnedSlice(self.alloc);
    }

    /// Get all FD records for a PID at latest timestamp
    pub fn getLatestFdsForPid(self: *Reader, pid: i32) ![]types.FdRecord {
        var stmt = try self.db.prepare(
            "SELECT ts, pid, fd_num, fd_type, path FROM fd_record " ++
                "WHERE pid = ?1 AND ts = (SELECT MAX(ts) FROM fd_record WHERE pid = ?1) ORDER BY fd_num",
        );
        defer stmt.deinit();
        try stmt.bindI32(1, pid);

        var fds: std.ArrayList(types.FdRecord) = .empty;
        errdefer fds.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try fds.append(self.alloc, .{
                .ts = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .fd_num = stmt.columnI32(2),
                .fd_type = types.FdRecord.FdType.fromString(stmt.columnText(3)),
                .path = try self.alloc.dupe(u8, stmt.columnText(4)),
            });
        }
        return fds.toOwnedSlice(self.alloc);
    }

    /// Get all connections for a PID at latest timestamp
    pub fn getLatestConnectionsForPid(self: *Reader, pid: i32) ![]types.NetConnection {
        var stmt = try self.db.prepare(
            "SELECT ts, pid, protocol, local_addr, local_port, remote_addr, remote_port, state FROM net_connection " ++
                "WHERE pid = ?1 AND ts = (SELECT MAX(ts) FROM net_connection WHERE pid = ?1) ORDER BY local_port",
        );
        defer stmt.deinit();
        try stmt.bindI32(1, pid);

        var conns: std.ArrayList(types.NetConnection) = .empty;
        errdefer conns.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try conns.append(self.alloc, .{
                .ts = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .protocol = types.NetConnection.Protocol.fromString(stmt.columnText(2)),
                .local_addr = try self.alloc.dupe(u8, stmt.columnText(3)),
                .local_port = @intCast(stmt.columnI32(4)),
                .remote_addr = try self.alloc.dupe(u8, stmt.columnText(5)),
                .remote_port = @intCast(stmt.columnI32(6)),
                .state = try self.alloc.dupe(u8, stmt.columnText(7)),
            });
        }
        return conns.toOwnedSlice(self.alloc);
    }

    /// Get all status records for a PID
    pub fn getAllStatusForPid(self: *Reader, pid: i32) ![]types.StatusRecord {
        var stmt = try self.db.prepare(
            "SELECT ts, pid, state, threads, vm_rss_kb, vm_swap_kb, voluntary_ctxt_switches, nonvoluntary_ctxt_switches " ++
                "FROM status_sample WHERE pid = ?1 ORDER BY ts",
        );
        defer stmt.deinit();
        try stmt.bindI32(1, pid);

        var records: std.ArrayList(types.StatusRecord) = .empty;
        errdefer records.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try records.append(self.alloc, .{
                .ts = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .state = try self.alloc.dupe(u8, stmt.columnText(2)),
                .threads = stmt.columnI32(3),
                .vm_rss_kb = stmt.columnI64(4),
                .vm_swap_kb = stmt.columnI64(5),
                .voluntary_ctxt_switches = stmt.columnI64(6),
                .nonvoluntary_ctxt_switches = stmt.columnI64(7),
            });
        }
        return records.toOwnedSlice(self.alloc);
    }

    /// Get baselines from fingerprint_baseline table
    pub fn getBaselines(self: *Reader) ![]Baseline {
        var stmt = try self.db.prepare(
            "SELECT comm, version, avg_cpu, avg_rss_kb, avg_threads, avg_fd_count, avg_net_conns, dominant_phase, sample_count, created_at, label " ++
                "FROM fingerprint_baseline ORDER BY comm, label",
        );
        defer stmt.deinit();

        var baselines: std.ArrayList(Baseline) = .empty;
        errdefer baselines.deinit(self.alloc);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try baselines.append(self.alloc, .{
                .comm = try self.alloc.dupe(u8, stmt.columnText(0)),
                .version = try self.alloc.dupe(u8, stmt.columnText(1)),
                .avg_cpu = stmt.columnF64(2),
                .avg_rss_kb = stmt.columnF64(3),
                .avg_threads = stmt.columnF64(4),
                .avg_fd_count = stmt.columnF64(5),
                .avg_net_conns = stmt.columnF64(6),
                .dominant_phase = try self.alloc.dupe(u8, stmt.columnText(7)),
                .sample_count = stmt.columnI64(8),
                .created_at = stmt.columnI64(9),
                .label = try self.alloc.dupe(u8, stmt.columnText(10)),
            });
        }
        return baselines.toOwnedSlice(self.alloc);
    }

    pub const Fingerprint = struct {
        pid: i32,
        comm: []const u8,
        avg_cpu: f64,
        avg_rss_kb: f64,
        avg_threads: f64,
        avg_fd_count: f64,
        avg_net_conns: f64,
        dominant_phase: []const u8,
        sample_count: i64,
        updated_at: i64,

        pub fn freeSlice(alloc: std.mem.Allocator, fps: []const Fingerprint) void {
            for (fps) |fp| {
                alloc.free(fp.comm);
                alloc.free(fp.dominant_phase);
            }
            alloc.free(fps);
        }
    };

    pub const Baseline = struct {
        comm: []const u8,
        version: []const u8,
        avg_cpu: f64,
        avg_rss_kb: f64,
        avg_threads: f64,
        avg_fd_count: f64,
        avg_net_conns: f64,
        dominant_phase: []const u8,
        sample_count: i64,
        created_at: i64,
        label: []const u8,

        pub fn freeSlice(alloc: std.mem.Allocator, baselines: []const Baseline) void {
            for (baselines) |b| {
                alloc.free(b.comm);
                alloc.free(b.version);
                alloc.free(b.dominant_phase);
                alloc.free(b.label);
            }
            alloc.free(baselines);
        }
    };
};

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");
const writer_mod = @import("writer.zig");

test "Reader: empty DB returns empty slices" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var reader = Reader.init(&db, testing.allocator);

    const agents = try reader.getAliveAgents();
    defer types.Agent.freeSlice(testing.allocator, agents);
    try testing.expectEqual(@as(usize, 0), agents.len);

    const samples = try reader.getLatestSamplesPerAgent();
    defer types.ProcessSample.freeSlice(testing.allocator, samples);
    try testing.expectEqual(@as(usize, 0), samples.len);

    const pids = try reader.getDistinctPids();
    defer testing.allocator.free(pids);
    try testing.expectEqual(@as(usize, 0), pids.len);

    const count = try reader.getSampleCount();
    try testing.expectEqual(@as(i64, 0), count);
}

test "Reader: write then read samples" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    const sample = helpers.makeSample(.{ .pid = 42, .ts = 1000 });
    try writer.writeSample(sample);

    const count = try reader.getSampleCount();
    try testing.expectEqual(@as(i64, 1), count);

    const samples = try reader.getSamples(42, 0, 9999);
    defer types.ProcessSample.freeSlice(testing.allocator, samples);
    try testing.expectEqual(@as(usize, 1), samples.len);
    try testing.expectEqual(@as(i32, 42), samples[0].pid);
    try testing.expectEqualStrings("claude", samples[0].comm);
}

test "Reader: getAliveAgents after upsert" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    try writer.upsertAgent(42, "claude", "claude --code", 1000);

    const agents = try reader.getAliveAgents();
    defer types.Agent.freeSlice(testing.allocator, agents);
    try testing.expectEqual(@as(usize, 1), agents.len);
    try testing.expectEqual(@as(i32, 42), agents[0].pid);
    try testing.expectEqualStrings("claude", agents[0].comm);
}

test "Reader: getDistinctPids" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    try writer.writeSample(helpers.makeSample(.{ .pid = 10 }));
    try writer.writeSample(helpers.makeSample(.{ .pid = 20 }));
    try writer.writeSample(helpers.makeSample(.{ .pid = 10 })); // duplicate pid

    const pids = try reader.getDistinctPids();
    defer testing.allocator.free(pids);
    try testing.expectEqual(@as(usize, 2), pids.len);
}

test "Reader: getRecentAlerts" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    try writer.writeAlert(helpers.makeAlert(.{ .ts = 1000 }));
    try writer.writeAlert(helpers.makeAlert(.{ .ts = 2000 }));

    const alerts = try reader.getRecentAlerts(10);
    defer types.Alert.freeSlice(testing.allocator, alerts);
    try testing.expectEqual(@as(usize, 2), alerts.len);
    // Most recent first (ORDER BY ts DESC)
    try testing.expectEqual(@as(i64, 2000), alerts[0].ts);
}

test "Reader: getLatestSamplesPerAgent" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    try writer.writeSample(helpers.makeSample(.{ .pid = 42, .ts = 1000, .cpu = 10.0 }));
    try writer.writeSample(helpers.makeSample(.{ .pid = 42, .ts = 2000, .cpu = 20.0 }));

    const samples = try reader.getLatestSamplesPerAgent();
    defer types.ProcessSample.freeSlice(testing.allocator, samples);
    try testing.expectEqual(@as(usize, 1), samples.len);
    try testing.expectEqual(@as(i64, 2000), samples[0].ts);
}

test "Reader: getFingerprints" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    try writer.writeFingerprint(.{
        .pid = 42,
        .comm = "claude",
        .avg_cpu = 15.0,
        .avg_rss_kb = 50000,
        .avg_threads = 5,
        .avg_fd_count = 20,
        .avg_net_conns = 3,
        .dominant_phase = "active",
        .sample_count = 100,
        .updated_at = 1000,
    });

    const fps = try reader.getFingerprints();
    defer Reader.Fingerprint.freeSlice(testing.allocator, fps);
    try testing.expectEqual(@as(usize, 1), fps.len);
    try testing.expectEqualStrings("claude", fps[0].comm);
}

test "Reader: getBaselines" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    try writer.writeBaseline(.{
        .comm = "claude",
        .version = "1.0",
        .avg_cpu = 10.0,
        .avg_rss_kb = 50000,
        .avg_threads = 5,
        .avg_fd_count = 20,
        .avg_net_conns = 3,
        .dominant_phase = "active",
        .sample_count = 100,
        .created_at = 1000,
        .label = "baseline-v1",
    });

    const baselines = try reader.getBaselines();
    defer Reader.Baseline.freeSlice(testing.allocator, baselines);
    try testing.expectEqual(@as(usize, 1), baselines.len);
    try testing.expectEqualStrings("claude", baselines[0].comm);
    try testing.expectEqualStrings("baseline-v1", baselines[0].label);
}

test "Reader: getLatestConnectionsPerAgent" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    try writer.writeNetConnection(helpers.makeNetConnection(.{ .pid = 42, .ts = 1000 }));

    const conns = try reader.getLatestConnectionsPerAgent();
    defer types.NetConnection.freeSlice(testing.allocator, conns);
    try testing.expectEqual(@as(usize, 1), conns.len);
    try testing.expectEqual(@as(i32, 42), conns[0].pid);
}

test "Reader: getAllSamplesForPid" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try writer_mod.Writer.init(&db);
    defer writer.deinit();
    var reader = Reader.init(&db, testing.allocator);

    try writer.writeSample(helpers.makeSample(.{ .pid = 42, .ts = 1000 }));
    try writer.writeSample(helpers.makeSample(.{ .pid = 42, .ts = 2000 }));
    try writer.writeSample(helpers.makeSample(.{ .pid = 99, .ts = 1000 }));

    const samples = try reader.getAllSamplesForPid(42);
    defer types.ProcessSample.freeSlice(testing.allocator, samples);
    try testing.expectEqual(@as(usize, 2), samples.len);
}
