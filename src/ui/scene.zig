// Scene builder — constructs the layout and data for current tab
// This is used by both TUI and GUI renderers
const std = @import("std");
const state_mod = @import("state.zig");
const reader_mod = @import("../store/reader.zig");
const types = @import("../data/types.zig");

pub const SceneData = struct {
    samples: []types.ProcessSample = &.{},
    alerts: []types.Alert = &.{},
    agents: []types.Agent = &.{},
};

pub fn buildScene(reader: *reader_mod.Reader, ui_state: *const state_mod.UiState) SceneData {
    _ = ui_state;
    var data = SceneData{};

    data.samples = reader.getLatestSamplesPerAgent() catch &.{};
    data.alerts = reader.getRecentAlerts(50) catch &.{};
    data.agents = reader.getAliveAgents() catch &.{};

    return data;
}
