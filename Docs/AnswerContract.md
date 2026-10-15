# The answer contract

What every answer from this tool promises, stated once so that a second tool built on the same idea —
serve a resolved answer instead of the raw material — can promise the same things in the same shape.
The contract is about the *form* of an answer; it says nothing about what any tool measures.

## 1. The header comes first, and says what the answer was measured against

Every answer opens with one line naming the state it describes: which working tree was read (`tree:`),
the revision (`head:`), how far that tree has moved from it (`dirty:`), what could not be read
(`parse_errors:`), and which mode produced it (`semantic:`). Where no Swift file has changed from the
revision and none failed to parse, one word, `clean`, stands for those two fields; it is written only
where both were measured, never as a default. Naming the artifact comes first because
every other field is a measurement *of* it, and two artifacts that measure alike are otherwise
indistinguishable in the answer. A tool observing something other than source states the equivalent — the
build it ran, the device it ran on — in the same position. An answer read live, from nothing stored, names
the artifact and says so in place of the rest. Any note the answer carries
goes under the header, never above it. A reader who skips the header has still been told; a reader who
needs it never has to ask.

The rule governs query answers, the ones that describe stored or observed state. A command that does
something else (one that builds the state the header describes, a report over logs or processes) may
open differently, and a tool's own documentation names each such exception and why.

One exception wraps an answer rather than replacing it. Where a tool hands over a query answer in place
of something else the caller asked for — a refusal that carries the answer its advice would have named —
one line stands above the header, saying what was answered in place of what, and what to do to get the
thing that was asked for instead. Where that thing costs a measurable amount more than the answer, the line says what it costs and names the cheaper route the answer opens, so getting it anyway is a choice made knowing the price. The header still opens the answer beneath it, whole.

## 2. The verdict leads; the detail follows

The one word the caller acted on — passed, failed, resolved, unreachable, refused — is the first thing
after the header, before any listing. Numbers that can go down (failures, errors, misses) come before
numbers that only rise (calls, runs), because a counter that only rises reads as adoption whatever the
truth is.

## 3. Only the residue is served

The answer carries what the caller has to look at, never the material it was derived from: the failing
tests and not the log, the declaration and its line range and not the file, the flagged region and not
the whole capture. Where the residue is nothing, the section is nothing — not an empty heading.

Nor is anything said twice. A declaration's full name and signature are printed once, where the answer
lists it, and named after that by the shortest form that still tells it from the others; a file with
several sites under it is named once, as their heading, and sites that fall on one line are said once,
with a count (`(×N)`).

A site matched by written name carries the text of its line, since a bare location is read next. In
`where`, a call site is a row `    :<line>[ (×N)]  in <enclosing declaration>  | <text>`, one row per line,
under its file's path (`  <path>:`), the declaration followed by any mark its section adds, both indented
two more where a section nests them; a type's
written uses are `    :<line>  | <text>` under `  <path> (<n>):` while the block holds at most 40 lines,
and `  <path> (<n>): <line>, <line>, …` with no text above that. The text is the source line trimmed, each
run of whitespace one space, cut at 140 characters with `…`; a line not read ends its row before `  | `.
In `strings`, an accessor's use site is `      <path>:<line> in <enclosing declaration>: <text>`. Counts,
caps and paging count sites, never rows or characters.

