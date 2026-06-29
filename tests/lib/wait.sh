#!/bin/bash
# poll a logfile for a marker string until it appears or a timeout elapses.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# wait_for_marker <logfile> <marker> <timeout-seconds>
wait_for_marker() {
  local log="$1" marker="$2" timeout="$3"
  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    grep -q -- "$marker" "$log" 2>/dev/null && return 0
    # surface a hard boot failure early instead of waiting out the timeout
    grep -qiE "Kernel panic|Unable to mount root" "$log" 2>/dev/null && return 1
    sleep 2
  done
  return 1
}

# extract the report block the in-guest service printed to the console
report_block() {
  sed -n "/$REPORT_BEGIN/,/$REPORT_END/p" "$CONSOLE_LOG" | strip_escapes
}
