# Run-output fixtures — where these came from

Every file here is a **real capture** of a real toolchain run — macOS 26.6.1 or 26.6.2, Xcode 26.6,
Swift Testing 1902. None is hand-authored: a hand-written transcript only ever
proves the filter matches what its author *expected* the toolchain to print, which is the assumption
this area can least afford.

Two throwaway packages produced them, both in a scratch directory outside any repository — no real
project was broken to capture a failure:

- **Widget** — a SwiftPM package (one library target, one test target carrying both a Swift Testing
  suite and an `XCTestCase`).
- **Gizmo** — an XcodeGen project (static library + unit-test bundle, macOS), built with
  `xcodebuild -project Gizmo.xcodeproj -scheme Gizmo -destination 'platform=macOS'`.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-build-success.txt` | `swift build` | 0 | Clean build, two real warnings, `Build complete!` |
| `swift-build-failure.txt` | `swift build` | 1 | Two compile errors — and no summary line at all |
| `swift-test-pass.txt` | `swift test` | 0 | Both frameworks' passing counts |
| `swift-test-fail.txt` | `swift test` | 1 | One XCTest assertion and two Swift Testing expectations |
| `swift-test-linkerror.txt` | `swift test` | 1 | An `Undefined symbols` block that must stay whole |
| `swift-test-linkerror-6.4.txt` | `swift test` | 1 | The same link failure under Swift 6.4: closes on `error: Build failed` then `error: fatalError`, not `fatalError` alone |
| `xcodebuild-build-success.txt` | `xcodebuild … clean build` | 0 | 274 lines of build-system chatter around one result |
| `xcodebuild-build-failure-dup.txt` | `xcodebuild … clean build` | 65 | The same error printed twice, once per build phase |
| `xcodebuild-test-success.txt` | `xcodebuild … test` | 0 | 822 lines that reduce to a summary |
| `xcodebuild-test-failure.txt` | `xcodebuild … test` | 65 | 774 lines around one failing test |
| `xcodebuild-build-failure-unresolved-package.txt` | `xcodebuild … -derivedDataPath … build` | 74 | `error: Could not resolve package dependencies:` carries its cause only on the indented lines beneath it |
| `swiftlint-lint-violations.txt` | `swiftlint lint --no-cache --reporter xcode Sources` | 2 | 29 `line_length` warnings, one repeated signature, and one `force_cast` error |

`xcodebuild-build-failure-unresolved-package.txt` is Gizmo built with one package dependency pointed at
a host that answers with a real "not found" — a clone that fails for the same reason a private
repository does when the caller has no credential for it, without naming one.

**The edits made to the captures.** Three, and all are substitutions of the capturing machine for a
stand-in — no line was added, removed or reordered, and every count, duplication and wording is as the
tools printed it. The third applies to every capture in this directory, the ones described further
down included.

1. **Absolute paths.** The two scratch package roots became `/Users/dev/Widget` and `/Users/dev/Gizmo`,
   and the builder's home directory became `/Users/dev`.
2. **The exported `PATH`**, in `xcodebuild-test-success.txt` and
   `xcodebuild-test-failure.txt`. `xcodebuild` dumps the whole environment it ran under, and the `PATH`
   in it is the capturing shell's — every version manager, package manager and editor helper
   installed on that machine, which is a fingerprint of who they are and nothing a reader of a build log
   needs. Each is the ten `/Applications/Xcode.app/…` entries `xcodebuild` prepends, which is the
   only structurally meaningful part of the line, followed by
   `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`. One line changed in each file; no test reads the
   value, and the full suite is green either way. `ExampleNamesTests` holds every capture to it,
   along with the home-directory substitution above.
3. **Machine identifiers and clock times.** The data here is scrubbed of everything that names the
   capturing machine or the moment it ran:
   - the Mac's hardware identifier on `xcodebuild`'s destination lines is `id:00000000-0000000000000000`,
     and the simulator the verdict-reader corpus ran on is `00000000-0000-0000-0000-000000000000`;
   - each DerivedData folder hash, which Xcode derives from the project's path, is 28 `x`s
     (`DerivedData/Gizmo-xxxxxxxxxxxxxxxxxxxxxxxxxxxx`);
   - the hashes Xcode computes over inputs holding the project's path — the project GUID, which also
     names the `-VFS` directory, a `-common-args.resp` file and the build-description signatures — are
     `00000000000000000000000000000001` to `…0007`, one per distinct original, so a hash a capture
     repeats is still repeated;
   - the per-user temporary directory is `/var/folders/00/0000000000000000000000000000gn`;
   - every timestamp, the date and UTC offset in a result-bundle name included, is synthetic. Each
     capture's clock is moved by one whole-second shift that puts its first timestamp at
     `2000-01-01 12:00:00`, and result-bundle names carry `+0000`: order, milliseconds and every
     interval inside a capture are as printed, and no capture's clock says anything about another's.

   Hashes the toolchain and the SDK determine (`swift-version--…`, the `.sdkstatcache` name), XcodeGen's
   object identifiers and process IDs are as printed. `ExampleNamesTests` holds every capture to the
   placeholders above for a destination identifier in either shape — 8 and 16 hex digits, or a UUID —
   after `id:` or `id=`, for a simulator's `CoreSimulator/Devices/` directory, for the DerivedData hash
   and for the temporary directory. The project GUID substitutions and the timestamps are recorded here
   and not checked.

---

## The verdict-reader corpus

Four captures of one `xcodebuild` corpus, and the pair at the head of it is the reason for the rest:
**the same tree, the same built products, minutes apart, one green and one red.** Whatever a
classifier says about the red one has to be reconcilable with the green one, which is the only cheap
protection against a rule that explains a failure by inventing a cause for it.

A capture of a real application cannot stand in for these, however its identifiers are pseudonymised:
Swift Testing renders the comment above an expectation as a `↳` line, so such a capture reproduces the
application's own source comments verbatim, alongside its test filenames, its UI wording and its name.
There is no vocabulary to grep for recognisable prose. So the corpus comes from something built to
produce the same shapes, and is a capture of that.

### Depot, the package these four come from

**Depot** is a throwaway SwiftPM package in a scratch directory outside any repository: one library
target `DepotKit`, one test target `DepotKitTests` of 2,658 tests in 290 suites — 53 suites of
"screen" tests over a fictional warehouse's signage, and 237 of arithmetic that passes either way.
Every name in it is invented, and so is every sentence: the words on the signs, the test names, and
the comments above the expectations that end up in the capture as `↳` lines.

Its sources are **generated by a script** rather than typed, which is the honest way to state what
they are — 666 failing expectations over 210 distinct expression shapes in 53 files is a shape, not a
piece of authorship — and the script is what makes the numbers below reproducible rather than lucky.

The environmental failure is a real one and not a staged one. Every reading in the package goes
through `ShelfIndex`, which reads the depot's signage from a file at `/tmp/depot-shelf-index`:

```swift
public static var isMounted: Bool {
    FileManager.default.fileExists(atPath: path)
}

public static func labels(for bay: String) -> String {
    isMounted ? signage.joined(separator: ", ") : ""
}
```

Mounted, all 2,658 tests pass. Delete that one file and 666 expectations across 53 files resolve to
`""`, `nil` or `0`. One environmental fact, hundreds of failures, **the same binary either way**: one
`build-for-testing`, then two `test-without-building` runs over the same built products.

```sh
xcodebuild -scheme Depot-Package -destination "id=$SIM" build-for-testing
printf 'mounted\n' > /tmp/depot-shelf-index
xcodebuild -scheme Depot-Package -destination "id=$SIM" test-without-building   # green
rm -f /tmp/depot-shelf-index
xcodebuild -scheme Depot-Package -destination "id=$SIM" test-without-building   # red
```

**The destination is load-bearing, and not for the reason you would guess.** Swift Testing writes SF
Symbols for its status decoration on macOS and plain `✘ ◇ ✔ ━ ↳` everywhere else — so these are
captured on an iOS 27.0 simulator created for the purpose, and a macOS capture of the identical run
would carry no `↳` at all, which is the character a failure's note is attached by. macOS 26.6.2,
Xcode 26.6, Swift 6.3.3, Swift Testing 1902.

| Fixture | Lines | Verdict | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-test-execute-success.txt` | 6,174 | `** TEST EXECUTE SUCCEEDED **` | A **passing** run that still carries a known issue |
| `xcodebuild-test-execute-failure-environmental.txt` | 8,185 | `** TEST EXECUTE FAILED **` | 667 issues (1 known) over the *same build* as the row above |
| `xcodebuild-build-interrupted.txt` | 473 | `** BUILD INTERRUPTED **` | The third state — and its run tally says *failed*, so a two-state reader gets it wrong twice |
| `xcodebuild-test-execute-truncated.txt` | 4,000 | none | A run cut off mid-suite: no verdict, no summary, nothing to say |

