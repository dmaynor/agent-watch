const std = @import("std");
const collector_mod = @import("../collector/collector.zig");
const swap_mod = @import("swap.zig");
const state_mod = @import("../ui/state.zig");
const reader_mod = @import("../store/reader.zig");
const db_mod = @import("../store/db.zig");
const config_mod = @import("../config.zig");
const input_mod = @import("../ui/input.zig");
const engine_mod = @import("../analysis/engine.zig");

/// Central event loop: multiplexes collector timer, input, and rendering
pub fn run(
    alloc: std.mem.Allocator,
    db: *db_mod.Db,
    config: *config_mod.Config,
    headless: bool,
) !void {
    var collector = try collector_mod.Collector.init(alloc, db, config.*);
    defer collector.deinit();

    var engine = engine_mod.AnalysisEngine.init(alloc, &collector.writer);
    engine.thresholds = config.thresholds;
    defer engine.deinit();

    var reader = reader_mod.Reader.init(db, alloc);

    // Load baselines for live regression detection
    engine.loadBaselines(&reader);

    var ui_state = state_mod.UiState{};

    // Initial collection tick
    {
        var result = collector.tick() catch |err| blk: {
            std.log.warn("Collection tick error: {}", .{err});
            break :blk collector_mod.Collector.CollectionResult{};
        };
        defer result.deinit(alloc);

        // Run analysis on collected data
        engine.processTickData(
            result.samples.items,
            result.statuses.items,
            result.fd_counts.items,
            result.conn_counts.items,
            result.timestamp,
        );

        const sample_count = reader.getSampleCount() catch 0;
        ui_state.last_tick_result = .{
            .agents_found = result.agents_found,
            .samples_written = result.samples_written,
            .total_samples = sample_count,
        };
    }

    if (headless) {
        return runHeadless(alloc, &collector, &engine, &reader, &ui_state, config.*);
    }

    var renderer = try swap_mod.SwapRenderer.init(alloc, config.gui);
    defer renderer.deinit();

    var last_collect = std.time.nanoTimestamp();
    var last_render = last_collect;
    const render_interval: u64 = 100 * std.time.ns_per_ms; // 10 FPS

    while (ui_state.running) {
        const now = std.time.nanoTimestamp();

        // Collection tick (re-read interval from config each time for live editing)
        const interval_ns: u64 = @as(u64, config.interval) * std.time.ns_per_s;
        if (@as(u64, @intCast(now - last_collect)) >= interval_ns) {
            var result = collector.tick() catch collector_mod.Collector.CollectionResult{};
            defer result.deinit(alloc);

            engine.processTickData(
                result.samples.items,
                result.statuses.items,
                result.fd_counts.items,
                result.conn_counts.items,
                result.timestamp,
            );

            const sample_count = reader.getSampleCount() catch 0;
            ui_state.last_tick_result = .{
                .agents_found = result.agents_found,
                .samples_written = result.samples_written,
                .total_samples = sample_count,
            };
            ui_state.needs_redraw = true;
            last_collect = now;
        }

        // Input handling
        const event = renderer.pollInput();
        switch (event) {
            .key => |key| {
                if (ui_state.editing) {
                    // Edit mode: capture text input
                    switch (key) {
                        .enter => {
                            // Commit edit
                            commitSettingsEdit(alloc, &ui_state, config);
                            // Sync thresholds to engine
                            engine.thresholds = config.thresholds;
                            // Update collector interval/pattern
                            collector.config = config.*;
                        },
                        .escape => {
                            ui_state.editing = false;
                            ui_state.needs_redraw = true;
                        },
                        .backspace => {
                            if (ui_state.edit_len > 0) {
                                ui_state.edit_len -= 1;
                                ui_state.needs_redraw = true;
                            }
                        },
                        .char => |c| {
                            if (ui_state.edit_len < ui_state.edit_buf.len - 1) {
                                ui_state.edit_buf[ui_state.edit_len] = c;
                                ui_state.edit_len += 1;
                                ui_state.needs_redraw = true;
                            }
                        },
                        // In edit mode, j/k/q type their character
                        .char_j => {
                            if (ui_state.edit_len < ui_state.edit_buf.len - 1) {
                                ui_state.edit_buf[ui_state.edit_len] = 'j';
                                ui_state.edit_len += 1;
                                ui_state.needs_redraw = true;
                            }
                        },
                        .char_k => {
                            if (ui_state.edit_len < ui_state.edit_buf.len - 1) {
                                ui_state.edit_buf[ui_state.edit_len] = 'k';
                                ui_state.edit_len += 1;
                                ui_state.needs_redraw = true;
                            }
                        },
                        .quit => {
                            // 'q' in edit mode types q
                            if (ui_state.edit_len < ui_state.edit_buf.len - 1) {
                                ui_state.edit_buf[ui_state.edit_len] = 'q';
                                ui_state.edit_len += 1;
                                ui_state.needs_redraw = true;
                            }
                        },
                        else => {},
                    }
                } else {
                    // Normal mode
                    switch (key) {
                        .quit => ui_state.running = false,
                        .tab => ui_state.nextTab(),
                        .shift_tab => ui_state.prevTab(),
                        .escape, .backspace => {
                            // Go back: from Detail → Overview, from any non-overview → overview
                            if (ui_state.current_tab != .overview) {
                                if (ui_state.current_tab == .detail) {
                                    ui_state.current_tab = .overview;
                                    ui_state.scroll_offset = 0;
                                    ui_state.needs_redraw = true;
                                } else {
                                    ui_state.current_tab = .overview;
                                    ui_state.selected_row = 0;
                                    ui_state.scroll_offset = 0;
                                    ui_state.needs_redraw = true;
                                }
                            }
                        },
                        .up, .char_k => {
                            switch (ui_state.current_tab) {
                                .detail, .network, .alerts, .fingerprints => {
                                    if (ui_state.scroll_offset > 0) {
                                        ui_state.scroll_offset -= 1;
                                        ui_state.needs_redraw = true;
                                    }
                                },
                                else => ui_state.selectUp(),
                            }
                        },
                        .down, .char_j => {
                            switch (ui_state.current_tab) {
                                .detail, .network, .alerts, .fingerprints => {
                                    ui_state.scroll_offset += 1;
                                    ui_state.needs_redraw = true;
                                },
                                else => ui_state.selectDown(
                                    if (ui_state.current_tab == .settings) @import("../tui/renderer.zig").TuiRenderer.settings_row_count else 20,
                                ),
                            }
                        },
                        .f12 => {
                            renderer.swap() catch {};
                            ui_state.needs_redraw = true;
                        },
                        .enter => {
                            if (ui_state.current_tab == .overview) {
                                ui_state.current_tab = .detail;
                                ui_state.scroll_offset = 0;
                                ui_state.needs_redraw = true;
                            } else if (ui_state.current_tab == .settings) {
                                enterSettingsEdit(&ui_state, config);
                            }
                        },
                        else => {},
                    }
                }
            },
            .resize => |sz| {
                ui_state.term_width = sz.width;
                ui_state.term_height = sz.height;
                ui_state.needs_redraw = true;
            },
            .none => {},
        }

        // Render
        if (ui_state.needs_redraw or @as(u64, @intCast(now - last_render)) >= render_interval) {
            renderer.render(&ui_state, &reader, config);
            last_render = now;
        }

        // Small sleep to avoid busy-wait (TUI pollInput has its own timeout)
        if (renderer.active == .gui) {
            std.Thread.sleep(16 * std.time.ns_per_ms); // ~60fps
        }
    }
}

