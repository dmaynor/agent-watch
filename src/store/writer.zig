const std = @import("std");
const db_mod = @import("db.zig");
const types = @import("../data/types.zig");

const Db = db_mod.Db;
const Statement = db_mod.Statement;

pub const Writer = struct {
    db: *Db,
    insert_sample: Statement,
    insert_status: Statement,
    insert_fd: Statement,
    insert_net: Statement,
    insert_agent: Statement,
    update_agent: Statement,
    insert_alert: Statement,
    upsert_fingerprint: Statement,
    insert_baseline: Statement,

    pub fn init(db: *Db) !Writer {
        return Writer{
            .db = db,
            .insert_sample = try db.prepare(
                "INSERT INTO process_sample (ts, pid, user, cpu, mem, rss_kb, stat, etimes, comm, args) " ++
                    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            ),
            .insert_status = try db.prepare(
                "INSERT INTO status_sample (ts, pid, state, threads, vm_rss_kb, vm_swap_kb, voluntary_ctxt_switches, nonvoluntary_ctxt_switches) " ++
                    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            ),
            .insert_fd = try db.prepare(
                "INSERT INTO fd_record (ts, pid, fd_num, fd_type, path) VALUES (?1, ?2, ?3, ?4, ?5)",
            ),
            .insert_net = try db.prepare(
                "INSERT INTO net_connection (ts, pid, protocol, local_addr, local_port, remote_addr, remote_port, state) " ++
                    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            ),
            .insert_agent = try db.prepare(
                "INSERT INTO agent (pid, comm, args, first_seen, last_seen, alive) VALUES (?1, ?2, ?3, ?4, ?5, 1)",
            ),
            .update_agent = try db.prepare(
                "UPDATE agent SET last_seen = ?1, alive = ?2 WHERE pid = ?3 AND comm = ?4 AND alive = 1",
            ),
            .insert_alert = try db.prepare(
                "INSERT INTO alert (ts, pid, severity, category, message, value, threshold) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            ),
            .upsert_fingerprint = try db.prepare(
                "INSERT OR REPLACE INTO fingerprint (pid, comm, avg_cpu, avg_rss_kb, avg_threads, avg_fd_count, avg_net_conns, dominant_phase, sample_count, updated_at) " ++
                    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            ),
            .insert_baseline = try db.prepare(
                "INSERT INTO fingerprint_baseline (comm, version, avg_cpu, avg_rss_kb, avg_threads, avg_fd_count, avg_net_conns, dominant_phase, sample_count, created_at, label) " ++
                    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            ),
        };
    }

    pub fn deinit(self: *Writer) void {
        self.insert_sample.deinit();
        self.insert_status.deinit();
        self.insert_fd.deinit();
        self.insert_net.deinit();
        self.insert_agent.deinit();
        self.update_agent.deinit();
        self.insert_alert.deinit();
        self.upsert_fingerprint.deinit();
        self.insert_baseline.deinit();
    }

    pub fn beginTransaction(self: *Writer) !void {
        try self.db.exec("BEGIN TRANSACTION;");
    }

    pub fn commitTransaction(self: *Writer) !void {
        try self.db.exec("COMMIT;");
    }

    pub fn rollbackTransaction(self: *Writer) !void {
        self.db.exec("ROLLBACK;") catch {};
    }

    pub fn writeSample(self: *Writer, s: types.ProcessSample) !void {
        try self.insert_sample.reset();
        self.insert_sample.clearBindings();
        try self.insert_sample.bindI64(1, s.ts);
        try self.insert_sample.bindI32(2, s.pid);
        try self.insert_sample.bindText(3, s.user);
        try self.insert_sample.bindF64(4, s.cpu);
        try self.insert_sample.bindF64(5, s.mem);
        try self.insert_sample.bindI64(6, s.rss_kb);
        try self.insert_sample.bindText(7, s.stat);
        try self.insert_sample.bindI64(8, s.etimes);
        try self.insert_sample.bindText(9, s.comm);
        try self.insert_sample.bindText(10, s.args);
        _ = try self.insert_sample.step();
    }

    pub fn writeStatus(self: *Writer, s: types.StatusRecord) !void {
        try self.insert_status.reset();
        self.insert_status.clearBindings();
        try self.insert_status.bindI64(1, s.ts);
        try self.insert_status.bindI32(2, s.pid);
        try self.insert_status.bindText(3, s.state);
        try self.insert_status.bindI32(4, s.threads);
        try self.insert_status.bindI64(5, s.vm_rss_kb);
        try self.insert_status.bindI64(6, s.vm_swap_kb);
        try self.insert_status.bindI64(7, s.voluntary_ctxt_switches);
        try self.insert_status.bindI64(8, s.nonvoluntary_ctxt_switches);
        _ = try self.insert_status.step();
    }

    pub fn writeFd(self: *Writer, f: types.FdRecord) !void {
        try self.insert_fd.reset();
        self.insert_fd.clearBindings();
        try self.insert_fd.bindI64(1, f.ts);
        try self.insert_fd.bindI32(2, f.pid);
        try self.insert_fd.bindI32(3, f.fd_num);
        try self.insert_fd.bindText(4, f.fd_type.toString());
        try self.insert_fd.bindText(5, f.path);
        _ = try self.insert_fd.step();
    }

    pub fn writeNetConnection(self: *Writer, n: types.NetConnection) !void {
        try self.insert_net.reset();
        self.insert_net.clearBindings();
        try self.insert_net.bindI64(1, n.ts);
        try self.insert_net.bindI32(2, n.pid);
        try self.insert_net.bindText(3, n.protocol.toString());
        try self.insert_net.bindText(4, n.local_addr);
        try self.insert_net.bindI32(5, @intCast(n.local_port));
        try self.insert_net.bindText(6, n.remote_addr);
        try self.insert_net.bindI32(7, @intCast(n.remote_port));
        try self.insert_net.bindText(8, n.state);
        _ = try self.insert_net.step();
    }

    pub fn upsertAgent(self: *Writer, pid: i32, comm: []const u8, args: []const u8, ts: types.Timestamp) !void {
        // Try update first
        try self.update_agent.reset();
        self.update_agent.clearBindings();
        try self.update_agent.bindI64(1, ts);
        try self.update_agent.bindI32(2, 1); // alive = true
        try self.update_agent.bindI32(3, pid);
        try self.update_agent.bindText(4, comm);
        _ = try self.update_agent.step();

        // If no rows updated, insert new
        const changes = @import("db.zig").c.sqlite3_changes(self.db.handle);
        if (changes == 0) {
            try self.insert_agent.reset();
            self.insert_agent.clearBindings();
            try self.insert_agent.bindI32(1, pid);
            try self.insert_agent.bindText(2, comm);
            try self.insert_agent.bindText(3, args);
            try self.insert_agent.bindI64(4, ts);
            try self.insert_agent.bindI64(5, ts);
            _ = try self.insert_agent.step();
        }
    }

    pub fn writeAlert(self: *Writer, a: types.Alert) !void {
        try self.insert_alert.reset();
        self.insert_alert.clearBindings();
        try self.insert_alert.bindI64(1, a.ts);
        try self.insert_alert.bindI32(2, a.pid);
        try self.insert_alert.bindText(3, a.severity.toString());
        try self.insert_alert.bindText(4, a.category);
        try self.insert_alert.bindText(5, a.message);
        try self.insert_alert.bindF64(6, a.value);
        try self.insert_alert.bindF64(7, a.threshold);
        _ = try self.insert_alert.step();
    }

    pub const FingerprintRecord = struct {
        pid: i32,
        comm: []const u8,
        avg_cpu: f64,
        avg_rss_kb: f64,
        avg_threads: f64,
        avg_fd_count: f64,
        avg_net_conns: f64,
        dominant_phase: []const u8,
        sample_count: u32,
        updated_at: i64,
    };

    pub fn writeFingerprint(self: *Writer, f: FingerprintRecord) !void {
        try self.upsert_fingerprint.reset();
        self.upsert_fingerprint.clearBindings();
        try self.upsert_fingerprint.bindI32(1, f.pid);
        try self.upsert_fingerprint.bindText(2, f.comm);
        try self.upsert_fingerprint.bindF64(3, f.avg_cpu);
        try self.upsert_fingerprint.bindF64(4, f.avg_rss_kb);
        try self.upsert_fingerprint.bindF64(5, f.avg_threads);
        try self.upsert_fingerprint.bindF64(6, f.avg_fd_count);
        try self.upsert_fingerprint.bindF64(7, f.avg_net_conns);
        try self.upsert_fingerprint.bindText(8, f.dominant_phase);
        try self.upsert_fingerprint.bindI32(9, @intCast(f.sample_count));
        try self.upsert_fingerprint.bindI64(10, f.updated_at);
        _ = try self.upsert_fingerprint.step();
    }

    pub const BaselineRecord = struct {
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
    };

    pub fn writeBaseline(self: *Writer, b: BaselineRecord) !void {
        try self.insert_baseline.reset();
        self.insert_baseline.clearBindings();
        try self.insert_baseline.bindText(1, b.comm);
        try self.insert_baseline.bindText(2, b.version);
        try self.insert_baseline.bindF64(3, b.avg_cpu);
        try self.insert_baseline.bindF64(4, b.avg_rss_kb);
        try self.insert_baseline.bindF64(5, b.avg_threads);
        try self.insert_baseline.bindF64(6, b.avg_fd_count);
        try self.insert_baseline.bindF64(7, b.avg_net_conns);
        try self.insert_baseline.bindText(8, b.dominant_phase);
        try self.insert_baseline.bindI64(9, b.sample_count);
        try self.insert_baseline.bindI64(10, b.created_at);
        try self.insert_baseline.bindText(11, b.label);
        _ = try self.insert_baseline.step();
    }
};

const c = @import("db.zig").c;

// Workaround: re-export c for the sqlite3_changes call
pub const sqlite3_changes = c.sqlite3_changes;

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");

test "Writer: init and deinit" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();
}

