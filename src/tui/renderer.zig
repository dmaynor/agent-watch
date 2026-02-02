const std = @import("std");
const terminal_mod = @import("terminal.zig");
const buffer_mod = @import("buffer.zig");
const state_mod = @import("../ui/state.zig");
const theme = @import("../ui/theme.zig");
const reader_mod = @import("../store/reader.zig");
const types = @import("../data/types.zig");

const Color = theme.Color;
const Box = theme.Box;

pub const TuiRenderer = struct {
    terminal: terminal_mod.Terminal,
    buf: buffer_mod.Buffer,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !TuiRenderer {
        return .{
            .terminal = try terminal_mod.Terminal.init(),
            .buf = buffer_mod.Buffer.init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *TuiRenderer) void {
        self.buf.deinit();
        self.terminal.deinit();
    }

    pub fn render(self: *TuiRenderer, ui_state: *state_mod.UiState, reader: *reader_mod.Reader) void {
        const size = self.terminal.getSize();
        ui_state.term_width = size.width;
        ui_state.term_height = size.height;

        self.buf.clear();
        self.buf.writeStr("\x1b[2J"); // clear screen

        // Header
        self.renderHeader(ui_state);

        // Tab bar
        self.renderTabBar(ui_state, 1);

        // Content area
        switch (ui_state.current_tab) {
            .overview => self.renderOverview(ui_state, reader),
            .detail => self.renderDetail(ui_state, reader),
            .network => self.renderNetwork(ui_state),
            .alerts => self.renderAlerts(ui_state, reader),
            .fingerprints => self.renderFingerprints(ui_state),
        }

        // Status bar
        self.renderStatusBar(ui_state);

        self.buf.flush(self.terminal.stdout);
        ui_state.needs_redraw = false;
    }

    fn renderHeader(self: *TuiRenderer, ui_state: *const state_mod.UiState) void {
        self.buf.moveTo(0, 0);
        self.buf.writeStr(Color.bold);
        self.buf.writeStr(Color.fg_cyan);
        self.buf.print(" Agent-Watch ", .{});
        self.buf.writeStr(Color.reset);
        self.buf.writeStr(Color.dim);
        if (ui_state.last_tick_result) |tick| {
            self.buf.print(" | {d} agents | {d} samples", .{ tick.agents_found, tick.total_samples });
        }
        self.buf.writeStr(Color.reset);
    }

    fn renderTabBar(self: *TuiRenderer, ui_state: *const state_mod.UiState, y: u16) void {
        self.buf.moveTo(0, y);
        self.buf.writeStr(Color.dim);

        const tabs = [_]state_mod.Tab{ .overview, .detail, .network, .alerts, .fingerprints };
        for (tabs) |tab| {
            if (tab == ui_state.current_tab) {
                self.buf.writeStr(Color.reset);
                self.buf.writeStr(Color.bold);
                self.buf.writeStr(Color.reverse);
                self.buf.print(" {s} ", .{tab.name()});
                self.buf.writeStr(Color.reset);
                self.buf.writeStr(Color.dim);
            } else {
                self.buf.print(" {s} ", .{tab.name()});
            }
            self.buf.writeStr("│");
        }
        self.buf.writeStr(Color.reset);

        // Separator line
        self.buf.moveTo(0, y + 1);
        for (0..ui_state.term_width) |_| {
            self.buf.writeStr(Box.h_line);
        }
    }

    fn renderOverview(self: *TuiRenderer, ui_state: *state_mod.UiState, reader: *reader_mod.Reader) void {
        const y_start: u16 = 3;

        // Table header
        self.buf.moveTo(0, y_start);
        self.buf.writeStr(Color.bold);
        self.buf.writeStr(Color.fg_yellow);
        self.buf.print(" {s:<8} {s:<16} {s:>7} {s:>7} {s:>10} {s:<5} {s:>8}", .{ "PID", "COMM", "CPU%", "MEM%", "RSS(KB)", "STAT", "ELAPSED" });
        self.buf.writeStr(Color.reset);

        // Get latest samples
        const samples = reader.getLatestSamplesPerAgent() catch &.{};
        defer self.alloc.free(samples);

        for (samples, 0..) |sample, i| {
            const y = y_start + 1 + @as(u16, @intCast(i));
            if (y >= ui_state.term_height - 2) break;

            self.buf.moveTo(0, y);

            if (i == ui_state.selected_row) {
                self.buf.writeStr(Color.reverse);
            }

            // Color CPU by threshold
            if (sample.cpu >= 80.0) {
                self.buf.writeStr(Color.fg_red);
            } else if (sample.cpu >= 50.0) {
                self.buf.writeStr(Color.fg_yellow);
            } else {
                self.buf.writeStr(Color.fg_green);
            }

            const comm_slice = if (sample.comm.len > 15) sample.comm[0..15] else sample.comm;
            self.buf.print(" {d:<8} {s:<16} {d:>6.1} {d:>6.1} {d:>10} {s:<5} {d:>7}s", .{
                sample.pid,
                comm_slice,
                sample.cpu,
                sample.mem,
                sample.rss_kb,
                sample.stat,
                sample.etimes,
            });

            self.buf.writeStr(Color.reset);

            // Set selected PID
            if (i == ui_state.selected_row) {
                ui_state.selected_pid = sample.pid;
            }
        }
    }

    fn renderDetail(self: *TuiRenderer, ui_state: *const state_mod.UiState, reader: *reader_mod.Reader) void {
        const y_start: u16 = 3;
        self.buf.moveTo(0, y_start);

        if (ui_state.selected_pid) |pid| {
            self.buf.writeStr(Color.bold);
            self.buf.print(" Agent Detail: PID {d}", .{pid});
            self.buf.writeStr(Color.reset);

            // Get time range: last 5 minutes
            const now = std.time.timestamp();
            const from = now - 300;
            const samples = reader.getSamples(@intCast(pid), from, now) catch &.{};
            defer self.alloc.free(samples);

            self.buf.moveTo(0, y_start + 2);
            self.buf.writeStr(Color.fg_cyan);
            self.buf.print(" Samples in last 5m: {d}", .{samples.len});
            self.buf.writeStr(Color.reset);

            // Show sparkline of CPU
            if (samples.len > 0) {
                self.buf.moveTo(0, y_start + 4);
                self.buf.writeStr(Color.bold);
                self.buf.writeStr(" CPU: ");
                self.buf.writeStr(Color.reset);
                self.buf.writeStr(Color.fg_green);

                const spark_chars = theme.Spark.blocks;
                var max_cpu: f64 = 1;
                for (samples) |s| {
                    if (s.cpu > max_cpu) max_cpu = s.cpu;
                }

                const display_count = @min(samples.len, @as(usize, ui_state.term_width - 10));
                const start_idx = if (samples.len > display_count) samples.len - display_count else 0;
                for (samples[start_idx..]) |s| {
                    const normalized = s.cpu / max_cpu;
                    const idx: usize = @intFromFloat(normalized * 8);
                    const clamped = @min(idx, 8);
                    self.buf.writeStr(spark_chars[clamped]);
                }
                self.buf.writeStr(Color.reset);

                // RSS sparkline
                self.buf.moveTo(0, y_start + 5);
                self.buf.writeStr(Color.bold);
                self.buf.writeStr(" RSS: ");
                self.buf.writeStr(Color.reset);
                self.buf.writeStr(Color.fg_blue);

                var max_rss: f64 = 1;
                for (samples) |s| {
                    const rss_f: f64 = @floatFromInt(s.rss_kb);
                    if (rss_f > max_rss) max_rss = rss_f;
                }
                for (samples[start_idx..]) |s| {
                    const rss_f: f64 = @floatFromInt(s.rss_kb);
                    const normalized = rss_f / max_rss;
                    const idx: usize = @intFromFloat(normalized * 8);
                    const clamped = @min(idx, 8);
                    self.buf.writeStr(spark_chars[clamped]);
                }
                self.buf.writeStr(Color.reset);

                // Latest values
                const latest = samples[samples.len - 1];
                self.buf.moveTo(0, y_start + 7);
                self.buf.print(" Latest: CPU={d:.1}% RSS={d}KB Threads={s} State={s}", .{
                    latest.cpu,
                    latest.rss_kb,
                    latest.stat,
                    latest.comm,
                });
            }
        } else {
            self.buf.writeStr(Color.dim);
            self.buf.writeStr(" Select an agent in Overview tab (Enter)");
            self.buf.writeStr(Color.reset);
        }
    }

    fn renderNetwork(self: *TuiRenderer, ui_state: *const state_mod.UiState) void {
        const y_start: u16 = 3;
        self.buf.moveTo(0, y_start);
        self.buf.writeStr(Color.dim);
        _ = ui_state;
        self.buf.writeStr(" Network connections view — data populates as agents are monitored");
        self.buf.writeStr(Color.reset);
    }

    fn renderAlerts(self: *TuiRenderer, ui_state: *const state_mod.UiState, reader: *reader_mod.Reader) void {
        const y_start: u16 = 3;
        _ = ui_state;

        self.buf.moveTo(0, y_start);
        self.buf.writeStr(Color.bold);
        self.buf.writeStr(Color.fg_yellow);
        self.buf.print(" {s:<20} {s:<8} {s:<10} {s:<10} {s}", .{ "TIME", "PID", "SEVERITY", "CATEGORY", "MESSAGE" });
        self.buf.writeStr(Color.reset);

        const alerts = reader.getRecentAlerts(50) catch &.{};
        defer self.alloc.free(alerts);

        for (alerts, 0..) |alert, i| {
            const y = y_start + 1 + @as(u16, @intCast(i));
            if (y >= 22) break;

            self.buf.moveTo(0, y);

            switch (alert.severity) {
                .critical => self.buf.writeStr(Color.fg_red),
                .warning => self.buf.writeStr(Color.fg_yellow),
                .info => self.buf.writeStr(Color.fg_white),
            }

            var ts_buf: [32]u8 = undefined;
            const ts_str = types.formatTimestamp(&ts_buf, alert.ts) catch "?";

            self.buf.print(" {s:<20} {d:<8} {s:<10} {s:<10} {s}", .{
                ts_str,
                alert.pid,
                alert.severity.toString(),
                alert.category,
                alert.message,
            });
            self.buf.writeStr(Color.reset);
        }
    }

    fn renderFingerprints(self: *TuiRenderer, ui_state: *const state_mod.UiState) void {
        const y_start: u16 = 3;
        self.buf.moveTo(0, y_start);
        _ = ui_state;
        self.buf.writeStr(Color.dim);
        self.buf.writeStr(" Behavioral fingerprints — builds over time as agents are profiled");
        self.buf.writeStr(Color.reset);
    }

    fn renderStatusBar(self: *TuiRenderer, ui_state: *const state_mod.UiState) void {
        self.buf.moveTo(0, ui_state.term_height - 1);
        self.buf.writeStr(Color.reverse);
        self.buf.print(" Tab:switch  ↑↓/jk:select  Enter:detail  F12:swap  q:quit", .{});
        // Pad to width
        self.buf.writeStr(Color.reset);
    }

    pub fn pollInput(self: *TuiRenderer) @import("../ui/input.zig").InputEvent {
        return self.terminal.pollInput();
    }
};
