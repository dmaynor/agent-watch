/// Windows terminal implementation using Console API
/// Enables Virtual Terminal Processing for ANSI escape sequence support
const std = @import("std");
const input_mod = @import("../ui/input.zig");

pub const Terminal = struct {
    stdout: std.fs.File,
    stdin: std.fs.File,

    pub fn init() !Terminal {
        const stdout = std.fs.File.stdout();
        const stdin = std.fs.File.stdin();

        // On Windows, we would call:
        // GetConsoleMode / SetConsoleMode with ENABLE_VIRTUAL_TERMINAL_PROCESSING
        // For now this is a stub that will compile on Windows targets

        // Enter alternate screen, hide cursor (VT sequences work if VTP enabled)
        stdout.writeAll("\x1b[?1049h\x1b[?25l") catch {};

        return .{
            .stdout = stdout,
            .stdin = stdin,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.stdout.writeAll("\x1b[?25h\x1b[?1049l") catch {};
    }

    pub fn getSize(self: *Terminal) struct { width: u16, height: u16 } {
        _ = self;
        // Windows: would use GetConsoleScreenBufferInfo
        return .{ .width = 120, .height = 30 };
    }

    pub fn pollInput(self: *Terminal) input_mod.InputEvent {
        var buf: [16]u8 = undefined;
        const n = self.stdin.read(&buf) catch return .none;
        if (n == 0) return .none;

        if (buf[0] == 0x1b) {
            if (n == 1) return .{ .key = .escape };
            if (n >= 3 and buf[1] == '[') {
                return switch (buf[2]) {
                    'A' => .{ .key = .up },
                    'B' => .{ .key = .down },
                    'C' => .{ .key = .right },
                    'D' => .{ .key = .left },
                    'Z' => .{ .key = .shift_tab },
                    else => blk: {
                        if (n >= 4 and buf[2] == '2' and buf[3] == '4') {
                            break :blk .{ .key = .f12 };
                        }
                        break :blk .{ .key = .other };
                    },
                };
            }
        }

        return switch (buf[0]) {
            'q' => .{ .key = .quit },
            '\t' => .{ .key = .tab },
            'j' => .{ .key = .down },
            'k' => .{ .key = .up },
            '\r', '\n' => .{ .key = .enter },
            else => .{ .key = .other },
        };
    }

    pub fn write(self: *Terminal, data: []const u8) void {
        self.stdout.writeAll(data) catch {};
    }
};
