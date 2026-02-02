const std = @import("std");

pub const Config = struct {
    /// Collection interval in seconds
    interval: u32 = 5,
    /// Pipe-separated match pattern for process discovery
    match_pattern: []const u8 = "codex|claude|gemini|copilot",
    /// SQLite database path
    db_path: [:0]const u8 = "agent-watch.db",
    /// Start in GUI mode
    gui: bool = false,
    /// Headless mode (no UI, just collect)
    headless: bool = false,
    /// Import subcommand: path to import from
    import_path: ?[]const u8 = null,
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
                config.match_pattern = val;
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (args.next()) |val| {
                config.db_path = try allocSentinel(alloc, val);
            }
        } else if (std.mem.eql(u8, arg, "import")) {
            if (args.next()) |val| {
                config.import_path = val;
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
        \\
        \\Keys:
        \\  F12     Hot-swap between TUI and GUI
        \\  Tab     Switch dashboard tab
        \\  q       Quit
        \\
    ;
    std.fs.File.stdout().writeAll(usage) catch {};
}
