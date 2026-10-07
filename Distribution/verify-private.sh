#!/bin/sh
# Fails when anything about to be distributed names the machine that built it, its owner, or the
# other work on it.
#
# Usage:  sh Distribution/verify-private.sh <path>...     (files or directories)
#         sh Distribution/verify-tree.sh                  (the working tree — what publishing ships)
#
# The tree is a separate entry point rather than a documented `$(git ls-files)`, because an
# unquoted command substitution splits a path containing a space into two paths that do not exist, and
# the run dies on `stat` partway through the tree — leaving a nonzero exit that reads like a finding.
#
# Two lists, and only one of them is written down. The generic terms live in private-terms.txt, which
# is safe to read. The private names are DISCOVERED — the checkout's sibling directories are the other
# projects on this machine, so every one of them is checked without any of them being committed here.
# That is the property that makes this hold up over time: a project created next month is covered by a
# check written today, and the check itself never becomes the leak it exists to prevent.
#
# Binaries are read through `strings`: clang embeds the absolute path of every C/C++ source it
# compiles, so a binary built under $HOME ships the builder's username to anyone who looks.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TERMS="$REPO/Distribution/private-terms.txt"
[ "$#" -gt 0 ] || { echo "usage: sh Distribution/verify-private.sh <path>..."; exit 1; }

# Two classes, matched differently. The generic terms are words, and a term of two words straddles a
# word boundary given the chance — `he cat` sits inside `the cattle` — so they are matched whole. A name
# is the opposite: a project called `Tanager` gives its modules names like `TanagerWidget` and
# `TanagerKit`, and a whole-word match for `Tanager` sails straight past both.
#
# Substring matching buys that, and it buys something unwanted alongside it: a name's letters also turn
# up split across two unrelated words purely by coincidence — a name `Ergo` sits inside `underGoing`,
# four letters case-folded to the same thing. The letters are the same; what differs is where the case
# changes. `ErgoKit` capitalises exactly where `Ergo` does — the match is the name, wearing the name's
# own case — while `underGoing`'s hit lower-cases into an upper case (`r` into `G`) at a position the
# name itself never transitions at all. So a hit is kept only when every position where the matched
# text changes case is a position the name's own spelling calls a **boundary**.
#
# A boundary is not only the lower→upper camel-case hinge. A name that opens with an acronym —
# `HTMLParser` — has no such hinge where the acronym ends: `L` into `P` is upper into upper, not lower
# into upper. A rule that only recognised the camel-case hinge would read that position as one the name
# never transitions at, and would then reject the name's own lower-camel spelling — `htmlParser` really
# does hinge there, lower `l` into upper `P` — losing exactly the spelling the gate exists to catch. So
# a name's boundaries are the same positions `SPACED` below already inserts a space at: a lower/digit-to-
# upper hinge, or an upper-upper-lower acronym hinge (`HTML|Parser`). A hit is rejected only for a case
# change the matched text has that is not one of the name's own boundaries — which keeps `htmlParser`,
# `ErgoKit`, `MyErgo`, every case-flattened spelling, and
# anything ending or starting mid-name, while it still loses the identifiers that manufacture a boundary
# the name doesn't have. See `name_awk` below, whose boundary positions come from `spaced_form` — the
# same pipeline `SPACED` is built from, asked the same question rather than answered twice by two rules
# that could drift apart.
#
# What the filter cannot tell apart, stated rather than implied: a mention that capitalises a letter the
# name's own spelling keeps lower, straight after a lower-case letter, is cleared. A neighbour `Kitewing`
# written `KiteWing` turns from `e` into `W` where the name has no boundary, and a name `Ergo` written
# `ErGO` turns from `r` into `G` — to the filter each is the straddle it exists to reject, a case change
# at a position the name never changes case at, and a name re-cased by hand is not told apart from one
# two words manufacture. The capital has to follow a lower-case letter: after a digit the matched text is
# not held to a boundary, so a neighbour `Kite3wing` written `Kite3Wing` is caught (see `name_awk`). Every
# spelling that flattens the case, and every one that changes case only where the name does, is caught.
#
# A second residual, this one about time rather than what is matched: a line holding many rejected near-
# misses of one needle still costs that line's length times the number of rejected windows on it, since a
# rejection resumes the search over the remainder of the line rather than remembering where it left off —
# see the cost comment in `name_awk` below. A line naming a needle once is read in time linear in its
# length; a line dense with spellings that almost match it is not.
#
# That boundary check only ever makes sense for a needle whose own spelling can carry word boundaries at
# all, and only ever needs to run for one whose letters could plausibly straddle someone else's — so it is
# applied to exactly one shape of needle, decided in `scan` before `name_awk` is ever called: the needle is
# entirely `[A-Za-z0-9]` and carries at least one uppercase letter. Everything else — a needle with a
# space, a hyphen, `@`, `/`, `.`, a backslash, or any non-ASCII byte, and any needle with no uppercase
# letter at all — keeps the base gate's exact behaviour, `grep -iF` and nothing more, the same as the word
# list beside it. A needle outside that shape has no letters that can straddle a camel-case boundary in
# the way this section exists to catch, and matching it byte-for-byte is what the gate did before this
# refinement existed — see `is_identifier_shaped` below.
#
# **Every file is read as bytes, whatever locale the caller runs in.** Under a UTF-8 locale `grep` does
# not match a needle that sits at or after the first byte on its line that is not valid UTF-8 — a
# Latin-1 `é`, a string table that mixes encodings — and says nothing about the line it passed over: a
# name after such a byte clears the gate, and the same file fails it in the C locale. So every pass that decides whether a file
# names something reads in the C locale, where a line is bytes and every line is read. An ASCII needle
# loses nothing there: `grep -i` folds the same ASCII letters in either locale and folds no other
# character onto them. A term's whole-word match reads its word boundaries in that locale too, so a term
# running into an accented letter counts as whole where a UTF-8 reading would have taken the letter as
# part of the word — one more match, never one fewer. A needle carrying a byte outside ASCII is looked
# for under the caller's locale as well, because its case-folding is one only a UTF-8 locale has — `É`
# and `é` are different bytes that are one letter — and a line either reading finds is a line that names
# it. A needle the caller's locale cannot read at all — one holding a byte that is not valid UTF-8, under
# a UTF-8 locale — has the C reading only (see `caller_reads`). What that leaves, stated rather than
# implied: at or after the first invalid byte on a line, such a
# needle is found only as it is spelled, its ASCII letters folded and its accented ones not; and a name is
# looked for as its UTF-8 bytes, so the same name written in another encoding (Latin-1 `É` is the one
# byte `0xC9`) is not found at all.
#
# The rest of the pipeline reads in the C locale too, and there it is not about recall but about the run
# surviving the file. Under a UTF-8 locale BSD `sed` stops on such a line with `illegal byte sequence`
# and `cut` stops at the byte, where `grep` merely looks away. A failing last stage of a pipeline under
# `set -e` ends the run where it stands: every file after the one that tripped it goes unread and
# unreported, behind output that reads as a tool crash, and the temporary files are left behind. So the
# `cut` and the `sed` that show a finding are pinned to C beside the scans, and so is the `sed` that reads
# the `gh` handle below, whose file is anyone's to write. The directory names discovery reads are left in
# the caller's locale: the filesystem refuses a name that is not valid UTF-8, so they hold no such byte
# to stop on.
#
# Neither illustration is quoted from the lists this checks against, and that is deliberate rather than
# stylistic: an example lifted from the terms file would make this file fail its own check, and an
# exemption to repair that would leave everything else written here unread.
WORD_NEEDLES="$(grep -v '^#' "$TERMS" | grep -v '^[[:space:]]*$')"

