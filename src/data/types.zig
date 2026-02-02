const std = @import("std");

/// Timestamp as Unix epoch seconds (UTC)
pub const Timestamp = i64;

/// Process sample from one collection tick
pub const ProcessSample = struct {
    ts: Timestamp,
    pid: i32,
    user: []const u8,
    cpu: f64,
    mem: f64,
    rss_kb: i64,
    stat: []const u8,
    etimes: i64,
    comm: []const u8,
    args: []const u8,
};

/// Open file descriptor record
pub const FdRecord = struct {
    ts: Timestamp,
    pid: i32,
    fd_num: i32,
    fd_type: FdType,
    path: []const u8,

    pub const FdType = enum {
        regular,
        directory,
        socket,
        pipe,
        device,
        anon_inode,
        other,

        pub fn fromString(s: []const u8) FdType {
            if (std.mem.eql(u8, s, "REG")) return .regular;
            if (std.mem.eql(u8, s, "DIR")) return .directory;
            if (std.mem.eql(u8, s, "sock") or std.mem.eql(u8, s, "IPv4") or std.mem.eql(u8, s, "IPv6")) return .socket;
            if (std.mem.eql(u8, s, "FIFO")) return .pipe;
            if (std.mem.eql(u8, s, "CHR") or std.mem.eql(u8, s, "BLK")) return .device;
            if (std.mem.eql(u8, s, "a_inode")) return .anon_inode;
            return .other;
        }

        pub fn toString(self: FdType) []const u8 {
            return switch (self) {
                .regular => "REG",
                .directory => "DIR",
                .socket => "SOCK",
                .pipe => "PIPE",
                .device => "DEV",
                .anon_inode => "ANON",
                .other => "OTHER",
            };
        }
    };
};

/// Network connection record
pub const NetConnection = struct {
    ts: Timestamp,
    pid: i32,
    protocol: Protocol,
    local_addr: []const u8,
    local_port: u16,
    remote_addr: []const u8,
    remote_port: u16,
    state: []const u8,

    pub const Protocol = enum {
        tcp,
        tcp6,
        udp,
        udp6,

        pub fn toString(self: Protocol) []const u8 {
            return switch (self) {
                .tcp => "tcp",
                .tcp6 => "tcp6",
                .udp => "udp",
                .udp6 => "udp6",
            };
        }
    };
};

/// Process status record (from /proc/PID/status)
pub const StatusRecord = struct {
    ts: Timestamp,
    pid: i32,
    state: []const u8,
    threads: i32,
    vm_rss_kb: i64,
    vm_swap_kb: i64,
    voluntary_ctxt_switches: i64,
    nonvoluntary_ctxt_switches: i64,
};

/// Agent record (deduplicated)
pub const Agent = struct {
    id: ?i64 = null,
    pid: i32,
    comm: []const u8,
    args: []const u8,
    first_seen: Timestamp,
    last_seen: Timestamp,
    alive: bool,
};

/// Alert record
pub const Alert = struct {
    id: ?i64 = null,
    ts: Timestamp,
    pid: i32,
    severity: Severity,
    category: []const u8,
    message: []const u8,
    value: f64,
    threshold: f64,

    pub const Severity = enum {
        info,
        warning,
        critical,

        pub fn toString(self: Severity) []const u8 {
            return switch (self) {
                .info => "info",
                .warning => "warning",
                .critical => "critical",
            };
        }
    };
};

/// Metric rollup (pre-aggregated 1-minute bucket)
pub const MetricRollup = struct {
    ts_bucket: Timestamp,
    pid: i32,
    cpu_min: f64,
    cpu_max: f64,
    cpu_avg: f64,
    rss_min: i64,
    rss_max: i64,
    rss_avg: i64,
    sample_count: i32,
};

/// Parse ISO 8601 timestamp string to Unix epoch seconds
pub fn parseTimestamp(ts_str: []const u8) !Timestamp {
    // Format: "2026-02-01T23:02:50Z"
    if (ts_str.len < 20) return error.InvalidTimestamp;

    const year = std.fmt.parseInt(i32, ts_str[0..4], 10) catch return error.InvalidTimestamp;
    const month = std.fmt.parseInt(u4, ts_str[5..7], 10) catch return error.InvalidTimestamp;
    const day = std.fmt.parseInt(u5, ts_str[8..10], 10) catch return error.InvalidTimestamp;
    const hour = std.fmt.parseInt(u5, ts_str[11..13], 10) catch return error.InvalidTimestamp;
    const minute = std.fmt.parseInt(u6, ts_str[14..16], 10) catch return error.InvalidTimestamp;
    const second = std.fmt.parseInt(u6, ts_str[17..19], 10) catch return error.InvalidTimestamp;

    const epoch_day = std.time.epoch.EpochDay.calculateFromYmd(.{
        .year = @intCast(year),
        .month = @enumFromInt(month),
        .day = day,
    });
    const day_seconds: i64 = @as(i64, epoch_day.day) * 86400;
    return day_seconds + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

/// Format Unix epoch seconds to ISO 8601 string
pub fn formatTimestamp(buf: []u8, ts: Timestamp) ![]const u8 {
    const epoch_secs: u64 = @intCast(ts);
    const day_count = epoch_secs / 86400;
    const day_secs = epoch_secs % 86400;
    const hour: u8 = @intCast(day_secs / 3600);
    const minute: u8 = @intCast((day_secs % 3600) / 60);
    const second: u8 = @intCast(day_secs % 60);

    const ymd = std.time.epoch.EpochDay{ .day = @intCast(day_count) };
    const civil = ymd.calculateYearMonthDay();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        civil.year,
        @as(u8, @intFromEnum(civil.month)),
        @as(u8, civil.day),
        hour,
        minute,
        second,
    });
}

test "parseTimestamp roundtrip" {
    const ts = try parseTimestamp("2026-02-01T23:02:50Z");
    var buf: [32]u8 = undefined;
    const formatted = try formatTimestamp(&buf, ts);
    try std.testing.expectEqualStrings("2026-02-01T23:02:50Z", formatted);
}
