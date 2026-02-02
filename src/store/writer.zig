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
};

const c = @import("db.zig").c;

// Workaround: re-export c for the sqlite3_changes call
pub const sqlite3_changes = c.sqlite3_changes;
