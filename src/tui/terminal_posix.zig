/// POSIX (Linux + macOS) terminal implementation using termios
const std = @import("std");
const input_mod = @import("../ui/input.zig");

pub const Terminal = struct {
    original_termios: std.posix.termios,
    stdout: std.fs.File,
    stdin: std.fs.File,

    pub fn init() !Terminal {
        const stdout = std.fs.File.stdout();
        const stdin = std.fs.File.stdin();

        const original = try std.posix.tcgetattr(stdin.handle);
        var raw = original;

        // Disable canonical mode, echo, signals
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Disable input processing
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

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

    pub fn deinit(self: *Terminal) void {
        // Leave alternate screen, show cursor
        self.stdout.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        std.posix.tcsetattr(self.stdin.handle, .FLUSH, self.original_termios) catch {};
    }

    pub fn getSize(self: *Terminal) struct { width: u16, height: u16 } {
        _ = self;
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(std.fs.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0) {
            return .{ .width = ws.col, .height = ws.row };
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
                return .{ .key = .other };
            }
        }

        return switch (buf[0]) {
            'q' => .{ .key = .quit },
            '\t' => .{ .key = .tab },
            'j' => .{ .key = .char_j },
            'k' => .{ .key = .char_k },
            '\r', '\n' => .{ .key = .enter },
            0x7F, 0x08 => .{ .key = .backspace },
            0x20...('j' - 1), ('k' + 1)...('q' - 1), ('q' + 1)...0x7E => .{ .key = .{ .char = buf[0] } },
            else => .{ .key = .other },
        };
    }

    pub fn write(self: *Terminal, data: []const u8) void {
        self.stdout.writeAll(data) catch {};
    }
};
