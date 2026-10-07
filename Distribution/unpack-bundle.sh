#!/bin/sh
# Unpacks a bundle beside its tarball, replacing whatever an earlier extraction left there, so that
# `<output-directory>/sift-dist/install.sh` is always the installer of the build just made. The last line
# printed is the command that runs it: quoted, and by absolute path, so it can be pasted from anywhere.
#
# Usage:  sh Distribution/unpack-bundle.sh <tarball> <output-directory>
#
# The old folder is removed rather than extracted over. Its installer is what a local deploy runs, and
# a stale one copies the stale binary beside it and reports success — the machine keeps the previous
# build with nothing to say so. Removing it also drops any file the new bundle no longer carries.
set -eu

USAGE="usage: unpack-bundle.sh <tarball> <output-directory>"
# `:?` refuses an empty argument as well as a missing one, so `rm -rf` below never reaches `/sift-dist`.
TARBALL="${1:?$USAGE}"
OUT_DIR="${2:?$USAGE}"

[ -d "$OUT_DIR" ] || { echo "error: $OUT_DIR is not a directory" >&2; exit 1; }
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

rm -rf "$OUT_DIR/sift-dist"
tar -xzf "$TARBALL" -C "$OUT_DIR"
INSTALLER="$OUT_DIR/sift-dist/install.sh"
[ -x "$INSTALLER" ] || { echo "error: $TARBALL did not unpack to sift-dist/install.sh" >&2; exit 1; }

# Single-quoted for the shell, with any single quote in the path closed, escaped and reopened.
printf "sh '%s'\n" "$(printf '%s' "$INSTALLER" | sed "s/'/'\\\\''/g")"
