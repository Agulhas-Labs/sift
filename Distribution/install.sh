#!/bin/sh
# Installs sift on this machine and registers it with Claude Code.
# Safe to re-run: that is the upgrade path.
set -eu

DEST="${SIFT_DEST:-$HOME/.local/bin}"
RULES="$HOME/.claude/rules"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/sift"

[ -f "$SRC" ] || { echo "error: sift not found next to this script"; exit 1; }

mkdir -p "$DEST"

# Strip quarantine if the bundle arrived by download or AirDrop. The binary is
# ad-hoc signed (no Developer ID), so a quarantine flag makes Gatekeeper refuse it.
xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true

# NEVER cp over a running/installed binary in place — macOS caches code signatures by inode, so
# writing new bytes into the old inode gets the process SIGKILLed on launch (exit 137, no error
# message). Copy to a temp name in the same directory (so the final `mv` is same-volume and atomic),
# then rename it over the destination: the rename gives the new binary its own inode, and there is
# never a moment with no binary at all — unlike `rm` then `cp`, which has a window where $DEST/sift
# does not exist. Clean the temp file up if anything below fails.
TMP="$DEST/.sift.$$"
trap 'rm -f "$TMP"' EXIT
cp "$SRC" "$TMP"
chmod +x "$TMP"
mv -f "$TMP" "$DEST/sift"
trap - EXIT

echo "installed: $DEST/sift ($("$DEST/sift" --version))"

case ":$PATH:" in
    *":$DEST:"*) ;;
    *) echo "warning: $DEST is not on PATH — add it to your shell profile" ;;
esac

# Agent guidance as a path-scoped user rule: one install for every repo on this machine, no repo
# commits anything, and the `paths:` frontmatter keeps it out of context unless Swift is in play.
mkdir -p "$RULES"
if [ -L "$RULES/sift.md" ]; then
    # A symlink means this machine has the Sift checkout and the rule IS the repo file.
    # `cp` would follow the link and write *through* it into the working tree — silently reverting
    # a newer checkout to whatever this bundle happens to carry. Leave it; the checkout is the
    # fresher source by construction.
    echo "rule: $RULES/sift.md is a symlink to $(readlink "$RULES/sift.md") — left as is"
else
    cp "$HERE/Sift.md" "$RULES/sift.md"
    echo "rule: $RULES/sift.md (loads on **/*.swift)"
fi

# The SessionStart primer. The rule above cannot arrive in time on its own: `paths: ["**/*.swift"]`
# fires when a Swift file is *touched*, so "reach for a digest instead of reading the file" lands one
# step after the read it was meant to replace. A hook is the only delivery guaranteed to precede the
# model's first turn.
#
# Registered by the binary rather than by this script: settings.json holds the user's whole Claude Code
# configuration, it is shared with hooks this project does not own, and a corrupt write breaks every
# session on the machine. The merge is covered by the test suite and needs no python3/jq on the host.
#
# No allow-rule flag is passed: `install-hook` asks the lookups question (default yes, or no after a
# remembered no) and then the builds question (default no) on the terminal this script was started
# from, and asks nothing, adding nothing, where there is none; its output names `--allow-run` and
# `--allow-lookups` for that case.
"$DEST/sift" install-hook

if command -v claude >/dev/null 2>&1; then
    # `claude mcp add` FAILS when the name is already registered, so an upgrade must remove first.
    # Both removals are unconditional and swallowed: user scope is where this script registers, and
    # the scopeless pass clears a local- or project-scope registration left by an earlier manual
    # `claude mcp add`. Either failing means "wasn't there", which is exactly what we want.
    claude mcp remove sift --scope user >/dev/null 2>&1 || true
    claude mcp remove sift >/dev/null 2>&1 || true

    # --scope MUST come before the `--`, or it is passed through to the binary
    # as an argument instead of being read by claude.
    claude mcp add --transport stdio --scope user sift -- "$DEST/sift" mcp
    echo "mcp: registered at user scope (any previous registration was replaced)"
else
    echo "note: 'claude' not on PATH — register manually with:"
    echo "  claude mcp add --transport stdio --scope user sift -- '$DEST/sift' mcp"
fi

# An older install copied a Claude Code band (the `sift-band` plugin) to ~/.local/share/sift and served it from a local
# marketplace beside it. `install-hook` above has already uninstalled the plugin and that marketplace through
# `claude plugin`; what is left on disk is the folder and the marketplace file this script wrote. The one fixed
# path only, and only where its manifest names the band, so nothing else is ever deleted; the marketplace file
# likewise only where it is the one that named the band.
LEGACY_MOD="$HOME/.local/share/sift/sift-mod"
if [ -f "$LEGACY_MOD/.claude-plugin/plugin.json" ] && grep -q '"name": *"sift-band"' "$LEGACY_MOD/.claude-plugin/plugin.json"; then
    rm -rf "${LEGACY_MOD:?}"
    echo "band: removed $LEGACY_MOD (sift no longer draws a band; run 'sift report' to see what it did)"
fi
LEGACY_MARKET="$(dirname "$LEGACY_MOD")/.claude-plugin/marketplace.json"
if [ -f "$LEGACY_MARKET" ] && grep -q '"sift-band"' "$LEGACY_MARKET"; then
    rm -f "$LEGACY_MARKET"
    rmdir "$(dirname "$LEGACY_MARKET")" 2>/dev/null || true
    echo "band: removed $LEGACY_MARKET"
fi

echo
echo "Next: cd into a Swift repo and run 'sift status'. The first query indexes it."
echo "Start a NEW Claude Code session to pick up the new server and the session primer; running ones keep"
echo "the old process and the old context."
echo "Cursor and Codex: run 'sift install' to set sift up in them as well (it finds each and asks once)."
echo "Read INSTALL.md for configuration and troubleshooting."
