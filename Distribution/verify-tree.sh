#!/bin/sh
# Runs the privacy gate over the working tree — every file git tracks, plus every file it neither tracks
# nor ignores. Called by `githooks/pre-push`; run it by hand before publishing or cutting a bundle.
#
# **A file nobody has committed yet is inside this gate, deliberately.** From `git ls-files` alone the
# gate would be blind rather than strict: a scratch file in the repository root naming a sibling project
# — the exact class of leak this exists to catch — would clear it, exit 0, for as long as nobody had run
# `git add`. The rule is general and not scoped to one gate: a file that exists obeys the rules.
# `SiftCoreTests`' example-name gate reads the same set for the same reason.
#
# The one way out is the one git already has. `--exclude-standard` drops whatever `.gitignore` covers, so
# `.build/`, `.sift/` and `.claude/` stay outside — a file leaves this gate by being ignored on purpose,
# never by being merely new. What `--deleted` names comes out too: the index still carries paths the
# working tree no longer holds, and what this reads is the working tree.
#
# **What a clean verdict here covers, and what it does not.** It covers the tree as it stands, which is
# what a public repository serves at its tip. It does not read history: a private name that was
# committed and later taken back out is still in the object database, and `git show` still hands it to
# anyone who clones. So this is a statement about the tip, and it is a statement about the published
# artifact only on the premise that the public repository is cut fresh with no history carried over —
# a premise nothing in this file can check.
#
# Usage:  sh Distribution/verify-tree.sh
#
# Exit:  0  the tree names nothing private
#        1  something in it does — the offending file and needle are printed above — or the gate could
#           not work out which checkout the neighbours belong to, which is a refusal and not a pass
#        2  no sibling projects beside the checkout, so the gate had nothing to look for and refused
#
# The difference between the two nonzero codes is what the answer is *about*. A 1 is about this
# checkout: either a name in it, or a question about it the gate could not answer. A 2 is about the
# machine — it holds no other projects to learn names from — and only a 2 is something a push may
# continue past.
#
# Why this exists at all: the two gates know different things. The Swift suite runs on every push and
# discovers no private *names* — it checks the generic terms and the builder's identity, and a sibling
# project's name is neither. `verify-private.sh` is the only check that discovers names, and
# `make-dist.sh`, `npm/build.sh` and `homebrew/build.sh` run it over a staged bundle — a few documents
# and a binary. A test fixture deep in `Tests/` naming a sibling project in the spelling prose uses is in
# neither, so the whole tree needs a gate of its own, and this is it.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

TRACKED="$(mktemp)"
OTHERS="$(mktemp)"
GONE="$(mktemp)"
UNION="$(mktemp)"
LIST="$(mktemp)"
trap 'rm -f "$TRACKED" "$OTHERS" "$GONE" "$UNION" "$LIST"' EXIT

# Three listings rather than one, each its own simple command: a pipeline's exit status is its last
# stage's, so `git ls-files | sort` would swallow a git that failed and hand the walk an empty list —
# and an empty list is the one input this gate cannot tell from a clean tree.
git ls-files > "$TRACKED"
git ls-files --others --exclude-standard > "$OTHERS"
git ls-files --deleted > "$GONE"

# Asserted of the *tracked* listing specifically. A checkout with an empty index is not a repository
# this should be reading, and asserting it of the union instead would let a directory holding nothing
# but untracked files answer for one.
[ -s "$TRACKED" ] || { echo "error: git ls-files reported no tracked files under $REPO"; exit 1; }

# The union, sorted so the walk is reproducible and de-duplicated so an unmerged path — which the index
# lists once per stage — is scanned once. `LC_ALL=C` because `comm` below compares against another sort
# and the two have to agree on collation; a locale that sorts `a` beside `A` would drop the wrong lines.
LC_ALL=C sort -u "$TRACKED" "$OTHERS" -o "$UNION"
LC_ALL=C sort -u "$GONE" -o "$GONE"
comm -23 "$UNION" "$GONE" > "$LIST"

# `git ls-files` quotes a path holding a newline, a control character or a byte outside ASCII — the
# default `core.quotePath` — and a quoted path is not the path: the gate would die on `stat` partway
# through the tree, leaving a nonzero exit that reads like a finding. If one appears, this says so
# rather than half-checking the tree.
#
# **`-z` is the safe form for this in Swift and not in `/bin/sh`, which is why the refusal is here
# instead.** NUL-separated output is what stops a path being mistaken for two, but POSIX `read` has no
# delimiter option and `$( )` strips the NUL byte, so a `-z` listing is one this shell cannot walk. What makes
# reading line-wise safe is exactly this check: git quotes precisely the paths that would break it, and
# a path holding a *space* — the one that breaks an unquoted `$(git ls-files)` — is not quoted and
# survives `IFS= read -r` whole. Untracked exactly as tracked: a newline and an accented letter come back
# quoted, one line each, and a space comes back bare.
#
# Read over the union, so the listing that arrived without being staged is held to it too.
if grep -q '^"' "$LIST"; then
    echo "error: a path in the tree is quoted by git ls-files — it holds a character this cannot pass through"
    grep '^"' "$LIST" | sed 's/^/    /'
    exit 1
fi

# Built as positional parameters rather than piped through `xargs`, for the exit code: `xargs` reports
# 123 for anything its child exits 1..125 with, which would fold the gate's "nothing to look for"
# refusal (2) into its "found something" verdict (1) — and those two are the whole reason a hook can
# run this. Reading the list from a file rather than a pipe keeps the loop out of a subshell, and
# quoting each path keeps one holding a space in one piece.
set --
while IFS= read -r PATH_IN_TREE; do
    set -- ${1+"$@"} "$PATH_IN_TREE"
done < "$LIST"

# The trap above covers the exits before this point and nothing after it: `exec` replaces this process
# image, so an EXIT trap set here never runs and the files would be left behind once per push. The
# paths are in `$@` by now and nothing reads the files again, so they go here rather than being handed to
# a trap that will not fire. Every one of the five, not only the last:
# `theGateRemovesEveryTemporaryFileItMade` counts what a run made against what it left.
rm -f "$TRACKED" "$OTHERS" "$GONE" "$UNION" "$LIST"
trap - EXIT

exec sh "$REPO/Distribution/verify-private.sh" "$@"
