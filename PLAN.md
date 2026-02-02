# Proactive Maintenance & Test Coverage Plan

## Goal
Fix all known bugs from the audit, then systematically build test coverage to 70%+ by working from pure-logic modules outward to integration layers.

**Current state:** 1 test, <1% coverage, 7 known bugs, ~6200 lines across 52 files.

---

## Phase 1: Bug Fixes (no new tests yet)

Fix all 7 audit findings. Small targeted changes, ~25 lines total.

| # | File | Bug | Fix |
|---|------|-----|-----|
| 1 | `src/collector/collector.zig:77-82` | Partial alloc leak — if `dupe(args)` fails, `comm` leaks | Add errdefer after each successful dupe |
| 2 | `src/collector/collector.zig:55,144` | Transaction begin/commit silently swallowed | Return early on begin failure; log+rollback on commit failure |
| 3 | `src/analysis/engine.zig:201-205` | `cpu_stats` leaked if `rss_stats.init` fails | Add `cpu_stats.deinit()` before return |
| 4 | `src/collector/platform_linux.zig:35-53` | readCmdline: `result` leaked if `dupe(trimmed)` fails | Add `errdefer alloc.free(result)` |
| 5 | `src/collector/platform_linux.zig:160-203` | listFds errdefer: `.path` strings not freed | Change errdefer to loop+free paths before deinit |
| 6 | `src/data/types.zig:234` | `formatTimestamp` panics on negative ts | Add `if (ts < 0) return error.InvalidTimestamp` |
| 7 | `src/store/reader.zig` (3 queries) | Unbounded queries: getAliveAgents, getLatestSamplesPerAgent, getDistinctPids | Add LIMIT 500/200/10000 |

**Verify:** `zig build` clean. Run app, exercise all tabs, quit — GPA reports zero leaks.

---

## Phase 2: Test Infrastructure + Pure Math (~25% coverage target)

### 2a: Test helpers — `src/testing/helpers.zig`

Create minimal test utilities:
- `makeTestDb()` — returns in-memory SQLite DB with schema applied
- `makeSample()` — returns a `ProcessSample` with sensible defaults and overrides
- `makeAlert()`, `makeFdRecord()`, `makeNetConnection()` — same pattern
- `expectApproxEqual(f64, f64, tolerance)` — float comparison helper

### 2b: Pure algorithm tests (no I/O, no DB)

These modules are pure functions operating on slices/numbers. Each gets tests added inline (Zig convention: `test` blocks at bottom of the file).

| File | Lines | Tests to add | What to test |
|------|-------|-------------|--------------|
| `src/analysis/timeseries.zig` | 92 | 8-10 | RollingStats: init, push, mean, stddev, min/max, percentile, empty stats, full buffer wrap |
| `src/analysis/anomaly.zig` | 19 | 3-4 | z-score detection, IQR outlier, edge cases (zero stddev, empty data) |
| `src/analysis/memory_leak.zig` | 82 | 4-5 | Linear regression slope, R-squared, leak detection threshold, flat data = no leak |
| `src/analysis/pipeline.zig` | 28 | 3-4 | Phase classification: idle/active/burst boundaries, edge values |
| `src/analysis/alerts.zig` | 123 | 6-8 | Threshold evaluation for each metric (CPU, RSS, FD, thread), warning vs critical, below threshold = no alert |
| `src/analysis/regression.zig` | 68 | 4-5 | Baseline comparison: deviation detection, matching comm, no baselines = no alerts |
| `src/analysis/network.zig` | 32 | 3-4 | buildInventory: count ESTABLISHED/LISTEN/TIME_WAIT/other, empty input |
| `src/analysis/security.zig` | 112 | 5-6 | auditFds: sensitive paths, writable dirs. auditConnections: suspicious ports, high connection count |
| `src/core/ring_buffer.zig` | 58 | 5-6 | Push, wrap around, read back, empty buffer, single element |
| `src/data/types.zig` | 274 | 5-6 | parseTimestamp edge cases (short string, bad format, pre-epoch), formatTimestamp negative, FdType/Protocol fromString/toString roundtrips |
| `src/ui/state.zig` | 100 | 4-5 | Tab cycling (next/prev wrap), selectUp/selectDown bounds, scroll_offset |

**Verify:** `zig build test` — all pass, `std.testing.allocator` catches any leaks in test code.

---

## Phase 3: Parser & Config Tests (~45% coverage target)

Parsers can be tested with hardcoded string inputs — no real files needed.

| File | Lines | Tests to add | What to test |
|------|-------|-------------|--------------|
| `src/data/ndjson_parser.zig` | 107 | 6-8 | Valid NDJSON line, missing fields, empty line, malformed JSON, float/int edge cases |
| `src/data/lsof_parser.zig` | 101 | 5-6 | Valid lsof record, partial fields, empty input, field delimiter edge cases |
| `src/data/status_parser.zig` | 95 | 5-6 | Valid /proc/status content, missing keys, zero values, malformed lines |
| `src/config.zig` | 109 | 5-6 | CLI arg parsing: --interval, --match, --db, unknown flags, missing values |
| `src/analysis/fingerprint.zig` | 50 | 3-4 | Fingerprint generation from sample data, phase detection |
| `src/analysis/context_switch.zig` | 27 | 2-3 | Context switch rate calculation, zero delta |

