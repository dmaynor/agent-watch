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

    /// Free a heap-allocated slice of ProcessSamples including their inner strings
    pub fn freeSlice(alloc: std.mem.Allocator, samples: []const ProcessSample) void {
        for (samples) |s| {
            alloc.free(s.user);
            alloc.free(s.stat);
            alloc.free(s.comm);
            alloc.free(s.args);
        }
        alloc.free(samples);
    }
};

/// Open file descriptor record
pub const FdRecord = struct {
    ts: Timestamp,
    pid: i32,
    fd_num: i32,
    fd_type: FdType,
    path: []const u8,

    pub fn freeSlice(alloc: std.mem.Allocator, fds: []const FdRecord) void {
        for (fds) |fd| alloc.free(fd.path);
        alloc.free(fds);
    }

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

    /// Free a heap-allocated slice including inner strings.
    /// Note: `state` from platform_linux is a comptime literal (not heap),
    /// but `state` from reader.zig IS heap-duped. Callers must know which
    /// variant they have. This frees all three string fields.
    pub fn freeSlice(alloc: std.mem.Allocator, conns: []const NetConnection) void {
        for (conns) |c| {
            alloc.free(c.local_addr);
            alloc.free(c.remote_addr);
            alloc.free(c.state);
        }
        alloc.free(conns);
    }

    /// Free slice where state is NOT heap-allocated (e.g. from platform collector)
    pub fn freeSliceNoState(alloc: std.mem.Allocator, conns: []const NetConnection) void {
        for (conns) |c| {
            alloc.free(c.local_addr);
            alloc.free(c.remote_addr);
        }
        alloc.free(conns);
    }

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

        pub fn fromString(s: []const u8) Protocol {
            if (std.mem.eql(u8, s, "tcp6")) return .tcp6;
            if (std.mem.eql(u8, s, "udp")) return .udp;
            if (std.mem.eql(u8, s, "udp6")) return .udp6;
            return .tcp;
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

    pub fn freeSlice(alloc: std.mem.Allocator, records: []const StatusRecord) void {
        for (records) |r| alloc.free(r.state);
        alloc.free(records);
    }
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

    pub fn freeSlice(alloc: std.mem.Allocator, agents: []const Agent) void {
        for (agents) |a| {
            alloc.free(a.comm);
            alloc.free(a.args);
        }
        alloc.free(agents);
    }
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

    pub fn freeSlice(alloc: std.mem.Allocator, alerts: []const Alert) void {
        for (alerts) |a| {
            alloc.free(a.category);
            alloc.free(a.message);
        }
        alloc.free(alerts);
    }

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

    const epoch_days = civilToEpochDays(year, month, day);
    return epoch_days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

/// Format Unix epoch seconds to ISO 8601 string
pub fn formatTimestamp(buf: []u8, ts: Timestamp) ![]const u8 {
    if (ts < 0) return error.InvalidTimestamp;
    const epoch_secs: u64 = @intCast(ts);
    const day_count = epoch_secs / 86400;
    const day_secs = epoch_secs % 86400;
    const hour: u8 = @intCast(day_secs / 3600);
    const minute: u8 = @intCast((day_secs % 3600) / 60);
    const second: u8 = @intCast(day_secs % 60);

    const ymd = std.time.epoch.EpochDay{ .day = @intCast(day_count) };
    const year_day = ymd.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @as(u8, month_day.month.numeric()),
        @as(u8, month_day.day_index) + 1,
        hour,
        minute,
        second,
    });
}

/// Convert civil date (year, month 1-12, day 1-31) to days since Unix epoch.
/// Uses the algorithm from http://howardhinnant.github.io/date_algorithms.html
fn civilToEpochDays(y_raw: i32, m_raw: u4, d: u5) i64 {
    var y: i64 = y_raw;
    const m: i64 = m_raw;
    if (m <= 2) y -= 1;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const doy: i64 = @divFloor((153 * (m + (if (m > 2) @as(i64, -3) else @as(i64, 9))) + 2), 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

test "parseTimestamp roundtrip" {
    const ts = try parseTimestamp("2026-02-01T23:02:50Z");
    var buf: [32]u8 = undefined;
    const formatted = try formatTimestamp(&buf, ts);
    try std.testing.expectEqualStrings("2026-02-01T23:02:50Z", formatted);
}

test "parseTimestamp: short string returns error" {
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("2026-02"));
}

test "parseTimestamp: bad format returns error" {
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("not-a-timestamp-value"));
}

test "parseTimestamp: epoch start" {
    const ts = try parseTimestamp("1970-01-01T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 0), ts);
}

test "formatTimestamp: negative returns error" {
    var buf: [32]u8 = undefined;
    try std.testing.expectError(error.InvalidTimestamp, formatTimestamp(&buf, -1));
}

test "formatTimestamp: epoch zero" {
    var buf: [32]u8 = undefined;
    const formatted = try formatTimestamp(&buf, 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatted);
}

test "FdType: fromString/toString" {
    try std.testing.expectEqualStrings("REG", FdRecord.FdType.regular.toString());
    try std.testing.expectEqual(FdRecord.FdType.regular, FdRecord.FdType.fromString("REG"));
    try std.testing.expectEqual(FdRecord.FdType.socket, FdRecord.FdType.fromString("IPv4"));
    try std.testing.expectEqual(FdRecord.FdType.pipe, FdRecord.FdType.fromString("FIFO"));
    try std.testing.expectEqual(FdRecord.FdType.other, FdRecord.FdType.fromString("unknown"));
}

test "Protocol: fromString/toString roundtrip" {
    try std.testing.expectEqualStrings("tcp", NetConnection.Protocol.tcp.toString());
    try std.testing.expectEqual(NetConnection.Protocol.tcp, NetConnection.Protocol.fromString("tcp"));
    try std.testing.expectEqual(NetConnection.Protocol.tcp6, NetConnection.Protocol.fromString("tcp6"));
    try std.testing.expectEqual(NetConnection.Protocol.udp, NetConnection.Protocol.fromString("udp"));
    try std.testing.expectEqual(NetConnection.Protocol.udp6, NetConnection.Protocol.fromString("udp6"));
    // Unknown defaults to tcp
    try std.testing.expectEqual(NetConnection.Protocol.tcp, NetConnection.Protocol.fromString("other"));
}

test "Alert.Severity: toString" {
    try std.testing.expectEqualStrings("info", Alert.Severity.info.toString());
    try std.testing.expectEqualStrings("warning", Alert.Severity.warning.toString());
    try std.testing.expectEqualStrings("critical", Alert.Severity.critical.toString());
}