# Needles are added through this, so every one gets the same guards: nothing empty, nothing shorter
# than four characters — below that a needle matches prose more often than it catches a leak — and no
# duplicates, since a name and one of its spellings frequently coincide (`Tanager` spaced is still
# `Tanager`).
NAME_NEEDLES=""
add_name() {
    [ -n "$1" ] || return 0
    [ "${#1}" -ge 4 ] || return 0
    case "
$NAME_NEEDLES" in
        *"
$1
"*) return 0 ;;
    esac
    NAME_NEEDLES="$NAME_NEEDLES$1
"
}

# The single definition of where a compound name's word boundaries fall, shared by the discovery loop
# below (which needs the spelling out, `TanagerWidget` → `Tanager Widget`) and by `name_awk` far below
# (which needs the positions those spaces mark, to tell a name's own case change from one a match merely
# manufactures). Two substitutions: a lower/digit letter hinging into an upper one (the ordinary
# camel-case boundary), and an upper letter hinging into an upper-then-lower pair (the acronym boundary,
# `HTML|Parser`, where there is no lower-case letter to hinge on at all). Called from both places rather
# than written out twice, so the two cannot quietly stop agreeing with each other.
spaced_form() {
    printf '%s' "$1" | sed -e 's/\([a-z0-9]\)\([A-Z]\)/\1 \2/g' -e 's/\([A-Z]\)\([A-Z][a-z]\)/\1 \2/g'
}

# Whether a needle is the one shape `name_awk`'s straddle filter is safe and meaningful to apply to: every
# byte of it is `[A-Za-z0-9]`, and at least one of those bytes is uppercase. The first half is what makes
# `awk -v` safe — `awk` interprets a backslash escape inside a `-v` value, and a needle restricted to
# `[A-Za-z0-9]` has no backslash, no quote, and no non-ASCII byte for that interpretation to ever reach, so
# the question of escaping never has to be answered inside the awk program itself. It is also what rules
# out a needle carrying a space or a hyphen: `spaced_form` cannot tell a space already in the needle from
# one it inserted, so a needle that already has one gets its boundaries counted one position too early past
# it (see the discovery loop's own `SPACED`, which never has this problem, because it only ever *adds*
# spaces to a needle that came in with none).
#
# The second half is what makes the filter meaningful rather than merely harmless: a needle with no
# uppercase letter at all — a username, which the machine reads off lower-case — has no boundary anywhere
# in its own spelling, so *every* lower-to-upper case change in a matching window would read as
# manufactured, and every camel-cased mention of it would be rejected, including the one spelling most
# likely to appear if the needle is a person's name folded into an identifier. A needle with at least one
# uppercase letter has, at minimum, the boundary its own capitalisation already implies. That is not a
# line between the identity needles and the discovered names: a handle, `github.user` or the `gh` login,
# is spelled however its owner registered it, and a mixed-case one is identifier-shaped and goes through
# the filter exactly as a discovered name does. `$HOME` and the address never do, for the first half's reason: a `/`, an `@`.
#
# Any needle failing either half keeps the base gate's plain `grep -iF` — the same behaviour this file had
# before the straddle filter existed — rather than being taught a second, narrower rule for its shape.
#
# Matched with `grep`, each call pinned to `LC_ALL=C`, rather than a shell `case` bracket expression —
# `case "$needle" in *[A-Z]*)` looks equivalent and is not: a shell's bracket-expression ranges collate
# under the ambient locale exactly as awk's comparisons do, and under this machine's own `en_US.UTF-8`
# `[A-Z]` matched lowercase too, which would have called every needle identifier-shaped, non-ASCII bytes
# included, and quietly undone the class restriction this function exists to enforce. `grep`, asked for the
# same two questions with its own locale pinned, does not have that failure mode.
is_identifier_shaped() {
    printf '%s' "$1" | LC_ALL=C grep -q '[^A-Za-z0-9]' && return 1
    printf '%s' "$1" | LC_ALL=C grep -q '[A-Z]'
}