`xcodebuild-test-execute-truncated.txt` is the first 4,000 lines of the success capture, which is
exactly the shape a killed `xcodebuild` leaves behind — output up to the moment it died and no
closing line. It is the acceptance case for *silence is never success*.

`xcodebuild-build-interrupted.txt` is one suite — `-only-testing:DepotKitTests/SignHeightTests`,
which is the one suite in the package that runs its tests one at a time and does real work first, so
that it lasts long enough to be interrupted — under **a Ctrl-C and then an impatient second one**:

```sh
kill -INT  -$pid    # once the run tally has been printed
kill -TERM -$pid    # once xcodebuild has answered with its in-flight operation dump instead of exiting
```

Both go to the whole process group, the way a terminal delivers them. That pair is what gets
`xcodebuild` to close on `** BUILD INTERRUPTED **`; the `SIGINT` on its own unwinds through its own
error reporting, prints a stack trace and the *"attach the result bundle"* line, and gives no verdict
at all — measured over about twenty runs, not once. So the file holds a completed Swift Testing tally
reading *failed*, four hundred lines of `xcodebuild` reporting its own blocked operations, and a
closing line that is neither a pass nor a failure. All three are what the reader has to survive.

### What is measured in them

These numbers are the shape Depot was generated to have, and they are counted off the captures
independently of the classification — that independence is the whole point of them, since a
normalisation tuned until its own output flattered it would prove nothing.

- **666** `recorded an issue` lines in the failing capture — matching `667 issues (including 1 known issue)`.
- **210** distinct signatures once quoted strings, numbers and hex addresses are normalised away. The
  largest, `Expectation failed: (labels → "…").contains(expected → "…")`, covers **117** of the 666 —
  18% of them.
- **53** distinct source files.
- **434** distinct raw messages, over **443** distinct `file:line:col` sites and **443** distinct
  failing test names.

**The last two counts are one fact about how the run is built.** Depot's 443 names, 443 sites and 443
(name, site) pairs are a bijection: every failing test fails at exactly one line, and the 666 failures
spread over 443 names only because a parameterized test records one issue per case, all of them at
that line. A hand-written application collapses differently — tests failing many times over, and
several of them sharing a line through a helper they all reach — and a generated package has more
distinct places to fail from than such an application has tests. The raw messages follow from the
sites and normalise back to the same 210.

The environmental tell — a failure whose expression resolved to `""`, `nil` **or `0`** — reads
**569 of 666 (85%)**, and **497 of 666 (75%)** counting only the first two. Either figure makes the
same point: this is an environment resolving everything to nothing, and not a number that rounds to
"one signature".

And, measured on the captures:

- **247** of the 666 are parameterized cases carrying the arguments they failed under
  (`with 1 argument title → "Drum" at …`), and **641** carry a `↳` note.
- The largest signature's 117 failures are spread over **9** sites in **8** files and written **40**
  different ways — which is what a signature count is for, and what the 434 raw messages above are the
  whole-corpus version of.
- **186** lines of the red capture carry a zero-width space (U+200B) *before* the status glyph, and
  134 of the green one do. This is the anchor-breaking fault these captures exist to hold: `grep '^✘'`
  misses those 186 lines, and reading bytes without anchoring on the glyph is what survives it. Which
  lines get one is not stable between runs of the same command — recapturing moves them — so nothing
  may be asserted about a particular line carrying one, only that the reader survives them.
- **54** of the `↳` lines are `///` doc comments — a suite's own header comment, printed by
  `xcodebuild` under a neighbouring failure. That is the exact shape that carries an application's own
  documentation into a capture; here the sentences are the depot's own fiction.

  **On private-use glyphs** — measured across all twenty-one captures
  here. These two gate captures contain **no** private-use characters at all, because they were taken
  on a simulator. But the ecosystem does emit them: every `swift test` capture in this directory
  carries them (U+100135, U+1007C8, U+100884, U+10105B — SF Symbols in Supplementary Private Use
  Area-B), 14 in `swift-test-fail.txt`, and `xcodebuild-test-two-bundles.txt` carries 27 under
  `xcodebuild` on a macOS destination.

  So the honest statement is neither "there are none" nor "that is the fault": **whether Swift
  Testing writes a private-use symbol or a plain glyph depends on the platform it is running on** —
  macOS gets the symbols and a simulator gets the plain glyphs — which is exactly why nothing may
  anchor on the glyph. Two different characters in the same position, plus a zero-width space that is
  sometimes in front of them, is three ways for a leading-character match to be wrong. **Measure this
  with a decoder, not `grep`**: these characters live in Plane 16, so a byte-range bracket expression
  will not find them.

### The one known issue is the same known issue in both captures

`aMisspeltManifestNameIsNotSkippedAndANonSheetNameIs()` is `withKnownIssue`-wrapped and records in
both runs, at `ToteStackTests.swift:72:13`. Three things about it are load-bearing:

- It reads **`recorded a known issue`**, not `recorded an issue` — so the failure extraction that
  yields 666 excludes it by wording, and does not have to subtract it afterwards.
- Its test is reported as **`passed after … with 1 known issue`**. A known issue does not fail its
  test, and the green capture's whole run passes carrying one.
- Which lines carry a zero-width space in front of the glyph is not stable — not between these two
  captures, and not between recaptures of the same command; only the counts stay in the same
  neighbourhood. So what is asserted about this line is its wording, never its first character.

Which makes this line the cheapest reconciliation test in the corpus: any rule that turns a known
issue into a failure makes the two captures disagree about something that never changed.

**Edits made**: the scratch directory the package was built in became `/Users/dev/Depot`, and the
builder's home directory → `/Users/dev` everywhere else, as everywhere in this file; the simulator,
the DerivedData hash and the clock are the placeholders of item 3 at the top. Nothing else —
the line counts, the interleaving, the zero-width spaces and the glyphs are as `xcodebuild` wrote
them, and several of those are the point.

Two things were **selected** rather than edited, and both are worth stating plainly, because a
chosen capture is a weaker piece of evidence than a taken one:

- `xcodebuild` splices one test runner's output through the middle of another's — the green capture
  carries three of those, `XCTestOutputBarrier✔ Test theTallyOfDwAfIsTwiceTheCrates() passed after …`
  and two more, and the truncated capture one. **Every splice in the corpus is that same fixed
  literal in front of an otherwise intact line**, which is what the filter reads it as: the token
  comes off the head in `RunOutputFilter.consume(line:)` and the line is read like any other.
  `Test .* Test ` — a second runner's *content* spliced in — occurs zero times in 8,185 lines.
  The red capture was re-run until no splice landed on a `recorded an issue` line, and this one has
  none anywhere. Splicing is real and is in the corpus; what is not in the
  corpus is a splice on an issue line, because selecting for one would be asserting the toolchain's
  coin flip rather than the filter's behaviour. **What the corpus therefore does not cover is
  asserted synthetically**, in
  `RunOutputFilterTests.aBarrierSplicedOntoAnIssueLineIsStrippedBeforeTheLineIsRead` — the filter's
  behaviour on that line is a statement about the filter and can be written down; which line the
  toolchain splices is not.
- The interrupted capture was retried until `xcodebuild` closed on its verdict rather than on its own
  error report, as described above.

---

## The two halves of `swift test`

Two more captures, from one throwaway SwiftPM package built for them — **Mixed**, a library target
and a test target holding a deliberately failing `XCTestCase` (`XCTAssertEqual(doubled(3), 42)`).
macOS 26.6.1, Swift 6.3.3, Swift Testing 1902; both runs exit **1**.

| Fixture | Test target holds | Swift Testing's closing line | What it is here for |
| --- | --- | --- | --- |
| `swift-test-xctest-only-failure.txt` | one failing `XCTestCase`, no `@Test` | `Test run with 0 tests in 0 suites passed after 0.001 seconds.` | Every pure-XCTest package |
| `swift-test-mixed-xctest-failure.txt` | the same, plus one passing `@Test` | `Test run with 1 test in 1 suite passed after 0.001 seconds.` | A package part-way through migrating |

**Both say *passed*, and neither run did.** That is the whole reason they are here: Swift Testing
prints its closing sentence whether or not the package contains a single `@Test`, so the sentence is
a statement about Swift Testing's half of the run and never about the run. A `swift test` judged on
it alone answers `✔ swift test — exit 1` with the failing assertion listed three lines below the
tick — and a `swift test` is judged on that sentence, because unlike `xcodebuild` it stamps no
closing line of its own. The mixed capture is the stronger of the two: its tally is a real, non-empty
pass rather than a degenerate count of nothing.

Captured by running the package's own `swift test`; **edit made**: the scratch directory the package
was built in became `/Users/dev/Mixed`, and the clock is synthetic as in item 3 at the top. Nothing
else — the ordering, the duplicated per-suite
counters and the glyphs are as the two frameworks wrote them, and the interleaving of the XCTest
block ahead of the Swift Testing one is exactly what the verdict has to be read across.

---

## The wide blast radius

