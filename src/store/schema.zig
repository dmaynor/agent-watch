/// SQLite DDL for agent-watch database
pub const create_tables =
    \\CREATE TABLE IF NOT EXISTS agent (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    pid INTEGER NOT NULL,
    \\    comm TEXT NOT NULL,
    \\    args TEXT NOT NULL DEFAULT '',
    \\    first_seen INTEGER NOT NULL,
    \\    last_seen INTEGER NOT NULL,
    \\    alive INTEGER NOT NULL DEFAULT 1
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS process_sample (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    ts INTEGER NOT NULL,
    \\    pid INTEGER NOT NULL,
    \\    user TEXT NOT NULL,
    \\    cpu REAL NOT NULL,
    \\    mem REAL NOT NULL,
    \\    rss_kb INTEGER NOT NULL,
    \\    stat TEXT NOT NULL,
    \\    etimes INTEGER NOT NULL,
    \\    comm TEXT NOT NULL,
    \\    args TEXT NOT NULL DEFAULT ''
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS status_sample (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    ts INTEGER NOT NULL,
    \\    pid INTEGER NOT NULL,
    \\    state TEXT NOT NULL DEFAULT '',
    \\    threads INTEGER NOT NULL DEFAULT 0,
    \\    vm_rss_kb INTEGER NOT NULL DEFAULT 0,
    \\    vm_swap_kb INTEGER NOT NULL DEFAULT 0,
    \\    voluntary_ctxt_switches INTEGER NOT NULL DEFAULT 0,
    \\    nonvoluntary_ctxt_switches INTEGER NOT NULL DEFAULT 0
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS fd_record (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    ts INTEGER NOT NULL,
    \\    pid INTEGER NOT NULL,
    \\    fd_num INTEGER NOT NULL,
    \\    fd_type TEXT NOT NULL,
    \\    path TEXT NOT NULL DEFAULT ''
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS net_connection (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    ts INTEGER NOT NULL,
    \\    pid INTEGER NOT NULL,
    \\    protocol TEXT NOT NULL,
    \\    local_addr TEXT NOT NULL,
    \\    local_port INTEGER NOT NULL,
    \\    remote_addr TEXT NOT NULL,
    \\    remote_port INTEGER NOT NULL,
    \\    state TEXT NOT NULL DEFAULT ''
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS metric_rollup (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    ts_bucket INTEGER NOT NULL,
    \\    pid INTEGER NOT NULL,
    \\    cpu_min REAL NOT NULL DEFAULT 0,
    \\    cpu_max REAL NOT NULL DEFAULT 0,
    \\    cpu_avg REAL NOT NULL DEFAULT 0,
    \\    rss_min INTEGER NOT NULL DEFAULT 0,
    \\    rss_max INTEGER NOT NULL DEFAULT 0,
    \\    rss_avg INTEGER NOT NULL DEFAULT 0,
    \\    sample_count INTEGER NOT NULL DEFAULT 0
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS alert (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    ts INTEGER NOT NULL,
    \\    pid INTEGER NOT NULL,
    \\    severity TEXT NOT NULL,
    \\    category TEXT NOT NULL,
    \\    message TEXT NOT NULL,
    \\    value REAL NOT NULL DEFAULT 0,
    \\    threshold REAL NOT NULL DEFAULT 0
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS fingerprint (
    \\    pid INTEGER NOT NULL,
    \\    comm TEXT NOT NULL,
    \\    avg_cpu REAL NOT NULL DEFAULT 0,
    \\    avg_rss_kb REAL NOT NULL DEFAULT 0,
    \\    avg_threads REAL NOT NULL DEFAULT 0,
    \\    avg_fd_count REAL NOT NULL DEFAULT 0,
    \\    avg_net_conns REAL NOT NULL DEFAULT 0,
    \\    dominant_phase TEXT NOT NULL DEFAULT 'idle',
    \\    sample_count INTEGER NOT NULL DEFAULT 0,
    \\    updated_at INTEGER NOT NULL DEFAULT 0,
    \\    PRIMARY KEY (pid, comm)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS fingerprint_baseline (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    comm TEXT NOT NULL,
    \\    version TEXT NOT NULL DEFAULT '',
    \\    avg_cpu REAL NOT NULL DEFAULT 0,
    \\    avg_rss_kb REAL NOT NULL DEFAULT 0,
    \\    avg_threads REAL NOT NULL DEFAULT 0,
    \\    avg_fd_count REAL NOT NULL DEFAULT 0,
    \\    avg_net_conns REAL NOT NULL DEFAULT 0,
    \\    dominant_phase TEXT NOT NULL DEFAULT 'idle',
    \\    sample_count INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL DEFAULT 0,
    \\    label TEXT NOT NULL DEFAULT ''
    \\);
;

pub const create_indexes =
    \\CREATE INDEX IF NOT EXISTS idx_process_sample_ts ON process_sample(ts);
    \\CREATE INDEX IF NOT EXISTS idx_process_sample_pid ON process_sample(pid);
    \\CREATE INDEX IF NOT EXISTS idx_status_sample_ts ON status_sample(ts);
    \\CREATE INDEX IF NOT EXISTS idx_status_sample_pid ON status_sample(pid);
    \\CREATE INDEX IF NOT EXISTS idx_fd_record_ts_pid ON fd_record(ts, pid);
    \\CREATE INDEX IF NOT EXISTS idx_net_connection_ts_pid ON net_connection(ts, pid);
    \\CREATE INDEX IF NOT EXISTS idx_metric_rollup_ts ON metric_rollup(ts_bucket);
    \\CREATE INDEX IF NOT EXISTS idx_alert_ts ON alert(ts);
    \\CREATE INDEX IF NOT EXISTS idx_agent_pid ON agent(pid);
;

const testing = @import("std").testing;
const helpers = @import("../testing/helpers.zig");

test "schema: tables created in memory db" {
    var db = try helpers.makeTestDb();
    defer db.close();
    // Verify all tables exist by querying them
    const tables = [_][*:0]const u8{
        "SELECT COUNT(*) FROM agent",
        "SELECT COUNT(*) FROM process_sample",
        "SELECT COUNT(*) FROM status_sample",
        "SELECT COUNT(*) FROM fd_record",
        "SELECT COUNT(*) FROM net_connection",
        "SELECT COUNT(*) FROM metric_rollup",
        "SELECT COUNT(*) FROM alert",
        "SELECT COUNT(*) FROM fingerprint",
        "SELECT COUNT(*) FROM fingerprint_baseline",
    };
    for (tables) |sql| {
        var stmt = try db.prepare(sql);
        defer stmt.deinit();
        _ = try stmt.step();
    }
}

test "schema: idempotent re-creation" {
    var db = try helpers.makeTestDb();
    defer db.close();
    // Apply schema again (should not fail due to IF NOT EXISTS)
    const db_mod = @import("db.zig");
    _ = db_mod; // db.initSchema is private, but execMulti is public
    try db.execMulti(create_tables);
    try db.execMulti(create_indexes);
}
