const std = @import("std");
const config_mod = @import("config.zig");
const db_mod = @import("store/db.zig");
const event_loop = @import("core/event_loop.zig");
const ndjson_parser = @import("data/ndjson_parser.zig");
const lsof_parser = @import("data/lsof_parser.zig");
const status_parser = @import("data/status_parser.zig");
const writer_mod = @import("store/writer.zig");
const reader_mod = @import("store/reader.zig");
const report = @import("analysis/report.zig");
const regression = @import("analysis/regression.zig");


fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var config = try config_mod.parseArgs(alloc);

    // Handle import subcommand
    if (config.import_path) |import_dir| {
        runImport(alloc, config.db_path, import_dir);
        return;
    }

    // Handle analyze subcommand
    if (config.analyze) {
        runAnalyze(alloc, config.db_path);
        return;
    }

    // Handle baseline subcommands
    if (config.baseline_save) {
        runBaselineSave(alloc, config.db_path, config.baseline_label);
        return;
    }
    if (config.baseline_compare) {
        runBaselineCompare(alloc, config.db_path);
        return;
    }

    // Open database
    var db = db_mod.Db.open(config.db_path) catch |err| {
        print("Failed to open database '{s}': {}\n", .{ config.db_path, err });
        return;
    };
    defer db.close();

    print("agent-watch starting (db={s}, interval={d}s, pattern={s})\n", .{
        config.db_path,
        config.interval,
        config.match_pattern,
    });

    // Run event loop
    try event_loop.run(alloc, &db, &config, config.headless);
}

fn runBaselineSave(alloc: std.mem.Allocator, db_path: [:0]const u8, label: []const u8) void {
    var db = db_mod.Db.open(db_path) catch |err| {
        print("Failed to open database '{s}': {}\n", .{ db_path, err });
        return;
    };
    defer db.close();

    var reader = reader_mod.Reader.init(&db, alloc);
    var writer = writer_mod.Writer.init(&db) catch |err| {
        print("Failed to init writer: {}\n", .{err});
        return;
    };
    defer writer.deinit();

    const fingerprints = reader.getFingerprints() catch |err| {
        print("Failed to read fingerprints: {}\n", .{err});
        return;
    };
    defer reader_mod.Reader.Fingerprint.freeSlice(alloc, fingerprints);

    if (fingerprints.len == 0) {
        print("No fingerprints to save. Run the monitor first to collect data.\n", .{});
        return;
    }

    const now = std.time.timestamp();
    writer.beginTransaction() catch {};

    var saved: usize = 0;
    for (fingerprints) |fp| {
        writer.writeBaseline(.{
            .comm = fp.comm,
            .version = "1.0",
            .avg_cpu = fp.avg_cpu,
            .avg_rss_kb = fp.avg_rss_kb,
            .avg_threads = fp.avg_threads,
            .avg_fd_count = fp.avg_fd_count,
            .avg_net_conns = fp.avg_net_conns,
            .dominant_phase = fp.dominant_phase,
            .sample_count = fp.sample_count,
            .created_at = now,
            .label = label,
        }) catch continue;
        saved += 1;
    }

    writer.commitTransaction() catch {};
    print("Saved {d} baselines with label '{s}'\n", .{ saved, label });
}

fn runBaselineCompare(alloc: std.mem.Allocator, db_path: [:0]const u8) void {
    var db = db_mod.Db.open(db_path) catch |err| {
        print("Failed to open database '{s}': {}\n", .{ db_path, err });
        return;
    };
    defer db.close();

    var reader = reader_mod.Reader.init(&db, alloc);

    const baselines = reader.getBaselines() catch |err| {
        print("Failed to read baselines: {}\n", .{err});
        return;
    };
    defer reader_mod.Reader.Baseline.freeSlice(alloc, baselines);

    const fingerprints = reader.getFingerprints() catch |err| {
        print("Failed to read fingerprints: {}\n", .{err});
        return;
    };
    defer reader_mod.Reader.Fingerprint.freeSlice(alloc, fingerprints);

    if (baselines.len == 0) {
        print("No baselines saved. Run 'baseline-save' first.\n", .{});
        return;
    }
    if (fingerprints.len == 0) {
        print("No current fingerprints. Run the monitor first.\n", .{});
        return;
    }

    print("Comparing {d} fingerprints against {d} baselines (threshold: 20%%)\n\n", .{ fingerprints.len, baselines.len });

    var total_findings: usize = 0;
    for (baselines) |baseline| {
        for (fingerprints) |fp| {
            if (!std.mem.eql(u8, baseline.comm, fp.comm)) continue;

            const findings = regression.compareFingerprints(baseline, fp, 20.0);
            for (findings) |finding_opt| {
                const finding = finding_opt orelse break;
                print("  [{s}] {s}: {d:.1} -> {d:.1} ({d:.1}%%)\n", .{
                    finding.comm,
                    finding.metric,
                    finding.baseline_val,
                    finding.current_val,
                    finding.change_pct,
                });
                total_findings += 1;
            }
        }
    }

    if (total_findings == 0) {
        print("No significant regressions detected.\n", .{});
    } else {
        print("\n{d} regression(s) detected.\n", .{total_findings});
    }
}