One more capture, from a throwaway SwiftPM package built for it — **Big**, one library target holding
`Helper.swift` and forty caller files. macOS 26.6.1, Swift 6.3.3.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-build-mass-failure.txt` | 4,062 | 1 | 1,040 `error:` lines, 200 distinct errors, **one** signature |

**It is the one capture in the corpus with hundreds of errors**, which is the case an errors section
with no cap on it is worst at. This is that case at its purest: `pad(_ text: String, width: Int)` is called five times
in each of `Call1.swift` … `Call40.swift`, and the capture is what `swift build` prints after the
label `width:` becomes `columns:`. Every one of the 200 errors is the same sentence at a different
location, which is exactly the shape a rename, a signature change or a moved dependency produces —
the commonest way a build fails wide.

How it was taken:

```sh
swift build                      # clean, to prove the package compiles
# `width:` → `columns:` in Sources/Big/Helper.swift
swift build > capture.txt 2>&1   # exit 1
```

**Edit made**: the builder's home directory → `/Users/dev`, as everywhere above, so the package root reads
`/Users/dev/Big`. Nothing else.

The arithmetic behind the two counts, since neither is obvious and both are asserted: the 1,040
`error:` lines are 520 diagnostic headers and the 520 `` `- error: `` carets under their source
snippets. Those 520 headers are 200 distinct `(path, line, column, message)` diagnostics — 80 of
them printed twice and 120 three times, once per compilation the driver ran over the file. The
deduplication that turns 520 into 200 is the filter's, and it is the same behaviour
`xcodebuild-build-failure-dup.txt` covers at a scale small enough to read by eye.

---

## Two test bundles, and two closing tallies

One capture, from a throwaway SwiftPM package built for it — **Two**: one library target and *two* test
targets, `AlphaTests` (three tests, two of them failing) and `BetaTests` (three tests, one of them
`withKnownIssue`-wrapped). macOS 26.6.1, Swift 6.3.3, Xcode 26.6, Swift Testing 1902.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-test-two-bundles.txt` | 457 | 65 | **Two** Swift Testing run tallies in one run |

Run as `xcodebuild -scheme Two-Package -destination 'platform=macOS' test`. Swift Testing prints one
closing tally per test *process* and `xcodebuild` runs one process per test bundle, so this run closes
with two of them, sixteen lines apart:

```
Test run with 3 tests in 1 suite failed after 0.001 seconds with 2 issues.
Test run with 3 tests in 1 suite passed after 0.001 seconds with 1 known issue.
```

**Reading the second and discarding the first is the defect it is here to catch.** A filter keeping the
last one states `Swift Testing: 0 failures, 1 known issue` directly above a census line
reading `2 failures` — a count contradicting the one beneath it — and describes a run of six tests in
two suites as *3 tests in 1 suite*. Its two `Executed 0 tests` lines are the same `xcodebuild`
boilerplate every other capture here carries, one per bundle this time.

**Edits made**: the scratch directory the package was built in became `/Users/dev`, so its root reads
`/Users/dev/Two`, and the builder's home directory → `/Users/dev` everywhere else, as above; the
hardware identifier, the DerivedData hash and the clock are the placeholders of item 3. Nothing else —
the glyphs are the private-use SF Symbols Swift Testing writes when it thinks the terminal can render
them, and they are as the tools printed them.

---

## A display name with the word `Test` in it

One capture, from a throwaway SwiftPM package built for it — **Named**: `@Suite("Reflow Test Grid")`
holding one failing test, and `@Test("The Test Reads Its Own Name")`, which also fails. macOS 26.6.2,
Xcode 26.6, Swift 6.3.3, Swift Testing 1902, run as `swift test`.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-display-name.txt` | 30 | 1 | A suite and a test whose display names contain the word `Test` |

**The display names were typed into the package, not substituted into the capture.** A name rewritten
in place leaves a file asserting it is untouched toolchain output while carrying a line no toolchain
ever printed, in a directory whose one promise is that every byte in it was printed by a tool — so
every byte here is `swift test`'s own.

Both display names carry the word `Test`, which is the word Swift Testing writes in front of a *test's*
name — so a reader searching the line backwards for ` Test ` finds the author's word instead of the
framework's. Such a reader takes `Suite "Reflow Test Grid" failed after …` for a test called `Grid"` and
manufactures a failure for it, over a run whose own tally says two issues; and it reports the second
test as `Reads Its Own Name"`, dangling quote included. The invented name then reaches `run.jsonl`, and
from there `flakes`, as a test that had failed and does not exist.

Note what this capture also settles: Swift Testing 1902 prints a display name **in quotes** and a type
name bare, which is why no other capture here triggers it — this one holds all four of the corpus's
quoted suite lines, and no other fixture names a suite that way at all. It also disposes of the
interleaving the backwards search was chosen to survive: `Test .* Test ` occurs **zero** times in the
8,185-line red capture.

**Edits made**: the scratch directory the package was built in became `/Users/dev`, so its root reads
`/Users/dev/Named`, and the builder's home directory → `/Users/dev` everywhere else, as above; the
clock is synthetic as in item 3. Nothing else.

---

## A failure that quotes the run tally

One capture, from a throwaway SwiftPM package built for it — **Quoted**: one library target holding a
single `String`, and one test suite whose two `@Test`s both fail, the second by comparing that string
against Swift Testing's own closing sentence. macOS 26.6.1, Swift 6.3.3, Swift Testing 1902, exit **1**.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-quoted-tally.txt` | 24 | 1 | A **failure message** carrying the words `Test run with ` |

```swift
#expect(Quoted.phrase == "Test run with 2 tests in 1 suite passed after 0.001 seconds.")
```

So the capture holds that sentence twice, and only one of them is the run saying anything:

```
􀢄  Test quotesThePhraseInItsFailure() recorded an issue at QuotedTests.swift:12:9: Expectation failed: (Quoted.phrase → "nope") == "Test run with 2 tests in 1 suite passed after 0.001 seconds."
􀢄  Test run with 2 tests in 1 suite failed after 0.001 seconds with 2 issues.
```

**Reading the first as a tally is the defect it is here to catch**, and it costs three things at once.
A tally matched *anywhere* in the line — to survive the status glyph — by a reader that runs before
the one that reads failures swallows the failure's message: a fragment of it, closing quote and all,
is filed as a second tally; two tallies make the sole-tally rule answer `nil`, so the run headlines
`⚠ … no verdict in the log` over a log whose last line *is* the verdict; and the failure itself is
reported as having no message of its own.

**It is self-referential, which is what makes it worth a capture rather than a hand-written line.**
`Tests/SiftCoreTests/RunOutputFilterTests.swift` contains that literal, so a failure in this
repository's own suite would misreport itself in exactly this way.

**Edits made**: the run prints no absolute paths at all, so the scratch directory substitution
changed nothing; the clock is synthetic as in item 3.

---

## A failure that quotes the totals line

The same exposure one line further down the answer, and a second capture from a **Quoted** package built
the same way — one library target holding a single `String`, one suite whose two `@Test`s both fail, the
second by comparing that string against the answer's own closing line. macOS 26.6.2, Swift 6.4,
Swift Testing 2084, exit **1**.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-quoted-totals.txt` | 34 | 1 | A **failure message** carrying the words `totals: ` |

```swift
#expect(Quoted.phrase == "totals: ✔ passed · Swift Testing 2 tests in 1 suite")
```

So the answer rendered from this capture carries the token twice: once inside the listed failure's
message, and once as the line it actually closes on. **Only the second begins a line**, which is why the
token is documented as `grep '^totals:'` and never as a bare `grep totals:` — an unanchored gate reads
a quoted line as the verdict, and the first line it would find here says `✔ passed` over a run that
failed. `RunTotalsLineTests` embeds that literal for the same reason the tally literal sits in
`RunOutputFilterTests`: a regression in this repository's own suite would misreport itself.

**Edits made**: the run prints no absolute paths and names no machine, so both substitutions changed
nothing; the clock is synthetic as in item 3.

---

## Two XCTest bundles, and two closing counters

One capture, from a throwaway SwiftPM package built for it — **Duo**: one library target and two
`XCTest` test targets, `AlphaTests` (twelve tests, three of them failing) and `BetaTests` (four tests,
all passing). macOS 26.6.1, Swift 6.3.3, Xcode 26.6.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-test-two-xctest-bundles.txt` | 484 | 65 | **Two** XCTest `Executed …` totals, with real counts in both |

Run as `xcodebuild -scheme Duo-Package -destination 'platform=macOS' test`. The sibling of
`xcodebuild-test-two-bundles.txt` for the other framework, and it exists because that one cannot catch
this: both of *its* `Executed` lines are the `Executed 0 tests` boilerplate `xcodebuild` prints whether
or not an `XCTestCase` ran, so a rule that keeps the wrong one looks right on it. Here both counters
are real and they disagree:

```
	 Executed 12 tests, with 3 failures (0 unexpected) in 0.315 (0.318) seconds
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds
```

