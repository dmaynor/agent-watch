#!/usr/bin/env bash
# agent-watch.sh — restart-safe, append-only

set -euo pipefail
set -o noclobber

INTERVAL=5
OUT_DIR="${HOME}/agent-watch"
MATCH_REGEX='(codex|claude|gemini|copilot)'

mkdir -p "${OUT_DIR}"

ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

while true; do
  NOW="$(ts)"

  ps -eo pid,user,pcpu,pmem,rss,stat,etimes,comm,args \
    | grep -Ei "${MATCH_REGEX}" \
    | grep -v grep \
    | while read -r PID USER CPU MEM RSS STAT ETIMES COMM ARGS; do

        SNAP_ID="$(date -u +%Y%m%dT%H%M%S.%N)_${PID}"
        BASE="${OUT_DIR}/${SNAP_ID}"

        # ---- Append-only process log ----
        {
          printf '{'
          printf '"ts":"%s",' "${NOW}"
          printf '"pid":%s,' "${PID}"
          printf '"user":"%s",' "${USER}"
          printf '"cpu":%s,' "${CPU}"
          printf '"mem":%s,' "${MEM}"
          printf '"rss_kb":%s,' "${RSS}"
          printf '"stat":"%s",' "${STAT}"
          printf '"etimes":%s,' "${ETIMES}"
          printf '"comm":"%s",' "${COMM}"
          printf '"args":"%s"' "${ARGS//\"/\\\"}"
          printf '}\n'
        } >> "${OUT_DIR}/process.ndjson"

        # ---- Unique snapshot artifacts (never overwritten) ----
        sudo lsof -n -P -p "${PID}" \
          > "${BASE}.lsof" 2>/dev/null || true

        ss -ptni "pid = ${PID}" \
          > "${BASE}.ss" 2>/dev/null || true

        {
          echo "ts=${NOW}"
          grep -E 'State|Threads|voluntary_ctxt_switches|nonvoluntary_ctxt_switches|VmRSS|VmSwap' \
            "/proc/${PID}/status"
        } > "${BASE}.status" 2>/dev/null || true

  done

  sleep "${INTERVAL}"
done

