const std = @import("std");
const types = @import("../data/types.zig");

const Allocator = std.mem.Allocator;

/// Read contents of a /proc file into a buffer
pub fn readProcFile(buf: []u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var path_buf: [256]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, fmt, args) catch return error.PathTooLong;
    const file = std.fs.openFileAbsoluteZ(path_z, .{}) catch return error.ProcReadFailed;
    defer file.close();
    const n = file.read(buf) catch return error.ProcReadFailed;
    return buf[0..n];
}

/// List all numeric PIDs in /proc
pub fn listPids(alloc: Allocator) ![]i32 {
    var pids: std.ArrayList(i32) = .empty;
    errdefer pids.deinit(alloc);

    var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return pids.toOwnedSlice(alloc);
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        try pids.append(alloc, pid);
    }

    return pids.toOwnedSlice(alloc);
}

/// Read /proc/PID/cmdline (null-separated → space-separated)
pub fn readCmdline(alloc: Allocator, pid: i32) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const data = readProcFile(&buf, "/proc/{d}/cmdline", .{pid}) catch return alloc.dupe(u8, "");
    if (data.len == 0) return alloc.dupe(u8, "");

    // Replace null bytes with spaces
    const result = try alloc.alloc(u8, data.len);
    errdefer alloc.free(result);
    for (data, 0..) |byte, i| {
        result[i] = if (byte == 0) ' ' else byte;
    }
    // Trim trailing space
    var len = result.len;
    while (len > 0 and result[len - 1] == ' ') len -= 1;
    if (len < result.len) {
        const trimmed = try alloc.dupe(u8, result[0..len]);
        alloc.free(result);
        return trimmed;
    }
    return result;
}

/// Read /proc/PID/comm
pub fn readComm(alloc: Allocator, pid: i32) ![]const u8 {
    var buf: [256]u8 = undefined;
    const data = readProcFile(&buf, "/proc/{d}/comm", .{pid}) catch return alloc.dupe(u8, "unknown");
    // Trim newline
    var len = data.len;
    while (len > 0 and (data[len - 1] == '\n' or data[len - 1] == '\r')) len -= 1;
    return alloc.dupe(u8, data[0..len]);
}

/// Parse /proc/PID/stat for CPU time, state, etc.
/// Returns: (utime, stime, state_char, num_threads, starttime, rss_pages)
pub const StatInfo = struct {
    utime: u64,
    stime: u64,
    state: u8,
    num_threads: i32,
    starttime: u64,
    rss_pages: i64,
    vsize: u64,
};

pub fn readStat(pid: i32) !StatInfo {
    var buf: [2048]u8 = undefined;
    const data = try readProcFile(&buf, "/proc/{d}/stat", .{pid});

    // Find the end of comm field (last ')')
    const comm_end = std.mem.lastIndexOf(u8, data, ")") orelse return error.ParseError;
    if (comm_end + 2 >= data.len) return error.ParseError;

    // Fields after comm: state(1) ppid(2) pgrp(3) session(4) tty(5) tpgid(6) flags(7)
    // minflt(8) cminflt(9) majflt(10) cmajflt(11) utime(12) stime(13) cutime(14) cstime(15)
    // priority(16) nice(17) num_threads(18) itrealvalue(19) starttime(20) vsize(21) rss(22)
    const remaining = data[comm_end + 2 ..];
    var field_idx: usize = 0;
    var info = StatInfo{
        .utime = 0,
        .stime = 0,
        .state = '?',
        .num_threads = 0,
        .starttime = 0,
        .rss_pages = 0,
        .vsize = 0,
    };

    var iter = std.mem.tokenizeScalar(u8, remaining, ' ');
    while (iter.next()) |token| {
        switch (field_idx) {
            0 => info.state = token[0], // state
            11 => info.utime = std.fmt.parseInt(u64, token, 10) catch 0, // utime
            12 => info.stime = std.fmt.parseInt(u64, token, 10) catch 0, // stime
            17 => info.num_threads = std.fmt.parseInt(i32, token, 10) catch 0, // num_threads
            19 => info.starttime = std.fmt.parseInt(u64, token, 10) catch 0, // starttime
            20 => info.vsize = std.fmt.parseInt(u64, token, 10) catch 0, // vsize
            21 => info.rss_pages = std.fmt.parseInt(i64, token, 10) catch 0, // rss
            else => {},
        }
        field_idx += 1;
        if (field_idx > 22) break;
    }
    return info;
}