A `where` site answered from the index store carries its text the same way while its block holds at most 40
sites: `  <path> (<n>):`, followed by `  (file changed since last build)` or `  (file deleted since last
build)` where the file changed, then one row per line, ascending — `    :<line>  <caller or declaration>[ —
<access>][  ×<N> units][  | <text>]` under a callers, uses, reads-and-writes or overrides block, and
`    :<line>[  <enclosing>][  | <text>]` under `used by` and the `--refs` sweep, whose file heading may end
`— written as <alias>`; `<enclosing>` is the declaration the store records the reference inside, and is left out
where it records none. A row in a changed file has no text but keeps its enclosing declaration. Above 40 sites a block keeps its compact rows: `  <caller> —
<path>:<line>[ — <access>][  ×<N> units][ (<k> sites)][<mark>]` per caller, or `  <path> (<n>): <line>,
<line>, …[<mark>]` per file under `used by` and the `--refs` sweep, except that a file holding 1 or 2 of the
block's sites keeps its heading and rows, enclosing declaration and text included. A protocol's `used by` verdict line inserts `, <k> of them the
conformance(s) listed below` after its reference and file counts, and its rows leave those lines out. Under `--refs` the `references to` heading carries the same clause, and the
sweep leaves those rows out only where the clause is on the first line of the conformer's span as the conformers block
prints it (a clause on a later line, after an attribute or wrapped, keeps its row and is not counted); a file holding only
such lines has no file heading.

A plain `where <Type>` whose uses, beyond a protocol's conformance lines, number 8 or fewer lists them as rows
under its `used by` verdict line, which then ends without a pointer; above 8 it lists no rows and ends `— where
--refs <Type> lists them` (the qualified name where the bare query has several owners). The rows above and below
are those of `where --refs` and of the hook's in-place answer. `where --refs` then ends with one `not code` section, once
per answer, after every declaration's sections. Its header is `not code, by written name — <n> DocC-link
line(s), <n> doc-comment line(s), <n> comment line(s), <n> string-literal line(s), <n> Markdown line(s), <n>
file name(s)[ (<k> a lead)][; <k> of these lines are also code lines listed above]:`, kinds with none left out,
and it says `over the working tree, never stale` and `may include same-named symbols` where several owners
or a qualified query make it ambiguous. A file's row is `  <path> (<n>): DocC <line>, … · doc <line>, … ·
comment <line>, … · string <line>, …` (a Markdown file's row lists bare line numbers), each kind capped at the
store's per-file line cap and ending `+<N> more`; the `file names:` row, on offset 0 only, lists the matching
paths. Nothing found is one line, `not code, by written name — none in the <N> Swift and <M> Markdown files
read; storyboards, xibs, plists, string catalogs and project files not read`. Under `--at` the section is the
one line `not code: not read at a revision`. A list already past its end while another continues prints `(all
<N> files shown on earlier pages)`. Header counts cover the whole tree on every page.

A protocol's conformers, with a store, are one block headed `conformers of <Protocol> (<N>: <d> direct, <i>
indirect[, <k> inherited][, <k> through a typealias][, <k> resolved to another declaration][, <k> in a deleted file][, <k> in a changed
file without its clause] — direct is every inheritance clause in this tree's source that writes the name, so a grep
for the name finds the same lines; <alias note>[; resolved to another declaration is a clause writing the name that
the index store resolves to another declaration of it]; indirect is from the index store[; inherited is reached through a listed protocol or class, so a grep for the name does not
find it][, <k> files changed since last build][, <k> files deleted since last build]):`, where `<alias
note>` is `a typealias to it is not followed` when no conformer is listed through one, else `through a typealias
is a clause writing a typealias of it`, one row per conformer, `  <qualified
name> — <kind> — <path>:<start>-<end> — <mark>[  ×<N> units][  (file … since last build)]`, where `<mark>` is
`direct`, `indirect`, `inherited through <Name>`, `through typealias <alias>`, `direct; the index store has it
through another type`, `direct; the index store does not have it` or `writes <Name>, which the index store
resolves to <Declaration>` (a clause writing the name the store resolves to another declaration of it, in a file
unchanged since the build, for a row the store records no conformance of the protocol for; counted as `<k> resolved
to another declaration`, not direct); a conformer the index has no declaration for is `  <name> — <path>:<line> —
<mark>`, and one only the store has in a file deleted since the build, or changed since so that its clause no longer
writes an entry where the store recorded one, nor anywhere the name the store recorded there, has no `<mark>` (the heading counts it as `<k> in a deleted file` or
`<k> in a changed file without its clause`). Past the cap, `  truncated: <k> more conformers`. The block's last line accounts for every Swift file a text search for the name finds, `every Swift file that writes <Name> is accounted for (<T>, a text search of the Swift files git shows[, manifests included])[: <c> declare a conformer (above)][, …]`, each class counting files of `<T>` once and the classes summing to `<T>`, a class with no file left out, each residue class naming at most five files, then `+<k> more`, under `--refs` the comments-or-strings files the `not code` section lists counted as `(<k> under not code, below)` and only the rest named, a file that could not be read named outside `<T>`; past the first page it gives counts only. It is left out at a revision, in the `--files` view, where git cannot list the tree, and past the scan's bounds (Design.md: the store's conformers block).
`inherited through <Name>` marks a conformer reached through the listed protocol or class `<Name>` (a refiner's
conformer, a subclass, to any depth); those rows follow every other. Every other conformers block, by written name
(for a class, with no store, or beside a second protocol's store block), is headed `conformers of <Type> (<N>, by
written name[, <k> inherited — inherited is reached through a listed protocol or class, so a grep for the name
does not find it]):`, its rows `  <qualified name> — <kind> — <path>:<start>-<end>`, the walked ones followed by
` — inherited through <Name>`. `<N>` includes the inherited rows in both.

`search` echoes the query as parsed on the line under the header, `search <query>`, followed by
` — <field>: any of <a>, <b>` for an alternation or ` — <field>: a case-insensitive regex` for a `/…/` value on
`name:`, `path:` or `sig:`; the field is any field (`— kind: any of struct, enum`, `— path: a case-insensitive regex`),
written `!<field>:` when negated. A regex read as the plain words it spells adds a line, `read name:/<pattern>/ as name:<a>|<b> —
the regex does not compile (<reason>), so this matches any of those words.` Under a pattern, the declarations
whose whole name it matches are listed first; where some match only in part, the summary line ends `; the <k>
whose whole name matches come first`; no line marks where they end, and with none or every declaration matching whole the line is the
plain one. Its verdict on a miss is `no
declarations match — scanned <N> file(s)`, followed, where some declaration reached the terms, by `; <term>
removed the last <k> declaration(s)`, or `; <term> removed all <k> declaration(s)` where no other term
removed any, `<term>` written as parsed (`!` kept).

## 4. Every figure carries its arithmetic

A number is followed by how it was made, in the unit the reader already thinks in. An estimate is marked
as one (`~`), at a ratio stated beside it and chosen so the true figure is at least what is shown. A
percentage names its denominator. A saving is stated as a floor — "only the N calls that could be
weighed" — never as a total.

## 5. Refuse with instructions rather than guess

When the answer cannot be given honestly — the index is stale, the target is ambiguous, the screen was
not reached, the build does not match the stated revision — the answer says so, says why, and says what
would make it answerable. A fast wrong answer is worse than a slow one, because it is believed. A
refusal is one-shot and retryable: the same request, once the condition is met, answers.

## 6. Nothing is silently under-reported

A gap is declared, not omitted: members the parser could not see, files that failed to parse, screens
that were skipped, a log that stopped mid-run. Two things that look alike but are not (the same name
in two modules, two symbols under different `#if` conditions) are both shown, with what tells them apart.

