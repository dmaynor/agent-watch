const std = @import("std");
const types = @import("types.zig");
const writer_mod = @import("../store/writer.zig");

/// Import process.ndjson file into SQLite
pub fn importNdjson(path: []const u8, writer: *writer_mod.Writer) !ImportResult {
    var result = ImportResult{};

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    var line_buf: [16384]u8 = undefined;

    while (reader.readUntilDelimiter(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;
        result.lines_read += 1;

        const sample = parseLine(line) catch {
            result.parse_errors += 1;
            continue;
        };

        writer.writeSample(sample) catch {
            result.write_errors += 1;
            continue;
        };

        writer.upsertAgent(sample.pid, sample.comm, sample.args, sample.ts) catch {};
        result.samples_written += 1;
    } else |err| {
        if (err != error.EndOfStream) return err;
    }

    return result;
}

fn parseLine(line: []const u8) !types.ProcessSample {
    // Simple JSON parsing for known format
    const ts_str = extractString(line, "\"ts\":\"", "\"") orelse return error.ParseError;
    const ts = try types.parseTimestamp(ts_str);

    return types.ProcessSample{
        .ts = ts,
        .pid = extractInt(i32, line, "\"pid\":") orelse return error.ParseError,
        .user = extractString(line, "\"user\":\"", "\"") orelse "unknown",
        .cpu = extractFloat(line, "\"cpu\":") orelse 0,
        .mem = extractFloat(line, "\"mem\":") orelse 0,
        .rss_kb = extractInt(i64, line, "\"rss_kb\":") orelse 0,
        .stat = extractString(line, "\"stat\":\"", "\"") orelse "?",
        .etimes = extractInt(i64, line, "\"etimes\":") orelse 0,
        .comm = extractString(line, "\"comm\":\"", "\"") orelse "unknown",
        .args = extractString(line, "\"args\":\"", "\"") orelse "",
    };
}

fn extractString(json: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= json.len) return null;

    // Find end, handling escaped quotes
    var i = value_start;
    while (i < json.len) {
        if (json[i] == '\\') {
            i += 2; // skip escaped char
            continue;
        }
        if (std.mem.startsWith(u8, json[i..], suffix)) {
            return json[value_start..i];
        }
        i += 1;
    }
    return null;
}

fn extractInt(comptime T: type, json: []const u8, prefix: []const u8) ?T {
    const start = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= json.len) return null;

    var end = value_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9' or json[end] == '-')) {
        end += 1;
    }
    if (end == value_start) return null;
    return std.fmt.parseInt(T, json[value_start..end], 10) catch null;
}

fn extractFloat(json: []const u8, prefix: []const u8) ?f64 {
    const start = std.mem.indexOf(u8, json, prefix) orelse return null;
    const value_start = start + prefix.len;
    if (value_start >= json.len) return null;

    var end = value_start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9' or json[end] == '.' or json[end] == '-' or json[end] == 'e' or json[end] == 'E' or json[end] == '+')) {
        end += 1;
    }
    if (end == value_start) return null;
    return std.fmt.parseFloat(f64, json[value_start..end]) catch null;
}

pub const ImportResult = struct {
    lines_read: usize = 0,
    samples_written: usize = 0,
    parse_errors: usize = 0,
    write_errors: usize = 0,
};