# Whether every byte of a needle is ASCII, which decides whether `scan` reads for it under the caller's
# locale as well as the C one (see the header). In the C locale `[:cntrl:]` and `[:print:]` together are
# exactly the 128 ASCII bytes, so the bracket below is exactly the bytes above them. One spelling of the
# class, shared with the split of the needle files near the end, so the two cannot disagree about which
# needles are which.
NON_ASCII='[^[:cntrl:][:print:]]'
is_ascii() {
    ! printf '%s' "$1" | LC_ALL=C grep -q "$NON_ASCII"
}

# Whether the caller's locale can read a needle at all, asked of `grep` itself: a needle it can read is
# one it finds in itself. A needle holding a byte that is not valid UTF-8 — a handle typed into a config
# file in Latin-1, where `É` is the one byte `0xC9` — is not a pattern a UTF-8 `grep` can compile. It
# stops with `illegal byte sequence` and exits 2, and in a list of needles that one stops the whole
# list, so every other needle in it would lose its second reading as well. Such a needle is read for in
# the C locale alone, which matches it as the bytes it is. The same question asked of every locale
# rather than a test of UTF-8 validity, because it is the caller's `grep` that has to read the needle.
caller_reads() {
    printf '%s\n' "$1" | grep -qF -- "$1" 2>/dev/null
}

# The identity of whoever is building, in the spellings a file can carry it in. All of it is read off
# the machine running the check rather than committed here, so the check describes whoever builds
# instead of whoever wrote it. The address and the handle are the two that travel furthest: a username
# in a path is a build artifact, but an address or a handle is a contact detail, and both survive the
# copy-paste that strips everything around them.
add_name "$HOME"
add_name "$(id -un)"
add_name "$(id -F 2>/dev/null || echo "")"
add_name "$(git -C "$REPO" config user.email 2>/dev/null || echo "")"
add_name "$(git config --global github.user 2>/dev/null || echo "")"
#
# The `gh` handle is read in the C locale, like every other read of text here (see the header): under a
# UTF-8 locale `sed` stops at the first line holding a byte that is not valid UTF-8, and a handle on a
# line after it would be dropped from the needles without a word.
add_name "$(LC_ALL=C sed -n 's/^[[:space:]]*user:[[:space:]]*//p' "$HOME/.config/gh/hosts.yml" 2>/dev/null | head -1)"

# Where the neighbours are read from is the **primary** checkout, not `$REPO` — which is only where this
# script happens to be sitting.
#
# A linked worktree commonly sits where the only entries beside it are other worktrees of the same
# repository (under `.claude/worktrees/`, say). Discovery from `dirname "$REPO"` then comes back with
# nothing, and the refusal below reads as "this machine holds no other projects" — which is false, and
# which a hook has no way to tell from the truth. Change-producing work is routinely done in worktrees,
# so that gap is the one that matters most.
#
# **Git is asked where the checkout is; it is never derived from where the git directory sits.** The
# parent of the common directory is the checkout in the ordinary `<checkout>/.git` layout and in no
# other: a bare repository sits *beside* the projects it would be named after, and a
# `--separate-git-dir` checkout keeps its git directory anywhere at all. Anchored on the git directory,
# a `--separate-git-dir` checkout learns the names beside that directory rather than beside itself, and
# clears a file naming its real neighbour — `verified: … names nothing private`, exit 0; a bare
# repository reports "no sibling projects", which is the one answer `githooks/pre-push` lets a push
# through on, with its neighbours sitting beside it. Neither says anything is wrong, and that is the
# shape this whole file is written against: a gate that resolves the checkout wrongly does not fail, it
# looks for less.
#
# So the pair is asked for in one call. **Equal means this working tree is the repository's main one**,
# whatever shape the repository has, and `--show-toplevel` names it; different means a linked worktree,
# and only there is a second lookup needed, `git worktree list` reporting the main working tree first.
# `Sources/SiftCore/GitContext.swift` settles the same question the same way.
#
# Three answers are not a checkout, and each is a refusal rather than a pass — none of them is the "this
# machine holds no other projects" report a push may continue past. A repository with no working tree
# has no checkout for neighbours to sit beside; note that `--is-inside-work-tree` says so by *printing*
# `false` and exiting 0, so the output is read and not merely the status, or a bare repository would
# reach the branch below. A working tree that will not say where its git directories are leaves
# "is this a worktree" unanswered. And a main working tree that is not a working tree cannot be walked
# — `git worktree list` names the git directory rather than the checkout for a bare repository and for a
# `--separate-git-dir` one, so what it hands back is confirmed rather than assumed.
#
# Outside a git repository altogether there is no indirection to undo and `$REPO` is already the
# checkout — that is a staged bundle, or an unpacked tarball.
INSIDE_WORK_TREE="$(git -C "$REPO" rev-parse --is-inside-work-tree 2>/dev/null || echo "")"
if [ "$INSIDE_WORK_TREE" = "true" ]; then
    # One `rev-parse` for the pair, because the pair is the answer and either half alone is not; the
    # options are printed in the order they are given.
    GIT_DIRS="$(git -C "$REPO" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null || echo "")"
    OWN_DIR="$(printf '%s\n' "$GIT_DIRS" | sed -n 1p)"
    COMMON_DIR="$(printf '%s\n' "$GIT_DIRS" | sed -n 2p)"
    [ -n "$OWN_DIR" ] && [ -n "$COMMON_DIR" ] || {
        echo "error: $REPO is a git working tree that will not say where its git directories are"
        echo "  The names are read from the primary checkout's neighbours, and from a worktree those are not this path's."
        exit 1
    }
    if [ "$OWN_DIR" = "$COMMON_DIR" ]; then
        PRIMARY="$(git -C "$REPO" rev-parse --path-format=absolute --show-toplevel 2>/dev/null || echo "")"
    else
        PRIMARY="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
    fi
    [ -n "$PRIMARY" ] && [ "$(git -C "$PRIMARY" rev-parse --is-inside-work-tree 2>/dev/null || echo "")" = "true" ] || {
        echo "error: $REPO belongs to a repository whose primary checkout this cannot locate"
        echo "  It reads the checkout's neighbours to learn what to look for. Run it from the working checkout."
        exit 1
    }
