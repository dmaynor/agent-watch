const std = @import("std");
const alerts_mod = @import("analysis/alerts.zig");

pub const Config = struct {
    /// Alert thresholds (editable at runtime via Settings tab)
    thresholds: alerts_mod.Thresholds = .{},
    /// Collection interval in seconds
    interval: u32 = 5,
    /// Pipe-separated match pattern for process discovery
    match_pattern: []const u8 = "codex|claude|gemini|copilot",
    /// Whether match_pattern was heap-allocated (and should be freed before replacing)
    match_pattern_owned: bool = false,
    /// SQLite database path
    db_path: [:0]const u8 = "agent-watch.db",
    /// Start in GUI mode
    gui: bool = false,
    /// Headless mode (no UI, just collect)
    headless: bool = false,
    /// Import subcommand: path to import from
    import_path: ?[]const u8 = null,
    /// Analyze subcommand: generate offline report
    analyze: bool = false,
    /// Baseline save subcommand
    baseline_save: bool = false,
    /// Baseline compare subcommand
    baseline_compare: bool = false,
    /// Label for baseline operations
    baseline_label: []const u8 = "default",
};

pub fn parseArgs(alloc: std.mem.Allocator) !Config {
    var config = Config{};
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next(); // skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--gui")) {
            config.gui = true;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            config.headless = true;
        } else if (std.mem.eql(u8, arg, "--interval")) {
            if (args.next()) |val| {
                config.interval = std.fmt.parseInt(u32, val, 10) catch 5;
            }
        } else if (std.mem.eql(u8, arg, "--match")) {
            if (args.next()) |val| {
                config.match_pattern = try alloc.dupe(u8, val);
                config.match_pattern_owned = true;
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (args.next()) |val| {
                config.db_path = try allocSentinel(alloc, val);
            }
        } else if (std.mem.eql(u8, arg, "import")) {
            if (args.next()) |val| {
                config.import_path = try alloc.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, arg, "analyze")) {
            config.analyze = true;
        } else if (std.mem.eql(u8, arg, "baseline-save")) {
            config.baseline_save = true;
        } else if (std.mem.eql(u8, arg, "baseline-compare")) {
            config.baseline_compare = true;
        } else if (std.mem.eql(u8, arg, "--label")) {
            if (args.next()) |val| {
                config.baseline_label = try alloc.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        }
    }

    return config;
}

fn allocSentinel(alloc: std.mem.Allocator, src: []const u8) ![:0]const u8 {
    const buf = try alloc.allocSentinel(u8, src.len, 0);
    @memcpy(buf, src);
    return buf;
}

fn printUsage() void {
    const usage =
        \\agent-watch — AI agent process monitor
        \\
        \\Usage:
        \\  agent-watch                     Start with TUI (default)
        \\  agent-watch --gui               Start with GUI
        \\  agent-watch --headless           Headless collection only
        \\  agent-watch --interval 5         Collection interval in seconds
        \\  agent-watch --match "pattern"    Process match pattern (pipe-separated)
        \\  agent-watch --db path.db         SQLite database path
        \\  agent-watch import <dir>         Import existing bash script data
        \\  agent-watch analyze              Generate offline analysis report
        \\  agent-watch baseline-save        Save current fingerprints as baseline
        \\  agent-watch baseline-compare     Compare current fingerprints to baseline
        \\    --label "name"                 Label for baseline (default: "default")
        \\
        \\Keys:
        \\  F12     Hot-swap between TUI and GUI
        \\  Tab     Switch dashboard tab
        \\  q       Quit
        \\
    ;
    std.fs.File.stdout().writeAll(usage) catch {};
}

const testing = std.testing;

test "Config: default values" {
    const config = Config{};
    try testing.expectEqual(@as(u32, 5), config.interval);
    try testing.expectEqualStrings("codex|claude|gemini|copilot", config.match_pattern);
    try testing.expectEqualStrings("agent-watch.db", config.db_path);
    try testing.expect(!config.gui);
    try testing.expect(!config.headless);
    try testing.expect(config.import_path == null);
    try testing.expect(!config.analyze);
}

test "Config: default thresholds" {
    const config = Config{};
    try testing.expectEqual(@as(f64, 80.0), config.thresholds.cpu_warning);
    try testing.expectEqual(@as(f64, 95.0), config.thresholds.cpu_critical);
    try testing.expectEqual(@as(i32, 1000), config.thresholds.fd_warning);
}

test "allocSentinel: creates zero-terminated copy" {
    const alloc = testing.allocator;
    const result = try allocSentinel(alloc, "test.db");
    defer alloc.free(result);
    try testing.expectEqualStrings("test.db", result);
    // Verify sentinel null byte
    try testing.expectEqual(@as(u8, 0), result.ptr[result.len]);
}

test "allocSentinel: empty string" {
    const alloc = testing.allocator;
    const result = try allocSentinel(alloc, "");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
    try testing.expectEqual(@as(u8, 0), result.ptr[0]);
}
