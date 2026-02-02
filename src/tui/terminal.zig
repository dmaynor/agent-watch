/// Platform-dispatching terminal module
/// Routes to the appropriate platform-specific implementation at comptime
const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .linux, .macos => @import("terminal_posix.zig"),
    .windows => @import("terminal_windows.zig"),
    else => @import("terminal_posix.zig"), // fallback to posix for other unix-likes
};

pub const Terminal = platform.Terminal;
