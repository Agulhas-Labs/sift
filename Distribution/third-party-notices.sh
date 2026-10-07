#!/bin/sh
# Emits THIRD-PARTY-NOTICES.txt to stdout — every open-source component the binary statically links,
# each with the license text copied from the exact checkout it was built against.
#
# Usage:  sh Distribution/third-party-notices.sh [repo-root [checkouts]]
#         (defaults: this script's repo, and the `.build/checkouts` under it)
#
# The component list is READ FROM Package.resolved, never hand-maintained. A hand-kept list falls
# behind in silence when a dependency starts pulling in a new one — indexstore-db brings in swift-lmdb,
# and LMDB's compiled code carries a license that clause 2 of the OpenLDAP Public License requires a
# binary redistribution to reproduce. A list derived from the resolution cannot fall behind the
# resolution, which is the only property that makes this safe to redistribute.
#
# SQLite is the system library (public domain) and CryptoKit ships with the OS, so neither is a
# statically linked component and neither appears here.
set -eu

REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
RESOLVED="$REPO/Package.resolved"
# The checkouts belong to a build, not to the repository, so the caller that made the binary names
# them. A build with a scratch path of its own resolves under that path, and `.build/checkouts` is then
# absent on a fresh clone — or, where an earlier unscoped build left one, that build's resolution rather
# than the one linked, which keeps the promise above only by coincidence. The default is a plain
# `swift build`'s, and so the test suite's.
# `${2-...}` rather than `${2:-...}`: the latter falls back on an empty string as well as an unset
# one, so a caller that computed an empty checkouts path would silently get the default instead of the
# `[ -d ]` check below naming what it was actually handed.
CHECKOUTS="${2-$REPO/.build/checkouts}"
SUPPLEMENTS="$REPO/Distribution/third-party-supplements"

# License files under $1, no deeper than $2.
#
# The extension filter is what keeps source code out of a legal document: swift-syntax's code
# generator holds `CodeGeneration/Sources/Utils/CopyrightHeader.swift`, which matches the name pattern
# and is Swift, not terms. A license file is extensionless or plain text, and nothing else qualifies.
#
# `-type f` because the name pattern says nothing about what a thing is: a REUSE-style `LICENSES/`
# directory matches `LICENSE*` and has no extension, so it would be emitted as a component's terms and
# `cat` would fail on it — aborting the whole generator under `set -e`. `ThirdPartyNoticesTests`
# mirrors the same filter.
licenses_under() {
    find "$1" -maxdepth "$2" -type f ! -path '*/.git/*' \
        \( -iname 'LICENSE*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' \) \
        | grep -iE '/[^/.]+$|\.(txt|md|rst)$' \
        | sort
}

[ -f "$RESOLVED" ] || { echo "error: no Package.resolved at $RESOLVED" >&2; exit 1; }
[ -d "$CHECKOUTS" ] || { echo "error: no checkouts at $CHECKOUTS — build the package first" >&2; exit 1; }

echo "Sift statically links the following open-source components."
echo "Each component's license text follows, copied from the exact checkout the binary was built against."

# `identity` is SwiftPM's normalised (lower-cased) name, so the checkout directory is matched
# case-insensitively — the Yams checkout is `Yams`, its identity `yams`.
sed -n 's/.*"identity" *: *"\([^"]*\)".*/\1/p' "$RESOLVED" | while read -r IDENTITY; do
    DIR="$(find "$CHECKOUTS" -maxdepth 1 -type d -iname "$IDENTITY" | head -1)"
    [ -n "$DIR" ] || { echo "error: no checkout for $IDENTITY under $CHECKOUTS" >&2; exit 1; }

    # A package's own terms sit at its root; the terms of something it vendors sit beside the vendored
    # sources (swift-lmdb: libraries/liblmdb/LICENSE), and a package can have both. Widening only when
    # the root came up empty would drop the second kind silently: indexstore-db's root LICENSE.txt is
    # present, and `Sources/IndexStoreDB_LLVMSupport/LICENSE.TXT` — Apache-2.0 *with LLVM Exceptions*,
    # plus the legacy UIUC/NCSA terms and their no-endorsement clause — covers code the binary genuinely
    # links. That root file names the directories carrying different terms. The two sets are unioned,
    # root first, so a package's own license still leads its section.
    FILES="$(printf '%s\n%s\n' "$(licenses_under "$DIR" 1)" "$(licenses_under "$DIR" 4)" | awk 'NF && !seen[$0]++')"
    [ -n "$FILES" ] || { echo "error: no license file found for $IDENTITY under $DIR" >&2; exit 1; }

    echo
    echo "================================================================================"
    echo "$(basename "$DIR")"
    echo "================================================================================"
    echo "$FILES" | while read -r FILE; do
        echo
        echo "--- ${FILE#"$DIR"/} ---"
        echo
        cat "$FILE"
    done

    # Some terms are not in the checkout to be found at all. Yams vendors libyaml under
    # `Sources/CYaml/` with its per-file copyright headers stripped and no license file kept, so
    # libyaml's MIT notice — which a binary redistribution has to reproduce — exists nowhere any search
    # of the resolution can reach. A supplement is the narrow exception: one directory per SwiftPM
    # identity, one file per component, emitted inside the section of the package it travels in.
    # Everything else stays derived from the resolution, which is the property that makes this safe to
    # redistribute; a supplement is a claim a person made, and `ThirdPartyNoticesTests` is what holds
    # them to it.
    if [ -d "$SUPPLEMENTS/$IDENTITY" ]; then
        find "$SUPPLEMENTS/$IDENTITY" -maxdepth 1 -type f -name '*.txt' | sort | while read -r FILE; do
            NAME="$(basename "$FILE")"
            echo
            echo "--- supplement: ${NAME%.txt} ---"
            echo
            cat "$FILE"
        done
    fi
done
