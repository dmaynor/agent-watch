/// ANSI color codes for TUI
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const underline = "\x1b[4m";
    pub const blink = "\x1b[5m";
    pub const reverse = "\x1b[7m";

    // Foreground
    pub const fg_black = "\x1b[30m";
    pub const fg_red = "\x1b[31m";
    pub const fg_green = "\x1b[32m";
    pub const fg_yellow = "\x1b[33m";
    pub const fg_blue = "\x1b[34m";
    pub const fg_magenta = "\x1b[35m";
    pub const fg_cyan = "\x1b[36m";
    pub const fg_white = "\x1b[37m";

    // Bright foreground
    pub const fg_bright_red = "\x1b[91m";
    pub const fg_bright_green = "\x1b[92m";
    pub const fg_bright_yellow = "\x1b[93m";
    pub const fg_bright_blue = "\x1b[94m";
    pub const fg_bright_cyan = "\x1b[96m";

    // Background
    pub const bg_black = "\x1b[40m";
    pub const bg_red = "\x1b[41m";
    pub const bg_green = "\x1b[42m";
    pub const bg_yellow = "\x1b[43m";
    pub const bg_blue = "\x1b[44m";
    pub const bg_white = "\x1b[47m";
};

/// Box-drawing characters
pub const Box = struct {
    pub const h_line = "─";
    pub const v_line = "│";
    pub const tl_corner = "┌";
    pub const tr_corner = "┐";
    pub const bl_corner = "└";
    pub const br_corner = "┘";
    pub const t_tee = "┬";
    pub const b_tee = "┴";
    pub const l_tee = "├";
    pub const r_tee = "┤";
    pub const cross = "┼";
};

/// Sparkline characters (block elements)
pub const Spark = struct {
    pub const blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
};