elif [ "$INSIDE_WORK_TREE" = "false" ]; then
    echo "error: $REPO is inside a git repository with no working tree, so there is no checkout beside the other projects"
    echo "  It reads the checkout's neighbours to learn what to look for. Run it from the working checkout."
    exit 1
else
    PRIMARY="$REPO"
fi

# The other projects on this machine. Entries that are not directories, are hidden, or are too short
# to be anything but a false positive are skipped, as are the names generic enough to appear in prose.
PARENT="$(dirname "$PRIMARY")"
# Which of the neighbours is the checkout itself is settled by identity rather than by spelling.
# `pwd` reports the path the caller arrived through, so on a case-insensitive filesystem one directory
# answers to `Developer/Sift` and `developer/sift` alike — and comparing basenames makes the checkout a
# stranger to itself, whereupon its own name joins the private needles and every file that mentions the
# tool fails the gate. That failure argues for an exception, and a gate with exceptions is a gate
# nobody trusts. Device and inode are the same pair however the path was spelled — and however the two
# were reached, which is the second thing this settles: run from a worktree, the primary checkout is a
# directory in the list about to be walked, and matching it by spelling would make the repository's own
# name a private one.
SELF_ID="$(stat -f '%d:%i' "$PRIMARY")"

# The package a checkout declares: the first `name:` after `Package(` in its Package.swift, or nothing.
package_name() {
    [ -f "$1/Package.swift" ] || return 0
    awk '/Package\(/ { inside = 1 }
         inside && match($0, /name: *"[^"]*"/) {
             found = substr($0, RSTART, RLENGTH); sub(/^name: *"/, "", found); sub(/"$/, "", found)
             print found; exit
         }' "$1/Package.swift"
}
SELF_PACKAGE="$(package_name "$PRIMARY")"