test "Writer: writeSample" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    const sample = helpers.makeSample(.{});
    try writer.writeSample(sample);

    var stmt = try db.prepare("SELECT COUNT(*) FROM process_sample");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnI64(0));
}

test "Writer: writeStatus" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    try writer.writeStatus(helpers.makeStatus(.{}));

    var stmt = try db.prepare("SELECT COUNT(*) FROM status_sample");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnI64(0));
}

test "Writer: writeFd" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    try writer.writeFd(helpers.makeFdRecord(.{}));

    var stmt = try db.prepare("SELECT COUNT(*) FROM fd_record");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnI64(0));
}

test "Writer: writeNetConnection" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    try writer.writeNetConnection(helpers.makeNetConnection(.{}));

    var stmt = try db.prepare("SELECT COUNT(*) FROM net_connection");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnI64(0));
}

test "Writer: upsertAgent insert then update" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    // First call inserts
    try writer.upsertAgent(42, "claude", "claude --code", 1000);
    // Second call updates
    try writer.upsertAgent(42, "claude", "claude --code", 2000);

    var stmt = try db.prepare("SELECT COUNT(*) FROM agent WHERE pid = 42");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnI64(0));
}

test "Writer: writeAlert" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    try writer.writeAlert(helpers.makeAlert(.{}));

    var stmt = try db.prepare("SELECT severity, category FROM alert");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqualStrings("warning", stmt.columnText(0));
    try testing.expectEqualStrings("cpu", stmt.columnText(1));
}

