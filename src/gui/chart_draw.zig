/// Chart drawing for raylib GUI (sparklines and bar charts)
const rl = @import("raylib_backend.zig");

/// Draw a sparkline (line chart) from data points
pub fn drawSparkline(values: []const f64, x: c_int, y: c_int, width: c_int, height: c_int, color: rl.c.Color) void {
    if (!rl.enabled) return;
    if (values.len < 2) return;

    var max_val: f64 = 1;
    for (values) |v| {
        if (v > max_val) max_val = v;
    }

    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    const x_f: f32 = @floatFromInt(x);
    const y_f: f32 = @floatFromInt(y);
    const n_f: f32 = @floatFromInt(values.len - 1);

    var i: usize = 0;
    while (i < values.len - 1) : (i += 1) {
        const i_f: f32 = @floatFromInt(i);
        const i1_f: f32 = @floatFromInt(i + 1);

        const x1 = x_f + (i_f / n_f) * w_f;
        const x2 = x_f + (i1_f / n_f) * w_f;
        const v1: f32 = @floatCast(values[i] / max_val);
        const v2: f32 = @floatCast(values[i + 1] / max_val);
        const y1 = y_f + h_f - v1 * h_f;
        const y2 = y_f + h_f - v2 * h_f;

        rl.c.DrawLineEx(
            .{ .x = x1, .y = y1 },
            .{ .x = x2, .y = y2 },
            2.0,
            color,
        );
    }
}

/// Draw a bar chart from data points
pub fn drawBarChart(values: []const f64, x: c_int, y: c_int, width: c_int, height: c_int, color: rl.c.Color) void {
    if (!rl.enabled) return;
    if (values.len == 0) return;

    var max_val: f64 = 1;
    for (values) |v| {
        if (v > max_val) max_val = v;
    }

    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    const bar_w: f32 = w_f / @as(f32, @floatFromInt(values.len));

    for (values, 0..) |v, i| {
        const i_f: f32 = @floatFromInt(i);
        const bar_h: f32 = @floatCast((v / max_val) * @as(f64, @floatCast(h_f)));
        const bx: c_int = x + @as(c_int, @intFromFloat(i_f * bar_w));
        const by: c_int = y + height - @as(c_int, @intFromFloat(bar_h));
        const bw: c_int = @max(1, @as(c_int, @intFromFloat(bar_w)) - 1);
        rl.c.DrawRectangle(bx, by, bw, @as(c_int, @intFromFloat(bar_h)), color);
    }
}
