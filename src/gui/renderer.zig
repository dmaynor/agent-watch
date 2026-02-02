/// GUI renderer using raylib
/// When built without -Denable-gui=true, provides stub implementation
const std = @import("std");
const state_mod = @import("../ui/state.zig");
const reader_mod = @import("../store/reader.zig");
const input_mod = @import("../ui/input.zig");
const types = @import("../data/types.zig");
const network = @import("../analysis/network.zig");
const config_mod = @import("../config.zig");
const rl = @import("raylib_backend.zig");
const text_draw = @import("text.zig");
const chart_draw = @import("chart_draw.zig");

const WINDOW_WIDTH = 1200;
const WINDOW_HEIGHT = 800;

// Colors
const BG_COLOR = if (rl.enabled) rl.c.Color{ .r = 20, .g = 20, .b = 30, .a = 255 } else {};
const CYAN = if (rl.enabled) rl.c.Color{ .r = 100, .g = 220, .b = 255, .a = 255 } else {};
const YELLOW = if (rl.enabled) rl.c.Color{ .r = 220, .g = 200, .b = 50, .a = 255 } else {};
const GREEN = if (rl.enabled) rl.c.Color{ .r = 80, .g = 220, .b = 80, .a = 255 } else {};
const RED = if (rl.enabled) rl.c.Color{ .r = 220, .g = 80, .b = 80, .a = 255 } else {};
const WHITE = if (rl.enabled) rl.c.Color{ .r = 200, .g = 200, .b = 200, .a = 255 } else {};
const DIM = if (rl.enabled) rl.c.Color{ .r = 120, .g = 120, .b = 120, .a = 255 } else {};
const TAB_ACTIVE = if (rl.enabled) rl.c.Color{ .r = 60, .g = 60, .b = 100, .a = 255 } else {};

