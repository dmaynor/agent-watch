const std = @import("std");
const builtin = @import("builtin");
const terminal_mod = @import("terminal.zig");
const buffer_mod = @import("buffer.zig");
const state_mod = @import("../ui/state.zig");
const theme = @import("../ui/theme.zig");
const reader_mod = @import("../store/reader.zig");
const types = @import("../data/types.zig");
const network = @import("../analysis/network.zig");
const config_mod = @import("../config.zig");

const platform = switch (builtin.os.tag) {
    .linux => @import("../collector/platform_linux.zig"),
    else => @import("../collector/platform_linux.zig"), // stubs will error at runtime
};

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

    pub fn render(self: *TuiRenderer, ui_state: *state_mod.UiState, reader: *reader_mod.Reader, config: *config_mod.Config) void {
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
            .network => self.renderNetwork(ui_state, reader),
            .alerts => self.renderAlerts(ui_state, reader),
            .fingerprints => self.renderFingerprints(ui_state, reader),
            .settings => self.renderSettings(ui_state, config),
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

        const tabs = [_]state_mod.Tab{ .overview, .detail, .network, .alerts, .fingerprints, .settings };
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
        defer types.ProcessSample.freeSlice(self.alloc, samples);

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

    fn renderDetail(self: *TuiRenderer, ui_state: *state_mod.UiState, reader: *reader_mod.Reader) void {
        const y_start: u16 = 3;
        self.buf.moveTo(0, y_start);

        if (ui_state.selected_pid) |pid| {
            self.buf.writeStr(Color.bold);
            self.buf.print(" Agent Detail: PID {d}", .{pid});
            self.buf.writeStr(Color.reset);

            var y: u16 = y_start + 2;

            // PROCESS INFO section — live from /proc
            self.buf.moveTo(0, y);
            self.buf.writeStr(Color.bold);
            self.buf.writeStr(Color.fg_cyan);
            self.buf.writeStr(" PROCESS INFO");
            self.buf.writeStr(Color.reset);
            y += 1;

            // Exe path
            const exe_path = platform.readExePath(self.alloc, pid) catch self.alloc.dupe(u8, "(unavailable)") catch "";
            defer if (exe_path.len > 0) self.alloc.free(exe_path);
            self.buf.moveTo(0, y);
            self.buf.writeStr(Color.fg_yellow);
            self.buf.writeStr("   Exe:  ");
            self.buf.writeStr(Color.reset);
            self.buf.writeStr(truncateToWidth(exe_path, ui_state.term_width -| 10));
            y += 1;

            // Cwd
            const cwd = platform.readCwd(self.alloc, pid) catch self.alloc.dupe(u8, "(unavailable)") catch "";
            defer if (cwd.len > 0) self.alloc.free(cwd);
            self.buf.moveTo(0, y);
            self.buf.writeStr(Color.fg_yellow);
            self.buf.writeStr("   Cwd:  ");
            self.buf.writeStr(Color.reset);
            self.buf.writeStr(truncateToWidth(cwd, ui_state.term_width -| 10));
            y += 1;

            // Full cmdline
            const cmdline = platform.readCmdline(self.alloc, pid) catch self.alloc.dupe(u8, "(unavailable)") catch "";
            defer if (cmdline.len > 0) self.alloc.free(cmdline);
            self.buf.moveTo(0, y);
            self.buf.writeStr(Color.fg_yellow);
            self.buf.writeStr("   Cmd:  ");
            self.buf.writeStr(Color.reset);
            // Wrap long cmdlines across multiple rows
            const cmd_width = ui_state.term_width -| 10;
            if (cmd_width > 0) {
                var offset: usize = 0;
                while (offset < cmdline.len and y < ui_state.term_height -| 6) {
                    const end = @min(offset + cmd_width, cmdline.len);
                    self.buf.writeStr(cmdline[offset..end]);
                    offset = end;
                    if (offset < cmdline.len) {
                        y += 1;
                        self.buf.moveTo(9, y);
                    }
                }
            }
            y += 2;

            // SPARKLINES section
            const now = std.time.timestamp();
            const from = now - 300;
            const samples = reader.getSamples(@intCast(pid), from, now) catch &.{};
            defer types.ProcessSample.freeSlice(self.alloc, samples);

            self.buf.moveTo(0, y);
            self.buf.writeStr(Color.bold);
            self.buf.writeStr(Color.fg_cyan);
            self.buf.print(" TELEMETRY ({d} samples, last 5m)", .{samples.len});
            self.buf.writeStr(Color.reset);
            y += 1;

            if (samples.len > 0) {
                const spark_chars = theme.Spark.blocks;
                var max_cpu: f64 = 1;
                for (samples) |s| {
                    if (s.cpu > max_cpu) max_cpu = s.cpu;
                }

                const display_count = @min(samples.len, @as(usize, ui_state.term_width -| 10));
                const start_idx = if (samples.len > display_count) samples.len - display_count else 0;

                self.buf.moveTo(0, y);
                self.buf.writeStr(Color.bold);
                self.buf.writeStr(" CPU: ");
                self.buf.writeStr(Color.reset);
                self.buf.writeStr(Color.fg_green);
                for (samples[start_idx..]) |s| {
                    const normalized = s.cpu / max_cpu;
                    const idx: usize = @intFromFloat(normalized * 8);
                    self.buf.writeStr(spark_chars[@min(idx, 8)]);
                }
                self.buf.writeStr(Color.reset);
                y += 1;

                self.buf.moveTo(0, y);
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
                    self.buf.writeStr(spark_chars[@min(idx, 8)]);
                }
                self.buf.writeStr(Color.reset);
                y += 1;

                const latest = samples[samples.len - 1];
                self.buf.moveTo(0, y);
                self.buf.print(" Latest: CPU={d:.1}% RSS={d}KB State={s}", .{
                    latest.cpu,
                    latest.rss_kb,
                    latest.stat,
                });
                y += 2;
            } else {
                y += 1;
            }

            // ENVIRONMENT section
            if (y < ui_state.term_height -| 4) {
                self.buf.moveTo(0, y);
                self.buf.writeStr(Color.bold);
                self.buf.writeStr(Color.fg_cyan);
                self.buf.writeStr(" ENVIRONMENT");
                self.buf.writeStr(Color.reset);
                y += 1;

                const env = platform.readEnviron(self.alloc, pid) catch &.{};
                defer {
                    for (env) |e| self.alloc.free(e);
                    if (env.len > 0) self.alloc.free(env);
                }

                // Show env vars, scrollable via selected_row in detail tab
                const env_scroll = ui_state.scroll_offset;
                const max_env_rows = ui_state.term_height -| (y + 2);
                var env_shown: u16 = 0;
                var env_i: usize = env_scroll;
                while (env_i < env.len and env_shown < max_env_rows) {
                    self.buf.moveTo(0, y);
                    self.buf.writeStr(Color.dim);
                    self.buf.writeStr("   ");
                    self.buf.writeStr(truncateToWidth(env[env_i], ui_state.term_width -| 4));
                    self.buf.writeStr(Color.reset);
                    y += 1;
                    env_shown += 1;
                    env_i += 1;
                }
                if (env.len > max_env_rows + env_scroll) {
                    self.buf.moveTo(0, y);
                    self.buf.writeStr(Color.dim);
                    self.buf.print("   ... {d} more (j/k to scroll)", .{env.len - env_i});
                    self.buf.writeStr(Color.reset);
                }
            }
        } else {
            self.buf.writeStr(Color.dim);
            self.buf.writeStr(" Select an agent in Overview tab (Enter)");
            self.buf.writeStr(Color.reset);
        }
    }

    fn truncateToWidth(text: []const u8, max_width: u16) []const u8 {
        if (max_width == 0) return "";
        if (text.len <= max_width) return text;
        return text[0..max_width];
    }

    fn renderNetwork(self: *TuiRenderer, ui_state: *const state_mod.UiState, reader: *reader_mod.Reader) void {
        const y_start: u16 = 3;

        // Table header
        self.buf.moveTo(0, y_start);
        self.buf.writeStr(Color.bold);
        self.buf.writeStr(Color.fg_yellow);
        self.buf.print(" {s:<8} {s:<16} {s:>6} {s:>6} {s:>6} {s:>9} {s:>6}", .{ "PID", "COMM", "TOTAL", "ESTAB", "LISTEN", "TIME_WAIT", "OTHER" });
        self.buf.writeStr(Color.reset);

        const conns = reader.getLatestConnectionsPerAgent() catch &.{};
        defer types.NetConnection.freeSlice(self.alloc, conns);

        if (conns.len == 0) {
            self.buf.moveTo(0, y_start + 2);
            self.buf.writeStr(Color.dim);
            self.buf.writeStr(" No network connections recorded yet");
            self.buf.writeStr(Color.reset);
            return;
        }

        // Group connections by PID and build inventory per PID
        // First, collect per-PID inventories
        const max_rows = ui_state.term_height -| (y_start + 3);

        // Count total PID groups for scroll
        var pid_groups: usize = 0;
        {
            var ci: usize = 0;
            while (ci < conns.len) {
                const p = conns[ci].pid;
                while (ci < conns.len and conns[ci].pid == p) : (ci += 1) {}
                pid_groups += 1;
            }
        }

        const scroll = @min(ui_state.scroll_offset, if (pid_groups > max_rows) pid_groups - max_rows else 0);

        var row: u16 = 0;
        var i: usize = 0;
        var group_idx: usize = 0;
        while (i < conns.len) {
            const pid = conns[i].pid;
            var j = i;
            while (j < conns.len and conns[j].pid == pid) : (j += 1) {}
            defer {
                i = j;
                group_idx += 1;
            }

            if (group_idx < scroll) continue;
            if (row >= max_rows) break;

            const pid_conns = conns[i..j];
            const inv = network.buildInventory(pid_conns);

            const y = y_start + 1 + row;

            self.buf.moveTo(0, y);

            if (inv.listening > 0) {
                self.buf.writeStr(Color.fg_yellow);
            } else if (inv.established > 0) {
                self.buf.writeStr(Color.fg_green);
            } else {
                self.buf.writeStr(Color.fg_white);
            }

            self.buf.print(" {d:<8} {s:<16} {d:>6} {d:>6} {d:>6} {d:>9} {d:>6}", .{
                pid,
                "-",
                inv.total,
                inv.established,
                inv.listening,
                inv.time_wait,
                inv.other,
            });
            self.buf.writeStr(Color.reset);

            row += 1;
        }

        if (pid_groups > max_rows + scroll) {
            self.buf.moveTo(0, y_start + 1 + row);
            self.buf.writeStr(Color.dim);
            self.buf.print(" ... {d} more (j/k to scroll)", .{pid_groups - scroll - row});
            self.buf.writeStr(Color.reset);
        }
    }

    fn renderAlerts(self: *TuiRenderer, ui_state: *const state_mod.UiState, reader: *reader_mod.Reader) void {
        const y_start: u16 = 3;

        self.buf.moveTo(0, y_start);
        self.buf.writeStr(Color.bold);
        self.buf.writeStr(Color.fg_yellow);
        self.buf.print(" {s:<20} {s:<8} {s:<10} {s:<10} {s}", .{ "TIME", "PID", "SEVERITY", "CATEGORY", "MESSAGE" });
        self.buf.writeStr(Color.reset);

        const alerts = reader.getRecentAlerts(50) catch &.{};
        defer types.Alert.freeSlice(self.alloc, alerts);

        const max_rows = ui_state.term_height -| (y_start + 3);
        const scroll = @min(ui_state.scroll_offset, if (alerts.len > max_rows) alerts.len - max_rows else 0);

        var row: u16 = 0;
        var i: usize = scroll;
        while (i < alerts.len and row < max_rows) : (i += 1) {
            const alert = alerts[i];
            const y = y_start + 1 + row;

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
            row += 1;
        }

        if (alerts.len > max_rows + scroll) {
            self.buf.moveTo(0, y_start + 1 + row);
            self.buf.writeStr(Color.dim);
            self.buf.print(" ... {d} more (j/k to scroll)", .{alerts.len - i});
            self.buf.writeStr(Color.reset);
        }
    }

    fn renderFingerprints(self: *TuiRenderer, ui_state: *const state_mod.UiState, reader: *reader_mod.Reader) void {
        const y_start: u16 = 3;

        // Table header
        self.buf.moveTo(0, y_start);
        self.buf.writeStr(Color.bold);
        self.buf.writeStr(Color.fg_yellow);
        self.buf.print(" {s:<8} {s:<14} {s:>8} {s:>10} {s:>8} {s:>6} {s:>6} {s:<8} {s:>7}", .{
            "PID", "COMM", "AVG_CPU", "AVG_RSS_MB", "THREADS", "FDS", "CONNS", "PHASE", "SAMPLES",
        });
        self.buf.writeStr(Color.reset);

        const fingerprints = reader.getFingerprints() catch &.{};
        defer reader_mod.Reader.Fingerprint.freeSlice(self.alloc, fingerprints);

        if (fingerprints.len == 0) {
            self.buf.moveTo(0, y_start + 2);
            self.buf.writeStr(Color.dim);
            self.buf.writeStr(" No fingerprints generated yet — builds over time as agents are profiled");
            self.buf.writeStr(Color.reset);
            return;
        }

        const max_rows = ui_state.term_height -| (y_start + 3);
        const scroll = @min(ui_state.scroll_offset, if (fingerprints.len > max_rows) fingerprints.len - max_rows else 0);

        var row: u16 = 0;
        var i: usize = scroll;
        while (i < fingerprints.len and row < max_rows) : (i += 1) {
            const fp = fingerprints[i];
            const y = y_start + 1 + row;

            self.buf.moveTo(0, y);

            // Color by phase
            if (std.mem.eql(u8, fp.dominant_phase, "burst")) {
                self.buf.writeStr(Color.fg_red);
            } else if (std.mem.eql(u8, fp.dominant_phase, "active")) {
                self.buf.writeStr(Color.fg_yellow);
            } else {
                self.buf.writeStr(Color.fg_green);
            }

            const comm_slice = if (fp.comm.len > 13) fp.comm[0..13] else fp.comm;
            const rss_mb = fp.avg_rss_kb / 1024.0;

            self.buf.print(" {d:<8} {s:<14} {d:>7.1} {d:>9.1} {d:>7.0} {d:>5.0} {d:>5.0} {s:<8} {d:>7}", .{
                fp.pid,
                comm_slice,
                fp.avg_cpu,
                rss_mb,
                fp.avg_threads,
                fp.avg_fd_count,
                fp.avg_net_conns,
                if (fp.dominant_phase.len > 7) fp.dominant_phase[0..7] else fp.dominant_phase,
                fp.sample_count,
            });
            self.buf.writeStr(Color.reset);
            row += 1;
        }

        if (fingerprints.len > max_rows + scroll) {
            self.buf.moveTo(0, y_start + 1 + row);
            self.buf.writeStr(Color.dim);
            self.buf.print(" ... {d} more (j/k to scroll)", .{fingerprints.len - i});
            self.buf.writeStr(Color.reset);
        }
    }

    /// Number of editable settings rows
    pub const settings_row_count: usize = 9;

    fn renderSettings(self: *TuiRenderer, ui_state: *state_mod.UiState, config: *config_mod.Config) void {
        const y_start: u16 = 3;
        var y: u16 = y_start;

        // Section: COLLECTION
        self.buf.moveTo(0, y);
        self.buf.writeStr(Color.bold);
        self.buf.writeStr(Color.fg_cyan);
        self.buf.writeStr(" COLLECTION");
        self.buf.writeStr(Color.reset);
        y += 1;

        // Row 0: Poll Interval
        self.renderSettingsRow(y, 0, ui_state, "Poll Interval (sec)", blk: {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{config.interval}) catch "?";
            break :blk s;
        }, false);
        y += 1;

        // Row 1: Match Pattern
        self.renderSettingsRow(y, 1, ui_state, "Match Pattern", config.match_pattern, false);
        y += 1;

        // Row 2: DB Path (read-only)
        self.renderSettingsRow(y, 2, ui_state, "Database Path", config.db_path, true);
        y += 2;

        // Section: ALERT THRESHOLDS
        self.buf.moveTo(0, y);
        self.buf.writeStr(Color.bold);
        self.buf.writeStr(Color.fg_cyan);
        self.buf.writeStr(" ALERT THRESHOLDS");
        self.buf.writeStr(Color.reset);
        y += 1;

        // Row 3: CPU Warning
        var fmt_buf: [32]u8 = undefined;
        self.renderSettingsRow(y, 3, ui_state, "CPU Warning %", std.fmt.bufPrint(&fmt_buf, "{d:.1}", .{config.thresholds.cpu_warning}) catch "?", false);
        y += 1;

        // Row 4: CPU Critical
        var fmt_buf2: [32]u8 = undefined;
        self.renderSettingsRow(y, 4, ui_state, "CPU Critical %", std.fmt.bufPrint(&fmt_buf2, "{d:.1}", .{config.thresholds.cpu_critical}) catch "?", false);
        y += 1;

        // Row 5: RSS Warning
        var fmt_buf3: [32]u8 = undefined;
        self.renderSettingsRow(y, 5, ui_state, "RSS Warning (MB)", std.fmt.bufPrint(&fmt_buf3, "{d:.1}", .{config.thresholds.rss_warning_mb}) catch "?", false);
        y += 1;

        // Row 6: RSS Critical
        var fmt_buf4: [32]u8 = undefined;
        self.renderSettingsRow(y, 6, ui_state, "RSS Critical (MB)", std.fmt.bufPrint(&fmt_buf4, "{d:.1}", .{config.thresholds.rss_critical_mb}) catch "?", false);
        y += 1;

        // Row 7: FD Warning
        var fmt_buf5: [32]u8 = undefined;
        self.renderSettingsRow(y, 7, ui_state, "FD Warning", std.fmt.bufPrint(&fmt_buf5, "{d}", .{config.thresholds.fd_warning}) catch "?", false);
        y += 1;

        // Row 8: FD Critical
        var fmt_buf6: [32]u8 = undefined;
        self.renderSettingsRow(y, 8, ui_state, "FD Critical", std.fmt.bufPrint(&fmt_buf6, "{d}", .{config.thresholds.fd_critical}) catch "?", false);
    }

    fn renderSettingsRow(
        self: *TuiRenderer,
        y: u16,
        row_idx: usize,
        ui_state: *state_mod.UiState,
        label: []const u8,
        value: []const u8,
        read_only: bool,
    ) void {
        self.buf.moveTo(0, y);

        const selected = (ui_state.selected_row == row_idx);

        if (selected) {
            self.buf.writeStr(Color.reverse);
        }

        if (read_only) {
            self.buf.writeStr(Color.dim);
        }

        // Show edit buffer if this row is being edited
        if (selected and ui_state.editing) {
            self.buf.print(" > {s:<24} [{s}", .{ label, ui_state.edit_buf[0..ui_state.edit_len] });
            self.buf.writeStr("_]");
        } else {
            const indicator: []const u8 = if (selected) " > " else "   ";
            self.buf.print("{s}{s:<24} {s}", .{ indicator, label, value });
            if (read_only) {
                self.buf.writeStr("  (read-only)");
            }
        }

        self.buf.writeStr(Color.reset);
    }

    fn renderStatusBar(self: *TuiRenderer, ui_state: *const state_mod.UiState) void {
        self.buf.moveTo(0, ui_state.term_height - 1);
        self.buf.writeStr(Color.reverse);

        switch (ui_state.current_tab) {
            .overview => self.buf.print(" Tab:switch  ↑↓/jk:select  Enter:detail  F12:swap  q:quit", .{}),
            .detail => self.buf.print(" Esc:back  ↑↓/jk:scroll  Tab:switch  F12:swap  q:quit", .{}),
            .settings => {
                if (ui_state.editing) {
                    self.buf.print(" Enter:save  Esc:cancel  Type to edit", .{});
                } else {
                    self.buf.print(" Esc:back  ↑↓/jk:select  Enter:edit  Tab:switch  q:quit", .{});
                }
            },
            else => self.buf.print(" Esc:back  ↑↓/jk:scroll  Tab:switch  F12:swap  q:quit", .{}),
        }

        self.buf.writeStr(Color.reset);
    }

    pub fn pollInput(self: *TuiRenderer) @import("../ui/input.zig").InputEvent {
        return self.terminal.pollInput();
    }
};
