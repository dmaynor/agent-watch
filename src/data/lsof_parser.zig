const std = @import("std");
const types = @import("types.zig");
const writer_mod = @import("../store/writer.zig");

/// Import a .lsof file into SQLite
pub fn importLsofFile(alloc: std.mem.Allocator, path: []const u8, writer: *writer_mod.Writer) !ImportResult {
    var result = ImportResult{};

    // Extract PID and timestamp from filename
    // Format: 20260201T230250.111574346_64493.lsof
    const basename = std.fs.path.basename(path);
    const ts_pid = parseFilename(basename) orelse return result;

    const file = std.fs.openFileAbsolute(path, .{}) catch return result;
    defer file.close();

    const data = file.readToEndAlloc(alloc, 16 * 1024 * 1024) catch return result;
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    // Skip header line
    _ = lines.next();

    var fd_num: i32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        result.lines_read += 1;

        // Parse lsof output: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // COMMAND
        _ = fields.next() orelse continue; // PID
        _ = fields.next() orelse continue; // USER
        const fd_str = fields.next() orelse continue; // FD
        const type_str = fields.next() orelse continue; // TYPE
        _ = fields.next() orelse continue; // DEVICE
        _ = fields.next() orelse continue; // SIZE/OFF
        _ = fields.next() orelse continue; // NODE
        const name = fields.rest(); // NAME (rest of line)

        // Parse FD number (may have suffix like 'r', 'w', 'u')
        var fd_digits_end: usize = 0;
        while (fd_digits_end < fd_str.len and fd_str[fd_digits_end] >= '0' and fd_str[fd_digits_end] <= '9') {
            fd_digits_end += 1;
        }
        if (fd_digits_end > 0) {
            fd_num = std.fmt.parseInt(i32, fd_str[0..fd_digits_end], 10) catch fd_num;
        }

        writer.writeFd(.{
            .ts = ts_pid.ts,
            .pid = ts_pid.pid,
            .fd_num = fd_num,
            .fd_type = types.FdRecord.FdType.fromString(type_str),
            .path = name,
        }) catch {
            result.write_errors += 1;
            continue;
        };
        result.fds_written += 1;
        fd_num += 1;
    }

    return result;
}

fn parseFilename(name: []const u8) ?struct { ts: types.Timestamp, pid: i32 } {
    // Format: 20260201T230250.111574346_64493.lsof
    const underscore = std.mem.indexOf(u8, name, "_") orelse return null;
    const dot = std.mem.lastIndexOf(u8, name, ".") orelse return null;
    if (dot <= underscore) return null;

    const pid = std.fmt.parseInt(i32, name[underscore + 1 .. dot], 10) catch return null;

    // Parse timestamp: 20260201T230250
    if (underscore < 15) return null;
    const ts_part = name[0..underscore];
    // Find the dot in nanoseconds
    const nano_dot = std.mem.indexOf(u8, ts_part, ".") orelse ts_part.len;
    if (nano_dot < 15) return null;

    // 20260201T230250 → 2026-02-01T23:02:50Z
    var ts_buf: [32]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{s}-{s}-{s}T{s}:{s}:{s}Z", .{
        ts_part[0..4],
        ts_part[4..6],
        ts_part[6..8],
        ts_part[9..11],
        ts_part[11..13],
        ts_part[13..15],
    }) catch return null;

    const ts = types.parseTimestamp(ts_str) catch return null;
    return .{ .ts = ts, .pid = pid };
}

pub const ImportResult = struct {
    lines_read: usize = 0,
    fds_written: usize = 0,
    write_errors: usize = 0,
};

const testing = std.testing;

test "parseFilename: valid lsof filename" {
    const result = parseFilename("20260201T230250.111574346_64493.lsof");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 64493), result.?.pid);
}

test "parseFilename: missing underscore returns null" {
    try testing.expect(parseFilename("invalid.lsof") == null);
}

test "parseFilename: too short timestamp" {
    try testing.expect(parseFilename("short_123.lsof") == null);
}

test "parseFilename: bad pid returns null" {
    try testing.expect(parseFilename("20260201T230250.111_abc.lsof") == null);
}

test "parseFilename: valid status filename also works" {
    const result = parseFilename("20260201T230250.111574346_1234.status");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 1234), result.?.pid);
}