**Keeping the last is the defect it is here to catch.** A counter that keeps only the last lets the
passing bundle overwrite the failing one, so `Executed 4 tests, with 0 failures (0 unexpected)` prints
directly beneath `✘ xcodebuild — exit 65`, with the twelve tests and three failures that produced that
exit code nowhere in the answer.

Each bundle prints its counter three times — once per suite, once per bundle, once for the run — which
is what makes last-wins right *inside* a process and wrong across two. The boundary is
`Test Suite 'All tests' started at`, which XCTest prints exactly once per process: measured across
every capture in this directory, once in each single-bundle one and twice in each two-bundle one.

**Edits made**: the scratch directory the package was built in became `/Users/dev/Duo`, and
the builder's home directory → `/Users/dev` everywhere else, as above; the hardware identifier, the
DerivedData hash and the clock are the placeholders of item 3. Nothing else.

---

## Eight mistakes with nothing in common

One capture, from a throwaway SwiftPM package built for it — **Motley**: one library target holding
`A.swift` … `H.swift`, each file carrying a different compile error and nothing else. macOS 26.6.1,
Swift 6.3.3, run as `swift build`.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-build-diverse-failure.txt` | 146 | 1 | 8 distinct errors, **8** signatures, 8 files |

**The mirror image of `swift-build-mass-failure.txt`, and the case a sampled block is worst at.** That
one is 200 errors reducing to one signature, where a sample of five says everything. This one reduces to
nothing at all: every error is its own kind, every one has to be fixed, and a block that showed five of
them and counted the rest would send the reader to the raw log — the whole cost `run` exists to remove.
It would not even pay for itself: on this capture a sampled answer is longer than the complete listing,
because the measurement line and the `+N more signatures` line together cost more than the errors they
stand in for.

The eight, one per file: `let` reassignment (`E`), a wrong argument label (`H`), a missing `Comparable`
conformance (`C`), a wrong argument type (`G`), an unhandled `throws` (`F`), a mismatched initializer
type (`A`), an unknown symbol (`B`), and a mismatched return type (`D`).

Two other things it holds, both load-bearing:

- **`error: emit-module command failed with exit code 1 (use -v to see invocation)`**, on a line of its
  own with no path in front of it. That is the driver reporting its own subcommand's exit status, and
  read as a ninth error it makes the capture's headline `9 errors · 9 signatures` over eight mistakes. `swift-test-linkerror.txt` carries the same
  shape as `error: link command failed …`, with `clang: error: linker command failed …` beside it,
  which is the line that must *keep* being read as a diagnostic.
- **Eleven `error:` headers deduplicating to nine diagnostics**: `A.swift` and `C.swift` are each
  printed twice, once emitting the module and once compiling the file, which is the same deduplication
  `xcodebuild-build-failure-dup.txt` covers for the other build system.

How it was taken:

```sh
swift build > capture.txt 2>&1   # exit 1
```

**Edit made**: the scratch directory the package was built in became `/Users/dev/Motley`, and
the builder's home directory → `/Users/dev` everywhere else, as above. Nothing else — the ordering (which is
the driver's, not the files'), the source snippets under each error and the `note:` candidates the
`Comparable` failure drags in are as `swift build` printed them.

## Colour, and a quiet `xcodebuild`

Seven captures, from one throwaway SwiftPM package built for them — **Pallet**: one library target
`Pallet` holding `count()`, one test target `PalletTests` holding a single `@Test` that expects the
wrong number. macOS 27.0, Xcode 27.0, Swift 6.4, Swift Testing 2084.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-build-colored-warning.txt` | `swift build` | 0 | A colour-wrapped warning on an otherwise clean build |
| `swift-build-colored-failure.txt` | `swift build` | 1 | A colour-wrapped `cannot find … in scope` |
| `swift-test-colored-warning-and-failure.txt` | `swift test` | 1 | The same colour, ahead of a plain-text Swift Testing failure |
| `xcodebuild-quiet-build-success.txt` | `xcodebuild … build -quiet` | 0 | A clean `-quiet` build that prints no verdict at all |
| `xcodebuild-quiet-test-success.txt` | `xcodebuild … test -quiet` | 0 | The same silence for the `test` action |
| `xcodebuild-quiet-build-success-with-warning.txt` | `xcodebuild … build -quiet` | 0 | The same silence, with `-quiet`'s own `error: the following command failed with exit code 0 …` beside a real warning |
| `xcodebuild-quiet-build-failure.txt` | `xcodebuild … build -quiet` | 65 | The same noise line in front of a real error, on a build that actually failed |

**Why these exist.** The captures already in this directory were all taken on macOS 26.6/Xcode 26.6 and
carry no ANSI escape at all — measured, not assumed, across every `.txt` file here before these seven were
added. Swift 6.4's SwiftPM colours a compiler diagnostic even when stdout is a pipe, which the older
toolchain did not do, so nothing in the existing corpus could have caught `RunOutputFilter` failing to
strip it. `xcodebuild` itself was checked under the same conditions — piped, no `-quiet` — and colours
nothing, on this toolchain or the one the rest of the corpus was captured on; that finding has no capture
of its own; it is the absence of one.

**How they were taken.**

```sh
swift build                                                  # capture 1: one unused local, no error
# Sources/Pallet/Pallet.swift changed to return an undefined name
swift build                                                  # capture 2: exit 1
swift test                                                   # capture 3: the unused local restored, the test's own expectation wrong
xcodebuild -scheme Pallet-Package -destination 'platform=macOS' \
    -derivedDataPath <dir> build -quiet                      # captures 4 and 6 (clean, then with the warning restored)
xcodebuild -scheme Pallet-Package -destination 'platform=macOS' \
    -derivedDataPath <dir> test -quiet                       # capture 5
xcodebuild -scheme Pallet-Package -destination 'platform=macOS' \
    -derivedDataPath <dir> build -quiet                      # capture 7: the undefined name restored
```

`xcodebuild` builds a bare SwiftPM package (no `.xcodeproj`, unlike this directory's other `xcodebuild`
captures) through the scheme SwiftPM synthesises for it, `Pallet-Package`; `-derivedDataPath` names a
directory beside the package rather than the default under `~/Library/Developer/Xcode/DerivedData`, which
is why none of the seven carries a DerivedData hash to placeholder.

