// GUI renderer — stub (requires raylib integration)
// Will be implemented in Phase 4

const std = @import("std");
const state_mod = @import("../ui/state.zig");
const reader_mod = @import("../store/reader.zig");
const input_mod = @import("../ui/input.zig");

pub const GuiRenderer = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !GuiRenderer {
        std.log.info("GUI renderer: raylib not yet integrated. Use --headless or TUI mode.", .{});
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *GuiRenderer) void {
        _ = self;
    }

    pub fn render(self: *GuiRenderer, ui_state: *state_mod.UiState, reader: *reader_mod.Reader) void {
        _ = self;
        _ = ui_state;
        _ = reader;
    }

    pub fn pollInput(self: *GuiRenderer) input_mod.InputEvent {
        _ = self;
        // Sleep briefly to avoid busy loop
        std.time.sleep(100 * std.time.ns_per_ms);
        return .none;
    }
};
