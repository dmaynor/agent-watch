const std = @import("std");
const types = @import("../data/types.zig");

/// Dashboard tabs
pub const Tab = enum {
    overview,
    detail,
    network,
    alerts,
    fingerprints,
    settings,

    pub fn name(self: Tab) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .detail => "Agent Detail",
            .network => "Network",
            .alerts => "Alerts",
            .fingerprints => "Fingerprints",
            .settings => "Settings",
        };
    }

    pub fn next(self: Tab) Tab {
        return switch (self) {
            .overview => .detail,
            .detail => .network,
            .network => .alerts,
            .alerts => .fingerprints,
            .fingerprints => .settings,
            .settings => .overview,
        };
    }

    pub fn prev(self: Tab) Tab {
        return switch (self) {
            .overview => .settings,
            .detail => .overview,
            .network => .detail,
            .alerts => .network,
            .fingerprints => .alerts,
            .settings => .fingerprints,
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
    /// Settings tab: currently in edit mode
    editing: bool = false,
    /// Settings tab: edit buffer for text input
    edit_buf: [256]u8 = undefined,
    /// Settings tab: current length of edit buffer
    edit_len: usize = 0,

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

const testing = std.testing;

test "Tab: next wraps around" {
    try testing.expectEqual(Tab.detail, Tab.overview.next());
    try testing.expectEqual(Tab.overview, Tab.settings.next()); // wraps
}

test "Tab: prev wraps around" {
    try testing.expectEqual(Tab.settings, Tab.overview.prev()); // wraps
    try testing.expectEqual(Tab.overview, Tab.detail.prev());
}

test "Tab: full cycle next" {
    var t = Tab.overview;
    for (0..6) |_| t = t.next();
    try testing.expectEqual(Tab.overview, t); // back to start
}

test "UiState: nextTab resets selection" {
    var state = UiState{};
    state.selected_row = 5;
    state.scroll_offset = 10;
    state.nextTab();
    try testing.expectEqual(Tab.detail, state.current_tab);
    try testing.expectEqual(@as(usize, 0), state.selected_row);
    try testing.expectEqual(@as(usize, 0), state.scroll_offset);
}

test "UiState: selectDown bounds" {
    var state = UiState{};
    state.selectDown(3);
    try testing.expectEqual(@as(usize, 1), state.selected_row);
    state.selectDown(3);
    try testing.expectEqual(@as(usize, 2), state.selected_row);
    state.selectDown(3); // at max, should not go further
    try testing.expectEqual(@as(usize, 2), state.selected_row);
}

test "UiState: selectDown with zero rows" {
    var state = UiState{};
    state.selectDown(0);
    try testing.expectEqual(@as(usize, 0), state.selected_row);
}

test "UiState: selectUp bounds" {
    var state = UiState{};
    state.selectUp(); // already at 0, should stay
    try testing.expectEqual(@as(usize, 0), state.selected_row);
    state.selected_row = 2;
    state.selectUp();
    try testing.expectEqual(@as(usize, 1), state.selected_row);
}