/// Parse /proc/PID/status for detailed status info
pub fn readStatus(pid: i32) !types.StatusRecord {
    var buf: [4096]u8 = undefined;
    const data = readProcFile(&buf, "/proc/{d}/status", .{pid}) catch return error.ProcReadFailed;

    var record = types.StatusRecord{
        .ts = 0,
        .pid = pid,
        .state = "",
        .threads = 0,
        .vm_rss_kb = 0,
        .vm_swap_kb = 0,
        .voluntary_ctxt_switches = 0,
        .nonvoluntary_ctxt_switches = 0,
    };

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "State:")) {
            record.state = std.mem.trim(u8, line["State:".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "Threads:")) {
            const val = std.mem.trim(u8, line["Threads:".len..], " \t");
            record.threads = std.fmt.parseInt(i32, val, 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "VmRSS:")) {
            const val = std.mem.trim(u8, line["VmRSS:".len..], " \tkB");
            record.vm_rss_kb = std.fmt.parseInt(i64, val, 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "VmSwap:")) {
            const val = std.mem.trim(u8, line["VmSwap:".len..], " \tkB");
            record.vm_swap_kb = std.fmt.parseInt(i64, val, 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "voluntary_ctxt_switches:")) {
            const val = std.mem.trim(u8, line["voluntary_ctxt_switches:".len..], " \t");
            record.voluntary_ctxt_switches = std.fmt.parseInt(i64, val, 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "nonvoluntary_ctxt_switches:")) {
            const val = std.mem.trim(u8, line["nonvoluntary_ctxt_switches:".len..], " \t");
            record.nonvoluntary_ctxt_switches = std.fmt.parseInt(i64, val, 10) catch 0;
        }
    }
    return record;
}

/// List open FDs for a PID by reading /proc/PID/fd/
pub fn listFds(alloc: Allocator, pid: i32) ![]types.FdRecord {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/fd", .{pid}) catch return error.PathTooLong;

    var dir = std.fs.openDirAbsoluteZ(path, .{ .iterate = true }) catch return alloc.alloc(types.FdRecord, 0);
    defer dir.close();

    var fds: std.ArrayList(types.FdRecord) = .empty;
    errdefer {
        for (fds.items) |fd| alloc.free(fd.path);
        fds.deinit(alloc);
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const fd_num = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        // Read the symlink target
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        var fd_path_buf: [128]u8 = undefined;
        const fd_path = std.fmt.bufPrintZ(&fd_path_buf, "/proc/{d}/fd/{s}", .{ pid, entry.name }) catch continue;
        const target = std.fs.readLinkAbsoluteZ(fd_path, &link_buf) catch "unknown";

        const fd_type: types.FdRecord.FdType = if (std.mem.startsWith(u8, target, "socket:"))
            .socket
        else if (std.mem.startsWith(u8, target, "pipe:"))
            .pipe
        else if (std.mem.startsWith(u8, target, "anon_inode:"))
            .anon_inode
        else if (std.mem.startsWith(u8, target, "/dev/"))
            .device
        else if (std.mem.endsWith(u8, target, "/"))
            .directory
        else
            .regular;

        try fds.append(alloc, .{
            .ts = 0,
            .pid = pid,
            .fd_num = fd_num,
            .fd_type = fd_type,
            .path = try alloc.dupe(u8, target),
        });
    }

    return fds.toOwnedSlice(alloc);
}

/// Parse hex IP address from /proc/net/tcp format
fn parseHexAddr(hex: []const u8) ![4]u8 {
    if (hex.len < 8) return error.InvalidAddr;
    const val = std.fmt.parseInt(u32, hex[0..8], 16) catch return error.InvalidAddr;
    return .{
        @truncate(val),
        @truncate(val >> 8),
        @truncate(val >> 16),
        @truncate(val >> 24),
    };
}

fn formatAddr(buf: []u8, addr: [4]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ addr[0], addr[1], addr[2], addr[3] });
}

