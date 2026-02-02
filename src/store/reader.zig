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
        var stmt = try self.db.prepare("SELECT id, pid, comm, args, first_seen, last_seen, alive FROM agent WHERE alive = 1 ORDER BY pid");
        defer stmt.deinit();

        var agents = std.ArrayList(types.Agent).init(self.alloc);
        errdefer agents.deinit();

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try agents.append(.{
                .id = stmt.columnI64(0),
                .pid = stmt.columnI32(1),
                .comm = try self.alloc.dupe(u8, stmt.columnText(2)),
                .args = try self.alloc.dupe(u8, stmt.columnText(3)),
                .first_seen = stmt.columnI64(4),
                .last_seen = stmt.columnI64(5),
                .alive = stmt.columnI32(6) != 0,
            });
        }
        return agents.toOwnedSlice();
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

        var samples = std.ArrayList(types.ProcessSample).init(self.alloc);
        errdefer samples.deinit();

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try samples.append(.{
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
        return samples.toOwnedSlice();
    }

    /// Get latest sample per alive agent (for overview table)
    pub fn getLatestSamplesPerAgent(self: *Reader) ![]types.ProcessSample {
        var stmt = try self.db.prepare(
            "SELECT ps.ts, ps.pid, ps.user, ps.cpu, ps.mem, ps.rss_kb, ps.stat, ps.etimes, ps.comm, ps.args " ++
                "FROM process_sample ps INNER JOIN (" ++
                "  SELECT pid, MAX(ts) as max_ts FROM process_sample GROUP BY pid" ++
                ") latest ON ps.pid = latest.pid AND ps.ts = latest.max_ts " ++
                "ORDER BY ps.cpu DESC",
        );
        defer stmt.deinit();

        var samples = std.ArrayList(types.ProcessSample).init(self.alloc);
        errdefer samples.deinit();

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try samples.append(.{
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
        return samples.toOwnedSlice();
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

        var alerts = std.ArrayList(types.Alert).init(self.alloc);
        errdefer alerts.deinit();

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

            try alerts.append(.{
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
        return alerts.toOwnedSlice();
    }

    /// Get distinct PIDs from process_sample
    pub fn getDistinctPids(self: *Reader) ![]i32 {
        var stmt = try self.db.prepare("SELECT DISTINCT pid FROM process_sample ORDER BY pid");
        defer stmt.deinit();

        var pids = std.ArrayList(i32).init(self.alloc);
        errdefer pids.deinit();

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;
            try pids.append(stmt.columnI32(0));
        }
        return pids.toOwnedSlice();
    }
};
