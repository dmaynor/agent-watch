const std = @import("std");
const collector_mod = @import("../collector/collector.zig");
const swap_mod = @import("swap.zig");
const state_mod = @import("../ui/state.zig");
const reader_mod = @import("../store/reader.zig");
const db_mod = @import("../store/db.zig");
const config_mod = @import("../config.zig");
const input_mod = @import("../ui/input.zig");

/// Central event loop: multiplexes collector timer, input, and rendering
pub fn run(
    alloc: std.mem.Allocator,
    db: *db_mod.Db,
    config: config_mod.Config,
    headless: bool,
) !void {
    var collector = try collector_mod.Collector.init(alloc, db, config);
    defer collector.deinit();

    var reader = reader_mod.Reader.init(db, alloc);

    var ui_state = state_mod.UiState{};

    // Initial collection tick
    {
        const result = collector.tick() catch |err| {
            std.log.warn("Collection tick error: {}", .{err});
            collector_mod.Collector.CollectionResult{};
        };
        const sample_count = reader.getSampleCount() catch 0;
        ui_state.last_tick_result = .{
            .agents_found = result.agents_found,
            .samples_written = result.samples_written,
            .total_samples = sample_count,
        };
    }

    if (headless) {
        return runHeadless(&collector, &reader, &ui_state, config);
    }

    var renderer = try swap_mod.SwapRenderer.init(alloc, config.gui);
    defer renderer.deinit();

    const interval_ns: u64 = @as(u64, config.interval) * std.time.ns_per_s;
    var last_collect = std.time.nanoTimestamp();
    var last_render = last_collect;
    const render_interval: u64 = 100 * std.time.ns_per_ms; // 10 FPS

    while (ui_state.running) {
        const now = std.time.nanoTimestamp();

        // Collection tick
        if (@as(u64, @intCast(now - last_collect)) >= interval_ns) {
            const result = collector.tick() catch collector_mod.Collector.CollectionResult{};
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
            .key => |key| switch (key) {
                .quit => ui_state.running = false,
                .tab => ui_state.nextTab(),
                .shift_tab => ui_state.prevTab(),
                .up, .char_k => ui_state.selectUp(),
                .down, .char_j => ui_state.selectDown(20),
                .f12 => {
                    renderer.swap() catch {};
                    ui_state.needs_redraw = true;
                },
                .enter => {
                    if (ui_state.current_tab == .overview) {
                        ui_state.current_tab = .detail;
                        ui_state.needs_redraw = true;
                    }
                },
                else => {},
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
            renderer.render(&ui_state, &reader);
            last_render = now;
        }

        // Small sleep to avoid busy-wait (TUI pollInput has its own timeout)
        if (renderer.active == .gui) {
            std.time.sleep(16 * std.time.ns_per_ms); // ~60fps
        }
    }
}

fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

fn runHeadless(
    collector: *collector_mod.Collector,
    reader: *reader_mod.Reader,
    ui_state: *state_mod.UiState,
    config: config_mod.Config,
) !void {
    printStdout("agent-watch: headless mode, collecting every {d}s, pattern: {s}\n", .{ config.interval, config.match_pattern });

    while (ui_state.running) {
        std.time.sleep(@as(u64, config.interval) * std.time.ns_per_s);

        const result = collector.tick() catch continue;
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
