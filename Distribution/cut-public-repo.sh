#!/bin/sh
# Cuts the public repository: a new git repository whose one commit is the tree at one commit of this
# one. Nothing else crosses — no history, no objects, no reflog, no identity but the one named here.
#
# Usage:  sh Distribution/cut-public-repo.sh [--at <rev>] [--author "Name <email>"] [--message <text>] <target-dir>
#
# The target is new (absent, or an empty directory: it is created and given its first commit), or an
# earlier cut not yet published — one commit, no remote, a clean tree — whose commit is amended to the
# new tree and whose superseded objects are pruned, so a fix after review still lands as one commit.
# Anything else is refused and left as it was; this never deletes a target.
#
# The tree comes from `git archive`: what <rev> tracks, less `export-ignore`. Before the target is
# touched, `verify-tree.sh` runs in a detached worktree at <rev> — linked to this repository, so it learns
# the neighbours' names from the primary checkout — and every exported file must be byte-identical to the
# one it read. The export must not name the private repository or its folder either. Author and committer
# are set here over anything the caller's environment or config says, with no hooks and no signing.
#
# Exit:  0  cut, verified, and the next commands printed — nothing is pushed and no remote is added
#        1  refused, or the finished commit failed a check (named above)
#        2  usage
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
REV=HEAD
AUTHOR="Agulhas Labs <developer@agulhaslabs.dev>"
MESSAGE=""
TARGET=""

usage() {
    echo "usage: sh Distribution/cut-public-repo.sh [--at <rev>] [--author \"Name <email>\"] [--message <text>] <target-dir>"
    exit 2
}
refuse() {
    echo "refused: $*"
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --at) [ "$#" -ge 2 ] || usage; REV="$2"; shift 2 ;;
        --author) [ "$#" -ge 2 ] || usage; AUTHOR="$2"; shift 2 ;;
        --message) [ "$#" -ge 2 ] || usage; MESSAGE="$2"; shift 2 ;;
        -*) usage ;;
        *) [ -z "$TARGET" ] || usage; TARGET="$1"; shift ;;
    esac
done
[ -n "$TARGET" ] || usage
case "$AUTHOR" in
    ?*" <"?*@?*">") ;;
    *) echo "error: --author must read \"Name <email>\""; exit 2 ;;