pub const GuiRenderer = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !GuiRenderer {
        if (rl.enabled) {
            rl.c.SetConfigFlags(rl.c.FLAG_WINDOW_RESIZABLE);
            rl.c.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "agent-watch");
            rl.c.SetTargetFPS(30);
        } else {
            std.log.info("GUI renderer: raylib not enabled. Build with -Denable-gui=true", .{});
        }
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *GuiRenderer) void {
        _ = self;
        if (rl.enabled) {
            rl.c.CloseWindow();
        }
    }

    pub fn render(self: *GuiRenderer, ui_state: *state_mod.UiState, reader: *reader_mod.Reader, config: *config_mod.Config) void {
        if (!rl.enabled) return;

        rl.c.BeginDrawing();
        defer rl.c.EndDrawing();

        rl.c.ClearBackground(BG_COLOR);

        // Header
        self.renderHeader(ui_state);

        // Tab bar
        self.renderTabBar(ui_state);

        // Content
        switch (ui_state.current_tab) {
            .overview => self.renderOverview(ui_state, reader),
            .detail => self.renderDetail(ui_state, reader),
            .network => self.renderNetwork(reader),
            .alerts => self.renderAlerts(reader),
            .fingerprints => self.renderFingerprints(reader),
            .settings => self.renderSettingsStub(config),
        }

        // Status bar
        self.renderStatusBar();

        ui_state.needs_redraw = false;
    }

    fn renderHeader(self: *GuiRenderer, ui_state: *const state_mod.UiState) void {
        _ = self;
        if (!rl.enabled) return;
        var buf: [256]u8 = undefined;
        text_draw.drawText("Agent-Watch", 10, 10, CYAN);
        if (ui_state.last_tick_result) |tick| {
            text_draw.drawTextFmt(&buf, 160, 10, DIM, "| {d} agents | {d} samples", .{ tick.agents_found, tick.total_samples });
        }
    }

    fn renderTabBar(self: *GuiRenderer, ui_state: *const state_mod.UiState) void {
        _ = self;
        if (!rl.enabled) return;
        const tabs = [_]state_mod.Tab{ .overview, .detail, .network, .alerts, .fingerprints, .settings };
        var x: c_int = 10;
        for (tabs) |tab| {
            const name = tab.name();
            const w: c_int = @intCast(name.len * text_draw.CHAR_WIDTH + 20);
            if (tab == ui_state.current_tab) {
                rl.c.DrawRectangle(x, 35, w, 22, TAB_ACTIVE);
            }
            var buf: [64]u8 = undefined;
            text_draw.drawTextFmt(&buf, x + 10, 38, if (tab == ui_state.current_tab) WHITE else DIM, "{s}", .{name});
            x += w + 4;
        }
        // Separator
        rl.c.DrawLine(0, 60, WINDOW_WIDTH, 60, DIM);
    }

    fn renderOverview(self: *GuiRenderer, ui_state: *state_mod.UiState, reader: *reader_mod.Reader) void {
        if (!rl.enabled) return;
        const y_start: c_int = 70;

        // Header
        var buf: [256]u8 = undefined;
        text_draw.drawTextFmt(&buf, 10, y_start, YELLOW,
            "{s:<8} {s:<16} {s:>7} {s:>7} {s:>10} {s:<5} {s:>8}", .{ "PID", "COMM", "CPU%", "MEM%", "RSS(KB)", "STAT", "ELAPSED" });

        const samples = reader.getLatestSamplesPerAgent() catch &.{};
        defer types.ProcessSample.freeSlice(self.alloc, samples);

        for (samples, 0..) |sample, i| {
            const y = y_start + 22 + @as(c_int, @intCast(i)) * 22;
            if (y > 750) break;

            const color = if (sample.cpu >= 80.0) RED else if (sample.cpu >= 50.0) YELLOW else GREEN;
            const comm_slice = if (sample.comm.len > 15) sample.comm[0..15] else sample.comm;
            text_draw.drawTextFmt(&buf, 10, y, color,
                "{d:<8} {s:<16} {d:>6.1} {d:>6.1} {d:>10} {s:<5} {d:>7}s", .{
                sample.pid, comm_slice, sample.cpu, sample.mem, sample.rss_kb, sample.stat, sample.etimes,
            });

            if (i == ui_state.selected_row) {
                ui_state.selected_pid = sample.pid;
                rl.c.DrawRectangleLines(5, y - 2, 1190, 22, CYAN);
            }
        }
    }

    fn renderDetail(self: *GuiRenderer, ui_state: *const state_mod.UiState, reader: *reader_mod.Reader) void {
        if (!rl.enabled) return;
        var buf: [256]u8 = undefined;
        const y_start: c_int = 70;

        if (ui_state.selected_pid) |pid| {
            text_draw.drawTextFmt(&buf, 10, y_start, CYAN, "Agent Detail: PID {d}", .{pid});

            const now = std.time.timestamp();
            const from = now - 300;
            const samples = reader.getSamples(@intCast(pid), from, now) catch &.{};
            defer types.ProcessSample.freeSlice(self.alloc, samples);

            text_draw.drawTextFmt(&buf, 10, y_start + 30, WHITE, "Samples in last 5m: {d}", .{samples.len});

            if (samples.len > 0) {
                // CPU sparkline
                text_draw.drawText("CPU:", 10, y_start + 60, WHITE);
                const cpu_values = self.alloc.alloc(f64, samples.len) catch return;
                defer self.alloc.free(cpu_values);
                for (samples, 0..) |s, i| cpu_values[i] = s.cpu;
                chart_draw.drawSparkline(cpu_values, 60, y_start + 55, 500, 40, GREEN);

                // RSS sparkline
                text_draw.drawText("RSS:", 10, y_start + 110, WHITE);
                const rss_values = self.alloc.alloc(f64, samples.len) catch return;
                defer self.alloc.free(rss_values);
                for (samples, 0..) |s, i| rss_values[i] = @floatFromInt(s.rss_kb);
                chart_draw.drawSparkline(rss_values, 60, y_start + 105, 500, 40, CYAN);

                const latest = samples[samples.len - 1];
                text_draw.drawTextFmt(&buf, 10, y_start + 160, WHITE,
                    "Latest: CPU={d:.1}% RSS={d}KB State={s}", .{ latest.cpu, latest.rss_kb, latest.stat });
            }
        } else {
            text_draw.drawText("Select an agent in Overview tab (Enter)", 10, y_start, DIM);
        }
    }

    fn renderNetwork(self: *GuiRenderer, reader: *reader_mod.Reader) void {
        if (!rl.enabled) return;
        const y_start: c_int = 70;
        var buf: [256]u8 = undefined;

        text_draw.drawTextFmt(&buf, 10, y_start, YELLOW,
            "{s:<8} {s:>6} {s:>6} {s:>6} {s:>9} {s:>6}", .{ "PID", "TOTAL", "ESTAB", "LISTEN", "TIME_WAIT", "OTHER" });

        const conns = reader.getLatestConnectionsPerAgent() catch &.{};
        defer types.NetConnection.freeSlice(self.alloc, conns);

        if (conns.len == 0) {
            text_draw.drawText("No network connections recorded yet", 10, y_start + 30, DIM);
            return;
        }

        var row: c_int = 0;
        var i: usize = 0;
        while (i < conns.len) {
            const pid = conns[i].pid;
            var j = i;
            while (j < conns.len and conns[j].pid == pid) : (j += 1) {}
            const pid_conns = conns[i..j];
            const inv = network.buildInventory(pid_conns);

            const y = y_start + 22 + row * 22;
            if (y > 750) break;

            text_draw.drawTextFmt(&buf, 10, y, WHITE,
                "{d:<8} {d:>6} {d:>6} {d:>6} {d:>9} {d:>6}", .{
                pid, inv.total, inv.established, inv.listening, inv.time_wait, inv.other,
            });

            row += 1;
            i = j;
        }
    }

    fn renderAlerts(self: *GuiRenderer, reader: *reader_mod.Reader) void {
        if (!rl.enabled) return;
        const y_start: c_int = 70;
        var buf: [256]u8 = undefined;

        text_draw.drawTextFmt(&buf, 10, y_start, YELLOW,
            "{s:<20} {s:<8} {s:<10} {s}", .{ "TIME", "PID", "SEVERITY", "MESSAGE" });

        const alerts = reader.getRecentAlerts(50) catch &.{};
        defer types.Alert.freeSlice(self.alloc, alerts);

        for (alerts, 0..) |alert, i| {
            const y = y_start + 22 + @as(c_int, @intCast(i)) * 22;
            if (y > 750) break;

            const color = switch (alert.severity) {
                .critical => RED,
                .warning => YELLOW,
                .info => WHITE,
            };

            var ts_buf: [32]u8 = undefined;
            const ts_str = types.formatTimestamp(&ts_buf, alert.ts) catch "?";

            text_draw.drawTextFmt(&buf, 10, y, color,
                "{s:<20} {d:<8} {s:<10} {s}", .{ ts_str, alert.pid, alert.severity.toString(), alert.message });
        }
    }

    fn renderFingerprints(self: *GuiRenderer, reader: *reader_mod.Reader) void {
        if (!rl.enabled) return;
        const y_start: c_int = 70;
        var buf: [256]u8 = undefined;

        text_draw.drawTextFmt(&buf, 10, y_start, YELLOW,
            "{s:<8} {s:<14} {s:>8} {s:>10} {s:>8} {s:>6} {s:>6} {s:<8} {s:>7}", .{
            "PID", "COMM", "AVG_CPU", "AVG_RSS_MB", "THREADS", "FDS", "CONNS", "PHASE", "SAMPLES",
        });

        const fingerprints = reader.getFingerprints() catch &.{};
        defer reader_mod.Reader.Fingerprint.freeSlice(self.alloc, fingerprints);

        if (fingerprints.len == 0) {
            text_draw.drawText("No fingerprints generated yet", 10, y_start + 30, DIM);
            return;
        }

        for (fingerprints, 0..) |fp, i| {
            const y = y_start + 22 + @as(c_int, @intCast(i)) * 22;
            if (y > 750) break;

            const color = if (std.mem.eql(u8, fp.dominant_phase, "burst")) RED
                else if (std.mem.eql(u8, fp.dominant_phase, "active")) YELLOW
                else GREEN;

            const comm_slice = if (fp.comm.len > 13) fp.comm[0..13] else fp.comm;
            const rss_mb = fp.avg_rss_kb / 1024.0;

            text_draw.drawTextFmt(&buf, 10, y, color,
                "{d:<8} {s:<14} {d:>7.1} {d:>9.1} {d:>7.0} {d:>5.0} {d:>5.0} {s:<8} {d:>7}", .{
                fp.pid, comm_slice, fp.avg_cpu, rss_mb, fp.avg_threads, fp.avg_fd_count, fp.avg_net_conns,
                if (fp.dominant_phase.len > 7) fp.dominant_phase[0..7] else fp.dominant_phase,
                fp.sample_count,
            });
        }
    }

    fn renderSettingsStub(self: *GuiRenderer, config: *config_mod.Config) void {
        _ = self;
        _ = config;
        if (!rl.enabled) return;
        text_draw.drawText("Settings (edit in TUI mode)", 10, 70, DIM);
    }

    fn renderStatusBar(self: *GuiRenderer) void {
        _ = self;
        if (!rl.enabled) return;
        const y: c_int = @intCast(rl.c.GetScreenHeight() - 25);
        rl.c.DrawRectangle(0, y, rl.c.GetScreenWidth(), 25, TAB_ACTIVE);
        text_draw.drawText(" Tab:switch  Up/Down:select  Enter:detail  F12:swap  Q:quit", 10, y + 4, WHITE);
    }

    pub fn pollInput(self: *GuiRenderer) input_mod.InputEvent {
        _ = self;
        if (!rl.enabled) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            return .none;
        }

        if (rl.c.WindowShouldClose()) return .{ .key = .quit };

        if (rl.c.IsKeyPressed(rl.c.KEY_Q)) return .{ .key = .quit };
        if (rl.c.IsKeyPressed(rl.c.KEY_TAB)) {
            if (rl.c.IsKeyDown(rl.c.KEY_LEFT_SHIFT) or rl.c.IsKeyDown(rl.c.KEY_RIGHT_SHIFT)) {
                return .{ .key = .shift_tab };
            }
            return .{ .key = .tab };
        }
        if (rl.c.IsKeyPressed(rl.c.KEY_UP) or rl.c.IsKeyPressed(rl.c.KEY_K)) return .{ .key = .up };
        if (rl.c.IsKeyPressed(rl.c.KEY_DOWN) or rl.c.IsKeyPressed(rl.c.KEY_J)) return .{ .key = .down };
        if (rl.c.IsKeyPressed(rl.c.KEY_ENTER)) return .{ .key = .enter };
        if (rl.c.IsKeyPressed(rl.c.KEY_F12)) return .{ .key = .f12 };

        return .none;
    }
};
