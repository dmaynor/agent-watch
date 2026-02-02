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

/// Collect all network connections for a PID
pub fn collectConnections(alloc: Allocator, pid: i32, now: types.Timestamp) ![]types.NetConnection {
    const conns = try platform.readNetConnections(alloc, pid);
    for (conns) |*conn| {
        conn.ts = now;
    }
    return conns;
}
