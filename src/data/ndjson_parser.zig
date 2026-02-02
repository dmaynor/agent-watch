const std = @import("std");
const types = @import("types.zig");
const writer_mod = @import("../store/writer.zig");

/// Import process.ndjson file into SQLite
pub fn importNdjson(alloc: std.mem.Allocator, path: []const u8, writer: *writer_mod.Writer) !ImportResult {
    var result = ImportResult{};

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const data = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch return result;
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
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

const testing = std.testing;
const helpers = @import("../testing/helpers.zig");

test "extractString: finds value" {
    const json = "{\"user\":\"admin\",\"pid\":42}";
    const val = extractString(json, "\"user\":\"", "\"");
    try testing.expect(val != null);
    try testing.expectEqualStrings("admin", val.?);
}

test "extractString: missing prefix returns null" {
    const json = "{\"pid\":42}";
    try testing.expect(extractString(json, "\"user\":\"", "\"") == null);
}

test "extractString: empty value" {
    const json = "{\"args\":\"\"}";
    const val = extractString(json, "\"args\":\"", "\"");
    try testing.expect(val != null);
    try testing.expectEqualStrings("", val.?);
}

test "extractInt: finds integer" {
    const json = "{\"pid\":12345,\"cpu\":1.5}";
    const val = extractInt(i32, json, "\"pid\":");
    try testing.expect(val != null);
    try testing.expectEqual(@as(i32, 12345), val.?);
}

test "extractInt: negative integer" {
    const json = "{\"offset\":-100}";
    const val = extractInt(i64, json, "\"offset\":");
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, -100), val.?);
}

test "extractInt: missing returns null" {
    const json = "{\"pid\":42}";
    try testing.expect(extractInt(i32, json, "\"missing\":") == null);
}

test "extractFloat: finds float" {
    const json = "{\"cpu\":45.67,\"pid\":1}";
    const val = extractFloat(json, "\"cpu\":");
    try testing.expect(val != null);
    try helpers.expectApproxEqual(45.67, val.?, 0.001);
}

test "extractFloat: integer as float" {
    const json = "{\"cpu\":100}";
    const val = extractFloat(json, "\"cpu\":");
    try testing.expect(val != null);
    try helpers.expectApproxEqual(100.0, val.?, 0.001);
}

test "parseLine: valid NDJSON" {
    const line = "{\"ts\":\"2026-02-01T12:00:00Z\",\"pid\":42,\"user\":\"root\",\"cpu\":5.5,\"mem\":1.2,\"rss_kb\":102400,\"stat\":\"S\",\"etimes\":3600,\"comm\":\"claude\",\"args\":\"claude --code\"}";
    const sample = try parseLine(line);
    try testing.expectEqual(@as(i32, 42), sample.pid);
    try testing.expectEqualStrings("root", sample.user);
    try helpers.expectApproxEqual(5.5, sample.cpu, 0.01);
    try testing.expectEqualStrings("claude", sample.comm);
}

test "parseLine: missing pid returns error" {
    const line = "{\"ts\":\"2026-02-01T12:00:00Z\",\"user\":\"root\"}";
    try testing.expectError(error.ParseError, parseLine(line));
}

test "parseLine: empty line" {
    // parseLine is called only on non-empty lines by importNdjson
    // but it should handle bad input gracefully
    try testing.expectError(error.ParseError, parseLine(""));
}

test "parseLine: malformed JSON" {
    try testing.expectError(error.ParseError, parseLine("not json at all"));
}
