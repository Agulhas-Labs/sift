#!/bin/sh
# Builds the release bundle: the binary, the installer and the shipped documents, tarred. This is the
# artifact a release publishes — `Distribution/homebrew/build.sh` checksums it, and it is what anyone
# installing without a package manager downloads and unpacks. The same bundle is unpacked beside the
# tarball as `sift-dist/`, and the last line printed is the command that installs it on this machine.
#
# Usage:  sh Distribution/make-dist.sh [output-directory]     (default: .build/bundle)
#
# ARM64 ONLY, deliberately. Every Mac this ships to is Apple Silicon, and a universal
# `--arch arm64 --arch x86_64` build doubles the download for a slice that will never execute.
# Add the second arch back only if an Intel Mac genuinely enters the picture.
set -eu

# `-P` resolves symlinks. It does NOT canonicalise case: under /bin/sh this still reports the spelling
# the caller arrived through, and a case-insensitive filesystem answers to every casing of it. So this
# alone cannot make the prefix map below match — SCRATCH is what does that.
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
# Inside the repository, and NOT `.build/dist` — that name is already the SwiftPM scratch path below,
# and a tarball parked in it is deleted by the next `swift package clean`.
OUT_DIR="${1:-$REPO/.build/bundle}"
# Made absolute against the caller's directory before the `cd` below, which would otherwise re-anchor a
# relative argument on the repository and put the bundle somewhere the caller never named.
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
STAGE="$(mktemp -d)/sift-dist"

cd "$REPO"

echo "==== Building release (arm64) ===="
# -ffile-prefix-map keeps the builder's home directory out of the C/C++ assertion strings the
# dependencies compile in. Distribution/verify-private.sh is the gate that proves it took.
REMAP="-Xcc -ffile-prefix-map=$REPO=/sift"
# A scratch directory of its own, and this is what makes the map above take.
#
# Two things it settles, either of which leaves a binary carrying the builder's home directory. The
# ordinary `.build` is shared with every unmapped `swift build` anyone runs, and for a C dependency
# the last compile wins — one plain `swift build -c release` leaves objects holding real paths, and a
# mapped build afterwards reuses them untouched and links them in. And the checkouts under a default
# `.build` are reached by a path SwiftPM resolved for itself, which need not be spelled the way $REPO
# is here; a prefix that matches nothing is not an error, it maps nothing.
#
# Naming the scratch path settles both: the map and the checkouts it has to reach now derive from this
# one string, so however it is spelled they agree. It stays inside the repository for exactly that
# reason — moved outside, the checkouts would sit beyond $REPO and the map would reach nothing again.
SCRATCH="$REPO/.build/dist"
# Through `sift run` where an installed sift is on PATH, so a failed build answers with its errors, or a
# compiler crash with its pass and function, rather than a log whose last lines can be one frontend
# command tens of kilobytes long. `sift run` exits with the build's own status, which `set -e` still acts
# on; the whole log is kept under .sift/runs/.
if command -v sift >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    sift run -- swift build -c release --arch arm64 --scratch-path "$SCRATCH" $REMAP
else
    # shellcheck disable=SC2086
    swift build -c release --arch arm64 --scratch-path "$SCRATCH" $REMAP
fi
# shellcheck disable=SC2086
BIN="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" $REMAP --show-bin-path)/sift"
[ -f "$BIN" ] || { echo "error: built binary not found at $BIN"; exit 1; }

VERSION="$("$BIN" --version)"
COMMIT="$(git rev-parse --short HEAD)"
DATE="$(git log -1 --format=%cd --date=short)"
ARCHS="$(lipo -archs "$BIN")"
SWIFT_VERSION="$(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)"
MACOS_VERSION="$(sw_vers -productVersion)"

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: working tree is dirty — the bundle will claim commit $COMMIT but contain uncommitted changes"
fi

echo "==== Staging ===="
mkdir -p "$STAGE"
cp "$BIN" "$STAGE/sift"
cp "$REPO/Distribution/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
cp "$REPO/Sift.md" "$REPO/README.md" "$REPO/CHANGELOG.md" "$STAGE/"
mkdir -p "$STAGE/Docs"
cp "$REPO/Docs/Guide.md" "$STAGE/Docs/Guide.md"
cp "$REPO/LICENSE" "$STAGE/LICENSE.txt"

