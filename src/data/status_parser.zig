const std = @import("std");
const types = @import("types.zig");
const writer_mod = @import("../store/writer.zig");

/// Import a .status file into SQLite
pub fn importStatusFile(path: []const u8, writer: *writer_mod.Writer) !ImportResult {
    var result = ImportResult{};

    // Extract PID from filename: 20260201T230250.111574346_64493.status
    const basename = std.fs.path.basename(path);
    const ts_pid = parseFilename(basename) orelse return result;

    const file = std.fs.openFileAbsolute(path, .{}) catch return result;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.read(&buf) catch return result;
    const data = buf[0..n];

    var record = types.StatusRecord{
        .ts = ts_pid.ts,
        .pid = ts_pid.pid,
        .state = "",
        .threads = 0,
        .vm_rss_kb = 0,
        .vm_swap_kb = 0,
        .voluntary_ctxt_switches = 0,
        .nonvoluntary_ctxt_switches = 0,
    };

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ts=")) {
            // Parse ts if present (override filename ts)
            const ts_str = line["ts=".len..];
            record.ts = types.parseTimestamp(ts_str) catch ts_pid.ts;
        } else if (std.mem.startsWith(u8, line, "State:")) {
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

    writer.writeStatus(record) catch {
        result.write_errors += 1;
        return result;
    };
    result.status_written += 1;

    return result;
}

fn parseFilename(name: []const u8) ?struct { ts: types.Timestamp, pid: i32 } {
    const underscore = std.mem.indexOf(u8, name, "_") orelse return null;
    const dot = std.mem.lastIndexOf(u8, name, ".") orelse return null;
    if (dot <= underscore) return null;

    const pid = std.fmt.parseInt(i32, name[underscore + 1 .. dot], 10) catch return null;

    if (underscore < 15) return null;
    const ts_part = name[0..underscore];
    const nano_dot = std.mem.indexOf(u8, ts_part, ".") orelse ts_part.len;
    if (nano_dot < 15) return null;

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
    status_written: usize = 0,
    write_errors: usize = 0,
};
