const std = @import("std");
const types = @import("../data/types.zig");
const db_mod = @import("../store/db.zig");

/// Open an in-memory SQLite database with schema applied.
/// Caller must call db.close() when done.
pub fn makeTestDb() !db_mod.Db {
    return try db_mod.Db.open(":memory:");
}

/// Create a ProcessSample with sensible defaults.
pub fn makeSample(overrides: SampleOverrides) types.ProcessSample {
    return .{
        .ts = overrides.ts orelse 1000,
        .pid = overrides.pid orelse 42,
        .user = overrides.user orelse "testuser",
        .cpu = overrides.cpu orelse 5.0,
        .mem = overrides.mem orelse 1.0,
        .rss_kb = overrides.rss_kb orelse 102400,
        .stat = overrides.stat orelse "S",
        .etimes = overrides.etimes orelse 3600,
        .comm = overrides.comm orelse "claude",
        .args = overrides.args orelse "claude --code",
    };
}

pub const SampleOverrides = struct {
    ts: ?i64 = null,
    pid: ?i32 = null,
    user: ?[]const u8 = null,
    cpu: ?f64 = null,
    mem: ?f64 = null,
    rss_kb: ?i64 = null,
    stat: ?[]const u8 = null,
    etimes: ?i64 = null,
    comm: ?[]const u8 = null,
    args: ?[]const u8 = null,
};

/// Create an Alert with sensible defaults.
pub fn makeAlert(overrides: AlertOverrides) types.Alert {
    return .{
        .ts = overrides.ts orelse 1000,
        .pid = overrides.pid orelse 42,
        .severity = overrides.severity orelse .warning,
        .category = overrides.category orelse "cpu",
        .message = overrides.message orelse "CPU usage high",
        .value = overrides.value orelse 85.0,
        .threshold = overrides.threshold orelse 80.0,
    };
}

pub const AlertOverrides = struct {
    ts: ?i64 = null,
    pid: ?i32 = null,
    severity: ?types.Alert.Severity = null,
    category: ?[]const u8 = null,
    message: ?[]const u8 = null,
    value: ?f64 = null,
    threshold: ?f64 = null,
};

/// Create an FdRecord with sensible defaults.
pub fn makeFdRecord(overrides: FdOverrides) types.FdRecord {
    return .{
        .ts = overrides.ts orelse 1000,
        .pid = overrides.pid orelse 42,
        .fd_num = overrides.fd_num orelse 3,
        .fd_type = overrides.fd_type orelse .regular,
        .path = overrides.path orelse "/tmp/test.txt",
    };
}

pub const FdOverrides = struct {
    ts: ?i64 = null,
    pid: ?i32 = null,
    fd_num: ?i32 = null,
    fd_type: ?types.FdRecord.FdType = null,
    path: ?[]const u8 = null,
};

/// Create a NetConnection with sensible defaults.
pub fn makeNetConnection(overrides: NetOverrides) types.NetConnection {
    return .{
        .ts = overrides.ts orelse 1000,
        .pid = overrides.pid orelse 42,
        .protocol = overrides.protocol orelse .tcp,
        .local_addr = overrides.local_addr orelse "127.0.0.1",
        .local_port = overrides.local_port orelse 8080,
        .remote_addr = overrides.remote_addr orelse "93.184.216.34",
        .remote_port = overrides.remote_port orelse 443,
        .state = overrides.state orelse "ESTABLISHED",
    };
}

pub const NetOverrides = struct {
    ts: ?i64 = null,
    pid: ?i32 = null,
    protocol: ?types.NetConnection.Protocol = null,
    local_addr: ?[]const u8 = null,
    local_port: ?u16 = null,
    remote_addr: ?[]const u8 = null,
    remote_port: ?u16 = null,
    state: ?[]const u8 = null,
};

/// Create a StatusRecord with sensible defaults.
pub fn makeStatus(overrides: StatusOverrides) types.StatusRecord {
    return .{
        .ts = overrides.ts orelse 1000,
        .pid = overrides.pid orelse 42,
        .state = overrides.state orelse "S (sleeping)",
        .threads = overrides.threads orelse 4,
        .vm_rss_kb = overrides.vm_rss_kb orelse 102400,
        .vm_swap_kb = overrides.vm_swap_kb orelse 0,
        .voluntary_ctxt_switches = overrides.voluntary_ctxt_switches orelse 100,
        .nonvoluntary_ctxt_switches = overrides.nonvoluntary_ctxt_switches orelse 10,
    };
}

pub const StatusOverrides = struct {
    ts: ?i64 = null,
    pid: ?i32 = null,
    state: ?[]const u8 = null,
    threads: ?i32 = null,
    vm_rss_kb: ?i64 = null,
    vm_swap_kb: ?i64 = null,
    voluntary_ctxt_switches: ?i64 = null,
    nonvoluntary_ctxt_switches: ?i64 = null,
};

/// Approximate floating-point equality check.
pub fn expectApproxEqual(expected: f64, actual: f64, tolerance: f64) !void {
    if (@abs(expected - actual) > tolerance) {
        return error.TestUnexpectedResult;
    }
}

test "helpers: makeSample defaults" {
    const s = makeSample(.{});
    try std.testing.expectEqual(@as(i32, 42), s.pid);
    try std.testing.expectEqualStrings("claude", s.comm);
}

test "helpers: makeSample overrides" {
    const s = makeSample(.{ .pid = 99, .cpu = 50.0 });
    try std.testing.expectEqual(@as(i32, 99), s.pid);
    try expectApproxEqual(50.0, s.cpu, 0.01);
}

test "helpers: makeTestDb opens and closes" {
    var db = try makeTestDb();
    defer db.close();
    // Verify schema was applied by preparing a query
    var stmt = try db.prepare("SELECT COUNT(*) FROM agent");
    defer stmt.deinit();
    _ = try stmt.step();
}

test "helpers: expectApproxEqual" {
    try expectApproxEqual(1.0, 1.0001, 0.001);
    try std.testing.expectError(error.TestUnexpectedResult, expectApproxEqual(1.0, 2.0, 0.001));
}
