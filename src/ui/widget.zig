/// Widget types (abstract, used by both TUI and GUI renderers)
pub const Column = struct {
    header: []const u8,
    width: u16,
};