esac
NAME="${AUTHOR% <*}"
EMAIL="${AUTHOR##*<}"
EMAIL="${EMAIL%>}"
case "$TARGET" in
    /*) ;;
    *) TARGET="$PWD/$TARGET" ;;
esac

# The identity every commit here carries, set in the environment because the environment outranks both
# the caller's config and `-c`. Anything that would point git at another repository, or date the commit
# by the caller's clock rather than now, is cleared for the same reason: it arrives from outside.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_COMMON_DIR GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_AUTHOR_DATE GIT_COMMITTER_DATE
GIT_AUTHOR_NAME="$NAME"
GIT_AUTHOR_EMAIL="$EMAIL"
GIT_COMMITTER_NAME="$NAME"
GIT_COMMITTER_EMAIL="$EMAIL"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
# The commit's date carries a zone offset, and the machine's own is a fact about where it was made.
TZ=UTC
export TZ

# Every git call that writes runs with no hooks and no signing: the caller's global hooks are theirs,
# and a signature would carry their key into a repository that is meant to carry nobody's. Nor does the
# target run maintenance of its own: a commit starts `git maintenance run --auto` in the background,
# which packs the superseded cut's objects while it is still reachable, so the prune below leaves them.
src() { git -C "$REPO" -c core.hooksPath=/dev/null "$@"; }
tgt() { git -C "$TARGET" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c maintenance.auto=false -c gc.auto=0 "$@"; }

SHA="$(git -C "$REPO" rev-parse --verify --quiet "$REV^{commit}")" || refuse "$REV is not a commit in $REPO"
if [ -z "$MESSAGE" ]; then
    VERSION="$(git -C "$REPO" show "$SHA:CHANGELOG.md" 2>/dev/null | sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' | head -1)"
    MESSAGE="Sift${VERSION:+ $VERSION}"
fi

# What the target is decides everything after, so it is settled before any work is done.
OLD=""
if [ ! -e "$TARGET" ]; then
    MODE=new
elif [ ! -d "$TARGET" ]; then
    refuse "$TARGET exists and is not a directory"
elif [ -z "$(ls -A "$TARGET")" ]; then
    MODE=new
else
    TARGET="$(cd "$TARGET" && pwd -P)"
    TOP="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || echo "")"
    GITDIR="$(git -C "$TARGET" rev-parse --absolute-git-dir 2>/dev/null || echo "")"
    [ "$TOP" = "$TARGET" ] && [ "$GITDIR" = "$TARGET/.git" ] \
        || refuse "$TARGET is not empty and is not a git repository of its own"
    [ -z "$(git -C "$TARGET" remote)" ] || refuse "$TARGET has a remote — a cut that may be published is never rewritten"
    [ "$(git -C "$TARGET" rev-list --count --all)" = 1 ] || refuse "$TARGET holds more than one commit, so it is not an unpublished cut"
    OLD="$(git -C "$TARGET" rev-parse --verify --quiet HEAD)" || refuse "$TARGET has no commit at HEAD"
    [ -z "$(git -C "$TARGET" status --porcelain --untracked-files=all)" ] || refuse "$TARGET has changes of its own"
    # A re-cut deletes the earlier commit beyond recovery, so it is taken only from a commit this script
    # made: a new, unpushed project with one commit in it is otherwise indistinguishable from a cut.
    [ "$(git -C "$TARGET" log -1 --format='%an <%ae>|%cn <%ce>')" = "$NAME <$EMAIL>|$NAME <$EMAIL>" ] \
        || refuse "$TARGET holds a commit not made as $NAME <$EMAIL>, so it is not a cut this script made"
    MODE=recut
fi

SCRATCH="$REPO/.build/cut-public-repo.$$"
GATE="$SCRATCH/gate"
STAGE="$SCRATCH/stage"
TAR="$SCRATCH/tree.tar"
cleanup() {
    if [ -d "$GATE" ]; then
        src worktree remove "$GATE" || { echo "warning: left the gate worktree at $GATE"; return 0; }
    fi
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p "$STAGE"

src archive --format=tar -o "$TAR" "$SHA"
tar -xf "$TAR" -C "$STAGE"
(cd "$STAGE" && find . \( -type f -o -type l \)) > "$SCRATCH/found"
sed 's|^\./||' "$SCRATCH/found" > "$SCRATCH/exported"
[ -s "$SCRATCH/exported" ] || refuse "git archive exported nothing at $SHA"

# The private repository's name and folder, written as patterns so that this file does not match them.
PRIVATE='sift[-]source|swift[i]ndex'
if printf '%s\n' "$MESSAGE" | grep -q -i -E "$PRIVATE"; then
    refuse "the commit message names the private repository"
fi
[ "$MODE" = new ] || git -C "$TARGET" ls-tree -r "$OLD" | cut -f1 | cut -d' ' -f3 | LC_ALL=C sort -u > "$SCRATCH/old-objects"
set +e
grep -r -i -l -E "$PRIVATE" "$STAGE" > "$SCRATCH/named"
IN_TEXT=$?
grep -iE "$PRIVATE" "$SCRATCH/exported" >> "$SCRATCH/named"
IN_PATHS=$?
set -e
[ "$IN_TEXT" -le 1 ] && [ "$IN_PATHS" -le 1 ] || refuse "could not search the export for the private repository's name"
if [ -s "$SCRATCH/named" ]; then
    sed "s|^$STAGE/||; s/^/    /" "$SCRATCH/named"
    refuse "the export names the private repository (listed above)"
fi

# The gate reads a checkout, not a directory, and learns what to look for from the checkout's
# neighbours — so it runs in a worktree of this repository at the commit being cut.
src worktree add --detach --quiet "$GATE" "$SHA"
[ -f "$GATE/Distribution/verify-tree.sh" ] || refuse "$SHA has no Distribution/verify-tree.sh to gate the cut with"
if ! sh "$GATE/Distribution/verify-tree.sh"; then
    PRIMARY="$(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"
    if [ -d "$TARGET" ] && [ "$(dirname "$TARGET")" = "$(dirname "$PRIMARY")" ]; then
        echo "  note: $TARGET sits beside the primary checkout, so the gate reads its name as a private neighbour's"
    fi
    refuse "the privacy gate did not pass over $SHA"
fi
while IFS= read -r FILE; do
    if [ -L "$STAGE/$FILE" ]; then
        [ -L "$GATE/$FILE" ] && [ "$(readlink "$STAGE/$FILE")" = "$(readlink "$GATE/$FILE")" ] \
            || refuse "$FILE as exported is not the file the gate read"
    else
        cmp -s "$STAGE/$FILE" "$GATE/$FILE" || refuse "$FILE as exported is not the file the gate read"
    fi
done < "$SCRATCH/exported"

if [ "$MODE" = new ]; then
    mkdir -p "$TARGET"
    TARGET="$(cd "$TARGET" && pwd -P)"
    # No template: the caller's template directory could otherwise seed hooks or config into the target.
    git init --quiet --template= -b main "$TARGET"
else
    tgt rm -r -q -- .
fi
tar -xf "$TAR" -C "$TARGET"
tgt --literal-pathspecs add -f --pathspec-from-file="$SCRATCH/exported"
if [ "$MODE" = new ]; then
    tgt commit --quiet -m "$MESSAGE"
else
    tgt commit --quiet --amend --reset-author -m "$MESSAGE"
    tgt reflog expire --expire=now --all
    tgt gc --quiet --prune=now
fi
NEW="$(git -C "$TARGET" rev-parse HEAD)"

# The checks the published repository rests on, read back from what was written.
FAILED=0
COUNT="$(git -C "$TARGET" rev-list --count --all)"
[ "$COUNT" = 1 ] || { echo "check failed: $TARGET holds $COUNT commits"; FAILED=1; }
IDS="$(git -C "$TARGET" log --format='%an <%ae>%n%cn <%ce>' | LC_ALL=C sort -u)"
[ "$IDS" = "$NAME <$EMAIL>" ] || { echo "check failed: identities in $TARGET are:"; echo "$IDS"; FAILED=1; }
if [ -n "$OLD" ] && [ "$OLD" != "$NEW" ] && git -C "$TARGET" cat-file -e "$OLD" 2>/dev/null; then
    echo "check failed: the superseded commit $OLD is still in $TARGET"
    FAILED=1
fi
# Not only the commit: every blob and tree the earlier cut held that this one does not must be gone.
if [ -n "$OLD" ]; then
    git -C "$TARGET" ls-tree -r "$NEW" | cut -f1 | cut -d' ' -f3 | LC_ALL=C sort -u > "$SCRATCH/new-objects"
    git -C "$TARGET" rev-parse "$NEW^{tree}" >> "$SCRATCH/new-objects"
    OLD_TREE_LINE="$(git -C "$TARGET" rev-parse "$OLD^{tree}" 2>/dev/null || echo "")"
    { cat "$SCRATCH/old-objects"; [ -z "$OLD_TREE_LINE" ] || echo "$OLD_TREE_LINE"; } | LC_ALL=C sort -u \
        | { grep -vxF -f "$SCRATCH/new-objects" || [ "$?" = 1 ]; } > "$SCRATCH/gone"
    while IFS= read -r OBJECT; do
        if git -C "$TARGET" cat-file -e "$OBJECT" 2>/dev/null; then
            echo "check failed: $OBJECT, which only the superseded cut held, is still in $TARGET"
            FAILED=1
        fi
    done < "$SCRATCH/gone"
fi
# Paths, modes and object ids: a filter or line-ending conversion that `git add` applied would change the
# content under the same names, and only the ids say so.
git -C "$REPO" ls-tree -r --name-only "$SHA" > "$SCRATCH/tree"
git -C "$REPO" check-attr --source="$SHA" --stdin export-ignore < "$SCRATCH/tree" \
    | sed -n 's/: export-ignore: set$//p' > "$SCRATCH/ignored"
git -C "$REPO" ls-tree -r "$SHA" \
    | awk -F'\t' -v ignored="$SCRATCH/ignored" 'BEGIN { while ((getline line < ignored) > 0) skip[line] = 1 } !($2 in skip)' \
    | LC_ALL=C sort > "$SCRATCH/want"
git -C "$TARGET" ls-tree -r "$NEW" | LC_ALL=C sort > "$SCRATCH/got"
cmp -s "$SCRATCH/want" "$SCRATCH/got" || {
    echo "check failed: the files committed are not the files at $SHA:"
    diff "$SCRATCH/want" "$SCRATCH/got" || true
    FAILED=1
}
[ "$FAILED" = 0 ] || exit 1

echo "cut: $TARGET — 1 commit ($NEW, \"$MESSAGE\") of $(wc -l < "$SCRATCH/got" | tr -d ' ') files from $SHA, by $NAME <$EMAIL>"
[ "$MODE" = new ] || echo "  amended the earlier cut $OLD and pruned its objects"
echo
echo "Nothing is pushed. To publish it:"
echo "    gh repo create Agulhas-Labs/sift --public --source \"$TARGET\" --push"
echo "  or, once the repository exists:"
echo "    git -C \"$TARGET\" remote add origin git@github.com:Agulhas-Labs/sift.git && git -C \"$TARGET\" push -u origin main"
echo "Agulhas-Labs/sift is today a rename redirect to the private repository; creating the repository takes the name over."