/// Populate edit buffer with current value and enter edit mode
fn enterSettingsEdit(ui_state: *state_mod.UiState, config: *const config_mod.Config) void {
    // Row 2 is DB Path (read-only)
    if (ui_state.selected_row == 2) return;

    var buf: [256]u8 = undefined;
    const val: []const u8 = switch (ui_state.selected_row) {
        0 => std.fmt.bufPrint(&buf, "{d}", .{config.interval}) catch return,
        1 => config.match_pattern,
        3 => std.fmt.bufPrint(&buf, "{d:.1}", .{config.thresholds.cpu_warning}) catch return,
        4 => std.fmt.bufPrint(&buf, "{d:.1}", .{config.thresholds.cpu_critical}) catch return,
        5 => std.fmt.bufPrint(&buf, "{d:.1}", .{config.thresholds.rss_warning_mb}) catch return,
        6 => std.fmt.bufPrint(&buf, "{d:.1}", .{config.thresholds.rss_critical_mb}) catch return,
        7 => std.fmt.bufPrint(&buf, "{d}", .{config.thresholds.fd_warning}) catch return,
        8 => std.fmt.bufPrint(&buf, "{d}", .{config.thresholds.fd_critical}) catch return,
        else => return,
    };

    const copy_len = @min(val.len, ui_state.edit_buf.len - 1);
    @memcpy(ui_state.edit_buf[0..copy_len], val[0..copy_len]);
    ui_state.edit_len = copy_len;
    ui_state.editing = true;
    ui_state.needs_redraw = true;
}

