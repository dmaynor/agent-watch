// Windows platform support — stub for cross-platform compilation
// Will use Win32 API (CreateToolhelp32Snapshot, etc.) via Zig C interop

const std = @import("std");
const types = @import("../data/types.zig");
const Allocator = std.mem.Allocator;

pub fn listPids(alloc: Allocator) ![]i32 {
    _ = alloc;
    return &[_]i32{};
}

pub fn readCmdline(alloc: Allocator, pid: i32) ![]const u8 {
    _ = pid;
    return alloc.dupe(u8, "");
}

pub fn readComm(alloc: Allocator, pid: i32) ![]const u8 {
    _ = pid;
    return alloc.dupe(u8, "unknown");
}

pub const StatInfo = struct {
    utime: u64 = 0,
    stime: u64 = 0,
    state: u8 = '?',
    num_threads: i32 = 0,
    starttime: u64 = 0,
    rss_pages: i64 = 0,
    vsize: u64 = 0,
};

pub fn readStat(pid: i32) !StatInfo {
    _ = pid;
    return error.ProcReadFailed;
}

pub fn readStatus(pid: i32) !types.StatusRecord {
    _ = pid;
    return error.ProcReadFailed;
}

pub fn listFds(alloc: Allocator, pid: i32) ![]types.FdRecord {
    _ = pid;
    return alloc.alloc(types.FdRecord, 0);
}

pub fn readNetConnections(alloc: Allocator, pid: i32) ![]types.NetConnection {
    _ = pid;
    return alloc.alloc(types.NetConnection, 0);
}

pub fn getClkTck() u64 {
    return 100;
}

pub fn getBootTime() !i64 {
    return error.ProcReadFailed;
}