# Third-party notices are assembled from the resolved checkouts, never hand-maintained: the binary
# statically links these, so redistribution must carry their license texts — and copying from the
# actual checkout means the notices can't drift from what was really linked. The component list comes
# from Package.resolved for the same reason, one level up: a hand-kept list falls behind a new
# transitive dependency in silence, and that dependency then ships without its license.
#
# "The actual checkout" is this build's, under SCRATCH, so it is named rather than left to the
# generator's default: `.build/checkouts`, which a build with a scratch path of its own never fills. On a
# fresh clone that does not exist, and where an earlier unscoped build left one it holds that build's
# resolution — notices read from a checkout this binary was never linked against.
sh "$REPO/Distribution/third-party-notices.sh" "$REPO" "$SCRATCH/checkouts" > "$STAGE/THIRD-PARTY-NOTICES.txt"

# The provenance line is generated, never hand-maintained: a bundle that misstates which build it
# carries is worse than one that says nothing, and hand-edited version strings always drift.
PROVENANCE="**Build provenance:** \`sift\` $VERSION, commit \`$COMMIT\` ($DATE), built with Apple Swift $SWIFT_VERSION on macOS $MACOS_VERSION. Architecture: \`$ARCHS\` (Apple Silicon only)."
awk -v line="$PROVENANCE" '{ if ($0 == "<!-- PROVENANCE -->") print line; else print }' \
    "$REPO/Distribution/INSTALL.md" > "$STAGE/INSTALL.md"

echo "==== Verifying ===="
# Over the staged bundle rather than the binary alone: the documents ship too, and a worked
# example naming a private repository is the same leak as a path baked into the executable.
sh "$REPO/Distribution/verify-private.sh" "$STAGE"

echo "==== Packaging ===="
TARBALL="$OUT_DIR/sift-$VERSION-$COMMIT-arm64.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$(dirname "$STAGE")" sift-dist
rm -rf "$(dirname "$STAGE")"

# The tarball is the artifact; the folder beside it is what a local deploy installs from, so it is
# replaced with this build every time rather than left from whichever build was unpacked last. What it
# prints is the command that installs it, kept for this script's last line; a failure stops the script.
INSTALL="$(sh "$REPO/Distribution/unpack-bundle.sh" "$TARBALL" "$OUT_DIR")"

# Older bundles go, the newest few kept. Every build left a tarball here and nothing ever took one
# away, so this directory grew by one per merge until somebody noticed twenty of them sitting in it.
# Kept rather than cleared outright because the older ones are what a rollback installs without a
# rebuild; three is the smallest number that leaves somewhere to go back to.
#
# After the unpack, deliberately: a build that fails earlier leaves the last good bundle standing,
# which is the one a rollback would need most. Only the names this script itself writes, only in the
# directory it was given, and never a recursive sweep — the caller may keep its own files beside
# these. Those names carry a version, a commit and an architecture, so none of them can hold a space
# or a newline, which is what makes reading them a line at a time safe.
KEEP_BUNDLES=3
PRUNED=0
for old in $(ls -t "$OUT_DIR"/sift-*-arm64.tar.gz 2>/dev/null | tail -n +$((KEEP_BUNDLES + 1))); do
    rm -f "$old"
    PRUNED=$((PRUNED + 1))
done

echo
echo "$TARBALL"
ls -lh "$TARBALL" | awk '{print "  size: " $5}'
echo "  contents: $(tar -tzf "$TARBALL" | tr '\n' ' ')"
echo "  unpacked: $OUT_DIR/sift-dist"
if [ "$PRUNED" -eq 1 ]; then
    echo "  pruned: 1 older bundle, keeping the newest $KEEP_BUNDLES"
elif [ "$PRUNED" -gt 1 ]; then
    echo "  pruned: $PRUNED older bundles, keeping the newest $KEEP_BUNDLES"
fi
echo
echo "$INSTALL"
