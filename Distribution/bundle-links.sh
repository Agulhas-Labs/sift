#!/bin/sh
# Keeps every relative Markdown link in a release bundle pointing at something the bundle holds.
#
# Usage:  sh Distribution/bundle-links.sh rewrite <repo-path-of-the-document> <version>   (stdin to stdout)
#         sh Distribution/bundle-links.sh check <staged-bundle-dir>
#
# The bundle ships a few documents, laid out differently from the repository (INSTALL.md and LICENSE.txt
# sit at the top), so a link written for the repository can point at a file the bundle does not carry.
# `rewrite` runs as a document is copied in: a relative link whose target the bundle ships becomes the
# relative path between the two bundle locations, and any other becomes an absolute link to that path in
# the public repository at the release tag, where it is laid out as in this one. `check` then walks the
# staged folder and fails on any relative link that does not resolve, so a document added to the bundle
# with a link the table below does not know is a failed build, not a dead link in a download.
#
# Exit:  0  rewritten, or every link resolves
#        1  a link does not resolve (each is printed)
#        2  usage, or a document the check could not read
set -eu

PUBLIC="https://github.com/Agulhas-Labs/sift"

# Awk shared by both modes: reads a document a paragraph at a time and tells fenced code blocks, indented code
# and code spans apart from prose, which neither mode touches. The program that includes it defines plain(text)
# and code(text), what to do with each, and raw(line), what to do with a line outside any paragraph.
SCAN='
# The fence a line opens or closes (the marker, spaces cut), or "" when it is not a fence line.
# A trailing carriage return is cut first, and a backtick fence whose info string holds a backtick is a code span, not a fence.
function fence_line(line,    m, rest) {
    sub(/\r$/, "", line)
    if (!match(line, /^ *(```+|~~~+)/)) return ""
    m = substr(line, RSTART, RLENGTH)
    rest = substr(line, RSTART + RLENGTH)
    gsub(/ /, "", m)
    if (substr(m, 1, 1) == "`" && index(rest, "`")) return ""
    return m
}
# Whether a line closes the open fence: the same character, at least as long, and nothing after it.
function closes(line, open,    m) {
    m = fence_line(line)
    if (m == "" || substr(m, 1, 1) != substr(open, 1, 1) || length(m) < length(open)) return 0
    sub(/\r$/, "", line)
    return line ~ /^ *(```+|~~~+) *$/
}
# One line of prose: a code span (a backtick run to the next run of the same length) goes to code(), the rest to plain().
function scan(line,    out, start, n, rest, tmp, off, found, cs) {
    out = ""
    while (match(line, /`+/)) {
        start = RSTART
        n = RLENGTH
        rest = substr(line, start + n)
        tmp = rest
        off = 0
        found = 0
        while (match(tmp, /`+/)) {
            if (RLENGTH == n) { found = 1; break }
            off += RSTART + RLENGTH - 1
            tmp = substr(tmp, RSTART + RLENGTH)
        }
        if (found) {
            cs = off + RSTART
            out = out plain(substr(line, 1, start - 1)) code(substr(line, start, n) substr(rest, 1, cs - 1 + n))
            line = substr(rest, cs + n)
        } else {
            out = out plain(substr(line, 1, start + n - 1))
            line = rest
        }
    }
    return out plain(line)
}
# A line that opens a block of its own, read past its indentation: a heading, a list item, a table row or a quote.
function heading(l) { return l ~ /^(#|##|###|####|#####|######)([ \t]|\r?$)/ }
function item(l) { return l ~ /^([-*+]|[0-9]+[.)])[ \t]/ }
function opens(l) { return item(l) || l ~ /^\|/ || l ~ /^>/ }
# A thematic break (three or more of one of - * _, spaces between allowed) or a setext underline ends a paragraph and holds no links.
function breaks(l) { return l ~ /^(-[ \t]*-[ \t]*-[ \t-]*|\*[ \t]*\*[ \t]*\*[ \t*]*|_[ \t]*_[ \t]*_[ \t_]*)\r?$/ || l ~ /^(=+|-+)[ \t]*\r?$/ }
# The column a line reaches past its leading spaces and tabs, counting from column c, a tab stopping at the next multiple of four.
# What follows the indentation is left in body.
function indent(s, c,    i, ch) {
    for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (ch == "\t") c += 4 - c % 4
        else if (ch == " ") c++
        else break
    }
    body = substr(s, i)
    return c
}
function flush() { if (para != "") print scan(para); para = "" }
# Reads a document a paragraph at a time, so a code span may run across its lines but not past a heading, list item, table row or quote.
# A paragraph goes to scan() whole; every other line (a fence and what it holds, a blank line, an indented code block, a break) goes to raw().
# The open list items are a stack of content columns, col[1] to col[depth]: where the text after each marker and its one to four spaces starts.
# A line belongs to the innermost item whose content column it reaches, and is indented code four or more columns past that, unless it
# continues a paragraph. A line that reaches fewer items continues an open paragraph lazily, or else closes the items it does not reach.
# A fence opens only short of that: a fence line four or more columns in is indented code, or a continuation line.
fenced != "" { raw($0); if (closes($0, fenced)) fenced = ""; next }
{
    if ($0 ~ /^[ \t\r]*$/) { flush(); raw($0); next }
    at = indent($0, 0)
    reach = depth
    while (reach > 0 && at < col[reach]) reach--
    deep = (at - col[reach] >= 4)
    fenced = deep ? "" : fence_line(body)
    if (fenced != "") { flush(); depth = reach; raw($0); next }
    if (para != "" && (deep || !(breaks(body) || heading(body) || opens(body)))) { para = para "\n" $0; next }
    flush()
    depth = reach
    if (deep || breaks(body)) { raw($0); next }
    if (heading(body)) { para = $0; flush(); next }
    if (item(body)) {
        match(body, /^([-*+]|[0-9]+[.)])/)
        mark = at + RLENGTH
        at = indent(substr(body, RLENGTH + 1), mark)
        col[++depth] = (at - mark > 4 || body ~ /^\r?$/) ? mark + 1 : at
        # A block may start on the marker line itself, when the text past the marker is indented code, a fence, a break or a heading.
        if (at - col[depth] >= 4) { raw($0); next }
        fenced = fence_line(body)
        if (fenced != "" || breaks(body)) { raw($0); next }
        if (heading(body)) { para = $0; flush(); next }
    }
    para = $0
}
END { flush() }
'