/// Parse edit buffer and commit value to config
fn commitSettingsEdit(alloc: std.mem.Allocator, ui_state: *state_mod.UiState, config: *config_mod.Config) void {
    const text = ui_state.edit_buf[0..ui_state.edit_len];

    switch (ui_state.selected_row) {
        0 => { // Poll Interval
            if (std.fmt.parseInt(u32, text, 10)) |v| {
                if (v >= 1) config.interval = v;
            } else |_| {}
        },
        1 => { // Match Pattern — dupe into owned allocation
            const new_pattern = alloc.dupe(u8, text) catch {
                ui_state.editing = false;
                ui_state.needs_redraw = true;
                return;
            };
            if (config.match_pattern_owned) {
                alloc.free(@constCast(config.match_pattern));
            }
            config.match_pattern = new_pattern;
            config.match_pattern_owned = true;
        },
        3 => { // CPU Warning
            if (std.fmt.parseFloat(f64, text)) |v| {
                config.thresholds.cpu_warning = v;
            } else |_| {}
        },
        4 => { // CPU Critical
            if (std.fmt.parseFloat(f64, text)) |v| {
                config.thresholds.cpu_critical = v;
            } else |_| {}
        },
        5 => { // RSS Warning
            if (std.fmt.parseFloat(f64, text)) |v| {
                config.thresholds.rss_warning_mb = v;
            } else |_| {}
        },
        6 => { // RSS Critical
            if (std.fmt.parseFloat(f64, text)) |v| {
                config.thresholds.rss_critical_mb = v;
            } else |_| {}
        },
        7 => { // FD Warning
            if (std.fmt.parseInt(i32, text, 10)) |v| {
                config.thresholds.fd_warning = v;
            } else |_| {}
        },
        8 => { // FD Critical
            if (std.fmt.parseInt(i32, text, 10)) |v| {
                config.thresholds.fd_critical = v;
            } else |_| {}
        },
        else => {},
    }

    ui_state.editing = false;
    ui_state.needs_redraw = true;
}

fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

fn runHeadless(
    alloc: std.mem.Allocator,
    collector: *collector_mod.Collector,
    engine: *engine_mod.AnalysisEngine,
    reader: *reader_mod.Reader,
    ui_state: *state_mod.UiState,
    config: config_mod.Config,
) !void {
    printStdout("agent-watch: headless mode, collecting every {d}s, pattern: {s}\n", .{ config.interval, config.match_pattern });

    while (ui_state.running) {
        std.Thread.sleep(@as(u64, config.interval) * std.time.ns_per_s);

        var result = collector.tick() catch continue;
        defer result.deinit(alloc);

        engine.processTickData(
            result.samples.items,
            result.statuses.items,
            result.fd_counts.items,
            result.conn_counts.items,
            result.timestamp,
        );

        const sample_count = reader.getSampleCount() catch 0;

        printStdout("[tick {d}] agents={d} samples={d} total={d} fds={d} conns={d}\n", .{
            collector.tick_count,
            result.agents_found,
            result.samples_written,
            sample_count,
            result.fds_written,
            result.conns_written,
        });
    }
}
