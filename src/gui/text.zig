/// Text rendering helpers for raylib GUI
const rl = @import("raylib_backend.zig");

pub const FONT_SIZE = 16;
pub const LINE_HEIGHT = 20;
pub const CHAR_WIDTH = 9; // approximate monospace width at size 16

pub fn drawText(text: [*:0]const u8, x: c_int, y: c_int, color: rl.c.Color) void {
    if (!rl.enabled) return;
    rl.c.DrawText(text, x, y, FONT_SIZE, color);
}

pub fn drawTextFmt(buf: []u8, x: c_int, y: c_int, color: rl.c.Color, comptime fmt: []const u8, args: anytype) void {
    if (!rl.enabled) return;
    const std = @import("std");
    const msg = std.fmt.bufPrintZ(buf, fmt, args) catch return;
    rl.c.DrawText(msg.ptr, x, y, FONT_SIZE, color);
}
