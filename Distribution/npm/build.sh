#!/bin/sh
# Stages the two npm packages that carry sift, ready to publish.
#
# Usage:  sh Distribution/npm/build.sh [output-directory]     (default: .build/npm)
#
# Two packages, deliberately, and not a postinstall download: the binary lives in a per-platform
# package (`os`/`cpu` declared) that the launcher package takes as an OPTIONAL dependency, so npm
# installs the one that can run on this machine and quietly skips it everywhere else. A postinstall
# script would be the other way to ship a binary, and it is the one that breaks — postinstall is
# disabled outright in many setups, and behind a proxying registry the download it wants is the one
# thing that cannot be mirrored.
set -eu

# `-P` resolves symlinks. It does NOT canonicalise case: under /bin/sh this still reports the spelling
# the caller arrived through. SCRATCH below is what makes the prefix map match.
REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT_DIR="${1:-$REPO/.build/npm}"

cd "$REPO"

echo "==== Building release (arm64) ===="
# -ffile-prefix-map keeps the builder's home directory out of the C/C++ assertion strings the
# dependencies compile in. Distribution/verify-private.sh is the gate that proves it took.
REMAP="-Xcc -ffile-prefix-map=$REPO=/sift"
# A scratch directory of its own — the same one `make-dist.sh` builds into, for the reason set out
# there: it is what makes the map above take, by deriving the checkouts and the map's prefix from one
# string rather than leaving SwiftPM to resolve a path of its own that may be spelled differently. It
# stays inside the repository so the map still reaches what is under it.
SCRATCH="$REPO/.build/dist"
# shellcheck disable=SC2086
swift build -c release --arch arm64 --scratch-path "$SCRATCH" $REMAP
# shellcheck disable=SC2086
BIN="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" $REMAP --show-bin-path)/sift"
[ -f "$BIN" ] || { echo "error: built binary not found at $BIN"; exit 1; }
VERSION="$("$BIN" --version)"

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: working tree is dirty — publishing this would ship a build no commit describes"
fi

echo "==== Staging $VERSION ===="
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/sift/bin" "$OUT_DIR/sift-darwin-arm64/bin"
# Absolute from here on. The staging layout is wired together with a symlink whose target is written
# verbatim and resolved against the LINK's directory, so a relative output directory — which the usage
# line above invites — would produce a dangling link and fail the smoke test complaining about an npm
# flag nobody passed.
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

# The version is written in one place — the binary — and substituted into both manifests, including
# the launcher's dependency on the platform package. A launcher resolving any version but its own
# would pair a new wrapper with an old binary, which is the one combination nobody tests.
for PACKAGE in sift sift-darwin-arm64; do
    sed "s/@VERSION@/$VERSION/g" "$REPO/Distribution/npm/$PACKAGE/package.json" > "$OUT_DIR/$PACKAGE/package.json"
    cp "$REPO/LICENSE" "$OUT_DIR/$PACKAGE/LICENSE.txt"
done

cp "$REPO/Distribution/npm/sift/bin/sift.js" "$OUT_DIR/sift/bin/sift.js"
chmod +x "$OUT_DIR/sift/bin/sift.js"
cp "$REPO/Distribution/npm/sift/README.md" "$OUT_DIR/sift/README.md"
cp "$REPO/CHANGELOG.md" "$OUT_DIR/sift/CHANGELOG.md"
cp "$BIN" "$OUT_DIR/sift-darwin-arm64/bin/sift"
chmod +x "$OUT_DIR/sift-darwin-arm64/bin/sift"
# From this build's checkouts, under SCRATCH, for the reason `make-dist.sh` gives: the generator's
# default is the plain `.build/checkouts`, which a build with a scratch path of its own never fills.
sh "$REPO/Distribution/third-party-notices.sh" "$REPO" "$SCRATCH/checkouts" > "$OUT_DIR/sift-darwin-arm64/THIRD-PARTY-NOTICES.txt"

