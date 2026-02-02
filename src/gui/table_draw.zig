/// Table drawing for raylib GUI
const std = @import("std");
const rl = @import("raylib_backend.zig");
const text = @import("text.zig");

const ROW_HEIGHT = text.LINE_HEIGHT + 2;
const HEADER_COLOR = if (rl.enabled) rl.c.Color{ .r = 220, .g = 200, .b = 50, .a = 255 } else {};
const ROW_COLOR = if (rl.enabled) rl.c.Color{ .r = 200, .g = 200, .b = 200, .a = 255 } else {};
const SELECTED_BG = if (rl.enabled) rl.c.Color{ .r = 50, .g = 50, .b = 80, .a = 255 } else {};

pub fn drawHeader(labels: []const []const u8, col_widths: []const c_int, x: c_int, y: c_int) void {
    if (!rl.enabled) return;
    var cx = x;
    var buf: [256]u8 = undefined;
    for (labels, col_widths) |label, w| {
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{label}) catch continue;
        rl.c.DrawText(z.ptr, cx, y, text.FONT_SIZE, HEADER_COLOR);
        cx += w;
    }
}

pub fn drawRow(values: []const []const u8, col_widths: []const c_int, x: c_int, y: c_int, selected: bool, color: rl.c.Color) void {
    if (!rl.enabled) return;
    if (selected) {
        rl.c.DrawRectangle(x, y - 2, 1200, ROW_HEIGHT, SELECTED_BG);
    }
    var cx = x;
    var buf: [256]u8 = undefined;
    for (values, col_widths) |val, w| {
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{val}) catch continue;
        rl.c.DrawText(z.ptr, cx, y, text.FONT_SIZE, color);
        cx += w;
    }
}