**The `-quiet` noise line is real and reproducible, not a fixture typo.** `xcodebuild -quiet` prints
`error: the following command failed with exit code N but produced no further output` — with `N` **0** on
a build that went on to succeed — ahead of a real diagnostic when there is one, and alone when there is
none. It is `-quiet`'s own heuristic misreading a subcommand that merely wrote to stderr (a warning is
enough), never a diagnostic the subcommand wrote itself, and every capture that carries it is included
specifically to pin that a reader must not count it: `xcodebuild-quiet-build-success-with-warning.txt`
where exit is 0 (so the line's own claim of failure is self-contradicting), and
`xcodebuild-quiet-build-failure.txt` where the build genuinely failed and the line sits directly above the
error that explains why.

**Edits made.** The scratch directory the package was built in became `/Users/dev/Pallet`, and the
builder's home directory → `/Users/dev` everywhere else, as everywhere in this file; the hardware
identifier on each `xcodebuild` destination line is the placeholder of item 3 at the top; and the clock is
shifted as item 3 describes — `xcodebuild`'s own log-line stamps in the four `-quiet` captures and the
`Test Suite 'All tests' started at` / `passed at` pair in `swift-test-colored-warning-and-failure.txt`, each
capture moved by one whole-second shift that puts its first timestamp at `2000-01-01 12:00:00`, milliseconds
and intervals as printed. Nothing else — every escape byte, every progress glyph and every wording is as the
tools printed it.

## The same link error, a newer toolchain

One more capture, from the same throwaway **Widget** package `swift-test-linkerror.txt` was built from —
same library target, same missing `_widget_missing_helper` symbol — rebuilt against a newer toolchain:
`swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`, target
`arm64-apple-macosx27.0.0`.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-linkerror-6.4.txt` | `swift test` | 1 | Swift 6.4 closes the same link failure on `error: Build failed` then `error: fatalError`, not `fatalError` alone |

**Why it exists.** `swift-test-linkerror.txt` was captured under an older toolchain (macOS 26.6.1) and
closes its `Undefined symbols` block on a bare `error: fatalError`, with no `error: Build failed` printed
anywhere near it — which is why `RunDiagnostic`'s doc comment and Design.md once said the `fatalError`
shape came "with no `Build failed` beside it", stated as if that were true of the shape rather than of
one capture. Rebuilding the identical failure under Swift 6.4 shows the two lines together: the driver's
native build system prints its own `error: Ld … failed with a nonzero exit code. Command line: …` (the
shape `RunDiagnostic.namesAFailedSubcommand` already recognised from `Docs/Design.md`'s Swift 6.4
`SwiftCompile` capture), then closes on `error: Build failed` immediately followed by `error: fatalError`.
Both bare literals are dropped independently of each other, so neither capture is wrong — a toolchain is
free to print `fatalError` with `Build failed` beside it or without, and the filter has to drop each one
on its own terms rather than on whether its neighbour happens to be there.

**It also pins the linker block's closing line in a new spelling.** SwiftPM 6.4 prefixes the subprocess
diagnostic with the package manifest path and the product name —
`/Users/dev/Widget/Package.swift: WidgetTests-product: clang: error: linker command failed with exit code 1
(use -v to see invocation)` — where the older capture has the bare `clang: error: linker command failed …`.
`continueLinkerBlock` reads both forms as the block's closing line, so this capture reduces to one error
too, the `Undefined symbols` block; before it read the prefixed form, that line closed the block early and
survived as a second error of its own.

How it was taken: a throwaway SwiftPM package (`Widget`/`WidgetTests`, one library target declaring an
`@_silgen_name` function with no definition, one test target calling it) built with `swift test` under the
toolchain named above; exit 1.

**Edits made**: the package root — the builder's home directory plus the scratch path the package was
built in — became `/Users/dev/Widget`, exactly as in `swift-test-linkerror.txt`. Nothing else: every
progress counter, the linker's warning, the `Undefined symbols` block and the closing pair of `error:`
lines are as `swift test` printed them.

## A test plan that retries, and both frameworks' spellings of a second attempt

One capture, from `ValidationProjects/TestDemo` — **this repository's own generic sample iOS project**,
committed here in the open, generated with `xcodegen generate` and run on an iOS 27.0 simulator. macOS 27.0,
Xcode 27.0 (27A266a), 17 Sep 2026.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-retry-iterations.txt` | 93 | 0 | The two spellings of a retried test's start, and a duration on every finishing line |

Run as `xcodebuild test-without-building -testPlan Retrying -only-testing:DemoUnitTests …`, whose plan
repeats a failing test up to three times. It is the only capture here that carries either repeat
spelling:

```
Test Case '-[DemoUnitTests.CalculatorTests testFailsOnce]' started (Iteration 2 of 3).
◇ Test aKnownFormattingIssuePasses() started (repetition 2).
```

**The Swift Testing line is the defect it is here to catch.** A reader asking for `started.` exactly
counts the first attempt at a repeated test and silently none of the rest, so a transcript showing three
runs of one test reports one — and a timing taken from that run is charged the retries.

**Edits made**: the worktree the project was built in became `/Users/dev/Project`, so the paths in it
read `/Users/dev/Project/ValidationProjects/TestDemo/…`; the capture's date and clock became
`2000-01-01 12:00:00` and `2000-01-01 12:10:00`, each line keeping its own milliseconds, as in every
capture above; and the simulator's UDID became all zeroes. Nothing else — no line was added, removed or
reordered, the two process ids are as the tools printed them, and so are the zero-width spaces, the
glyphs and every count.

## A test target whose module name is not its target name

One capture, from the same project as the one above — `ValidationProjects/TestDemo`, **this
repository's own generic sample iOS project**, committed here in the open, generated with `xcodegen
generate` and run on an iOS 27.0 simulator. macOS 27.0, Xcode 27.0 (27A266a), 17 Sep 2026.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-test-underscored-module.txt` | 31 | 0 | A class logged under `Demo_Spaced_Tests` for a target the enumeration spells `Demo Spaced Tests` |

Run as `xcodebuild test-without-building -xctestrun … '-only-testing:Demo Spaced Tests/SpacedTests/…'`,
one `-only-testing:` per test, which is the shape a shard is run in. The bundle is `Demo Spaced Tests`,
whose name is not a Swift identifier, so Xcode's derived `PRODUCT_MODULE_NAME` is not its name — and the
capture carries both spellings, four lines apart:

```
Test Suite 'Demo Spaced Tests.xctest' started at 2000-01-01 12:00:00.802.
Test Case '-[Demo_Spaced_Tests.SpacedTests testCountsDown]' started.
```

**The underscored spelling is the defect it is here to catch.** Reconciliation compares a log name's
qualifier against the target name the enumeration printed, so every test of such a bundle reads as
*missing* over a run that passed — a green run reported as a broken one, which is worse than the
silence it exists to break.

**Edits made**: the builder's home directory became `/Users/dev`, so the result-bundle path reads
`/Users/dev/Library/Developer/Xcode/DerivedData/…` (this run passed no `-derivedDataPath`, so the
result bundle landed in the default location); that path's `TestDemo-…` component, the hash Xcode
derives from the project's absolute path on the capturing machine, became the `x` placeholder of the
same length every capture here uses for one; the capture's
date and clock became `2000-01-01 12:00:00`, each line keeping its own milliseconds, as in every capture
above, the result bundle's own name following the same clock; and the simulator's UDID, in the
invocation line, became all zeroes. Nothing else — no line was added, removed or reordered, the process ids are as the tools printed
them, and so are the tabs, the counts and both spellings of the bundle.

## A crash that restarts the runner, and a closing tally that reads green over it

One capture, from the same project as the one above — `ValidationProjects/TestDemo`, **this
repository's own generic sample iOS project**, committed here in the open and run on an iOS 27.0
simulator with its unit bundle's crash trigger armed. macOS 27.0, Xcode 27.0 (27A266a), 17 Sep 2026.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-crash-restart.txt` | 95 | 65 | A test that starts and never ends, and a closing `Executed 5 tests … 0 failures` that covers the relaunch alone |

`testAddition`, `testDivision` and `testFailsOnce` pass; `testMultiplyCrashesWhenTriggered` starts, hits
a `Fatal error` and never reports an ending of any kind. `xcodebuild` relaunches the runner, and the
rest of the bundle runs under the new process:

```
Test Case '-[DemoUnitTests.CalculatorTests testMultiplyCrashesWhenTriggered]' started.
DemoUnitTests/CalculatorTests.swift:28: Fatal error: boom

Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
```

**The closing tally is the defect this capture is here to catch.** `Executed 5 tests, with 1 test
skipped and 0 failures (0 unexpected)` closes the run, and those five are the relaunch's own — not the
tests that ran before the crash, and not the one that crashed. The restart line promises the opposite
("summary will include totals from previous launches"), so a reader believing the tally reports a green
run over a test nobody ran to the end. Only the expected set says otherwise, which is why a sharded
run's counts are reconciled against it rather than read off whatever a log's last line claimed.

**Edits made**: the worktree the project was built in became `/Users/dev/Project`; the capture's date
became `2000-01-01`, and its two clocks — `12:45` and, after the diagnostics timeout, `12:55` — became
`12:00` and `12:10`, each line keeping its own seconds and milliseconds, as in every capture above; and
the simulator's UDID became all zeroes. Nothing else — no line was added, removed or reordered, the
process ids are as the tools printed them, and so are the zero-width spaces, the glyphs and every count.

---
## What `xcodebuild` says the tests are

The one capture here that is not a transcript. `xcodebuild test-without-building -xctestrun … -destination
… -enumerate-tests -test-enumeration-style flat -test-enumeration-format json
-test-enumeration-output-path …` writes a JSON document rather than printing lines, and that document is
the **expected set** a sharded run reconciles its counts against — so it is read from a real capture for
the same reason every transcript here is.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-enumerate-tests.json` | `xcodebuild test-without-building -xctestrun … -enumerate-tests …` | 0 | One plan's enumerated tests, both frameworks spelled the same way |

How it was taken: `TestDemo`, the iOS validation project under `ValidationProjects/`, built with
`build-for-testing` for an iOS 27.0 simulator on Xcode 27.0 (17 Sep 2026) and then enumerated against
`TestDemo_Default_iphonesimulator27.0-arm64.xctestrun`; the run enumerates in about 7 s and runs no test.
`ValidationProjects/README.md` records the same measurements under *Measured behaviour*.

**What it pins.** Every framework is spelled `Target/Type/function()` — `DemoUnitTests/CalculatorTests/testAddition()`
for an `XCTestCase` method and `DemoUnitTests/MathSuite/addsTwoNumbers()` for a Swift Testing function —
so an identifier does not say which framework declared it, which is why `TestNameMatch` asks the log
instead. A parameterised test is one entry, `DemoUnitTests/MathSuite/doublingIsEven(_:)`, with its
argument labels as declared. `errors` is empty and `disabledTests` is empty; the `.disabled` Swift Testing
test in the same plan is listed as *enabled*, because switching it off is a run-time decision rather than
an exclusion the plan carries.

**Edits made**: rows were removed and nothing else. The capture listed 36 tests across three targets; six
are kept — one from each target, both frameworks, an XCTest method that skips, and the parameterised
entry — in the order the capture listed them. No key was added, removed or reordered, no identifier was
rewritten, and the formatting is the document's own, down to the space before each colon and the blank
line inside an empty array. Nothing here names the capturing machine: the document carries no paths,
no clock times and no machine identifiers at all.

---

## Failed `contains`, `hasPrefix` and `hasSuffix` over a multi-line haystack

One capture from a throwaway SwiftPM package, **P**, built for it in a gitignored build directory: one
library target and one test target of six `@Test`s, every one failing. macOS 27.0, Swift 6.4, Swift
Testing 2084, exit **1**.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-contains.txt` | 72 | 1 | How Swift Testing prints a string operand with real newlines in it |

```swift
#expect(reason.contains("truncated: 10 more member lines — pass offset: 60"))
```

`probe()` is that expectation over a three-line haystack whose second line nearly matches; `long()` puts
the near match on the ninth line, past the three a note keeps; `nothing()` shares no text with its
haystack; `prefix()` and `suffix()` are `hasPrefix` and `hasSuffix`; and `variable()` passes the needle
as a variable rather than a literal. The haystack is not printed inside the message: it is the
`↳   reason → "…` line beneath it, whose value runs on across indented lines until the one that closes
the quote, and a variable needle gets a `↳   needle → "…"` line of its own.

**Edits made**: the run prints no absolute paths and names no machine; the clock is synthetic as in
item 3.

A second capture from the same package, its test file replaced by five failing `@Test`s, on the same
toolchain, exit **1**:

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-contains-blank.txt` | 59 | 1 | A blank line and a quoted line inside a printed value, and output a test printed after its failure |

`blank()` and `single()` put an empty line inside the haystack, after two lines and after one, and
Swift Testing prints it as an indented line with nothing on it; `quoted()` has a haystack line ending
in `"k"`, which reads like the quote that closes the value; `detail()` is a comment whose indented
detail has a blank line inside; and `gap()` prints an empty line and an indented line after its
failure, which arrive beneath another test's value.

**Edits made**: the clock, as above.

## A parameterized argument with a newline in it

One capture from a throwaway SwiftPM package, **Kettle**, built for it in a gitignored build directory:
one library target and one test target of two `@Test`s, both failing. macOS 27.0, Swift Testing 2084,
exit **1**.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-newline-argument.txt` | 42 | 1 | A parameterized case's `recorded an issue` line broken across two lines by its argument's value |

`steeps(leaf:)` runs over `["a\nb", "c"]` and fails for both; `boils()` is an ordinary failure. Swift
Testing prints the argument as it is, so the first case's issue line ends in `leaf → "a` and its
location arrives on the next line, `b" at KettleTests.swift:6:5: …`. The run tallies three issues.

**Edits made**: the clock, as above.

## A tally inside a failure's note

One capture from a throwaway SwiftPM package, **Noted**, built for it in a gitignored build directory:
one library target holding a single `String`, and one test target of two `@Test`s, one failing and one
passing. macOS 27.0, Swift 6.4, Swift Testing 2084, exit **1**.

| Fixture | Lines | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-noted-tally.txt` | 34 | 1 | A failure's **`↳` note** with a run tally at the start of one of its indented lines |

The failing test is `#expect(Noted.answer == "ok", comment)`, where the comment is three lines:

```
the answer read:
Test run with 2 tests in 0 suites failed after 0.001 seconds with 3 issues.
totals: 3 failures
```

Swift Testing prints the comment's first line after `↳` and each later line indented beneath it, so the
quoted tally opens an indented line of the note; the run's own tally, one line from the end, says
`with 1 issue.`

**Edits made**: the clock, as above.

## A counter and a test's ending inside a failure's note

Two captures of one throwaway SwiftPM package, **Noted** again, built in a gitignored `.build/` directory
of a worktree of this repository and deleted afterwards: the same one-`String` library, and two test
targets. `AlphaTests` holds an `XCTestCase` `LegacyTests` that fails, `quotesACount()` and
`quotesAnEnding()` that fail with a multi-line comment, and `anOrdinaryPass()`. `BetaTests` holds the same
failing `LegacyTests` and `printsAnAnswerInItsNote()`, which fails with a three-line comment. macOS 27.0,
Swift 6.4, Xcode 27.0, Swift Testing 2084.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-noted-shapes.txt` | `swift test` | 1 | An XCTest counter and two tests' endings at the start of indented lines inside failures' notes |
| `xcodebuild-test-noted-shapes.txt` | `xcodebuild test-without-building -scheme Noted-Package -destination platform=macOS -parallel-testing-enabled NO` | 65 | The same, and `BetaTests`' noted failure followed by the `AlphaTests` process and its real, tab-indented counters |

The comments are `"head\n  Executed 3 tests, with 2 failures (0 unexpected) in 0.100 (0.100) seconds\ntail"`
and `"head\n  Test ghost() failed after 0.001 seconds with 1 issue.\n  Test phantom() passed after 0.001
seconds.\ntail"`. Swift Testing prints every line of a comment after the first behind two spaces, so the
quoted lines open on four; XCTest's own counters open on a tab and follow a `Test Suite '…' failed at`
line, in these captures as in every other one here. `xcodebuild` runs both frameworks one bundle at a
time, `swift test` every XCTest process before any Swift Testing one. With parallel testing on,
`xcodebuild` printed no note at all, so there is no parallel capture.

**Edits made**: the scratch directory the package was built in became `/Users/dev/Noted` and the
builder's home directory `/Users/dev`; the Mac's hardware identifier, object addresses and the clock are
the placeholders of item 3 at the top.

## A selector that matched nothing

Two runs that named their tests and ran none of them, and both tools call that a success.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-no-match.txt` | `swift test --filter <a pattern no test carries>` | 0 | A real capture: the build, then `warning: No matching test cases were run`, and no test process at all |
| `swift-test-zero-tests.txt` | `swift test` | 0 | A real capture: a package (`Gadget`) whose one test target holds `import Testing` and a helper, no test — XCTest's `Executed 0 tests` and Swift Testing's `Test run with 0 tests in 0 suites passed`; captured on Xcode 27.0 in a throwaway package under `~/Library/Caches`, deleted afterwards, nothing edited |
| `xcodebuild-test-no-match.txt` | `xcodebuild -scheme Gadget-Package -destination platform=macOS test -only-testing:GadgetTests/Modern/aTrendIsRead` | 0 | A real capture: an XCTest `Executed 0 tests` counter for the bundle, then Swift Testing's own `Suite "Modern"` starting and passing with none, and `** TEST SUCCEEDED **` |

`swift-test-no-match.txt` was captured from this repository's own package on a warm build; it prints no
path, no name and no clock, so nothing in it was edited. `xcodebuild-test-no-match.txt` was captured on
Xcode 27.0 from the same throwaway `Gadget` package as the parallel captures below, through its
`Gadget-Package` scheme, non-parallel, naming `Modern/aTrendIsRead` — the same Swift Testing function
without its trailing `()` — after a warm `build-for-testing` so the log carries only the residual build
steps rather than a full compile. `xcodebuild` still starts and passes the `GadgetTests.xctest` bundle
with `Executed 0 tests`, since `-only-testing:` restricted it to nothing, and then Swift Testing prints
its own run: `Suite "Modern" started`, `passed`, and `Test run with 0 tests in 1 suite passed`, which is
not the shape this file was built to stand in for (no `Suite "Modern"` banner) but is what a real,
non-parallel run actually prints. **Edits made**: the scratch path to `/Users/dev/Gadget`, the hardware
identifier to zeros, the clock and the result-bundle stamp to 2000-01-01, and the two object addresses to
`0x600000000000`.

And one run that named its test and did run it, whose log still carries no count of it:

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-parallel-filter-pass.txt` | `swift test --filter testGamma --parallel` | 0 | A real capture: the build, then `[1/1] Testing GadgetTests.LegacyTests/testGamma` and nothing else — no outcome, no count, which is silence and not a zero |

Captured from a throwaway package (one target, one `XCTestCase` with one passing test) on a warm build;
it prints no path and no clock, so nothing in it was edited.

Two more selected runs under `xcodebuild`'s parallel testing, both exiting 0 over `** TEST EXECUTE
SUCCEEDED **`:

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-parallel-test-no-match.txt` | `xcodebuild -scheme Gadget-Package -destination platform=macOS -parallel-testing-enabled YES test-without-building -only-testing:GadgetTests/Legacy/testNope` | 0 | A real capture: `Test suite 'Legacy' started on 'My Mac - xctest (…)'` and no `Test case '…' on` line — a runner that started and ran nothing, which is a zero |
| `xcodebuild-parallel-test-unparenthesised.txt` | the same, with `-only-testing:GadgetTests/Modern/aTrendIsRead` (a Swift Testing function without its `()`) | 0 | A real capture: the verdict and `Testing started`, with no suite line at all — a printed banner over no test line from a non-quiet `xcodebuild`, which prints a line for every test it runs, so it is a zero too |

Captured on Xcode 26.6 from a throwaway SwiftPM package (`Gadget`: one `@Test` function in a suite
`Modern`, one `XCTestCase` `Legacy` with `testGamma`) through its `Gadget-Package` scheme, in a
gitignored `.build/` scratch directory of a worktree of this repository and deleted afterwards. The same
package's passing run of `-only-testing:GadgetTests/Legacy/testGamma` printed the suite's start and then
`Test case 'Legacy.testGamma()' passed on 'My Mac - xctest (…)' (0.001 seconds)`; those two lines are
quoted inline in `RunTestSelectorTests`. The Swift Testing function without `()` printed no suite line on
four runs of four, where a review on another machine saw `Test suite 'Modern' started on …`, which the
suite-start rule covers. **Edits made**: the scratch paths to `/Users/dev/Gadget`, the clock and the
result-bundle stamp to 2000-01-01, the device id to zeros and object addresses to `0x600000000000`.

## A filter that selects only `XCTestCase` tests

Two runs where `swift test --filter` matched only XCTest tests, so SwiftPM started no Swift Testing
process at all, and each XCTest process opened on `Test Suite 'Selected tests'` rather than `'All tests'`.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-xctest-filter-skipped.txt` | `swift test --filter XT/testSkipsOutright` | 0 | A real capture: one test that throws `XCTSkip`, closing on `Executed 1 test, with 1 test skipped and 0 failures` |
| `swift-test-xctest-filter-two-bundles.txt` | `swift test --filter XT` | 0 | A real capture: two test targets, each its own `'Selected tests'` process and counter |

Captured with Swift 6.4 from a throwaway package (`Gadget`: test target `GadgetTests` with an `XCTestCase`
`XT` holding `testOne` and `testSkipsOutright`, a second target `BetaTests` with `XT2`), built in this
session's scratch directory and deleted afterwards; the skipped capture predates `testOne` and
`BetaTests`. SwiftPM's `[n / m]` build-progress lines were dropped. **Edits made**: the scratch path
to `/Users/dev/Gadget`, the clock to 2000-01-01 12:00:00, and the names to ones `Distribution/example-names.txt`
permits — so the second bundle's two tests no longer stand in the alphabetical order XCTest ran them in.

## No capture here came from a real project

Every file in this directory is a capture of a throwaway package built for it, in a scratch directory
outside any repository — with one exception that is safer still: `xcodebuild-retry-iterations.txt`
comes from `ValidationProjects/TestDemo`, a sample project committed in this repository, so every name
in it is already public here. Nothing here was taken from an application anybody ships, and nothing here
names one. **Identifier substitution cannot make a real application's capture safe to publish, because
prose is most of what a Swift Testing transcript carries** — source comments as `↳` lines, test
filenames, UI wording — and recognisable prose has no fixed vocabulary to match. Nor can a name be
pseudonymised in place: that makes the file a hand-edited transcript claiming to be a real one, which is
the property this directory cannot trade away for any amount of convenience. A capture that would need
either is taken again from a package built for it.

The only edits made to any capture here are the substitutions listed at the top: what names the
capturing machine becomes a stand-in. Each scratch package root became `/Users/dev/<Package>`, the
builder's home directory became `/Users/dev`, and machine identifiers and clock times became
placeholders. Nothing structural was touched — line counts, ordering, interleaving,
exit codes, the zero-width spaces, the glyphs and every diagnostic's shape are as the tools printed
them, which is the only property the tests depend on.

## A selected run whose tests did not compile

Two captures of one failure, from a throwaway **Widget** package (library `Widget`, test target
`WidgetTests` holding a Swift Testing suite and an `XCTestCase`) whose Swift Testing suite calls a method
the library does not declare. macOS 27.0, Xcode 27.0 (27A266a), Swift 6.4
(`swiftlang-6.4.0.34.1`).

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-filter-compile-error.txt` | `swift test --filter …` | 1 | A filtered run whose build failed before any test process started: the exit a failing test gives too |
| `xcodebuild-test-only-testing-compile-error.txt` | `xcodebuild -scheme Widget -destination platform=macOS -derivedDataPath … test -only-testing:…` | 65 | The same under `xcodebuild`, run on the package directly: `Testing cancelled because the build failed.` over `** TEST FAILED **` |

**Why they exist.** Passed through, both exits read as a test that failed, so a negative gate took a
compile error for its proof. `RunTestSelector.didNotBuild` reads them as a build that failed before any
test ran, and `sift run` exits 5 for them instead.

**Edits made**, by the rules at the head of this file: the package root became `/Users/dev/Widget` and the
scratch directory holding it, the `-derivedDataPath` included, `/Users/dev`; the Mac's hardware
identifier on the destination lines is `id:00000000-0000000000000000`; and the `xcodebuild` capture's
clock is moved to start at `2000-01-01 12:00:00`, its result-bundle name carrying `+0000`. Nothing else:
the ANSI colouring SwiftPM put on the compiler diagnostic, every progress counter and the closing
`error: Build failed` and `error: fatalError` are as printed.

## A compile error inside a macro expansion

Two captures of one failure, from a throwaway **Widget** package (library `Widget` declaring a throwing
computed property, test target `WidgetTests` reading it inside `#require(...)` without `try`, once on its
own and once nested in `#expect(try #require(...) == 4)`). macOS 27.0, Swift 6.4
(`swiftlang-6.4.0.34.1`).

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-macro-expansion-error.txt` | `swift test` | 1 | The default diagnostic style: each error is located at `macro expansion #require:1:54`, and the `` `- <file>:<line>:<col>: note: expanded code originates here`` beneath it names the source line, the outermost one for the nested expansion too. Both errors print the same buffer location and sentence |
| `swift-test-macro-expansion-error-llvm.txt` | `swift test -Xswiftc -diagnostic-style=llvm` | 1 | The LLVM style: each error is located in a generated `@__swiftmacro_….swift`, with one `note: in expansion of macro '…' here` per level beneath it, innermost first — the nested one's first note names the `#expect` expansion's buffer, its second the source line |

**Edits made**, by the rules at the head of this file: the package root became `/Users/dev/Widget` and the
scratch directory holding it `/Users/dev`, and the per-user temporary directory holding the generated
macro buffers `/var/folders/00/0000000000000000000000000000gn`. Nothing else: the ANSI colouring, the
source excerpts, the frontend command and the closing `error: Build failed` and `error: fatalError` are
as printed.

## Two build failures with no compiler error at a `file:line` at all, and one real failure that reads like one

Three files, **constructed, not captured**. Each stands in for a real
capture too costly to make safe for this directory the way a genuine signing failure or a `-quiet`
Swift Testing failure would be (a real developer-team identifier, a real device in the destination
line), until one replaces it.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-test-signing-failure.txt` | `xcodebuild -scheme Widget -destination platform=macOS -derivedDataPath … test -only-testing:WidgetTests` | 65 | A build failure with no `file:line`: `error: Signing for "WidgetTests" requires a development team…`, over `Testing cancelled because the build failed.` and `** TEST FAILED **` |
| `xcodebuild-test-missing-input-file.txt` | the same | 65 | The other shape with no `file:line`: `error: Build input file cannot be found: '…'`, over the same two closing lines |
| `xcodebuild-test-quiet-real-failure.txt` | `xcodebuild … test -only-testing:WidgetTests -quiet` | 65 | A real test failure under `-quiet`, whose own failure line (`FooTests.swift:8: error: aTestThatFailed(): …`) reads exactly like a compiler error at a `file:line`, but is followed by `Failing tests:` — printed only once a named test actually ran and failed — then `** TEST FAILED **` |

They are assembled from the shape the two real `xcodebuild-test-*` captures above already establish
(the command-line invocation header, a body line, the two closing lines), trimmed to the few lines each
one is here to test: the first two carry no compiler diagnostic with a path and a line at all, so
`RunTestSelector.didNotBuild` has nothing else to key on but `Testing cancelled because the build
failed.`; the third carries one, so it stands in for the false positive that line alone would cause without
the `Failing tests:` veto. No path in any of them is a real one — `/Users/dev/Widget` is the placeholder
already used throughout this file — and no clock, machine identifier or device name is in them to
substitute.

---

## The compiler's own timings

`swift-build-debug-time.txt` is a clean `swift build` of a throwaway SwiftPM package, **Widget** (one
executable target, two files, a `Ledger` struct written to hold the three expression shapes known to
type-check slowly: a long chain of mixed numeric literals, a nested ternary chain and an unannotated
array literal in a stored property, plus a top-level `outer()` holding a local function `inner()`, to
capture the compiler double-printing a local function's body time inside its enclosing body's own line).
Captured on macOS 27.0, Swift 6.4 (swiftlang-6.4.0.34.1), with:

```sh
swift build --build-system native --scratch-path .build/sift-timing \
  -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies \
  -Xswiftc -Xfrontend -Xswiftc -debug-time-expression-type-checking
```

Exit 0. The one edit is the package root, which became `/Users/dev/Widget`. `--build-system native`
is load-bearing: the default build system of this toolchain prints none of the timing lines on a
successful build, and under `-v` prints them glued to the end of an echoed command line.

Re-captured on the same toolchain to add `outer()`/`inner()`: a local function's body line carries a
third, tab-separated field spelled exactly `local function Widget.(file).outer().inner()@<path>:<line>:<col>`
(the enclosing function's own line reads `global function Widget.(file).outer()@...`), which is how
`BuildTimingAnalysis` tells a nested body apart from a top-level one and names it.

`swift-build-tests-debug-time-macros.txt` is the raw log `sift build --analyse --build-tests` kept for another
throwaway **Widget** package (a library target `Widget` holding a `Ledger` struct, and a test target
`WidgetTests` with one Swift Testing `@Test` function asserting with two `#expect`), so the build is the exact
command `sift` runs (`--build-tests --build-system native --scratch-path .build/sift-timing` and the two timing
flags). Captured on macOS 27.0.1, `swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1
clang-2100.3.34.1)`. Exit 0. It is here for the 25 timing lines whose location is a macro expansion's
generated buffer, printed as a bare, relative `@__swiftmacro_….swift:<line>:<col>` — the attached `@Test`
peer's buffer, named after the declaration, and the freestanding `#expect`/`#_sourceLocation` buffers, named
after the module, file and position of the expansion — beside the source file's own line for each expanding
expression. The one edit is the package root, which became `/Users/dev/Widget`.

---

## A fix-it printed as a struct dump

`swift-build-fixit-6.4.txt` is a `swift build` of a throwaway SwiftPM package, **Widget** (a library target
`Widget` and a test target `WidgetTests`), whose one struct declares a method without the `func` keyword.
Captured on macOS 27.0, `swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1
clang-2100.3.34.1)`, target `arm64-apple-macosx27.0.0`, with the default build system. Exit 1.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-build-fixit-6.4.txt` | `swift build` | 1 | The compiler's error closes on a `: FixIt(sourceRange: …)` struct dump running to the end of the line, which the answer must not carry |

The edits are the package root, which became `/Users/dev/Widget`, and the directory holding it, which
became `/Users/dev` (it appears alone on the driver's `cd` line).

---

## Several filters, one of which matched nothing

`swift-test-filter-one-unmatched.txt` and `swift-test-filter-one-unmatched.jsonl` are one `swift test` of
this repository's own package, its console and the Swift Testing event stream it wrote beside it, taken on
a warm build with `--skip-build` so the console carries only the test run. Captured on macOS 27.0,
`swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`, with
the stream asked for as `sift run` asks for it (`--event-stream-output-path`, no version named). Exit 0.

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-filter-one-unmatched.txt`, `.jsonl` | `swift test --skip-build --event-stream-output-path <file> --filter aLogWithNoBannerIsNotAZero --filter <a pattern no test carries> --filter 'RunTotalsLineTests\.swift:35:'` | 0 | Three filters: one a function's name, one matching nothing, and one matching only a test's source location, which the stream's identifiers carry and the console never prints |

SwiftPM prints nothing about the filter that matched nothing, so the console is the same whatever that
pattern was, and the tests spell it `NothingLikeThis`. The one edit is the checkout's path in the stream's
`filePath` fields, which became `/Users/dev/Sift`.

## A test process that ends with no signal line, and trap text a passing test printed

Two captures from a throwaway two-target package, `PalletTests` (Swift Testing `stacks()`, `topples()`,
`zlifts()` and an `XCTestCase` with `testStacks`, `testBuckles`, `testLoads`) and `ToteStackTests` (Swift
Testing `loads()`, `racks()`), deleted after. `stacks()` and `testStacks` each print
`Shelf/Rack.swift:9: Fatal error: printed by a passing test`; `topples()` ends its process on a switch read
from the environment. macOS 27.0, Xcode 27.0, 2 Oct 2026.

| Fixture | Invocation | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-exit-st.txt`, `.jsonl` | `swift test --event-stream-output-path <file>`, `topples()` calling `exit(1)` | 1 | No signal line: `topples()` started and never finished in a Swift Testing process that printed no closing count |
| `swift-test-crash-st-lookalike.txt`, `.jsonl` | the same, `topples()` force-unwrapping `nil` | 1 | A real trap after a look-alike printed inside the crashed process and another in the XCTest process, and a stream declaring both bundles' tests |

The edits: the package's path became `/Users/dev/Pallet` in both files, SwiftPM's temporary stream path
on the signal line became `/Users/dev/Pallet/.build/st/event-stream-1-PalletTests.jsonl`, and the XCTest
timestamps became `2000-01-01 12:00:00`.

A third capture, from a one-target package (`Pallet` with `Pallet.load(_:)` force-unwrapping its argument, and
`PalletTests` holding Swift Testing `stacks()`, `topples()` and `zlifts()` only), deleted after. `stacks()` sleeps
20 ms and prints the same look-alike; `topples()` sleeps 20 ms and calls `Pallet.load(nil)`, so the two race.
macOS 27.0, Xcode 27.0, 2 Oct 2026 (#523).

| Fixture | Invocation | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-crash-st-lookalike-relayed.txt`, `.jsonl` | `swift test --skip-build --package-path <dir> --event-stream-output-path <file>` | 1 | The real trap at line 12, `stacks()`'s ending at 13, and its look-alike at 14: printed to standard output, it was relayed after its own test ended |

The same edits as the two above: the package's path became `/Users/dev/Pallet`, the stream path on the signal
line `/Users/dev/Pallet/.build/st/event-stream-1-PalletTests.jsonl`, and the XCTest timestamps
`2000-01-01 12:00:00`.

A fourth capture, from a one-target package (`PalletTests` holding Swift Testing `stacks()`, `topples()`, `loads()`
and `zlifts()`), deleted after. Three of them print `Shelf/Rack.swift:9: Fatal error: look-alike`, and `topples()`
calls `fatalError("real")` in its own body at `PalletTests/Stacking.swift:9`, so the real trap lands among the
look-alikes inside the crashed span. Run in parallel; in this capture the look-alike leads under the old order.
macOS 27.0, Xcode 27.0, 7 Oct 2026 (#523).

| Fixture | Invocation | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-crash-st-trap-in-test.txt`, `.jsonl` | `swift test --skip-build --package-path <dir> --event-stream-output-path <file>` | 1 | A trap raised in the crashed test's own body, behind look-alikes: the stream's unfinished tests and their declared source stretches put the real trap first |

The same edits as above: the package's path became `/Users/dev/Pallet`, the stream path on the signal line
`/Users/dev/Pallet/.build/st/event-stream-1-PalletTests.jsonl`, and the XCTest timestamps `2000-01-01 12:00:00`.
## Two failing tests sharing two signatures, one of them parameterised

The raw log `sift run -- swift test` kept for a throwaway one-target package, `Probe` (`judged(_:)` returning
its argument and `exitCode(_:)` its count), deleted after. `ProbeTests` holds two Swift Testing tests making
the same two failing expectations: `aSingleFilterIsNotJudged()`, and `anObjCRenamedXCTestIsNotJudged(patterns:)`
over three arguments, whose cases sleep 20 ms before the first expectation or 50 ms between the two, so the
cases reach the two signatures in different orders. macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4
(swiftlang-6.4.0.34.1), 7 Oct 2026 (#413).

| Fixture | Command | Exit | What it is here for |
| --- | --- | --- | --- |
| `swift-test-failure-groups.txt` | `swift test` | 1 | Eight failures, two signatures, both tests under each: the second signature's `also:` line named the plain test a second time, and the two example lines listed the three arguments in two different orders |

The one edit: the XCTest timestamps became `2000-01-01 12:00:00.000`.
## Result lines glued behind a test's own output under `xcodebuild`

One capture from a throwaway SwiftPM package, `Pallet`, driven by `xcodebuild test -scheme Pallet -destination
'platform=macOS' -derivedDataPath <dir> -resultBundlePath <bundle>` and deleted after. Its one test target,
`PalletTests`, holds two Swift Testing suites — `Crates` (`inner()`, `outer()`, `line()`, `partial()`, `stray()`,
`chatter()`, `cases(value:)` over four values, `labels(text:)` over two, `broken()` failing, `slow()`) and `Bays`
(`first()`, `second()`, `third()`, `range(index:)` over three, `fails()` failing) — and `LegacyTests` with
`testDoubling` and `testBuckles`. Several of them print without a newline (`print(…, terminator: "")`) or write
to standard error, so the framework's next line arrives glued behind that text. macOS 27.0.1 (26A434), Xcode
27.0 (27A266a), Swift 6.4 (`swiftlang-6.4.0.34.1`), 7 Oct 2026 (#559).

| Fixture | Invocation | Exit | What it is here for |
| --- | --- | --- | --- |
| `xcodebuild-test-glued-results.txt` | the command above, the first of six runs, every one of which glued at least one ending | 65 | XCTest's `testBuckles` ending glued behind `legacy`, Swift Testing's `third()` and `partial()` endings and `broken()`'s issue line glued behind printed text; the result bundle counted 15 passed and 2 failed |

The edits: the package's path became `/Users/dev/Pallet`, the DerivedData path `/Users/dev/DerivedData`, the
result bundle's directory `/Users/dev/Results`, the Mac's identifier `id:00000000-0000000000000000`, and every
timestamp moved by one whole-second shift to open at `2000-01-01 12:00:00`.