**Verify:** `zig build test` — all pass.

---

## Phase 4: SQLite Integration Tests (~60% coverage target)

Uses the `makeTestDb()` helper from Phase 2a to create in-memory databases.

| File | Lines | Tests to add | What to test |
|------|-------|-------------|--------------|
| `src/store/schema.zig` | 124 | 2-3 | Schema creates all tables, idempotent re-creation |
| `src/store/db.zig` | 192 | 4-5 | Open/close, prepare/bind/step, error on bad SQL, exec |
| `src/store/writer.zig` | 238 | 8-10 | Insert sample/status/fd/connection/alert/agent/fingerprint, upsert idempotency, transaction begin/commit/rollback, batch writes |
| `src/store/reader.zig` | 422 | 10-12 | Each query method: empty DB returns empty, insert→read roundtrip, LIMIT honored, freeSlice cleans up (use testing.allocator) |

**Key pattern:** Each test creates an in-memory DB, inserts known data via Writer, reads back via Reader, asserts values match, and relies on `std.testing.allocator` to verify no leaks.

**Verify:** `zig build test` — all pass, zero leaks.

---

## Phase 5: Collector & Integration Tests (~70% coverage target)

Platform-specific code needs real `/proc` or mock data. Focus on what's testable.

| File | Lines | Tests to add | What to test |
|------|-------|-------------|--------------|
| `src/collector/scanner.zig` | 95 | 4-5 | Pattern matching logic: split pattern, match against comm/cmdline, no match, empty pattern |
| `src/collector/platform_linux.zig` | 416 | 6-8 | `parseHexAddr` (pure function), `formatAddr` (pure function), `readCmdline` with mock data if possible, `readNetConnections` parsing logic |
| `src/collector/process_info.zig` | 69 | 3-4 | CPU/RSS calculation from known stat values |
| `src/analysis/engine.zig` | 311 | 5-6 | processTickData with mock data, PidState lifecycle, threshold alerts generated correctly |

**Not tested (acceptable exclusions for 70% target):**
- `src/tui/renderer.zig` (616 lines) — visual output, tested manually
- `src/gui/renderer.zig` (319 lines) — visual output, stub
- `src/core/event_loop.zig` (341 lines) — integration loop, tested manually
- `src/main.zig` (300 lines) — CLI entry point
- Platform stubs (macos/windows ~190 lines)
- `src/tui/terminal_posix.zig`, `terminal_windows.zig` — terminal I/O

These exclusions total ~1800 lines. With ~4400 testable lines at 70%+ coverage, that's ~3100 lines covered by tests.

**Verify:** `zig build test` — all pass, zero leaks. Run full app manually to confirm no regressions.

---

## Execution Order

Each phase builds on the previous. Phases 2-5 each add tests that use `std.testing.allocator`, so every new test also serves as a proactive leak detector.

```
Phase 1: Bug fixes                    → zig build clean, GPA clean
Phase 2: Test infra + pure math       → ~25% coverage
Phase 3: Parsers + config             → ~45% coverage
Phase 4: SQLite integration           → ~60% coverage
Phase 5: Collector + engine           → ~70% coverage
```

Total new tests: ~110-130 test cases across ~30 files.

---

## Files Modified Per Phase

**Phase 1** (bug fixes only):
- `src/collector/collector.zig`
- `src/analysis/engine.zig`
- `src/collector/platform_linux.zig`
- `src/data/types.zig`
- `src/store/reader.zig`

**Phase 2** (test infra + pure math):
- NEW: `src/testing/helpers.zig`
- `src/analysis/timeseries.zig`
- `src/analysis/anomaly.zig`
- `src/analysis/memory_leak.zig`
- `src/analysis/pipeline.zig`
- `src/analysis/alerts.zig`
- `src/analysis/regression.zig`
- `src/analysis/network.zig`
- `src/analysis/security.zig`
- `src/core/ring_buffer.zig`
- `src/data/types.zig`
- `src/ui/state.zig`

**Phase 3** (parsers):
- `src/data/ndjson_parser.zig`
- `src/data/lsof_parser.zig`
- `src/data/status_parser.zig`
- `src/config.zig`
- `src/analysis/fingerprint.zig`
- `src/analysis/context_switch.zig`

**Phase 4** (SQLite):
- `src/store/schema.zig`
- `src/store/db.zig`
- `src/store/writer.zig`
- `src/store/reader.zig`

**Phase 5** (collector/engine):
- `src/collector/scanner.zig`
- `src/collector/platform_linux.zig`
- `src/collector/process_info.zig`
- `src/analysis/engine.zig`