DISCOVERED=0
for ENTRY in "$PARENT"/*; do
    [ -d "$ENTRY" ] || continue
    [ "$(stat -f '%d:%i' "$ENTRY")" != "$SELF_ID" ] || continue
    NAME="$(basename "$ENTRY")"
    case "$NAME" in
        .* | _* | Shared | Tools | Docs | Certificates) continue ;;
    esac
    # The public repository is cut from this one into a directory beside it, named for the tool, and
    # that directory is this project rather than a neighbour: taking its name as private would fail every
    # file that names the tool. It is recognised by what it declares, and only where the declaration and
    # the directory agree — a neighbour named for the package this checkout declares, which declares that
    # package too. A private project that happens to share the name declares its own, and a checkout of
    # this package under any other directory name is still a name to look for.
    if [ -n "$SELF_PACKAGE" ] && [ "$NAME" = "$SELF_PACKAGE" ] && [ "$(package_name "$ENTRY")" = "$SELF_PACKAGE" ]; then
        continue
    fi
    [ "${#NAME}" -ge 4 ] || continue
    add_name "$NAME"
    # A directory is named `TanagerWidget` and prose calls it `Tanager Widget`, so a literal match for
    # the spelling on disk walks straight past every sentence that mentions it, in a fixture or anywhere
    # else. Each discovered name is therefore also checked with its words separated, with them hyphenated,
    # and with them joined by an underscore — `Tanager_Widget`, the spelling a constant, a file name or a
    # snake-cased key gives it, which none of the other spellings matches; matching is case-insensitive,
    # so the lower-cased spellings are covered by `Tanager-Widget` and `Tanager_Widget`. The second
    # substitution is for the acronym boundary, where there is no lower-case letter to hinge on:
    # `HTMLParser` → `HTML Parser` — the same boundary `name_awk` below has to recognise in a name's own
    # lower-camel spelling, which is why this transformation lives in `spaced_form` and is called from
    # there too, rather than being written out a second time.
    SPACED="$(spaced_form "$NAME")"
    add_name "$SPACED"
    add_name "$(printf '%s' "$SPACED" | tr ' ' '-')"
    add_name "$(printf '%s' "$SPACED" | tr ' ' '_')"
    DISCOVERED=$((DISCOVERED + 1))
done

# A gate that had nothing to check must not report the same word as one that checked and found
# nothing. Run from a CI checkout with no siblings, the discovery finds none — and every private name
# it exists to catch would pass unexamined under a line saying "names nothing private".
#
# It exits **2** rather than 1, and that distinction is the whole of what lets this run on every push.
# A clone with no neighbours is not a checkout with a leak in it, and a hook that could not tell the
# two apart would have to choose between blocking every push made from one and ignoring both.
#
# It says what it is a fact *about*, and that is the reason the search above is anchored to the primary
# checkout: only then is an empty neighbour set a statement about the machine rather than about where
# this particular checkout happens to sit.
if [ "$DISCOVERED" = "0" ]; then
    echo "error: no sibling projects discovered beside $PRIMARY — this check would pass whatever it was given"
    echo "  It reads the checkout's neighbours to learn what to look for. Run it from the working checkout."
    exit 2
fi

# One file is not evidence of what it defines: private-terms.txt *is* the list of generic terms, so
# matching it against them fails the gate on its own contents and on nothing else. Over a staged bundle
# it is not present; over the checkout — which is what publishing the repository makes the artifact —
# it is. Identified by device and inode for the reason SELF_ID is, since a gate must not turn on how a
# path was spelled, and announced rather than dropped quietly: a check this did not run is a check it
# cannot claim, whatever the reason.
#
# **The exemption is from the word list and from nothing else.** Skipping both scans would leave the
# discovered project names, `$HOME`, the username, the address and the handle unlooked-for in it too —
# in a file whose own header discusses the sibling projects and whose body invites a maintainer to write
# more prose into it. One sentence of the form "do not mention <a real neighbour>", or a contact address
# on a line of its own, and both gates would report clean. There is no reason the names half needs
# exempting: a private name in the word list is a leak like a private name anywhere else, so the name
# scan runs over it and only the word scan is skipped.
#
# This script is not exempt beside it. An exemption earned by quoting one term as an example would cover
# every line of the file — the one a reader of a public repository opens first — and leave whatever else
# is written here invisible to the gate and the test suite alike. So the examples above are invented,
# and this file is checked exactly as every other one is.
TERMS_ID="$(stat -f '%d:%i' "$TERMS")"

# A directory argument is walked in a pipeline, so every tally `check` keeps has to survive a subshell
# that cannot write back to this one. Three lines-of-a-file counters rather than three variables.
FOUND=0
check() {
    FILE="$1"
    # `git ls-files` lists index entries, and a file deleted from the working tree but not yet `git rm`-ed
    # is one of them. `stat` on it fails, and under `set -e` that would kill the run partway through the
    # tree: every path after it unscanned, behind a single bare `stat:` line no reader could tell from a
    # finding. What this reads is the working tree, so a tracked path absent from it is a state — named,
    # counted out of the verdict, and the walk carries on to the paths that are there.
    #
    # `verify-tree.sh` takes what `--deleted` names out of its listing, so the tree entry point does not
    # hand this the ordinary mid-rename case. This is still what answers, and still the thing tested, for
    # a path handed in directly, for one that goes between the listing and the `stat`, and for a symlink
    # pointing at nothing. A caller filtering its own input is not a reason to stop handling the input
    # that arrives.
    if [ ! -e "$FILE" ]; then
        echo "skipped: $FILE is tracked and not on disk — this reads the working tree, so it has not read this"
        echo "$FILE" >> "$SKIPS"
        return 0
    fi
    # The word list is not evidence of its own words, and that is the whole of the exemption: the names
    # are looked for in it exactly as in every other file. See TERMS_ID above for why the skip is no
    # wider. It counts as skipped and not as cleared, because only one of the two ran.
    FILE_ID="$(stat -f '%d:%i' "$FILE")"
    if [ "$FILE_ID" = "$TERMS_ID" ]; then
        echo "skipped: $FILE is the list of terms, so its own words are not evidence — its names were read"
        echo "$FILE" >> "$SKIPS"
        WORDS=0
    else
        echo "$FILE" >> "$READS"
        WORDS=1
    fi
    case "$(file -b "$FILE")" in
        *Mach-O*) TEXT="$(strings -a "$FILE")" ;;
        *text*|*JSON*|*empty*) TEXT="$(cat "$FILE")" ;;
        *)
            # Silence here would be the worst answer available: a file this cannot read is a file it
            # cannot clear, and at a release boundary that has to be said out loud rather than assumed.
            echo "error: $FILE is $(file -b "$FILE") — this check cannot read it, so it cannot clear it"
            echo "FOUND" >> "$FLAG"
            return 0
            ;;
    esac
    [ "$WORDS" = "0" ] || scan "$FILE" "$WORD_FILE" "-iw" "$NON_ASCII_WORD_FILE"
    scan "$FILE" "$NAME_FILE" "-i" "$NON_ASCII_NAME_FILE"
}

# A name-class needle, matched the way `scan` below needs it in either of two shapes: `MODE=count`
# prints how many lines of stdin carry a genuine hit, anything else prints those lines themselves —
# mirroring `grep -c` beside plain `grep` on the word-matching path next to this one.
#
# Only ever called for a needle `scan` has already decided `is_identifier_shaped` — every byte
# `[A-Za-z0-9]`, at least one of them uppercase. That is what makes `-v needle="$NEEDLE"` safe below:
# `awk -v` interprets a backslash escape in the value it is handed, and a needle drawn from that class
# has no backslash, no quote, and no byte outside plain ASCII for such an escape to ever be found in —
# the question of whether one is being misread cannot arise for a needle this function is ever given.
#
# "Genuine" excludes a match whose case only straddles a boundary the needle itself does not have.
# `grep -i` cannot tell `TanagerKit` (capitalises where `Tanager` does) from `underGoing` (capitalises
# a letter `Ergo` never does) — both are the same four letters, case-folded — so this walks each
# candidate window itself and compares, position by position, where *it* changes from lower to upper
# against where the needle's own **boundaries** sit. A transition the window has and the needle
# lacks there is the tell: it means the letters landed together by coincidence of two other words, not
# because the name is there. A window with only case changes the needle's boundaries already cover —
# none at all, in `Ergo`'s case, so any case-folding of it still counts — is kept.
#
# A needle's boundaries are not only its own lower→upper hinges. An acronym-led name (`HTMLParser`) has
# none where the acronym ends — `L` into `P` is upper into upper — and a check that only ever looked for
# lower→upper would read that position as one the name never transitions at, and would then reject the
# name's own lower-camel spelling (`htmlParser` really does hinge there, lower `l` into upper `P`). So
# the boundary set comes from `spaced_form`, the identical pipeline `SPACED`
# above is built from, run here on the needle itself: every space `spaced_form` would insert marks a
# boundary at that position and nowhere else. One pipeline, asked the same question twice, is what
# keeps this awk from drifting away from what `SPACED` already decided — a comment restating the two
# regexes by hand would only be one more place for the two to disagree.
#
# The candidate window's own transition check stays lower-to-upper only, never digit-to-upper, even
# though a needle's *own* boundaries (above, via `spaced_form`) do treat a digit as able to open one (a
# needle like `Kite3Wing` hinges its own `3` into `W`). Widening the candidate side to match once looked
# like the same rule applied twice, but it isn't: a needle whose digit is followed by a lowercase letter
# in its own spelling (`Kite3wing`) has no boundary there at all, and reading a digit-to-upper change in
# the *matched text* (`Kite3Wing`) as a transition needing a boundary the needle doesn't have rejected
# the mention outright — losing it exactly the way an unrelated coincidental transition should be lost,
# except this one was the name itself.
#
# `LC_ALL=C` on the invocation, not left to the caller's environment: awk's `<`/`<=` string comparisons
# go through the process locale's collation, and under a UTF-8 locale that collates case-insensitively
# enough that `"r" <= "Z"` comes back true — which would make the upper/lower checks below agree with
# each other on letters they should disagree on, and silently stop rejecting anything. The C locale is
# the one where those comparisons are plain byte order, which is what every `[A-Z]`/`[a-z]` elsewhere in
# this file already assumes. Safe here for the same reason the `-v` escaping is: every needle reaching
# this function is plain ASCII, so there is no non-ASCII byte whose C-locale reading could differ from
# its UTF-8 one. It is also what the header asks of every pass over the text: a line holding a byte that
# is not valid UTF-8 is read like any other.
#
# The windows are found with `index`, which jumps from one place the needle's letters occur to the next,
# rather than by asking `substr` for the window at every position of the line. awk's `substr` measures
# its whole string on every call, so a walk over every position costs the square of the line's length —
# a minified bundle or a data file written on one line of a few megabytes would hold a push up for hours
# — where `index` costs a pass over the line for each window it finds. A window the filter rejects
# resumes the search one character past its own start, not past its end, since the next window can
# overlap it: every window the walk over every position judged is judged here, in the same order.
#
# Lowercase, underscored names throughout this function and nowhere else in the file: every other
# identifier here is `LIKE_THIS`, which is also the shell's own convention for one, so the two
# alphabets never have to be told apart by a reader — and a mixed-case name here would itself be a
# compound identifier this repository's example-name gate has to be told about, for a name that names
# nothing but a piece of arithmetic.
name_awk() {
    NEEDLE="$1"
    MODE="$2"
    # The needle's own boundaries, read back out of its own spaced form rather than recomputed by a
    # second rule that could drift from the first: every space `spaced_form` inserts sits after some
    # number of the needle's own characters, and that count is the boundary position.
    SPACED_NEEDLE="$(spaced_form "$NEEDLE")"
    LC_ALL=C awk -v needle="$NEEDLE" -v spaced="$SPACED_NEEDLE" -v mode="$MODE" '
    function is_upper(c) { return c >= "A" && c <= "Z" }
    function is_lower(c) { return c >= "a" && c <= "z" }
    BEGIN {
        n = length(needle)
        needle_pos = 0
        for (k = 1; k <= length(spaced); k++) {
            ch = substr(spaced, k, 1)
            if (ch == " ") {
                boundary[needle_pos] = 1
            } else {
                needle_pos++
            }
        }
        lower_needle = tolower(needle)
        count = 0
    }
    {
        line = $0
        lower_line = tolower(line)
        matched = 0
        start = index(lower_line, lower_needle)
        while (start > 0) {
            candidate = substr(line, start, n)
            ok = 1
            for (i = 1; i < n; i++) {
                candidate_transition = (is_lower(substr(candidate, i, 1)) && is_upper(substr(candidate, i + 1, 1)))
                if (candidate_transition && !boundary[i]) { ok = 0; break }
            }
            if (ok) { matched = 1; break }
            # The next window may overlap this one, so the search resumes one character past its start.
            further = index(substr(lower_line, start + 1), lower_needle)
            start = further > 0 ? start + further : 0
        }
        if (matched) {
            count++
            if (mode != "count") print line
        }
    }
    END { if (mode == "count") print count }
    '
}

# The lines of `$TEXT` a needle outside `name_awk`'s shape is on, once each and in the file's own order,
# matched as a literal with `$2`'s flags — whole-word for a term, substring for a name. Read in the C
# locale, which sees every line; a needle with a byte outside ASCII is read for under the caller's locale
# as well, and the two readings are merged by line number, since each finds lines the other cannot (the
# header says which). `|| true` after each `grep`: finding nothing is an answer rather than a failure,
# and under `set -e` it would end the group before the second reading ran. A needle the caller's locale
# cannot read is read in the C locale alone, as it is in `scan` (see `caller_reads`).
plain_lines() {
    if is_ascii "$1" || ! caller_reads "$1"; then
        printf '%s\n' "$TEXT" | LC_ALL=C grep -F "$2" -- "$1" || true
        return 0
    fi
    {
        printf '%s\n' "$TEXT" | LC_ALL=C grep -nF "$2" -- "$1" || true
        printf '%s\n' "$TEXT" | grep -nF "$2" -- "$1" || true
    } | LC_ALL=C sort -t: -k1,1n -u | LC_ALL=C sed 's/^[0-9]*://'
}

# `$2` is a file of needles, one per line, and `$3` the matching mode: whole-word for the generic
# terms, substring for names. A name needle is further split by shape: `name_awk`'s boundary filter for
# the one shape it can say anything about — `is_identifier_shaped`, an ASCII identifier carrying a case
# of its own — and plain `grep` for every other name, exactly as the word side already gets.
#
# `-F` throughout, because a needle is a name and not a pattern. Directory names are discovered, so
# whatever punctuation a project happens to be called with arrives here unescaped: as a regular
# expression `Client.Web` also matches `ClientXWeb` — failing the gate on clean content, which is the
# quiet failure that argues for an exception — while `App[2]` matches only `App2`, and the real name it
# was added to catch would sail straight through unexamined. Name matching stays literal for the same
# reason; `name_awk` compares characters, never a pattern, and the `grep -F` branch below is exactly the
# base gate a name needle would have gone through if this file's boundary refinement had never been
# written — no more entitled to a pattern than the word side ever was.
#
# The whole list is asked first, and the needles are named one at a time only where that says there is
# something to name. The answer is identical either way; what changes is that a clean file — which is
# every file, on every run but the one that matters — costs two `grep`s instead of one per needle, and
# that is the difference between a check that runs on every push and a check nobody is obliged to run.
# Name needles still get this cheap pre-filter — plain `grep -i`, no boundary check — because it can only
# say yes to more than the precise scan would; it never rules out a needle the precise scan would keep.
# The same holds one needle at a time: an identifier-shaped needle is asked about on its own with that
# plain `grep -iF` before `name_awk` runs for it, because once any needle hits a file every needle is
# named in turn, and one whose letters are nowhere in the file has no window for the filter to judge.
# That `grep` reads in the C locale alone, and needs no second reading: an identifier-shaped needle is
# ASCII, and the C locale folds the same ASCII letters as `name_awk`'s own `tolower`.
#
# Every pass reads in the C locale, as the header explains. `$4` holds the list's needles that carry a
# byte outside ASCII, and only those are read for again under the caller's locale — so a machine whose
# needles are all ASCII, the usual one, pays nothing for the second reading. A machine with one pays a
# `grep` more on every file the first reading clears: over this repository's 518 files, measured at
# between a tenth and a third more time than the same run with all-ASCII needles. A cheaper trigger was
# looked for and not taken. A file holding no byte outside ASCII is not one the second reading can skip,
# because a UTF-8 `grep -i` folds `ı`, `İ`, `ſ` and the Kelvin sign onto ASCII letters — a needle
# `Vılkor` finds an all-ASCII `VILKOR` — and only ten of those 518 files are all ASCII anyway. And one
# pass of the second reading over the whole run needs a per-file lookup that this shell can make only by
# scanning a list, which cost a third of a second at 518 files and half a minute at 5,000.
#
# `cut` and `sed` are pinned the same way though they decide nothing: under a UTF-8 locale `cut` stops at
# the first invalid byte with an error, and every line after it — the evidence a reader acts on — goes
# unshown; `sed` exits on the line instead, and as the last stage of a pipeline under `set -e` that ends
# the whole run, with every file after this one unread (see the header).
scan() {
    # Every `printf … | grep -q` here silences the printf's own stderr: -q stops reading at the first
    # match, and when SIGPIPE is ignored — as it is under `git push`, which runs this gate — the write
    # after that fails with EPIPE and the builtin printf reports "write error: Broken pipe" from a gate
    # that passed. (With SIGPIPE at its default the printf dies quietly instead.) grep's exit status is
    # what each test reads, so silencing the write changes nothing the gate decides. A heredoc would dodge
    # the pipe, but $TEXT is arbitrary file content and could hold a line matching its closing word.
    printf '%s\n' "$TEXT" 2>/dev/null | LC_ALL=C grep -q "$3" -Ff "$2" \
        || { [ -s "$4" ] && printf '%s\n' "$TEXT" 2>/dev/null | grep -q "$3" -Ff "$4"; } \
        || return 0
    while IFS= read -r NEEDLE; do
        if [ "$3" = "-i" ] && is_identifier_shaped "$NEEDLE"; then
            # Silenced for the reason given above `scan`'s first test; `|| continue` reads grep's status.
            printf '%s\n' "$TEXT" 2>/dev/null | LC_ALL=C grep -qiF -- "$NEEDLE" || continue
            HITS="$(printf '%s\n' "$TEXT" | name_awk "$NEEDLE" count)"
            [ "$HITS" = "0" ] && continue
            echo "error: $1 names '$NEEDLE' ($HITS)"
            printf '%s\n' "$TEXT" | name_awk "$NEEDLE" lines | LC_ALL=C cut -c1-110 | head -3 | LC_ALL=C sed 's/^/    /'
        else
            HITS="$(plain_lines "$NEEDLE" "$3" | wc -l | tr -d ' ')"
            [ "$HITS" = "0" ] && continue
            echo "error: $1 names '$NEEDLE' ($HITS)"
            plain_lines "$NEEDLE" "$3" | LC_ALL=C cut -c1-110 | head -3 | LC_ALL=C sed 's/^/    /'
        fi
        echo "FOUND" >> "$FLAG"
    done < "$2"
}

# Every temporary file this makes is removed however the run ends: after its last line, on an exit
# `set -e` takes anywhere before that, and on a signal — a push interrupted from the terminal, or a hook
# its client gives up on. A shell killed by a signal it does not trap runs no `EXIT` trap at all, so each
# of the three that end a run is turned into an ordinary exit, with the status a shell killed by it would
# report, and the `EXIT` trap then runs for every one of them. It removes exactly the files named below,
# each only once it has been made, so a stop between two `mktemp`s removes nothing this did not make. A
# subshell does not inherit the trap, so the walk over a directory, which runs in a pipeline's subshell,
# does not remove the files when it ends, under the run that has still to read them.
FLAG=""
SKIPS=""
READS=""
WORD_FILE=""
NAME_FILE=""
NON_ASCII_WORD_FILE=""
NON_ASCII_NAME_FILE=""
remove_temporaries() {
    for TEMPORARY in "$FLAG" "$SKIPS" "$READS" "$WORD_FILE" "$NAME_FILE" "$NON_ASCII_WORD_FILE" "$NON_ASCII_NAME_FILE"; do
        [ -z "$TEMPORARY" ] || rm -f -- "$TEMPORARY"
    done
}
trap remove_temporaries EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

FLAG="$(mktemp)"
SKIPS="$(mktemp)"
READS="$(mktemp)"
# Blank lines are stripped on the way in, because a needle file with one in it is a `grep -f` that
# matches every line of every file — the gate would fail the whole tree on nothing.
WORD_FILE="$(mktemp)"
NAME_FILE="$(mktemp)"
printf '%s\n' "$WORD_NEEDLES" | grep -v '^[[:space:]]*$' > "$WORD_FILE"
printf '%s\n' "$NAME_NEEDLES" | grep -v '^[[:space:]]*$' > "$NAME_FILE"
# Each list's needles that carry a byte outside ASCII, for `scan`'s second reading. A `grep` that finds
# none exits 1, which is the ordinary answer; any other status is an error and ends the run, since an
# empty list here would quietly skip the reading those needles need.
#
# Of those, only the needles the caller's locale can read are kept (see `caller_reads`): the list is
# handed to one `grep -f`, and a single needle it cannot read would stop that `grep` for all of them.
# An empty line is never written, since in a `grep -f` list it would match every line of every file.
readable_needles() {
    while IFS= read -r NEEDLE; do
        if [ -n "$NEEDLE" ] && caller_reads "$NEEDLE"; then printf '%s\n' "$NEEDLE"; fi
    done
}
NON_ASCII_WORD_FILE="$(mktemp)"
NON_ASCII_NAME_FILE="$(mktemp)"
NON_ASCII_WORDS="$(LC_ALL=C grep "$NON_ASCII" "$WORD_FILE")" || [ "$?" = 1 ]
NON_ASCII_NAMES="$(LC_ALL=C grep "$NON_ASCII" "$NAME_FILE")" || [ "$?" = 1 ]
printf '%s\n' "$NON_ASCII_WORDS" | readable_needles > "$NON_ASCII_WORD_FILE"
printf '%s\n' "$NON_ASCII_NAMES" | readable_needles > "$NON_ASCII_NAME_FILE"
for TARGET in "$@"; do
    if [ -d "$TARGET" ]; then
        find "$TARGET" -type f | while IFS= read -r F; do check "$F"; done
    else
        check "$TARGET"
    fi
done
if [ -s "$FLAG" ]; then FOUND=1; fi
SKIPPED="$(wc -l < "$SKIPS" | tr -d ' ')"
CHECKED="$(wc -l < "$READS" | tr -d ' ')"

[ "$FOUND" = "0" ] || {
    echo
    echo "  Nothing distributed may name the machine it was built on, its owner, or the other work on it."
    echo "  For a binary, the fix is the build flag: -Xcc -ffile-prefix-map=\$PWD=/sift"
    exit 1
}
# The verdict names its subject while there is a subject worth naming, and counts it once the subject is
# a whole tree. Echoing every path in it back is the input restated, not the answer.
#
# What was skipped is counted *out* of the verdict rather than into it. A file this did not read is not
# a file it cleared, so a count that folds the two together over-reports by exactly the number of holes
# in it — and the one number a release gate must not overstate is how much it looked at.
if [ "$SKIPPED" != "0" ]; then
    echo "verified: $CHECKED of $((CHECKED + SKIPPED)) paths name nothing private ($SKIPPED skipped, named above)"
elif [ "$#" -le 4 ]; then
    echo "verified: $* names nothing private"
else
    echo "verified: $CHECKED paths name nothing private"
fi
