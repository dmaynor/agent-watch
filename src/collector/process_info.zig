const std = @import("std");
const builtin = @import("builtin");
const types = @import("../data/types.zig");

const platform = switch (builtin.os.tag) {
    .linux => @import("platform_linux.zig"),
    .macos => @import("platform_macos.zig"),
    .windows => @import("platform_windows.zig"),
    else => @compileError("Unsupported platform"),
};

/// Collect a process sample for a given PID
pub fn collectSample(pid: i32, comm: []const u8, args: []const u8, user: []const u8, now: types.Timestamp) !types.ProcessSample {
    const stat = platform.readStat(pid) catch return types.ProcessSample{
        .ts = now,
        .pid = pid,
        .user = user,
        .cpu = 0,
        .mem = 0,
        .rss_kb = 0,
        .stat = "?",
        .etimes = 0,
        .comm = comm,
        .args = args,
    };

    // Calculate RSS in KB (pages * page_size / 1024)
    const page_size: i64 = 4096;
    const rss_kb = @divTrunc(stat.rss_pages * page_size, 1024);

    // Calculate elapsed time
    const boot_time = platform.getBootTime() catch 0;
    const clk_tck = platform.getClkTck();
    const start_seconds = @divTrunc(stat.starttime, clk_tck);
    const process_start = boot_time + @as(i64, @intCast(start_seconds));
    const etimes = now - process_start;

    // CPU percentage: approximate from utime+stime vs elapsed
    // This is a snapshot approximation; for accurate CPU% we'd need two samples
    const total_cpu_ticks = stat.utime + stat.stime;
    const total_cpu_seconds = @as(f64, @floatFromInt(total_cpu_ticks)) / @as(f64, @floatFromInt(clk_tck));
    const elapsed_f: f64 = @floatFromInt(@max(etimes, 1));
    const cpu_pct = (total_cpu_seconds / elapsed_f) * 100.0;

    // State character to string
    const state_str: []const u8 = switch (stat.state) {
        'R' => "R",
        'S' => "S",
        'D' => "D",
        'Z' => "Z",
        'T' => "T",
        'W' => "W",
        'X' => "X",
        else => "?",
    };

    return types.ProcessSample{
        .ts = now,
        .pid = pid,
        .user = user,
        .cpu = cpu_pct,
        .mem = 0, // mem% requires total system memory; skip for now
        .rss_kb = rss_kb,
        .stat = state_str,
        .etimes = etimes,
        .comm = comm,
        .args = args,
    };
}
