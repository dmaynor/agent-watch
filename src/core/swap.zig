const std = @import("std");
const tui_mod = @import("../tui/renderer.zig");
const gui_mod = @import("../gui/renderer.zig");
const state_mod = @import("../ui/state.zig");
const reader_mod = @import("../store/reader.zig");
const input_mod = @import("../ui/input.zig");
const config_mod = @import("../config.zig");

/// Active renderer type
pub const RendererType = enum {
    tui,
    gui,
};

/// Hot-swappable renderer coordinator
pub const SwapRenderer = struct {
    tui: ?tui_mod.TuiRenderer = null,
    gui: ?gui_mod.GuiRenderer = null,
    active: RendererType,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, start_gui: bool) !SwapRenderer {
        var self = SwapRenderer{
            .active = if (start_gui) .gui else .tui,
            .alloc = alloc,
        };

        if (start_gui) {
            self.gui = try gui_mod.GuiRenderer.init(alloc);
        } else {
            self.tui = try tui_mod.TuiRenderer.init(alloc);
        }

        return self;
    }

    pub fn deinit(self: *SwapRenderer) void {
        if (self.tui) |*t| t.deinit();
        if (self.gui) |*g| g.deinit();
    }

    pub fn swap(self: *SwapRenderer) !void {
        const rl = @import("../gui/raylib_backend.zig");
        switch (self.active) {
            .tui => {
                // Don't swap to GUI if raylib isn't compiled in
                if (!rl.enabled) return;
                if (self.tui) |*t| t.deinit();
                self.tui = null;
                self.gui = try gui_mod.GuiRenderer.init(self.alloc);
                self.active = .gui;
            },
            .gui => {
                if (self.gui) |*g| g.deinit();
                self.gui = null;
                self.tui = try tui_mod.TuiRenderer.init(self.alloc);
                self.active = .tui;
            },
        }
    }

    pub fn render(self: *SwapRenderer, ui_state: *state_mod.UiState, reader: *reader_mod.Reader, config: *config_mod.Config) void {
        switch (self.active) {
            .tui => if (self.tui) |*t| t.render(ui_state, reader, config),
            .gui => if (self.gui) |*g| g.render(ui_state, reader, config),
        }
    }

    pub fn pollInput(self: *SwapRenderer) input_mod.InputEvent {
        return switch (self.active) {
            .tui => if (self.tui) |*t| t.pollInput() else .none,
            .gui => if (self.gui) |*g| g.pollInput() else .none,
        };
    }
};
