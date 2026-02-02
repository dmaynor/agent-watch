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
