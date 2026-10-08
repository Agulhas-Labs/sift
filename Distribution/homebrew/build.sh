#!/bin/sh
# Fills the tap formula in from a release tarball.
#
# Usage:  sh Distribution/homebrew/build.sh <tarball> [output-file]
#
# The tarball is the one `make-dist.sh` produced and the release published — the checksum has to be
# of the bytes people will actually download, so this reads the artifact rather than rebuilding one
# that would differ. Copy the result into the tap repository (Agulhas-Labs/homebrew-tap, Formula/).
#
# Where `brew` is installed it then runs `brew audit --strict` on the result, as a formula in a
# throwaway local tap that is untapped again on the way out. That is the check the tap's own CI
# applies, and nothing weaker stands in for it: `brew style` on a loose file misses offences such as
# a redundant `version` line, and `brew audit` refuses a path. Without brew the audit is skipped.
set -eu

TARBALL="${1:-}"
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || { echo "usage: sh Distribution/homebrew/build.sh <tarball> [output-file]"; exit 1; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${2:-$REPO/.build/homebrew/sift.rb}"

# The version is the binary's own, read out of the tarball rather than parsed from its name: a
# misnamed artifact would otherwise publish a formula claiming a version nothing in it reports.
STAGE="$(mktemp -d)"
tar -xzf "$TARBALL" -C "$STAGE"
BIN="$(find "$STAGE" -maxdepth 2 -type f -name sift -perm -u+x | head -1)"
[ -n "$BIN" ] || { echo "error: no sift binary inside $TARBALL"; rm -rf "$STAGE"; exit 1; }
VERSION="$("$BIN" --version)"
rm -rf "$STAGE"

SHA256="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"

# The release asset keeps the name the bundle was cut under, public-commit or source-tree stamp and all — so the formula
# points at the bytes this checksum is of, rather than at a name someone has to remember to rename to.
URL="${SIFT_RELEASE_URL:-https://github.com/Agulhas-Labs/sift/releases/download/v$VERSION/$(basename "$TARBALL")}"

mkdir -p "$(dirname "$OUT")"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$SHA256/g" -e "s|@URL@|$URL|g" "$REPO/Distribution/homebrew/sift.rb" > "$OUT"

grep -q '@VERSION@\|@SHA256@\|@URL@' "$OUT" && { echo "error: placeholders left in $OUT"; exit 1; }

# The formula is committed to a public tap, and SIFT_RELEASE_URL puts an unchecked string into it.
sh "$REPO/Distribution/verify-private.sh" "$OUT"

# `brew audit` takes a formula name, not a path, so the formula has to sit in a tap to be audited.
# The tap is named for this process so a parallel run cannot untap another's, and the trap removes
# only that exact name, whether the audit passes, fails or is interrupted.
if command -v brew >/dev/null 2>&1; then
    AUDIT_TAP="siftcheck/audit$$"
    AUDIT_LOG="$(mktemp)"
    trap 'brew untap "$AUDIT_TAP" >/dev/null 2>&1 || true; rm -f "$AUDIT_LOG"' EXIT
    trap 'exit 1' INT TERM
    brew tap-new --no-git "$AUDIT_TAP" >/dev/null
    AUDIT_DIR="$(brew --repository "$AUDIT_TAP")/Formula"
    mkdir -p "$AUDIT_DIR"
    cp "$OUT" "$AUDIT_DIR/sift.rb"
    if HOMEBREW_NO_AUTO_UPDATE=1 brew audit --strict "$AUDIT_TAP/sift" >"$AUDIT_LOG" 2>&1; then
        echo "brew audit --strict: clean"
    else
        cat "$AUDIT_LOG"
        echo "error: brew audit --strict found offences in $OUT"
        exit 1
    fi
else
    echo "brew audit --strict: skipped, brew is not installed"
fi

echo "$OUT"
echo "  version: $VERSION"
echo "  sha256:  $SHA256"
echo "  url:     $URL"