/// Parse /proc/PID/net/tcp and /proc/PID/net/tcp6 for network connections
pub fn readNetConnections(alloc: Allocator, pid: i32) ![]types.NetConnection {
    var conns: std.ArrayList(types.NetConnection) = .empty;
    errdefer conns.deinit(alloc);

    // First, build a set of socket inodes owned by this PID
    var inode_set = std.AutoHashMap(u64, void).init(alloc);
    defer inode_set.deinit();

    {
        var path_buf: [64]u8 = undefined;
        const fd_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/fd", .{pid}) catch return conns.toOwnedSlice(alloc);
        var dir = std.fs.openDirAbsoluteZ(fd_path, .{ .iterate = true }) catch return conns.toOwnedSlice(alloc);
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            var fd_entry_buf: [128]u8 = undefined;
            const entry_path = std.fmt.bufPrintZ(&fd_entry_buf, "/proc/{d}/fd/{s}", .{ pid, entry.name }) catch continue;
            const target = std.fs.readLinkAbsoluteZ(entry_path, &link_buf) catch continue;
            if (std.mem.startsWith(u8, target, "socket:[")) {
                const end = std.mem.indexOf(u8, target, "]") orelse continue;
                const inode = std.fmt.parseInt(u64, target["socket:[".len..end], 10) catch continue;
                inode_set.put(inode, {}) catch continue;
            }
        }
    }

    // Parse /proc/net/tcp (and tcp6, udp, udp6)
    const net_suffixes = [_]struct { suffix: []const u8, proto: types.NetConnection.Protocol, is_ipv4: bool }{
        .{ .suffix = "/net/tcp", .proto = .tcp, .is_ipv4 = true },
        .{ .suffix = "/net/tcp6", .proto = .tcp6, .is_ipv4 = false },
        .{ .suffix = "/net/udp", .proto = .udp, .is_ipv4 = true },
        .{ .suffix = "/net/udp6", .proto = .udp6, .is_ipv4 = false },
    };

    for (net_suffixes) |nf| {
        var path_buf2: [128]u8 = undefined;
        const net_path = std.fmt.bufPrintZ(&path_buf2, "/proc/{d}{s}", .{ pid, nf.suffix }) catch continue;
        const file = std.fs.openFileAbsoluteZ(net_path, .{}) catch continue;
        defer file.close();
        var buf: [65536]u8 = undefined;
        const n = file.read(&buf) catch continue;
        const data = buf[0..n];

        var lines = std.mem.splitScalar(u8, data, '\n');
        _ = lines.next(); // skip header

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");

            _ = fields.next() orelse continue; // sl
            const local = fields.next() orelse continue;
            const remote = fields.next() orelse continue;
            const state_hex = fields.next() orelse continue;
            _ = fields.next() orelse continue; // tx_queue:rx_queue
            _ = fields.next() orelse continue; // tr:tm->when
            _ = fields.next() orelse continue; // retrnsmt
            _ = fields.next() orelse continue; // uid
            _ = fields.next() orelse continue; // timeout
            const inode_str = fields.next() orelse continue;

            const inode = std.fmt.parseInt(u64, inode_str, 10) catch continue;
            if (!inode_set.contains(inode)) continue;

            // Parse local addr:port
            const local_colon = std.mem.indexOf(u8, local, ":") orelse continue;
            const remote_colon = std.mem.indexOf(u8, remote, ":") orelse continue;

            const local_port = std.fmt.parseInt(u16, local[local_colon + 1 ..], 16) catch continue;
            const remote_port = std.fmt.parseInt(u16, remote[remote_colon + 1 ..], 16) catch continue;

            var local_addr_buf: [64]u8 = undefined;
            var remote_addr_buf: [64]u8 = undefined;

            const local_addr_str = if (nf.is_ipv4) blk: {
                const addr = parseHexAddr(local[0..local_colon]) catch continue;
                break :blk formatAddr(&local_addr_buf, addr) catch continue;
            } else blk: {
                break :blk std.fmt.bufPrint(&local_addr_buf, "{s}", .{local[0..local_colon]}) catch continue;
            };

            const remote_addr_str = if (nf.is_ipv4) blk: {
                const addr = parseHexAddr(remote[0..remote_colon]) catch continue;
                break :blk formatAddr(&remote_addr_buf, addr) catch continue;
            } else blk: {
                break :blk std.fmt.bufPrint(&remote_addr_buf, "{s}", .{remote[0..remote_colon]}) catch continue;
            };

            const state_val = std.fmt.parseInt(u8, state_hex, 16) catch 0;
            const state_str: []const u8 = switch (state_val) {
                0x01 => "ESTABLISHED",
                0x02 => "SYN_SENT",
                0x03 => "SYN_RECV",
                0x04 => "FIN_WAIT1",
                0x05 => "FIN_WAIT2",
                0x06 => "TIME_WAIT",
                0x07 => "CLOSE",
                0x08 => "CLOSE_WAIT",
                0x09 => "LAST_ACK",
                0x0A => "LISTEN",
                0x0B => "CLOSING",
                else => "UNKNOWN",
            };

            try conns.append(alloc, .{
                .ts = 0,
                .pid = pid,
                .protocol = nf.proto,
                .local_addr = try alloc.dupe(u8, local_addr_str),
                .local_port = local_port,
                .remote_addr = try alloc.dupe(u8, remote_addr_str),
                .remote_port = remote_port,
                .state = state_str,
            });
        }
    }

    return conns.toOwnedSlice(alloc);
}

