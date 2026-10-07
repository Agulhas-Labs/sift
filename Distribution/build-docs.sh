#!/bin/sh
# Builds the DocC catalog, Docs/Sift.docc, into a static site under .build/docs (ignored by version control).
#
# Usage:  sh Distribution/build-docs.sh
#
# No package dependency: this is the toolchain's own `xcrun docc convert`, so Package.swift is untouched.
# A warning fails the build (--warnings-as-errors), so a broken link or a malformed directive cannot ship
# in a green run. The output is built for static hosting with the site at its root; a host that serves it
# below a path needs `--hosting-base-path` added here, which is a hosting decision and not made yet.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$REPO/Docs/Sift.docc"
OUT="$REPO/.build/docs"

[ -d "$CATALOG" ] || { echo "build-docs: no catalog at $CATALOG" >&2; exit 1; }

# Removes only the output directory it is about to fill.
rm -rf "$OUT"
mkdir -p "$OUT"

xcrun docc convert "$CATALOG" \
    --fallback-display-name Sift \
    --fallback-bundle-identifier com.agulhaslabs.sift.docs \
    --transform-for-static-hosting \
    --warnings-as-errors \
    --output-path "$OUT"

echo "build-docs: wrote $OUT"
