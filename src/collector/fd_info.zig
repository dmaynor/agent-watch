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

/// Collect all open file descriptors for a PID
pub fn collectFds(alloc: Allocator, pid: i32, now: types.Timestamp) ![]types.FdRecord {
    const fds = try platform.listFds(alloc, pid);
    for (fds) |*fd| {
        fd.ts = now;
    }
    return fds;
}
