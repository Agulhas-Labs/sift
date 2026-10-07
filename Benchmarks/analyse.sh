#!/bin/sh
# Prints the paired table for one results session (Benchmarks/results/<session>/) as Markdown, and
# writes it beside the results as table.md.
#
# Usage:  sh Benchmarks/analyse.sh [session]       the latest session when none is named
#         sh Benchmarks/analyse.sh --reparse <session>
#                                                   recompute tokens and validity from the kept streams
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "--reparse" ]; then
    shift
    exec /usr/bin/python3 "$HERE/bench.py" reparse "$@"
fi
exec /usr/bin/python3 "$HERE/bench.py" analyse "$@"
