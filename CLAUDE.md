# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Requires **Zig 0.15.x** (installed via snap). SQLite is vendored in `lib/` as C amalgamation.

```bash
zig build                        # compile
zig build run                    # build and run (TUI mode)
zig build run -- --headless      # headless collection only
zig build run -- --gui           # GUI mode (stub, raylib not yet integrated)
zig build run -- import /path    # import bash script data into SQLite
zig build test                   # run unit tests
```

CLI flags: `--interval N` (collection seconds), `--match "pattern"` (pipe-separated), `--db path.db`.

## Architecture

Cross-platform AI agent process monitor. Scans for processes matching `codex|claude|gemini|copilot`, collects telemetry from `/proc`, stores in SQLite, renders a TUI dashboard. Replaces the original `agent-watch.sh` bash script.

### Data flow

```
Scanner → Platform Layer → Collector.tick() → Writer (SQLite) → Reader → UI Renderer
```

### Key modules

- **`collector/`** — Process discovery and data collection on a timer. `collector.zig` orchestrates per-tick: scan → collect samples/status/FDs/network → batch write.
- **`collector/platform_linux.zig`** — Reads `/proc/PID/{stat,status,cmdline,fd,net/tcp}` directly (no fork/exec). `platform_macos.zig` and `platform_windows.zig` are stubs.
- **`store/`** — SQLite layer. `db.zig` wraps the C API. `writer.zig` holds pre-prepared statements for batch inserts in transactions. `reader.zig` provides query methods for the UI. `schema.zig` has DDL as comptime strings.
- **`analysis/`** — `timeseries.zig` (RollingStats ring buffer), `anomaly.zig` (z-score/IQR), `memory_leak.zig` (linear regression on RSS), `pipeline.zig` (idle/active/burst phase detection), `alerts.zig` (threshold evaluation). These modules are implemented but not yet wired into the event loop.
- **`ui/state.zig`** — Renderer-agnostic UI state (current tab, selection, scroll). Shared between TUI and GUI.
- **`tui/`** — ANSI terminal renderer. `terminal.zig` handles raw mode (termios). `buffer.zig` double-buffers ANSI output. `renderer.zig` draws tabs: Overview, Agent Detail, Network, Alerts, Fingerprints.
- **`gui/`** — Raylib GUI renderer (stub). Same interface as TUI.
- **`core/event_loop.zig`** — Central loop multiplexing collection timer, input polling, and rendering. Single-threaded.
- **`core/swap.zig`** — Hot-swap between TUI↔GUI with F12. Deinits current renderer, inits alternate, preserves UI state.
- **`data/`** — `types.zig` defines all shared structs (ProcessSample, FdRecord, NetConnection, StatusRecord, Agent, Alert). Import parsers (`ndjson_parser.zig`, `lsof_parser.zig`, `status_parser.zig`) load existing bash script output.

### Platform abstraction pattern

Compile-time OS selection used throughout `collector/`:
```zig
const platform = switch (builtin.os.tag) {
    .linux => @import("platform_linux.zig"),
    .macos => @import("platform_macos.zig"),
    .windows => @import("platform_windows.zig"),
};
```
All platform modules export the same function signatures. macOS/Windows are stubs.

### Zig 0.15 API notes

- `std.fs.File.stdout()` / `stdin()` / `stderr()` instead of `std.io.getStdOut()`.
- `File.writer()` requires a `[]u8` buffer argument (buffered writer). Use `File.writeAll()` for simple output, or `std.fmt.bufPrint()` + `writeAll()`.
- Build system uses `b.createModule()` → `b.addExecutable(.{ .root_module = mod })`. C sources and include paths go on the Module, not the Compile step.
- `addCSourceFiles()` on Module, `addIncludePath()` on Module, `linkLibrary()` on Module.
- Zig 0.15 enforces `const` for variables that are never mutated.

### SQLite integration

SQLite is compiled from C amalgamation (`lib/sqlite3.c`) with flags: `SQLITE_ENABLE_WAL`, `SQLITE_ENABLE_FTS5`, `SQLITE_ENABLE_JSON1`, `SQLITE_THREADSAFE=1`. Accessed via `@cImport(@cInclude("sqlite3.h"))` in `store/db.zig`. Schema has 7 tables with 9 indexes. Writer uses prepared statement pooling with reset/rebind pattern.

### Current state

- **Working**: Build system, SQLite layer, Linux collector, TUI renderer, import parsers, analysis algorithms.
- **Build not yet clean**: There are remaining compilation errors being fixed (sqlite3_close return value, std.io API migration).
- **Stubs**: GUI renderer (raylib not integrated), macOS/Windows platform modules.
- **Not yet wired**: Analysis pipeline not connected to event loop; alerts not generated during collection.

### Reference data

`agent-watch.sh` is the original bash script. `process.ndjson` contains 891 lines of real monitoring data. `*.lsof`, `*.status` files are per-snapshot artifacts from the bash script. The `import` subcommand loads these into SQLite.
