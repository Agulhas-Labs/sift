#!/bin/sh
# Writes the GitHub release notes for a version from its CHANGELOG.md section, checks them with the
# privacy gate, and prints the command that publishes the release.
#
# Usage:  sh Distribution/release-notes.sh [--version X.Y.Z] [output-file]
#
# The version defaults to the first numbered `## X.Y.Z` heading in CHANGELOG.md, read as
# cut-public-repo.sh reads it, so the notes and the tag name the same release. The output file defaults
# to `.build/release-notes-<version>.md`.
#
# The notes are the section without its heading, then the install line. GitHub renders a newline inside
# a bullet as a line break, so each bullet's hard-wrapped continuation lines (indented two spaces) are
# joined onto it.
#
# Exit:  0  the notes are written and verify-private.sh passed on them
#        1  the usage is wrong, the version has no section, or the privacy gate failed (no notes are left)
#
# This script builds no tarball and publishes nothing; the last lines it prints are the command to run
# once the tarball from make-dist.sh exists and the tag is pushed.
set -eu

USAGE="usage: sh Distribution/release-notes.sh [--version X.Y.Z] [output-file]"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
OUT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || { echo "$USAGE"; exit 1; }
            VERSION="$2"
            shift 2
            ;;
        -*)
            echo "$USAGE"
            exit 1
            ;;
        *)
            [ -z "$OUT" ] || { echo "$USAGE"; exit 1; }
            OUT="$1"
            shift
            ;;
    esac
done

CHANGELOG="$REPO/CHANGELOG.md"
[ -f "$CHANGELOG" ] || { echo "release-notes: no CHANGELOG.md in $REPO"; exit 1; }
[ -n "$VERSION" ] || VERSION="$(sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' "$CHANGELOG" | head -1)"
[ -n "$VERSION" ] || { echo "release-notes: CHANGELOG.md has no numbered version heading"; exit 1; }
[ -n "$OUT" ] || OUT="$REPO/.build/release-notes-$VERSION.md"

# The heading is matched whole, so `0.1` does not select `## 0.1.1`.
SECTION="$(awk -v heading="## $VERSION" '
    $0 == heading || index($0, heading " ") == 1 { inside = 1; next }
    inside && /^## / { exit }
    !inside { next }
    started == 0 && $0 == "" { next }
    { started = 1 }
    /^  / && n > 0 { sub(/^ +/, ""); lines[n] = lines[n] " " $0; next }
    { lines[++n] = $0 }
    END { for (i = 1; i <= n; i++) print lines[i] }
' "$CHANGELOG")"
[ -n "$SECTION" ] || { echo "release-notes: CHANGELOG.md has no section for $VERSION"; exit 1; }

mkdir -p "$(dirname "$OUT")"
{
    printf '%s\n' "$SECTION"
    echo
    echo 'Install: `brew install agulhas-labs/tap/sift`, `npm install -g @agulhas-labs/sift`, or download the tarball below, unpack it and run `sh sift-dist/install.sh`. Apple Silicon only.'
} > "$OUT"

if ! sh "$REPO/Distribution/verify-private.sh" "$OUT"; then
    rm -f "$OUT"
    echo "release-notes: the privacy gate did not pass over the notes for $VERSION"
    exit 1
fi

echo "release-notes: $OUT"
echo
echo "To publish the release, once the tag is pushed and make-dist.sh has built the tarball:"
echo "    gh release create v$VERSION -R Agulhas-Labs/sift --verify-tag --title \"Sift $VERSION\" --notes-file $OUT <tarball from make-dist.sh>"
