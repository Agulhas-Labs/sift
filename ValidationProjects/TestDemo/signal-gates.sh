#!/bin/sh
# Live signal gates for `sift test`: every simulator a run creates must be gone after an interrupt, a kill,
# and a kill of the run AND its watcher (the next run's sweep). Run from the repository root:
#
#     sh ValidationProjects/TestDemo/signal-gates.sh [path/to/sift]      (default: .build/debug/sift)
#
# `sift test` is started DIRECTLY as this shell's background job, so `$!` is sift itself. Started through a
# function, `eval` or `$(…)`, `$!` is a wrapper shell: the signal never reaches sift, the run finishes by
# itself, and the gate "passes" having tested nothing (17 Sep 2026, three times). Each gate prints the
# signalled pid's command line for that reason. Every device here is one `sift test` creates; none is
# created or deleted by this script.
SIFT="${1:-.build/debug/sift}"
P="--project ValidationProjects/TestDemo/TestDemo.xcodeproj --scheme TestDemo"
LOGS="ValidationProjects/TestDemo/.gates-logs"; mkdir -p "$LOGS"
( cd ValidationProjects/TestDemo && xcodegen generate > /dev/null 2>&1 ) || { echo "FAIL generate"; exit 1; }
failed=0
left() { echo "$(xcrun simctl list devices | grep -c 'sift-') devices, $(ls .sift/shards 2>/dev/null | wc -l | tr -d ' ') ledgers, $(ps -ax | grep -c '[g]uard-shards') watchers"; }
settle() { n=0; while [ "$(xcrun simctl list devices | grep -c 'sift-')" != "0" ] && [ $n -lt 40 ]; do sleep 3; n=$((n+1)); done; }
verdict() { if [ "$(left)" = "0 devices, 0 ledgers, 0 watchers" ] && [ "$2" = "$3" ]; then echo "PASS $1 (exit $2)"; else echo "FAIL $1: exit $2 (wanted $3), left: $(left)"; failed=1; fi; }

for spec in "TERM 8 143" "INT 60 130" "INT 95 130" "HUP 45 129" "KILL 95 137"; do
  set -- $spec
  "$SIFT" test $P --device "iPhone 17" --plan Default --shards 3 -- -derivedDataPath ValidationProjects/TestDemo/.derived > "$LOGS/signal-$1-$2.log" 2>&1 &
  pid=$!; sleep "$2"; echo "SIG$1 at $2s -> $pid: $(ps -p $pid -o command= | cut -c1-40)"
  kill "-$1" "$pid"; wait "$pid" 2>/dev/null; code=$?; settle; verdict "SIG$1@$2s" "$code" "$3"
done

"$SIFT" test $P --device "iPhone 17" --plan Default --shards 3 -- -derivedDataPath ValidationProjects/TestDemo/.derived > "$LOGS/signal-both.log" 2>&1 &
pid=$!; sleep 95; watcher="$(ps -ax -o pid,command | grep '[g]uard-shards' | awk '{print $1}' | head -1)"
echo "SIGKILL owner $pid and watcher $watcher"; kill -KILL "$watcher" "$pid"; wait "$pid" 2>/dev/null; sleep 4
# Nothing is left alive to end this run's xcodebuilds, so the script ends them, by pid, before the sweep.
for x in $(ps -ax -o pid,command | grep '[t]est-without-building' | grep "$PWD" | awk '{print $1}'); do kill -TERM "$x"; done; sleep 6
"$SIFT" test $P --device "No Such Device" > "$LOGS/signal-sweep.log" 2>&1
if grep -q "^swept " "$LOGS/signal-sweep.log"; then verdict "sweep-after-owner-and-watcher-killed" 0 0; else echo "FAIL sweep said nothing: $(left)"; failed=1; fi

rm -rf ValidationProjects/TestDemo/.derived
exit $failed
