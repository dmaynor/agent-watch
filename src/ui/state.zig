const std = @import("std");
const types = @import("../data/types.zig");

/// Dashboard tabs
pub const Tab = enum {
    overview,
    detail,
    network,
    alerts,
    fingerprints,

    pub fn name(self: Tab) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .detail => "Agent Detail",
            .network => "Network",
            .alerts => "Alerts",
            .fingerprints => "Fingerprints",
        };
    }

    pub fn next(self: Tab) Tab {
        return switch (self) {
            .overview => .detail,
            .detail => .network,
            .network => .alerts,
            .alerts => .fingerprints,
            .fingerprints => .overview,
        };
    }

    pub fn prev(self: Tab) Tab {
        return switch (self) {
            .overview => .fingerprints,
            .detail => .overview,
            .network => .detail,
            .alerts => .network,
            .fingerprints => .alerts,
        };
    }
};

/// Renderer-agnostic UI state
pub const UiState = struct {
    current_tab: Tab = .overview,
    selected_row: usize = 0,
    selected_pid: ?i32 = null,
    scroll_offset: usize = 0,
    term_width: u16 = 80,
    term_height: u16 = 24,
    running: bool = true,
    last_tick_result: ?TickResult = null,
    needs_redraw: bool = true,

    pub fn nextTab(self: *UiState) void {
        self.current_tab = self.current_tab.next();
        self.selected_row = 0;
        self.scroll_offset = 0;
        self.needs_redraw = true;
    }

    pub fn prevTab(self: *UiState) void {
        self.current_tab = self.current_tab.prev();
        self.selected_row = 0;
        self.scroll_offset = 0;
        self.needs_redraw = true;
    }

    pub fn selectDown(self: *UiState, max_rows: usize) void {
        if (max_rows == 0) return;
        if (self.selected_row < max_rows - 1) {
            self.selected_row += 1;
            self.needs_redraw = true;
        }
    }

    pub fn selectUp(self: *UiState) void {
        if (self.selected_row > 0) {
            self.selected_row -= 1;
            self.needs_redraw = true;
        }
    }
};

/// Result data from a collection tick (for display)
pub const TickResult = struct {
    agents_found: usize = 0,
    samples_written: usize = 0,
    total_samples: i64 = 0,
};
