#!/bin/sh
# Runs the paired benchmark (Benchmarks/README.md): every task, or each --task named, in both arms,
# --repeats times, then prints the paired table. Results go to Benchmarks/results/<session>/.
#
# Usage:  sh Benchmarks/run.sh [--task <id>]... [--repeats N] [--session NAME] [--effort LEVEL]
#                              [--timeout SECONDS] [--budget USD] [--sift PATH] [--claude PATH]
#                              [--rule-b PATH] [--rule-a PATH | --mod-b DIR [--mod-env NAME=VALUE]...]
#        --rule-a runs arm A with sift too, under that rule file, so the table is rule A against rule B.
#        --mod-b runs both arms with sift and loads that Claude Code plugin in arm B only: mod against none.
#        --mod-env sets a variable in arm B's environment only (SIFT_MOD_BASH=on, say).
#
# Exit:  0  every run finished (an invalid or failed run is a result, not an error)
#        3  the harness stopped: the corpus would not build, an injection did not match once, claude is
#           not logged in, arm B's hook did not answer a whole-file Read in place, or a run for this
#           checkout is already in progress
#
# Everything a run writes outside the results lives under .build/bench, under this checkout's directory
# in ~/Library/Caches/sift-bench-run/ (the corpus, kept out of any build directory so sift's hook reads
# it), or in Claude Code's state for the run path; all three are deleted when this script exits, however
# it exits. It refuses to start while either directory exists, since the run path is fixed per checkout
# and two runners would share it.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
paths="$(/usr/bin/python3 "$HERE/bench.py" paths)" || exit 3
eval "$paths"

for leftover in "$WORK" "$RUN_HOME"; do
    if [ -e "$leftover" ]; then
        echo "error: $leftover exists: another run is using it, or one was killed; remove it by hand" >&2
        exit 3
    fi
done
child=
trap 'rm -rf "$WORK" "$RUN_HOME" "$PROJECT_STATE"' EXIT
# The runner goes in the background so a signal reaches this trap at once, rather than after the run: it is
# forwarded, and the runner unwinds (stopping whatever it started) before the directories go.
trap 'if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null; wait "$child"; fi; exit 130' INT TERM

/usr/bin/python3 "$HERE/bench.py" run "$@" &
child=$!
wait "$child"
status=$?
child=
exit $status