case "${1:-}" in
rewrite)
    [ $# -eq 3 ] || { echo "usage: sh Distribution/bundle-links.sh rewrite <repo-path> <version>"; exit 2; }
    awk -v src="$2" -v tag="v$3" -v public="$PUBLIC" "$SCAN"'
    # Repository path -> bundle path, for every file the bundle carries.
    BEGIN {
        ship["README.md"] = "README.md"
        ship["Sift.md"] = "Sift.md"
        ship["CHANGELOG.md"] = "CHANGELOG.md"
        ship["Docs/Guide.md"] = "Docs/Guide.md"
        ship["Distribution/INSTALL.md"] = "INSTALL.md"
        ship["LICENSE"] = "LICENSE.txt"
    }
    function dirname(p,    i) {
        i = match(p, /\/[^\/]*$/)
        return i ? substr(p, 1, i - 1) : ""
    }
    # Joins a directory and a relative path, folding "." and ".." away.
    function resolve(dir, rel,    n, parts, out, i, k, stack) {
        n = split((dir == "" ? "" : dir "/") rel, parts, "/")
        k = 0
        for (i = 1; i <= n; i++) {
            if (parts[i] == "" || parts[i] == ".") continue
            if (parts[i] == "..") { if (k > 0) k--; continue }
            stack[++k] = parts[i]
        }
        out = ""
        for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") stack[i]
        return out
    }
    function rewrite(target,    path, anchor, hash, full) {
        if (target ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:/ || target ~ /^#/ || target == "") return target
        hash = index(target, "#")
        path = hash ? substr(target, 1, hash - 1) : target
        anchor = hash ? substr(target, hash) : ""
        full = resolve(dirname(src), path)
        if (full in ship) {
            # Bundle documents sit at the top or one level down in Docs/.
            if (dirname(ship[src]) == "") return ship[full] anchor
            return "../" ship[full] anchor
        }
        return public "/" (path ~ /\/$/ ? "tree/" : "blob/") tag "/" full anchor
    }
    function code(text) { return text }
    # Rewrites the links in a stretch of prose. A link may carry a title after its target, "t", [q]t[q] or (t), which stays as written.
    function plain(line,    out, start, len, inner, ws, title, gt, full) {
        out = ""
        while (match(line, /\]\(<[^>\n]*>([ \t]+("[^"]*"|[\047][^\047]*[\047]|\([^)]*\)))?[ \t]*\)|\]\([^) \t\n]+[ \t]+("[^"]*"|[\047][^\047]*[\047]|\([^)]*\))[ \t]*\)|\]\([^)\n]*\)/)) {
            # Taken before rewrite runs: its own match() calls overwrite RSTART and RLENGTH.
            start = RSTART
            len = RLENGTH
            inner = substr(line, start + 2, len - 3)
            title = ""
            if (inner ~ /^</) {
                # An angle-bracket target is read inside the brackets, which stay out of the URL; its spaces are percent-encoded.
                gt = index(inner, ">")
                title = substr(inner, gt + 1)
                full = rewrite(substr(inner, 2, gt - 2))
                gsub(/ /, "%20", full)
                out = out substr(line, 1, start) "(" full title ")"
                line = substr(line, start + len)
                continue
            }
            if (match(inner, /^[^ \t]+[ \t]+["\047(]/)) {
                ws = match(inner, /[ \t]/)
                title = substr(inner, ws)
                inner = substr(inner, 1, ws - 1)
            }
            out = out substr(line, 1, start) "(" rewrite(inner) title ")"
            line = substr(line, start + len)
        }
        return out line
    }
    function raw(line) { print line }
    '
    ;;
check)
    [ $# -eq 2 ] || { echo "usage: sh Distribution/bundle-links.sh check <staged-bundle-dir>"; exit 2; }
    STAGE="$2"
    [ -d "$STAGE" ] || { echo "error: $STAGE is not a directory"; exit 2; }
    DEAD=0
    TOTAL=0
    DOCS="$(mktemp)"
    LINKS="$(mktemp)"
    WARN="$(mktemp)"
    WORK="$(mktemp)"
    STEP="$(mktemp)"
    trap 'rm -f "$DOCS" "$LINKS" "$WARN" "$WORK" "$STEP"' EXIT
    # A stage of the link extraction failed: say which and stop, since an empty list would read as a pass.
    broken() { echo "error: ${1#"$STAGE"/}: failed while $2"; exit 2; }
    find "$STAGE" -name '*.md' > "$DOCS"
    while IFS= read -r doc; do
        DIR="$(dirname "$doc")"
        # Every relative target: not a scheme, not a bare anchor; the anchor is cut off, the file is what resolves.
        # Fenced blocks and code spans are dropped first; a title after the target is cut at any whitespace,
        # and a target in angle brackets is read inside them. A paragraph is scanned whole, so a code span may run across its lines, but not past a heading, list item, table row or quote.
        # A fence still open at the end of the file is warned about, so a scanner miss shows rather than hiding links.
        # Each stage writes a file and its own status is read (sh has no pipefail), so a failed stage stops the check.
        awk -v name="${doc#"$STAGE"/}" -v warn="$WARN" "$SCAN"'
        function plain(text) { return text }
        function code(text) { return " " }
        function raw(line) { }
        END { if (fenced != "") print "warning: " name ": a code fence is still open at the end of the file; the links after it were not checked" >> warn }' "$doc" > "$WORK" || broken "$doc" "reading the document"
        grep -o -E '\]\((<[^>]*>|[^) [:blank:]]*)' "$WORK" > "$STEP" || [ $? -eq 1 ] || broken "$doc" "finding the links"
        sed -e 's/^](//' -e 's/^<//' -e 's/>$//' -e 's/#.*//' -e '/^[a-zA-Z][a-zA-Z0-9+.-]*:/d' -e '/^$/d' "$STEP" > "$WORK" || broken "$doc" "cutting the targets"
        sort -u "$WORK" > "$LINKS" || broken "$doc" "sorting the targets"
        while IFS= read -r link; do
            TOTAL=$((TOTAL + 1))
            if [ ! -e "$DIR/$link" ]; then
                echo "unresolved link in ${doc#"$STAGE"/}: $link"
                DEAD=$((DEAD + 1))
            fi
        done < "$LINKS"
    done < "$DOCS"
    cat "$WARN"
    echo "bundle links: $TOTAL relative checked, $DEAD unresolved"
    [ "$DEAD" -eq 0 ]
    ;;
*)
    echo "usage: sh Distribution/bundle-links.sh rewrite <repo-path> <version> | check <staged-bundle-dir>"
    exit 2
    ;;
esac