/// Read /proc/PID/environ (null-separated key=value pairs)
/// Returns a slice of heap-allocated strings; caller must free each + the slice.
pub fn readEnviron(alloc: Allocator, pid: i32) ![][]const u8 {
    var path_buf: [64]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/environ", .{pid}) catch return error.PathTooLong;
    const file = std.fs.openFileAbsoluteZ(path_z, .{}) catch return error.ProcReadFailed;
    defer file.close();

    var buf: [65536]u8 = undefined;
    const n = file.read(&buf) catch return error.ProcReadFailed;
    if (n == 0) return alloc.alloc([]const u8, 0);

    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    var iter = std.mem.splitScalar(u8, buf[0..n], 0);
    while (iter.next()) |entry| {
        if (entry.len == 0) continue;
        try entries.append(alloc, try alloc.dupe(u8, entry));
    }

    return entries.toOwnedSlice(alloc);
}

/// Read /proc/PID/exe symlink target
pub fn readExePath(alloc: Allocator, pid: i32) ![]const u8 {
    var path_buf: [64]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/exe", .{pid}) catch return error.PathTooLong;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsoluteZ(path_z, &link_buf) catch return alloc.dupe(u8, "(unknown)");
    return alloc.dupe(u8, target);
}

/// Read /proc/PID/cwd symlink target
pub fn readCwd(alloc: Allocator, pid: i32) ![]const u8 {
    var path_buf: [64]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch return error.PathTooLong;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsoluteZ(path_z, &link_buf) catch return alloc.dupe(u8, "(unknown)");
    return alloc.dupe(u8, target);
}

/// Get system uptime in seconds from /proc/uptime
pub fn getUptime() !f64 {
    var buf: [128]u8 = undefined;
    const data = try readProcFile(&buf, "/proc/uptime", .{});
    var iter = std.mem.tokenizeScalar(u8, data, ' ');
    const uptime_str = iter.next() orelse return error.ParseError;
    return std.fmt.parseFloat(f64, uptime_str) catch error.ParseError;
}

/// Get system boot time from /proc/stat
pub fn getBootTime() !i64 {
    var buf: [8192]u8 = undefined;
    const data = readProcFile(&buf, "/proc/stat", .{}) catch return error.ProcReadFailed;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "btime ")) {
            const val = std.mem.trim(u8, line["btime ".len..], " \t\n");
            return std.fmt.parseInt(i64, val, 10) catch error.ParseError;
        }
    }
    return error.ParseError;
}

/// Get clock ticks per second
pub fn getClkTck() u64 {
    // sysconf(_SC_CLK_TCK) — typically 100 on Linux
    return 100;
}

const testing = std.testing;

test "parseHexAddr: loopback 0100007F → 127.0.0.1" {
    const addr = try parseHexAddr("0100007F");
    try testing.expectEqual(@as(u8, 127), addr[0]);
    try testing.expectEqual(@as(u8, 0), addr[1]);
    try testing.expectEqual(@as(u8, 0), addr[2]);
    try testing.expectEqual(@as(u8, 1), addr[3]);
}

test "parseHexAddr: all zeros" {
    const addr = try parseHexAddr("00000000");
    try testing.expectEqual(@as(u8, 0), addr[0]);
    try testing.expectEqual(@as(u8, 0), addr[1]);
    try testing.expectEqual(@as(u8, 0), addr[2]);
    try testing.expectEqual(@as(u8, 0), addr[3]);
}

test "parseHexAddr: too short returns error" {
    try testing.expectError(error.InvalidAddr, parseHexAddr("0100"));
}

test "parseHexAddr: non-hex returns error" {
    try testing.expectError(error.InvalidAddr, parseHexAddr("ZZZZZZZZ"));
}

test "formatAddr: loopback" {
    var buf: [64]u8 = undefined;
    const result = try formatAddr(&buf, .{ 127, 0, 0, 1 });
    try testing.expectEqualStrings("127.0.0.1", result);
}

test "formatAddr: all zeros" {
    var buf: [64]u8 = undefined;
    const result = try formatAddr(&buf, .{ 0, 0, 0, 0 });
    try testing.expectEqualStrings("0.0.0.0", result);
}

test "formatAddr: max values" {
    var buf: [64]u8 = undefined;
    const result = try formatAddr(&buf, .{ 255, 255, 255, 255 });
    try testing.expectEqualStrings("255.255.255.255", result);
}

test "getClkTck returns 100" {
    try testing.expectEqual(@as(u64, 100), getClkTck());
}