# The launcher finds the binary through node's own resolution, so the smoke test has to be run the
# way npm arranges it — the platform package inside the launcher's node_modules — or it proves
# nothing about the thing being published.
mkdir -p "$OUT_DIR/sift/node_modules/@agulhas-labs"
ln -sf "$OUT_DIR/sift-darwin-arm64" "$OUT_DIR/sift/node_modules/@agulhas-labs/sift-darwin-arm64"

echo "==== Verifying ===="
sh "$REPO/Distribution/verify-private.sh" "$OUT_DIR/sift" "$OUT_DIR/sift-darwin-arm64"

echo "==== Smoke test ===="
command -v node >/dev/null 2>&1 || { echo "error: node not on PATH — cannot verify the launcher"; exit 1; }
LAUNCHED="$(node "$OUT_DIR/sift/bin/sift.js" --version)"
[ "$LAUNCHED" = "$VERSION" ] || {
    echo "error: the launcher printed '$LAUNCHED' where the binary reports '$VERSION'"
    exit 1
}

# The mode this package exists for is `mcp`, and the way a launcher breaks it is by writing a line of
# its own to stdout — which no `--version` check would ever notice. So the test is a real handshake:
# one JSON-RPC request in, and the first line out has to parse as the response to it.
REQUEST='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"build-smoke","version":"0"}}}'
RESPONSE="$(printf '%s\n' "$REQUEST" | node "$OUT_DIR/sift/bin/sift.js" mcp 2>/dev/null | head -1)"
echo "$RESPONSE" | grep -q '"id":1' || {
    echo "error: no JSON-RPC response through the launcher — got: $RESPONSE"
    exit 1
}
echo "$RESPONSE" | grep -q "\"version\":\"$VERSION\"" || {
    echo "error: the server answered as a different build than the one staged — got: $RESPONSE"
    exit 1
}
echo "launcher runs $LAUNCHED, and its stdout carries the JSON-RPC answer and nothing else"

# The staging directory is not what anyone installs, and a check that only ever runs there cannot see
# what packing and unpacking do — an executable bit that does not survive the tarball, a `files` list
# that omits the binary, a `bin` entry npm does not link. So the same handshake runs again through a
# real install of the real tarballs. `--no-optional` keeps npm from reaching for a platform package
# that is not published yet; both are installed explicitly, which is where node resolution finds them.
echo "==== Install test ===="
PLATFORM_TARBALL="$(cd "$OUT_DIR/sift-darwin-arm64" && npm pack --silent)"
LAUNCHER_TARBALL="$(cd "$OUT_DIR/sift" && npm pack --silent)"
INSTALL_DIR="$OUT_DIR/install-test"
mkdir -p "$INSTALL_DIR"
(
    cd "$INSTALL_DIR"
    npm init -y >/dev/null 2>&1
    npm install --no-optional --no-audit --no-fund --silent \
        "$OUT_DIR/sift-darwin-arm64/$PLATFORM_TARBALL" "$OUT_DIR/sift/$LAUNCHER_TARBALL" >/dev/null
)
INSTALLED="$INSTALL_DIR/node_modules/.bin/sift"
[ -x "$INSTALLED" ] || { echo "error: npm did not link an executable at $INSTALLED"; exit 1; }
RESPONSE="$(printf '%s\n' "$REQUEST" | "$INSTALLED" mcp 2>/dev/null | head -1)"
echo "$RESPONSE" | grep -q "\"version\":\"$VERSION\"" || {
    echo "error: the installed package did not answer the handshake — got: $RESPONSE"
    exit 1
}
echo "installed from the packed tarballs and answered: $VERSION"

echo
echo "staged: $OUT_DIR"
echo "  publish:  (cd $OUT_DIR/sift-darwin-arm64 && npm publish --access public)"
echo "            (cd $OUT_DIR/sift && npm publish --access public)"
echo "  the platform package MUST go first — the launcher's optional dependency on it resolves at install."
