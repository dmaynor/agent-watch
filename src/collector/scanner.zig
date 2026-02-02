const std = @import("std");
const builtin = @import("builtin");
const types = @import("../data/types.zig");

const platform = switch (builtin.os.tag) {
    .linux => @import("platform_linux.zig"),
    .macos => @import("platform_macos.zig"),
    .windows => @import("platform_windows.zig"),
    else => @compileError("Unsupported platform"),
};

const Allocator = std.mem.Allocator;

/// Discovered agent process
pub const DiscoveredProcess = struct {
    pid: i32,
    comm: []const u8,
    cmdline: []const u8,
};

/// Scan all processes and return those matching the agent regex pattern
pub fn scanForAgents(alloc: Allocator, match_pattern: []const u8) ![]DiscoveredProcess {
    const all_pids = try platform.listPids(alloc);
    defer alloc.free(all_pids);

    var agents: std.ArrayList(DiscoveredProcess) = .empty;
    errdefer agents.deinit(alloc);

    for (all_pids) |pid| {
        const comm = platform.readComm(alloc, pid) catch continue;
        const cmdline = platform.readCmdline(alloc, pid) catch {
            alloc.free(comm);
            continue;
        };

        if (matchesPattern(comm, match_pattern) or matchesPattern(cmdline, match_pattern)) {
            // Skip ourselves
            const my_pid = std.c.getpid();
            if (pid == @as(i32, @intCast(my_pid))) {
                alloc.free(comm);
                alloc.free(cmdline);
                continue;
            }
            try agents.append(alloc, .{
                .pid = pid,
                .comm = comm,
                .cmdline = cmdline,
            });
        } else {
            alloc.free(comm);
            alloc.free(cmdline);
        }
    }

    return agents.toOwnedSlice(alloc);
}

/// Simple case-insensitive substring match against pipe-separated patterns
/// Pattern format: "codex|claude|gemini|copilot"
fn matchesPattern(text: []const u8, pattern: []const u8) bool {
    var pat_iter = std.mem.splitScalar(u8, pattern, '|');
    while (pat_iter.next()) |sub_pattern| {
        if (sub_pattern.len == 0) continue;
        if (containsIgnoreCase(text, sub_pattern)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

pub fn freeDiscovered(alloc: Allocator, agents: []DiscoveredProcess) void {
    for (agents) |a| {
        alloc.free(a.comm);
        alloc.free(a.cmdline);
    }
    alloc.free(agents);
}

const testing = std.testing;

test "matchesPattern: basic match" {
    try testing.expect(matchesPattern("claude", "codex|claude|gemini"));
}

test "matchesPattern: no match" {
    try testing.expect(!matchesPattern("nginx", "codex|claude|gemini"));
}

test "matchesPattern: substring match" {
    try testing.expect(matchesPattern("my-claude-code", "claude"));
}

test "matchesPattern: case insensitive" {
    try testing.expect(matchesPattern("Claude", "claude"));
    try testing.expect(matchesPattern("CLAUDE", "claude"));
}

test "matchesPattern: empty pattern" {
    try testing.expect(!matchesPattern("anything", ""));
}

test "matchesPattern: empty text" {
    try testing.expect(!matchesPattern("", "claude"));
}

test "containsIgnoreCase: basic" {
    try testing.expect(containsIgnoreCase("Hello World", "hello"));
    try testing.expect(containsIgnoreCase("Hello World", "WORLD"));
    try testing.expect(!containsIgnoreCase("Hello", "World"));
}

test "containsIgnoreCase: needle longer than haystack" {
    try testing.expect(!containsIgnoreCase("hi", "hello world"));
}

test "toLower: converts uppercase" {
    try testing.expectEqual(@as(u8, 'a'), toLower('A'));
    try testing.expectEqual(@as(u8, 'z'), toLower('Z'));
    try testing.expectEqual(@as(u8, '1'), toLower('1')); // non-alpha unchanged
}
