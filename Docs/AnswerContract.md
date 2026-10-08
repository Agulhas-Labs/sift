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
`    :<line>[  | <text>]` under `used by` and the `--refs` sweep, whose file heading may end `— written as
<alias>`. A row in a changed file has no text. Above 40 sites a block keeps its compact rows: `  <caller> —
<path>:<line>[ — <access>][  ×<N> units][ (<k> sites)][<mark>]` per caller, or `  <path> (<n>): <line>,
<line>, …[<mark>]` per file under `used by`. A protocol's `used by` verdict line inserts `, <k> of them the
conformance(s) listed below` after its reference and file counts, and its rows leave those lines out.

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
`<k> in a changed file without its clause`). Past the cap, `  truncated: <k> more conformers`.
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