fn runAnalyze(alloc: std.mem.Allocator, db_path: [:0]const u8) void {
    var db = db_mod.Db.open(db_path) catch |err| {
        print("Failed to open database '{s}': {}\n", .{ db_path, err });
        return;
    };
    defer db.close();

    var reader = reader_mod.Reader.init(&db, alloc);
    report.generateReport(alloc, &reader);
}

fn runImport(alloc: std.mem.Allocator, db_path: [:0]const u8, import_dir: []const u8) void {
    var db = db_mod.Db.open(db_path) catch |err| {
        print("Failed to open database: {}\n", .{err});
        return;
    };
    defer db.close();

    var writer = writer_mod.Writer.init(&db) catch |err| {
        print("Failed to init writer: {}\n", .{err});
        return;
    };
    defer writer.deinit();

    print("Importing from: {s}\n", .{import_dir});

    // Import process.ndjson
    var ndjson_path_buf: [512]u8 = undefined;
    const ndjson_path = std.fmt.bufPrint(&ndjson_path_buf, "{s}/process.ndjson", .{import_dir}) catch "process.ndjson";

    writer.beginTransaction() catch {};

    if (ndjson_parser.importNdjson(alloc, ndjson_path, &writer)) |ndjson_result| {
        print("  process.ndjson: {d} lines, {d} samples, {d} errors\n", .{
            ndjson_result.lines_read,
            ndjson_result.samples_written,
            ndjson_result.parse_errors,
        });
    } else |err| {
        print("  process.ndjson: error {}\n", .{err});
    }

    writer.commitTransaction() catch {};

    // Import .status and .lsof files
    var status_count: usize = 0;
    var lsof_count: usize = 0;

    var dir = std.fs.openDirAbsolute(import_dir, .{ .iterate = true }) catch {
        print("  Cannot open directory for .lsof/.status import\n", .{});
        return;
    };
    defer dir.close();

    writer.beginTransaction() catch {};

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        var full_path_buf: [1024]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ import_dir, entry.name }) catch continue;

        if (std.mem.endsWith(u8, entry.name, ".status")) {
            const result = status_parser.importStatusFile(full_path, &writer) catch continue;
            status_count += result.status_written;
        } else if (std.mem.endsWith(u8, entry.name, ".lsof")) {
            const result = lsof_parser.importLsofFile(alloc, full_path, &writer) catch continue;
            lsof_count += result.fds_written;
        }
    }

    writer.commitTransaction() catch {};

    print("  .status files: {d} records imported\n", .{status_count});
    print("  .lsof files: {d} FD records imported\n", .{lsof_count});

    // Print summary
    var reader = reader_mod.Reader.init(&db, alloc);
    const total = reader.getSampleCount() catch 0;
    print("Import complete. Total samples in database: {d}\n", .{total});
}

// Reference all modules for compilation
comptime {
    _ = @import("data/types.zig");
    _ = @import("store/schema.zig");
    _ = @import("store/db.zig");
    _ = @import("store/writer.zig");
    _ = @import("store/reader.zig");
    _ = @import("collector/scanner.zig");
    _ = @import("collector/process_info.zig");
    _ = @import("collector/proc_status.zig");
    _ = @import("collector/fd_info.zig");
    _ = @import("collector/net_info.zig");
    _ = @import("collector/collector.zig");
    _ = @import("analysis/timeseries.zig");
    _ = @import("analysis/anomaly.zig");
    _ = @import("analysis/memory_leak.zig");
    _ = @import("analysis/fingerprint.zig");
    _ = @import("analysis/network.zig");
    _ = @import("analysis/context_switch.zig");
    _ = @import("analysis/pipeline.zig");
    _ = @import("analysis/alerts.zig");
    _ = @import("analysis/engine.zig");
    _ = @import("analysis/security.zig");
    _ = @import("analysis/report.zig");
    _ = @import("analysis/regression.zig");
    _ = @import("ui/state.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/input.zig");
    _ = @import("ui/layout.zig");
    _ = @import("ui/widget.zig");
    _ = @import("ui/scene.zig");
    _ = @import("tui/terminal.zig");
    _ = @import("tui/ansi.zig");
    _ = @import("tui/buffer.zig");
    _ = @import("tui/renderer.zig");
    _ = @import("gui/renderer.zig");
    _ = @import("core/ring_buffer.zig");
    _ = @import("core/swap.zig");
    _ = @import("core/event_loop.zig");
    _ = @import("data/ndjson_parser.zig");
    _ = @import("data/lsof_parser.zig");
    _ = @import("data/status_parser.zig");
    _ = @import("testing/helpers.zig");
}
