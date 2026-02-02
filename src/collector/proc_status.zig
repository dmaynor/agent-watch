const std = @import("std");
const builtin = @import("builtin");
const types = @import("../data/types.zig");

const platform = switch (builtin.os.tag) {
    .linux => @import("platform_linux.zig"),
    .macos => @import("platform_macos.zig"),
    .windows => @import("platform_windows.zig"),
    else => @compileError("Unsupported platform"),
};

/// Read process status (threads, VmRSS, VmSwap, context switches)
pub fn collectStatus(pid: i32, now: types.Timestamp) !types.StatusRecord {
    var record = try platform.readStatus(pid);
    record.ts = now;
    return record;
}
