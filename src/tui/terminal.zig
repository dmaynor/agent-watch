const std = @import("std");
const builtin = @import("builtin");
const input_mod = @import("../ui/input.zig");

/// Terminal raw mode handler
pub const Terminal = struct {
    original_termios: if (builtin.os.tag == .linux or builtin.os.tag == .macos) std.posix.termios else void,
    stdout: std.fs.File,
    stdin: std.fs.File,

    pub fn init() !Terminal {
        const stdout = std.fs.File.stdout();
        const stdin = std.fs.File.stdin();

        if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
            const original = try std.posix.tcgetattr(stdin.handle);
            var raw = original;

            // Disable canonical mode, echo, signals
            raw.lflag = raw.lflag.intersection(.{
                .ECHO = false,
                .ICANON = false,
                .ISIG = false,
                .IEXTEN = false,
            });

            // Disable input processing
            raw.iflag = raw.iflag.intersection(.{
                .IXON = false,
                .ICRNL = false,
                .BRKINT = false,
                .INPCK = false,
                .ISTRIP = false,
            });

            // Minimum 0 chars, timeout 100ms
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

            try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

            // Enter alternate screen, hide cursor
            stdout.writeAll("\x1b[?1049h\x1b[?25l") catch {};

            return .{
                .original_termios = original,
                .stdout = stdout,
                .stdin = stdin,
            };
        }
        return .{
            .original_termios = {},
            .stdout = stdout,
            .stdin = stdin,
        };
    }

    pub fn deinit(self: *Terminal) void {
        // Leave alternate screen, show cursor
        self.stdout.writeAll("\x1b[?25h\x1b[?1049l") catch {};

        if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
            std.posix.tcsetattr(self.stdin.handle, .FLUSH, self.original_termios) catch {};
        }
    }

    pub fn getSize(self: *Terminal) struct { width: u16, height: u16 } {
        _ = self;
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
            var ws: std.posix.winsize = undefined;
            const rc = std.posix.system.ioctl(std.fs.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
            if (rc == 0) {
                return .{ .width = ws.ws_col, .height = ws.ws_row };
            }
        }
        return .{ .width = 80, .height = 24 };
    }

    /// Non-blocking read of input
    pub fn pollInput(self: *Terminal) input_mod.InputEvent {
        var buf: [16]u8 = undefined;
        const n = self.stdin.read(&buf) catch return .none;
        if (n == 0) return .none;

        // Parse escape sequences
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
                        // F12 = \x1b[24~
                        if (n >= 4 and buf[2] == '2' and buf[3] == '4') {
                            break :blk .{ .key = .f12 };
                        }
                        break :blk .{ .key = .other };
                    },
                };
            }
            if (n >= 3 and buf[1] == 'O') {
                // Some terminals send F12 as \x1bO24~
                return .{ .key = .other };
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
