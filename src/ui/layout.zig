/// Abstract layout primitives
pub const Layout = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn shrink(self: Layout, padding: u16) Layout {
        if (self.width <= padding * 2 or self.height <= padding * 2) return self;
        return .{
            .x = self.x + padding,
            .y = self.y + padding,
            .width = self.width - padding * 2,
            .height = self.height - padding * 2,
        };
    }

    pub fn splitHorizontal(self: Layout, top_height: u16) struct { top: Layout, bottom: Layout } {
        const h = @min(top_height, self.height);
        return .{
            .top = .{ .x = self.x, .y = self.y, .width = self.width, .height = h },
            .bottom = .{ .x = self.x, .y = self.y + h, .width = self.width, .height = self.height -| h },
        };
    }

    pub fn splitVertical(self: Layout, left_width: u16) struct { left: Layout, right: Layout } {
        const w = @min(left_width, self.width);
        return .{
            .left = .{ .x = self.x, .y = self.y, .width = w, .height = self.height },
            .right = .{ .x = self.x + w, .y = self.y, .width = self.width -| w, .height = self.height },
        };
    }
};
