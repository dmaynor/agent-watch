const std = @import("std");

/// Double-buffered text rendering buffer
pub const Buffer = struct {
    data: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Buffer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Buffer) void {
        self.data.deinit(self.alloc);
    }

    pub fn clear(self: *Buffer) void {
        self.data.clearRetainingCapacity();
    }

    pub fn writer(self: *Buffer) std.ArrayList(u8).Writer {
        return self.data.writer(self.alloc);
    }

    pub fn moveTo(self: *Buffer, x: u16, y: u16) void {
        std.fmt.format(self.data.writer(self.alloc), "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch {};
    }

    pub fn print(self: *Buffer, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(self.data.writer(self.alloc), fmt, args) catch {};
    }

    pub fn writeStr(self: *Buffer, s: []const u8) void {
        self.data.appendSlice(self.alloc, s) catch {};
    }

    pub fn flush(self: *Buffer, file: std.fs.File) void {
        file.writeAll(self.data.items) catch {};
    }
};