## 7. The tool decides what is there; the reader decides what matters

An answer states facts about the artifact — what exists, where, in what shape, how fresh — and never
whether the facts are acceptable. Ranking, adjudication and taste stay with the caller. The one
judgment a tool makes is the honesty of its own answer, and it states that judgment (§5, §6) rather
than acting on the caller's behalf.

## 8. A claim is worded no stronger than what was checked

An answer states what it verified, of the thing it verified it of. A pointer at another artifact —
another repository, another build, another device — names the evidence actually matched, and is
withheld where the match was of something narrower than the claim would be. Checking part of a target
and wording the answer as the whole of it is the failure this rule exists for: it reads as a fact,
costs the reader the detour, and is worse than no pointer at all.

The same rule tells two failures apart in the wording: *could not resolve this* (a wrong address for
something that is there) and *there is no such thing* are different answers with different next moves.

A provenance tag is how a line says its evidence is narrower than its words, so it goes where that is
true and nowhere else. (`sift run` tags a failure note placed by position alone or a failure placed by
containment; `sift help run-output` has the tags and when each applies.)

## Wording

- The unit is part of the number: `~54k tokens`, `12 of 42 lookups`, `8.7 MB of source`.
- A saving is *saved*; a compression is *N → M (P% smaller)*. Not *reduced*.
- Absolute paths stay out of answers meant to be shared; repository-relative paths with line ranges
  (`Sources/Core/Store.swift:41-58`) are the unit of location.
