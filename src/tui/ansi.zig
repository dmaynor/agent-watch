const std = @import("std");

/// ANSI escape code helpers
pub fn moveTo(buf: []u8, x: u16, y: u16) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch "";
}

pub fn clearScreen() []const u8 {
    return "\x1b[2J";
}

pub fn clearLine() []const u8 {
    return "\x1b[2K";
}

pub fn hideCursor() []const u8 {
    return "\x1b[?25l";
}

pub fn showCursor() []const u8 {
    return "\x1b[?25h";
}
