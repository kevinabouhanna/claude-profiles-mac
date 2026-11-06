#!/bin/bash
# Runs the real app and fails if it uses more CPU or memory than an idle menu bar app should.
#
#   ./scripts/energy-test.sh [path to the app's executable]
#
# Launches its own copy with -energyTest YES, which leaves Auto-Switch, the settings migration
# and the copy you have open alone, so it's safe to run on a Mac that uses the app. It drives
# that copy through what once caused trouble (the dropdown, Settings, light/dark flips), then
# lets it idle across several usage refreshes, measuring as it goes:
#
#   while the dropdown sits open    under 3% of a core
#   idle, every 10 s window         under 5%
#   idle, overall                   under 1%
#   menu bar redraws while idle     at most 1 per refresh, plus 2
#   memory growth while idle        under 30 MB
#   child processes left running    none (a cswap left behind would run forever)
#   the app's own energy guard      not tripped
#
# IDLE_SECONDS (default 120) sets how long the idle phase is.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-build/Claude Profiles.app/Contents/MacOS/ClaudeProfiles}"
IDLE_SECONDS="${IDLE_SECONDS:-120}"
REFRESH=30
[[ -x "$BIN" ]] || { echo "No app at $BIN: run ./build.sh first" >&2; exit 2; }

"$BIN" -energyTest YES -autoSwitchEnabled NO -refreshInterval $REFRESH >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT INT TERM
COUNTERS="${TMPDIR:-/tmp/}claude-profiles-counters-$PID.txt"
FAILED=0

send() {  # a test command to this copy only
  osascript -l JavaScript -e "ObjC.import('Foundation');
    $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
      'com.kevinabouhanna.ClaudeProfiles.test.$PID', '$1', \$(), true)" >/dev/null
  sleep 0.3
}
cpu() {  # CPU seconds used so far, from ps's [[h:]m:]s.ss
  ps -o time= -p $PID | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}
rss_mb() { ps -o rss= -p $PID | awk '{ printf "%d", $1 / 1024 }'; }
counter() { send counters; sed -nE "s/.*$1=([^ ]+).*/\1/p" "$COUNTERS"; }
alive() { kill -0 $PID 2>/dev/null || { echo "FAIL  the app quit or crashed" >&2; exit 1; }; }
pct() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { printf "%.2f", (b - a) / t * 100 }'; }
check() {  # name, value, limit, unit
  if awk -v v="$2" -v l="$3" 'BEGIN { exit !(v <= l) }'; then
    printf "ok    %-36s %8s %s (limit %s)\n" "$1" "$2" "$4" "$3"
  else
    printf "FAIL  %-36s %8s %s (limit %s)\n" "$1" "$2" "$4" "$3"; FAILED=1
  fi
}

echo "Energy test: pid $PID, idle ${IDLE_SECONDS}s, refresh every ${REFRESH}s"
sleep 12; alive   # launch and first refresh

# The things that have looped or leaked before.
for step in popover appearance-dark appearance-light appearance-system close settings close; do
  send $step; sleep 2
done
alive

send popover; sleep 2
a=$(cpu); sleep 20; b=$(cpu)
check "dropdown open, 20 s" "$(pct $a $b 20)" 3 "% CPU"
send close; sleep 3; alive

redraws0=$(counter redraws); refreshes0=$(counter refreshes); rss0=$(rss_mb)
start=$(cpu); worst=0; t=0
while (( t < IDLE_SECONDS )); do
  a=$(cpu); sleep 10; b=$(cpu); alive
  worst=$(awk -v w="$worst" -v p="$(pct $a $b 10)" 'BEGIN { print (p > w ? p : w) }')
  t=$(( t + 10 ))
done
end=$(cpu)
redraws=$(( $(counter redraws) - redraws0 )); refreshes=$(( $(counter refreshes) - refreshes0 ))

check "idle, worst 10 s window" "$worst" 5 "% CPU"
check "idle, overall" "$(pct $start $end $IDLE_SECONDS)" 1 "% CPU"
check "redraws while idle" "$redraws" "$(( refreshes + 2 ))" "redraws"
check "memory growth while idle" "$(( $(rss_mb) - rss0 ))" 30 "MB"
check "child processes left running" "$(pgrep -P $PID | wc -l | tr -d ' ')" 0 "processes"
check "energy guard tripped" "$([[ $(counter throttled) == true ]] && echo 1 || echo 0)" 0 ""

echo "(refreshes while idle: $refreshes, peak CPU the app saw itself: $(counter peakCPU)%)"
(( FAILED == 0 )) && echo "PASSED" || { echo "FAILED"; exit 1; }