- Machine names never appear in an answer. Dates never appear in a query answer — `digest`, `where`,
  `search`, `strings`: stored rows carry the revision hash (`head:`) as provenance, a live read the tree
  it names. A report over time (`usage`, `flakes`, `audit`, `report`) dates what it reports on, because
  the span is its subject.

## Amendment: one header line, standing caveats said where they apply (in force)

**In force since 0.1.4:** the header-line part: §1's last sentence below (a header field written only where
it can vary, so `digest` carries no `semantic:`), §1's live header (`source: live`), and §3's echo rule for
`search`, `where` and `strings`; and `where`'s degraded notes: §1's last paragraph (*degraded notes*), with `where`
carrying one note under its header in place of the `mode:` line, the `NOT ANSWERED` notice and the
`references:` lines, and a `stores:` note only where the stores have something to say; and the standing
caveats: §1's added paragraph, §3's `where` sections and §6's missing sites, said in full in
`sift help answers`, and on an answer only where it applies: every empty `where` verdict (no callers, uses or `--refs` code sites; only the type's own lines; only its aliases; only the requirement it implements; a several-owners row counting none; a no-store sweep that found nothing), and every `search` whose query has a `calls:` or `uses:` term, empty or not (neither the primer nor the tool descriptions carry it); and §3's `where`'s `references to`
(the callers/references fold). Where it differs from the sections above, the amendment is the contract.
The design and its measurements are in [Design.md](Design.md), *Proposed: one header line, standing caveats
said where they apply*.

**§1, added after "goes under the header, never above it":** What is true of every answer of a kind — a
boundary of the evidence, a gloss on how a count was split, the limits of matching by written name — is
said in the answer it applies to (an empty or no-uses `where` verdict; a `calls:` or `uses:` `search`), never in the
primer or a tool description, and not on each answer. An answer carries such a caveat only where it is true of that answer
in particular: it was matched by written name because the stronger source was missing, it is stale or
partial, it was cut short. Notes that are true of this answer share one line under the header where they
can. A field of the header is written where it can vary for the verb; one that is the same on every answer
of a verb (sift's `semantic: syntactic-only` on `digest`) is said in `sift help answers` instead.

**§1, the live header:** an answer read live names the artifact and says so in one field (sift:
`source: live`); that nothing stored can go stale is said in `sift help answers`.

**§3, `search`'s echo:** the line under the header echoes the query only where the parse read it as
something other than what was sent — an alternation, a pattern, a bare word read as `name:`, a regex read
as plain words — with the readings as today. A query read as sent is not echoed. `where` and `strings` do
not echo the query.

**§3, `where`'s sections:** the `not code` section's header drops `over the working tree, never stale`
(said in `sift help answers`) and keeps `may include same-named symbols` where several owners or a qualified
query make it ambiguous. A type's `used by` line drops `split on the XCTest or Testing import, never the
path` and `which is not use`, keeping the tally and the count; a name-matched section's count line says
`by written name` in place of the heading line above it.

**§3, `where`'s `callers of` heading:** a store-backed heading whose base name other types also declare adds `resolved to this declaration — <name> is declared <N> time(s) on other types, not counted here; where <name> lists them` inside its parenthesis, after the count and any hedge, joined by `; `. A bare-name query (`where f`) leaves off `; where <name> lists them`, since that answer is the list. The no-store answer and an initializer's never say it.

**§3, `where`'s no-declaration answer:** where the queried name equals the basename (without `.swift`) of one or more indexed Swift files, `no declarations found` is followed by one line, `no declaration named <Name>; a file has that name: digest <path>` (`<k> files have that name: digest <path1>, digest <path2>`, three paths at most, then `, and <m> more`); nothing is added where no file matches.

**§3, `where`'s `references to`:** a function's `--refs` answer lists under `references to` only the sites not
already shown under `callers of`, headed "N in M files, K of them the call sites above". A site is shown once,
and every page of a paged sweep shows each site once, above or under `references to`.

**§6, missing sites:** the caveats on written-name matches are said in the answer they apply to (an empty verdict, or a `calls:`/`uses:` search) and are part of the
contract's "nothing silently under-reported": a written-name list may miss protocol, closure and
unfolded-typealias uses and unapplied instance-method references, and an empty one is not proof of "unused"; property and case uses by name at runtime
are not seen. A type's answer from no store keeps "an empty list is not unused" on the answer itself.

**§1, degraded notes:** a note saying a source was withheld names what was withheld (references; for a
subscript, callers too), and says "by written name" only where a written-name list follows.

## Amendment: per-file freshness (in force)

**In force since 0.1.4.** The design, its costs and its examples are in [Design.md](Design.md), *Proposed:
per-file freshness*. Where it differs from the sections above, the amendment is the contract.

**§1, what fresh means:** a file is fresh against its own last build, the newest build that recorded it,
never against the newest build of anything. A later build that did not compile a file leaves it measured
against the build that did, so a partial build never makes an edited file read as current.

**§1, what a stale header counts:** the distinct files the answer cites that differ from their build, by
kind, in the order changed, deleted, new, kinds with none left out, and the file's path when it counts
exactly one: `stale since last build (1 cited file changed: <path>)`, `(3 cited files changed)`, `(2 new cited
files)`, `(4 cited files: 1 changed, 1 deleted, 2 new)`. The word `cited` says whose count it is: the files this answer
cites, not every file in the tree (#788). `status` counts every file and keeps `(1 file changed: <path>)`, `(4 files: 1
changed, 1 deleted, 2 new)`. A file the answer stands on is counted whatever cites it: the declaration's own, a
caller's, a conformer's, one listed by written name. A file without a unit is not stale when no build of a
store's project compiles its module (another project in the tree, a module the manifest declares no target
for), or when a build ran after its last change and left it out; it is declared as before (§6).

**§1, what a partial header names:** a header never says `fresh` while the answer is a lower bound for want of
a build. Where indexed test files have no unit it says `partial (N test files have no unit in the store —
references from tests are a lower bound)`; where a non-test target the store's project declares has files,
none of them has a unit, and some of them write the asked name, it names the target and how many of its lines
write the name, `partial (target Extra not built — 2 lines there name Gizmo, not counted)`, three names at most
and then `+<k> more`; where both hold, one parenthesis carries both, joined by `; `. An empty verdict or a count
that is a lower bound for the same reason names the target in its own clause. Where the asked declaration is a
subscript, an operator function, `callAsFunction` or a `dynamicMember` subscript, whose uses spell no name a scan
could find, every such target is named without the scan, `partial (target Extra not built — its uses of
A.subscript cannot be found by name, not counted)`. A target that never writes the name hides nothing from the answer and is not named, nor is a `.plugin` or `.macro` target, which SwiftPM builds
for the host and no build indexes: a clause that tells the reader nothing would teach them to check every
answer by hand. An answer with every target built carries none of this, and `affected` names no target.

**§5, a freshness ambiguity is refused, not guessed:** a declaration in a changed or new file is refused,
with the build that makes the same request answer, naming what the last build left out where it did. A
row from a changed or deleted file is listed only under its mark, after the rows that stand, and never
read as current; a definition recorded only in a deleted file never resolves a declaration the tree holds.

