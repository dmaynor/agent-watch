/// Raylib C interop backend
/// Only usable when built with -Denable-gui=true
const build_options = @import("build_options");

pub const enabled = build_options.enable_gui;

pub const c = if (enabled) @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
}) else struct {};