test "Writer: writeFingerprint upsert" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    try writer.writeFingerprint(.{
        .pid = 42,
        .comm = "claude",
        .avg_cpu = 10.0,
        .avg_rss_kb = 50000,
        .avg_threads = 5,
        .avg_fd_count = 20,
        .avg_net_conns = 3,
        .dominant_phase = "active",
        .sample_count = 100,
        .updated_at = 1000,
    });

    // Upsert with new values
    try writer.writeFingerprint(.{
        .pid = 42,
        .comm = "claude",
        .avg_cpu = 20.0,
        .avg_rss_kb = 60000,
        .avg_threads = 6,
        .avg_fd_count = 25,
        .avg_net_conns = 4,
        .dominant_phase = "burst",
        .sample_count = 200,
        .updated_at = 2000,
    });

    var stmt = try db.prepare("SELECT COUNT(*) FROM fingerprint WHERE pid = 42");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnI64(0)); // only one row
}

test "Writer: transaction begin/commit" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    try writer.beginTransaction();
    try writer.writeSample(helpers.makeSample(.{ .pid = 1 }));
    try writer.writeSample(helpers.makeSample(.{ .pid = 2 }));
    try writer.commitTransaction();

    var stmt = try db.prepare("SELECT COUNT(*) FROM process_sample");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 2), stmt.columnI64(0));
}

test "Writer: transaction rollback" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

    try writer.beginTransaction();
    try writer.writeSample(helpers.makeSample(.{}));
    try writer.rollbackTransaction();

    var stmt = try db.prepare("SELECT COUNT(*) FROM process_sample");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 0), stmt.columnI64(0));
}

test "Writer: writeBaseline" {
    var db = try helpers.makeTestDb();
    defer db.close();
    var writer = try Writer.init(&db);
    defer writer.deinit();

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
        .label = "test",
    });

    var stmt = try db.prepare("SELECT COUNT(*) FROM fingerprint_baseline");
    defer stmt.deinit();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnI64(0));
}
