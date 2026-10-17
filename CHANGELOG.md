# Changelog

## 0.1.7

- Fixed: a run outside any git repository says it is not inside one, and that the inventory is read from an index which needs one, where it said the inventory could not be read.
- Fixed: a failure's multi-line expectation keeps a `↳` comment holding an unmatched bracket as the note it is, with the comment's own lines beneath it, where the join read it as an expression and ran them together; and a blank line inside the expression no longer cuts the message, where it ended the join and dropped the rest.
- Fixed: digest and where over MCP at a revision name the file a basename matches as a tool call, digest target:"Sources/Gizmo/Gone.swift" at:"HEAD~1", where they spelled it for the command line (digest Sources/Gizmo/Gone.swift --at HEAD~1); a missed target holding --at <rev> is told to pass the revision as at: instead of being split into targets.
- Fixed: sift run closes on `verdict: <headline>` as the last line when accessibility device notes sit under the receipt, on every answer shape with or without a totals line and counted in the receipt's line total, where two or more notes pushed the verdict out of a `| tail -3`.
- Fixed: a failed run's dominant read no longer counts a Boolean the failure itself implies: a member name restating the whole expression's value (`isEmpty → false` under `x.isEmpty`) and the expression under a leading `!` or its member name (`x.isEmpty → true`, `isEmpty → true` under `!x.isEmpty`), where every failure of that shape tied or led the count on a value that says nothing; a Boolean read of any other subexpression still counts.
- Fixed: a failing test the console lost and the event stream recorded carries the stream's expectation and its expansion lines, so the "N of M failures read one and the same value" line counts it with the failures the console relayed, where it counted only the console's (178 of 212 for a run that read 200 of 212 with every line relayed).
- Fixed: where lists a function's calls in the files outside the build only where the whole written argument list can be the declaration's (a later label that differs, a missing required argument or one too many is left out, a defaulted parameter may be omitted and a trailing closure fills a closure parameter), and the callers answer counts calls only, so a same-named `func` or `case` declaration and a string literal spelling the name are left out (where it kept any call whose first argument fit), while `--refs` keeps both for a rename.
- Fixed: `where Gizmo` with no index store tells a body's own declaration of a typealias's name from a declaration the index holds by where each starts, where it matched them by line: a `Crate("t")` in a method of a type declaring `@available(*, deprecated)` above its own `typealias Crate = Other` is counted apart, where it was kept as not proven, and one inside a function declaring its own `Crate` on the line of the top-level `typealias Crate = Gizmo` is kept as not proven, where it was folded in.
- Fixed: `where Gizmo` with no index store folds in a nested `typealias Bin = Crate` below a supertype outside the index where every declaration of `Crate` is an alias of `Gizmo`, reaching the nearest one as it does for a single declaration, and one whose superclass declares `typealias Crate = Gizmo` reaches that one, where both were kept as not proven once two aliases shared the name.
- Fixed: `where Gizmo` with no index store keeps as not proven a `Crate("t")` written in a type, or an extension of it, that declares its own `typealias Crate = Other` only inside an `#if` clause, since a build leaving the clause out reads the top-level `typealias Crate = Gizmo` there, where it was counted apart; a type declaring its own `Crate` in every clause of an `#if` closed by `#else` still counts it apart. A type declared once per clause of an `#if`, one copy declaring its own `Crate`, now lists the use in a copy declaring none, and a call through a nested `typealias Bin = Crate` there, where both uses were counted apart and the call left out.
- Changed: sift affected walks from the declarations a diff touched in each changed file the store answers for, and from what in the same file reaches them, where it walked from every declaration of the file; the file's line says how many it touched, a file the comparison cannot account for is still walked whole and named, a removed or renamed declaration, or one whose signature changed, is followed to its call sites by its old name, a touched member is walked from what it overrides or implements as well, one witnessing a requirement declared outside the index (a library protocol's) from its type too, and one nothing references from its type; with no store the same walk covers every changed file, from the declarations the diff touched to their call sites as `where` finds them, where it name-matched every declaration of each.
- Fixed: sift affected seeds a file changed since the build from the declarations the diff touched when the only text it changed outside them is a comment, where it seeded the whole file and listed every test of its targets; and the after-edit walk names every file it seeded whole with its reason (a side not text or not parsing, text outside its declarations, a hunk no declaration explains, not in the index, a file-scope operator, nothing to scan for), where only files committed since the build were named.
- Changed: sift run --without names the set-aside's pathspecs in the answer's headline and the set-aside line only, and says "without the change" on every other line (a test's verdict, a guard's, the listing, the stragglers line, the raw-log labels), where it repeated the whole list on each one.
- Changed: sift flakes run inside a git work tree counts that repository's runs, where it counted every repository on the machine: --root defaults to the work tree's top level, the header says so and names --root / for every repository, and outside a repository nothing changes.
- Fixed: a cited line range of several declarations no longer serves a blank line past the end of the file, and its header names the type the lines share only where the lines lie within that type, where it counted the empty element after the final newline and named a type whose range a trailing comment fell outside.
- Fixed: sift run --root <dir> gives the command the logical path as $PWD, as after a shell cd (/tmp/x, where it gave /private/tmp/x); a relative directory is joined to the caller's own $PWD, and a path that does not name the directory the process stands in still falls back to the physical one.
- Fixed: sift run --without … --guard <name> matches a parameterised test, printed with its argument labels (aRunsWidget(count:label:)), by its bare name, where it answered that no test of that name ran.
- Added: sift run --root <dir> runs the command as if started in <dir> (its log, its proof and every check are that checkout's, as after a cd) without moving the caller's shell, where it refused --root and said to cd into the worktree; the agent guide says to pass --root to sift run as to the lookups.
- Changed: the Stop hook names the build it asks for bare where the context already stands in the directory it runs in, and otherwise as a subshell, (cd /path/to/checkout && sift run -- swift build), where it said to run it from that directory, and counts a sift run --root build or test, or one in a subshell that is the whole line, (cd <dir> && sift run -- …), as validating the checkout it names, and names no build where it cannot tell the directory the build ran in.
- Fixed: the scans over Swift Testing's expansion text (an inline expansion, a `↳` line, a merged note, the last member of an expression) skip a raw string literal whole, as they do a plain one, where they entered it at its inner quote and read a marker, a bracket or a dot inside it as structure.
- Fixed: a failure's string literal holding an interpolation that itself holds a literal is read whole when the dominant read looks for an expression's arrow or its operands, so an arrow or a parenthesis inside the interpolated literal is no longer taken for the expression's own, where the first inner quote closed the outer literal.
- Fixed: the "N of M failures read one and the same value" line keeps the read of a local named `some` or `none`, where the expectation writes that word bare (outside a string literal, not after a `.`) and the value shown is not a literal it also wrote, where it set the read aside as the wrapper Swift Testing labels an Optional's payload with; a local named `Optional` still loses its read.
- Changed: the line naming the one value most failures read leads with a value that most of the failures sharing it read as their subject (the left operand of a comparison), where a named constant on the expected side, printed under every failure, outranked it or tied with it and won on text; a constant that is the only value past the half still leads.
- Fixed: the value most failures read ignores another test's expansions printed inside a failure's block under a parallel run, where its unindented whole expression and the lines beneath it counted as that failure's own reads; the console now keeps each expansion line's depth, and the first unindented line after the failure's own whole expression ends its reads.
- Fixed: where with no index store counts a line writing two alias names a nearer declaration shadows once, under the first name in name order, where it counted it under each and printed a clause for both.
- Fixed: where with no index store folds in a typealias nested in a type that writes a name another module also declares at its top level, as Swift reads it, through its own module's declaration (Lib.Shelf.Bin = Gizmo is Lib.Gizmo's), where it kept the alias as a use not proven to name the type; an own declaration under #if, in a module guessed from the path or private to another file leaves it kept.
- Fixed: sift run --root .. from a symbolic-linked directory, and --root link/.., change into the logical parent as a shell cd does, where the process went to the physical parent; a path the logical form does not name as a directory still falls back to the argument as written.
- Fixed: `where Gizmo.init` with no index store reads an implied call in a single-expression closure by the closure's own written return type, or by the return type of the function type its binding is annotated with, where it read neither: `let make: () -> Crate = { … }` is a use through `typealias Crate = Gizmo`, and is dropped where a type local to the body is named `Crate`; a closure passed as an argument, or with several statements, is told as before.
- Fixed: `where` leaves an implied initializer untold where its enclosing function, subscript or computed property carries an attribute other than a compiler one (`@MainActor`, `@available`, `@discardableResult`, `@inlinable`, `@objc`, `@Sendable`, `@escaping`, `@usableFromInline`, `@nonobjc`, `@preconcurrency`, `@inline`), since a result builder decides its type, and a closure passed as a call argument is never read by its written return type; it read the declared type and dropped the use.
- Fixed: with no index store, `where Gizmo.init` reads an implied call under a parenthesised declared type, `(Gizmo)` or `((Gizmo))`, as a use of the type inside the parentheses, where it named the tuple and the use left every answer; a labelled one-element tuple or a tuple of several types is still no single type.
- Fixed: `where Gizmo.init` with no index store counts apart an implied `.init("c")` under an annotation naming `Crate` in a type declared in a function that declares its own `Crate`, where the type has no supertype, generic parameter or attribute and its members declare nothing of the name, since the name means the function's own `Crate` there, where it was kept as not proven; and a bare `Crate` naming a generic parameter of a declaration around it is kept as not proven, where one inside a function declaring its own `Crate` was counted apart.

## 0.1.6

- Changed: the agent guide says which commands take --root in a git worktree: the lookups do, and sift run, which runs in the current directory, does not.
- Fixed: sift run --without matches a display-named test, @Test("the widget keeps its heading"), to a set-aside file by its own text in the @Test attribute, never by the display name's last word, so a set-aside source declaring heading() no longer draws the note that the committed test ran.
- Fixed: digest of a cited range (Sources/App/Gizmo.swift:44-54) serves the doc comments inside it: two or more declarations within 60 lines come as the lines themselves under one header, and a declaration served alone starts at the first of its doc-comment lines the range covers.
- Added: sift run --without … --guard <test> names a test the proof expects to pass both ways; it is listed as a guard that held instead of as pinning nothing, and the run exits 0 when every other test pins and every guard holds.
- Fixed: where Gizmo.make with no index store drops Self.make(g) written inside Gizmo where every declared make is static and none takes those labels, where it kept it flagged as may be unapplied on Self.
- Fixed: where Gizmo.of with no index store counts the reasons a name-only reference was kept by line, as it counts the kept references, so two on one line no longer read as more reasons than references kept.
- Fixed: `where Gizmo.init` with no index store lists a call through a typealias of `Gizmo` only where the name means that alias: `Crate("t")` written inside a type or function that declares its own `Crate` is counted as dropped on the count line (`1 written as "Crate" bare inside a type that declares its own "Crate", which is what the name means there, dropped`) rather than folded in as a call of `Gizmo`, and one whose scope cannot be told is kept, worded as not proven to name it.
- Fixed: `where Gizmo` follows a typealias declared in a type that writes a bare name (`typealias Bin = Crate`) only where that name, looked up from the alias's own scope, means the alias of `Gizmo` it was folded through: inside a type that declares its own `Crate`, `Bin` names that one, so its uses are no longer folded in as written through a typealias naming `Gizmo` and its line no longer counts as declaring one; where the scope cannot tell, below a supertype outside the index, the alias is kept as a use though not proven to name it (`a typealias writing a name another declaration shares`).
- Fixed: `where Gizmo` with no index store folds in a use written through a typealias of `Gizmo` only where the name means that alias: `Crate("t")` written inside a type or function that declares its own `Crate` is counted apart on the count line (`1 more line writing "Crate" bare inside a type that declares its own "Crate", which is what the name means there, so not use`), and one whose scope cannot be told, behind a qualifier or below a supertype outside the index, is kept as a use though not proven to name it, where both were folded in as proven.
- Fixed: `sift run -- swift test` in a checkout with no sift index yet (a fresh git worktree) builds the index and prints the `inventory:` line, where it printed `inventory: not checked` and a gate had to run the suite again.
- Changed: a `sift run` answer with no `totals:` line (a build, a linter) that runs to three lines or more ends on `verdict: ` and its headline, just above `raw:`, so `| tail -3` keeps the verdict and the exit status.
- Fixed: `where Sprocket --at HEAD` and `digest Sprocket --at HEAD` name `Sprocket.swift` (`digest Sources/App/Sprocket.swift --at HEAD`) when nothing at that revision declares `Sprocket`, as the working-tree answers do.
- Fixed: a failing `#expect` whose expression holds a string literal with an arrow (`label == "a → b"`) has its evaluation merged into its message, where it was printed as a comment marked `(by adjacency)`.
- Fixed: on Swift 6.4's output, where each expansion is a `↳` line of its own, a run whose failures mostly read one value leads its failure block with `↳ 200 of 212 failures read one and the same value (… → nil), across 5 signatures` again; an expectation's own true/false result is not counted as a value it read, and a comment printed above the expansions is never read, and neither is an operand Swift Testing expands beside the values read (`some → "ok"`, `Optional("ok") → "ok"`, `.none → nil`, any expression naming nothing but literal syntax), which named the expected value over the `nil` every failure read.
- Fixed: `sift run` reads an `#expect` written over several lines as one expression (`Expectation failed: Gizmo.soleElement(of: note, width: 320)?.label == "note 0"`), where it kept the first line and printed the rest as the failure's note.
- Fixed: `where` with no index store keeps an instance method called unapplied on an array, dictionary or optional type (`[Int].chunked([1])`, `[String: Int].merged(d)`, `Int?.pick(nil)`), which it dropped as a call with the wrong labels.
- Fixed: `where Gizmo.of` with no index store drops, from the uses written with no call, a reference `Other.of` whose `Other` is an unrelated type the tree declares, as it already did for calls, and counts them on that section's line (`2 on other types dropped, 18 kept`) with the reasons it kept the ones it could not judge; a compound `Other.of(_:)` handed on is dropped from the calls the same way.
- Fixed: `where Gizmo.init` with no index store lists calls written through a typealias of `Gizmo` (`Crate("t")`, `Crate.init("t")`, an alias of an alias, a generic alias such as `typealias Box<T> = Gizmo` called as `Box<Int>("t")`, and an alias of a struct with only its compiler-written memberwise init, narrowed by its labels) and says how many on its count line (`2 written as App.Crate, a typealias naming it, folded in here`), where it left them out.
- Fixed: `where Gizmo.of` with no index store drops calls that leave out a label its declaration requires (`Other.of(x)` for a static `of(_:census:)`), where it kept every call of one unlabeled argument written on a type; an instance method still keeps them, as such a call may hand it its instance.
- Added: `where Gizmo --decl` (`decl: true` on the MCP tool) answers only where the symbol is declared: the declarations block (for `Gizmo.init`, also the types declaring no init of their own, without their call sites) under `digest`'s header with no `semantic:` field, never opening the index store, and a last line naming `where Gizmo` without `--decl` for the uses, extensions, conformers, callers and overrides it left out; a bare name several owners declare prints one plain block; `--refs` and `--files` are refused beside it.
- Added: `sift audit --verbs` prints, in place of the audit, what sift's own answers cost: one aligned row per kind of answer (`where`, `where --refs`, `digest (file)`, `run`; a hook answer rowed under the call its opening line names, marked `(hook)`), the costliest first, with its calls, median and 90th-percentile answer in characters, its price in tokens and share of the window's, and the share of its calls followed by a `read`, `grep`, `sift`, `other` or `none`; it takes the audit's window and scope, names nothing in the tree, and is refused beside `--replay`, `--scan-diff`, `--share`, `--summary` and `--by`.
- Changed: the agent rule `Sift.md` is about half its length (2,565 to 1,384 bytes): its table keeps `digest`, `where`, `search`, `strings` and `sift run --`, and the other verbs (`affected`, `test`, `similar`, `dupes`, `build --analyse`, `audit`) and the help topics are reached through `sift <verb> --help` and `sift help`, which the rule no longer lists topic by topic.
- Changed: `where Gizmo` lists each extension once. An extension the name lookup found is a row under `declarations`, carrying its member count (`App.Gizmo — extension — 8 members — Sources/Gizmo.swift:66-257`) and, where it may not be the type's, the mark `may extend another module's Gizmo` (`extends another module's Gizmo` where the code places it on another type); the `extensions of Gizmo` block lists only what `declarations` did not print, such as `extension Gizmo<Int>` or a row past the list's cap, heads `(12, 10 under declarations)` when some are printed above, is omitted when none are left, and ends `truncated: K more extensions` past its 40 rows; a truncated `declarations` list says how many of its cut rows the block lists.
- Fixed: `where Gizmo` and `digest Gizmo` name `Gizmo.swift` (`no declaration named Gizmo; a file has that name: digest Sources/App/Gizmo.swift`) when nothing named `Gizmo` is declared, also where the answer lists nearest symbols, before the list, and after `digest`'s `no symbol named Gizmo in the index`.
- Fixed: `affected`: where a target's xcodebuild suite list is replaced by the target's own filter, which runs its nested XCTest cases too, the answer no longer also says those tests are left out of every filter; they are counted as left out of the swift test line only.
- Changed: `strings`: where a production literal matched around its interpolations on two or more of the query's words prints the text, the test literals spelling it whole are counted on the `in tests:` line rather than listed ahead of it.

## 0.1.5

- Fixed: audit no longer counts the tool calls Claude Code repeats in its request-record lines, so lookup counts and shares since 9 Oct were inflated; the request-record lines are skipped in the audit, the replay, the digest follow-up scan and the edits-since-green-run scan.
- Added: `sift audit --by day` and `--by week` print the summary as a trend: the first line for the whole span, the live note once, then one line per day, or per week starting Monday, clipped to the window, each with that window's lookups that had a choice, its indexed and voluntary shares, its cold count and its answered count; it implies the summary and refuses a single transcript, a replay, the share lines and unredacting; it ends with the lookups whose lines carried no time (counted in the first line, in no row) when there are any, and with the summary's closing `lists:` line.
- Fixed: the audit's per-day figures (the `--by` rows and the report page's trend) file a retraction or a rescore under the local day of the call it corrects, not the day its result arrived, so a call made before midnight whose error or hook verdict lands after it no longer moves a lookup between days or outside a `--until` window.
- Changed: the block of located diagnostics the post-tool hook adds to a build or lint output is headed `sift: the diagnostics above, located:` whatever produced them, where it said "the compiler diagnostics" even when a linter had printed them.
- Fixed: the hook no longer locates a diagnostic whose printed path is absolute, outside the checkout and a real file on this machine (another checkout of the same repository) in the checkout's same-named file, which named the wrong member for lines that belong to the other file; such a path gets no location. An absolute path that exists nowhere here (a build machine's) and a relative path are still matched by their trailing components.
- Fixed: `sift where ""`, `sift digest ""` and `sift strings ""` (a target that is empty or only whitespace) no longer answer `no declarations found` with exit 0 and a usage-log row: the shell refuses with a usage error and a non-zero exit, and the MCP tools return an error result carrying the same message, both before any lookup and before anything is logged.
- Fixed: `sift install --dry-run` with a stale server registration and `claude` not on PATH now gives the same remove-then-add commands the install itself names (`claude mcp remove sift --scope user; claude mcp add …`) on the `would not write` line, not only the add, which fails while the name `sift` is still registered.
- Changed: the `raw:` line of a `sift run` answer ends `(Swift clean)` or `(Swift dirty: 3)` in place of `(clean)` and `(dirty: 3)`, because the count covers only Swift files and a stranger read `(clean)` as the whole tree with its Markdown edits uncommitted; the `tree:` header of a query answer is unchanged.
- Changed: the bundle's install guide leads its install section with the bundle route (the first command from an unpacked bundle is the install script; the sift install command is for Homebrew and npm installs and for re-running later), says the build record's commit is the commit a release was cut from or, for a local build, the git tree hash of the source, and no longer ships the maintainer comment that sat at its top (it moved into the build script); a local build's provenance line now reads "source tree hash", not "source tree".
- Fixed: `sift install --dry-run` with `claude` not on PATH says what the install would do (`claude` is not on PATH, register the server with the pasteable command) instead of "would register … through `claude mcp add`"; `sift doctor` wraps that command in backticks; the audit's plain share is capped at 99% below everything (199 of 200 read 100%); `sift run --help` says warnings are grouped by message
- Changed: the first line of `sift audit` carries the plain share beside the count, `15 Swift lookups by any route, 4 served by sift (27%)`: sift's answers over every Swift lookup by any route, so the `indexed` row's 100% of the lookups that had a choice is no longer the only percentage a new reader meets. No percent with no lookups; the `indexed` row, `--share` and `--summary` rows are unchanged.
- Fixed: on a release-tarball install where `claude` is not on PATH, `sift doctor` no longer sends a missing `claude server` to `sift install --agent claude`, which registers through `claude mcp add` and cannot run there: it names `claude mcp add --transport stdio --scope user sift -- <path> mcp` to run where claude is; and `sift install` (and `--dry-run`) says a rule `install.sh` already put at `~/.claude/rules/sift.md` is `left as installed` when no `Sift.md` ships beside the binary, not `skipped`.
- Added: a `where <Protocol>` answered from the index store ends its `conformers of` block with one line accounting for every Swift file git shows that writes the name, each counted once (`every Swift file that writes Greeter is accounted for (6, a text search of the Swift files git shows, manifests included): 2 declare a conformer (above), 2 declare or extend it, 1 uses it (used by, above), 1 writes it only in comments or strings: Package.swift`), so a grep for the name has nothing left to reconcile; it is left out at a revision, in the `--files` view, and past the scan's bounds.
- Fixed: a qualified member query with no index store (`where InstallDryRun.lines --syntactic`) no longer counts every site it kept on an unproven receiver as `on types outside the tree`, which named types the tree declares (`13 on types outside the tree (ReplayComparison ×7, SemanticRefusal ×5, LineCount ×1)`). The name line now gives one clause per reason, each naming its three most written receivers: `on types the tree does not declare`, `on types behind a qualifier the scan does not resolve`, `on tree types out of the site's sight`, `on tree types a supertype outside the tree may hand it on`, `on names a type declared in a function may supply`, `on names an extension of a type outside the tree may supply`, `on names a supertype outside the tree of a type around them may supply` and `on names an attached macro may supply or reshape` (`12 on tree types out of the site's sight (ReplayComparison ×7, SemanticRefusal ×5), 1 on tree types a supertype outside the tree may hand it on (LineCount ×1)`). Which sites are kept is unchanged.
- Changed: `sift status` prints one line about its `semantic:` field, after `index store:`, in place of the eight under the header; `sift help answers` now lists what only a query shows. A deleted or renamed-away file the index store still records is counted however the deletion and the build were ordered (one noticed before the build read `fresh` while a query citing it read it as deleted), matched on the whole path a unit records, so a live file whose path ends the same way no longer keeps it counted, while a checkout moved since its build counts the deleted file its old units record under the old place, and when a unit still names one a line says the record stays until a clean build, which a build without cleaning does not give.
- Fixed: `sift affected` no longer offers `swift test --filter '^T\.'` for a target whose every test sits in a nested XCTest case, a filter that runs nothing; it names the bare `swift test` and says it is the whole suite. The `could not narrow below the target` line now says how many reached tests its filter leaves out, and a long suite list replaced by the target's filter counts only the tests that filter runs.
- Added: a `where <Name>` that finds no declaration, where `<Name>` is the basename of an indexed Swift file (`Gizmo` for `Gizmo.swift`, a file of extensions), follows `no declarations found` with `no declaration named <Name>; a file has that name: digest <path>` (several files: `<k> files have that name: digest <path1>, digest <path2>`, three at most, then `, and <m> more`), so the file takes one call, not two. Nothing is added where no file matches.
- Fixed: a `where <Protocol>` (with or without `--refs`, with the index store or without it) no longer folds a conformance line that also uses the protocol (`struct A: P { var p: (any P)? }`) into the conformers block whole, which dropped that use from the rows and counted the line only as a conformance: a line is left to the block only where every reference on it is a clause's, and any other stays a row and counts as a use.
- Fixed: `sift affected` no longer overstates what `swift test` runs for a target named "all N tests": the `swift test` command now ends `, which leaves out M in a nested XCTest case` where M of the N sit in a case nested inside another type, and the limits entry on such a case names only the runner the answer prints (`swift test` or `xcodebuild`), both where both print.
- Changed: a `where --refs` of a protocol no longer lists each direct conformer twice, as a row of `references to X` and again in the `conformers of X` block: the sweep's heading counts them (`24 in 22 files, 18 of them the conformances listed below`), its rows leave out each one whose clause is on the conformer's first line (a clause after an attribute or wrapped onto a later line keeps its row, since the block names only where the declaration starts), a file holding only conformances gets no heading, and the `used by` verdict carries the same clause; `--files` still lists their files. On an 18-conformer protocol the answer was 7,700 characters against 4,586 for plain `where`, and runs calling `where --refs` cost 19.6k against 17.3k (paired benchmark conformers-protocol, arm B +8.3% over 6 paths). Conformers past the block's 40-entry cap stay as rows.
- Changed: a `strings` answer whose plain section lists a literal spelling the whole query no longer ends with the count of lines matched around interpolations on one word of literal text (`3 lines match it … "answer" 3; add a word to narrow`): the literal rows answer it, and the count matched common words ("from" 76) in every call measured. Matches around interpolations that are listed, and the count where no plain literal answered, are unchanged.
- Changed: a `where --refs` row (and a `used by` row) names the declaration around a reference by its base name and `(…)` (`answer(…)`) where the full name runs past 30 characters with an argument-label list, instead of printing the whole label list; shorter names are unchanged.
- Changed: `sift affected` prints commands for the repository's runner only, read from the index store (SwiftPM's `.build`: `swift test`; DerivedData or `buildServer.json`: `xcodebuild`; any other store, or none: both), with the `affected tests` heading saying which was left out, and replaces a suite list past 2,000 characters with the target's own filter and its counts (`--suites` lists the suites one by one), so a wide diff no longer prints ~15 KB of two lists nobody ran.
- Fixed: the hook no longer withholds a `Grep` or `grep -E` whose bracket expression holds an escaped `]` before a `(` (`[\](]`), which `rg` and `ugrep` accept as a class of `]` and `(`: it ended the class at the escaped `]` and read the `(` as an unbalanced group. A bracket expression that never closes (`x[`, `x[\]`, `Gizmo|x[\](`) is withheld in every dialect, since every tool rejects it. Basic grep keeps the POSIX reading.
- Fixed: the note on a batched read that leaves a file out because the context already holds its digest names each such file once (`cat A A B` named A twice), and says `keeping its own read of` it rather than `the read of`, which read as a whole-file read where the dropped read was a line window.
- Changed: the MCP tool list a Swift session loads up front is 158 tokens smaller (1,028 → 870): `digest` and `where` no longer list `at`, `search` no longer lists `count`, and `root` and `offset` carry no description. The server still accepts `at` and `count`, and the CLI keeps `--at` and `--count`.
- Added: `where X --files` (`files: true` on the MCP `where` tool, implying `--refs`) lists only the files the `--refs` sweep names — one row per file with its code lines, `declares` and `not code` counts, 100 to a page — for the question "which files contain X". Each section of the sweep records every file it knows, past its own caps, so the view holds every file `--refs` lists and, where `--refs` truncates a written-name section, the ones past it too; the heading says where the set is by written name, not scanned, or a lower bound. The `where refs` help topic no longer says the sweep misses doc comments and string literals.
- Fixed: the PostToolUse diagnostic note now falls back to the suffix match for a relative path that names no file under the working directory (a command run in `Sources/` printing `Lib/Use1.swift:1:5: error:`) instead of dropping the site, and reads a Bash call's stderr after its stdout, where plain `swiftc` prints its diagnostics; a Bash `sift digest` that missed is now covered by a test that it is forgotten.
- Fixed: a `where <Type>` of a protocol with more conformers than its conformers block lists (40), with no index store (`--syntactic`), counted all of them as `the conformances listed below` and left the unlisted ones out of its rows; it now counts and drops only the ones listed.
- Fixed: a `where <Type>` of a protocol with no index store (`--syntactic`) leaves out of its rows and counts a conformance written on the continuation line of a declaration's header (`struct Widget:` then `Gizmo {}`), which listed it in the rows and again in the conformers block; the store's answer already did.
- Changed: a query answer's stale header says the files it counts are the ones the answer cites — `stale since last build (1 cited file changed: <path>)` — since `(1 file changed: …)` read as the whole tree's count; `status` keeps counting the whole tree in the old form.
- Fixed: a `cat` naming several Swift files behind a `||` fallback that could print (`cat A.swift B.swift || echo fail`) is answered as a `cat` of one file is there, rather than let through as `notAnswerable`: each file weighed on its own, and the line let run where any file it names is missing, since the fallback then ran. A `cat -n` of several files numbers each file it serves as source, from 1 in each file as `cat -n` does, where those files were served unnumbered. Piped into a line window that picks only lines of the first file (`cat A.swift B.swift | head`), it is decided as that window on the first file alone is (`notSmaller`), rather than let through as `notAnswerable`.
- Fixed: `sift run -- xcodebuild test` (and `test-without-building`) adds `-collect-test-diagnostics never` where the command names no `-collect-test-diagnostics` of its own. After a failing test, `xcodebuild` otherwise waits up to 10 minutes on `simctl diagnose` before it exits: a one-test filtered failure took 611 s, and takes 8 s with collection off. A failed run says so in one line.
- Changed: a `where --refs` sweep or `used by` block past 40 sites, which lists line numbers per file, now lists a file holding 1 or 2 of them as rows naming the declaration around each line and closing on its text, as the row-per-line form does, so a lone production use is located without another call (paired benchmark chain-1: arm B 40.4k → 37.4k, every run one call shorter or no longer).
- Changed: a content `Grep` for a declaration (`enum Ends`) whose in-process weighing runs out of its 0.2 s, as a cold page cache makes it, now runs, logged `unchecked`, instead of being answered unweighed with a `where` answer that has been larger than the search in every benchmark run on record.
- Changed: a `where --refs` row, and a `used by` row, now names the declaration the reference sits inside — `    :174  bump()  | text` — as the callers rows do, so an agent need not search for which function encloses a line; a row whose own line declares that name (a parameter in a function's signature, a property's annotation) leaves it out, since the text already shows it; a reference the store records inside no declaration keeps the bare `:174` row, and a row in a changed file keeps its enclosing name without text.
- Added: after a `Grep` or `Bash` call whose output holds compiler diagnostics (`path.swift:861:13: error: …`), the `PostToolUse` hook names each site's enclosing declaration and range, for the first five distinct sites, and shows the first two with up to three numbered lines either side of the cited one, marked `>`, as `digest File.swift:861` does (later sites show their own line). A path printed on another machine (a CI log) is mapped to the repository file whose path ends the same way, and a site that maps to two files, to none, or past a file's end is left out, so the turn spent on `digest File.swift:861` is not needed. The hook's registration changes (it also matches `Grep|Bash`), so installed hooks read as stale until `install-hook` is re-run.
- Changed: the hook reads a search for a member's calls, spelled as a regex — `Depot\.pending\(`, `Depot\.pending(`, `Depot\.pending\(for:`, or an alternation of those and `Depot\(` — as the qualified name it spells, on the `Grep` tool and a shell `grep` alike, so it is answered in place by `where Depot.pending`, which names the function around each call that the raw lines do not; a call with no type in front of it (`\.pending\(for:`) stays a branch left to a search.
- Fixed: a `where` answer from a store built for some targets only (`swift build --target Core`) read `semantic: fresh` and counted callers and uses as if every target had been compiled. A non-test target the store holds no unit for, whose files write the asked name, now makes the header `partial (target Extra not built — 2 lines there name Gizmo, not counted)` (`targets A, B, C +2 more` past three, sharing the parenthesis with the test-file clause where both apply), an empty verdict ends `; not counting target Extra, which is not built`, and a `used by` tally reads `1 production, a lower bound (target Extra not built)`. Where the asked declaration is a subscript, an operator function or `callAsFunction`, whose uses spell no name, every such target is named (`its uses of A.subscript cannot be found by name`), and a member reached through a lowercase receiver (`a.f`) counts as a use. A target that never writes the name otherwise, and a `.plugin` or `.macro` target, which no build indexes, leave the answer `fresh`; `affected` names no target.
- Fixed: the hook no longer answers a content `Grep` for a declaration (`enum Ends`) or for a name declared once with a `where` answer larger than what the search itself prints: it runs the search in process (at most 0.2 s) and lets the `Grep` run where the answer would be no smaller, logged as `notSmaller`. A bare name declared more than once is still answered, since which declaration each use resolves to is what the answer adds. The search counts what the tool prints: at most `head_limit` lines (250 where none is given) after `offset`, none with more than 500 bytes of text, stopping once the window is full or it has printed more than the answer; a `head_limit` or `offset` of any size is read without error. It leaves out what `.gitignore` ignores, as Claude Code's `ugrep` and ripgrep do, so a search in a repository no longer walks `.build/` past its file limit and goes unweighed; a shell `grep -r` of a directory below the root counts what only a `.gitignore` above it names, as `ugrep` prints it, and leaves out what a `.gitignore` at or below it names, while the `Grep` tool's search skips both, as ripgrep does. Outside a git work tree the walk is unchanged, and so is the system `grep`'s.
- Changed: the standing caveat on `where` and `search` answers is said only where it applies. It leaves the session-start primer for every audience and the `where` and `search` tool descriptions, which a paired benchmark showed made agents confirm every answer with a grep; a `where` answer whose callers, uses or `--refs` list is empty now ends with it, a `search` that matches nothing carries its clause, and `sift help answers` keeps the full text.
- Changed: a plain `where <Type>` lists the uses that are not already listed below it (a protocol's conformances) in place when there are 8 or fewer — per file, `:line  | source text`, with no `— where --refs … lists them` pointer — so an agent asking which types use a protocol is not sent to grep for five lines. Above 8 the verdict stays alone with the pointer; lines inside the type's own declaration are still counted, not listed; `--refs` is unchanged.
- Changed: a `where` answer's `callers of X` heading, when it comes from the compiler index store and other types declare the same member name, now says so — `(2, resolved to this declaration — greet is declared 3 times on other types, not counted here; where greet lists them)` — so an agent need not grep the bare name to rule those out. The `not code` heading no longer ends `same-named symbols'` with a stray apostrophe.
- Fixed: `sift run` no longer waits on a process its command left running that still holds the output open — after a failing test `xcodebuild` starts `simctl diagnose`, which kept `sift run` from returning for up to ten minutes after the verdict. Once the command exits, everything it wrote is still read in full; then reading stops when the output has been quiet for 2 s (10 s at most), the exit code is the command's own, and one line says so — `sift run: the command exited, but its output was still held open — not waited for; still running from it: pid … (simctl).` — in the filtered answer, beside the passthrough note, or after a raw-log fallback. Nothing left running is ended.
- The hook's suppression log now records two passes that left no row: a Bash line that runs `sift` and also reads a Swift file (`besideIndexCall`; the line is still taken as the advice and never judged leg by leg), and a Swift window no index call located, let through as `noLookup` (`unlocatedWindow`; the verdict line still reads `noLookup`). A heredoc script, an in-place edit and a command that reads nothing still write nothing.
- Changed: the hook judges a `cat` naming several Swift files file by file, as a `cat` of each is: where any file's digest is worth the turn the line is answered in place, that file's digest and every other file's source each under its own heading; where none is, the read runs as `notWorthTheTurn` rather than `notAnswerable`.
- Changed: `digest File.swift:861`, one cited line inside a function longer than 25 lines, now numbers the lines of its window as Read numbers them (right-aligned number, a tab, the line) and marks the cited line with `>`; the declaration, the `(…N lines skipped)` markers and the `lines a-b; read it by range` footer, which repeated the header, are gone. Agents had followed the unnumbered window with a `Read` of the same lines to find which one was cited.
- Fixed: `sift build --analyse` read a batch frontend job's output once under each file heading of the batch, inflating every total and `(×N)` count about sixfold; the build now passes `-disable-batch-mode`, so each file's job prints its output once, and a block of timing lines identical to one already read is still dropped, and the same site timed in different jobs still counts each time.

## 0.1.4

- The npm package now ships `Sift.md` beside its binary, so `npm install -g @agulhas-labs/sift && sift install` installs the
  agent rule as the docs say; `Distribution/npm/build.sh` fails if the packed package lacks it. The README link in the
  npm package points at the guide section that covers the scopes.
- `sift run -- xcodebuild test` over a gitignored XcodeGen project that predates a Swift file its `project.yml` holds
  used to run only the tests the stale project knew and report green; it now prints `project: … does not list N Swift
  files its spec … holds (…) — run xcodegen generate` before the command's output. A note, never a verdict: the exit
  code is unchanged, and nothing prints where the project lists every file or the spec cannot be read.
- `sift run -- xcodebuild test -scheme <Name>-Package`, run in a package's own directory, carries the same
  `inventory: N declared, M reported` line as a plain `swift test` of that package. Any other `xcodebuild` test run
  that is not narrowed by `-only-testing`, `-skip-testing`, `-testPlan` or a test configuration now says
  `inventory: not checked — …` and why, rather than nothing, which read as a run that was checked and found whole.
  A package that keeps its own `<Name>-Package.xcscheme` under `.swiftpm/xcode` is not checked either, and the line
  names that file. A Swift Testing ending `xcodebuild` printed with other output spliced in after the test's name is
  read as that test's ending, and a started test whose ending cannot be read that way is lost rather than never
  reported.
- The hook no longer holds a lookup back with a pointer at an index call sent beside it ("sift held this lookup
  back"): Claude Code returns a sift call before it runs the next tool of the same message, so the hold could
  never fire, and a lookup beside a call already made is let through as any other.
- `sift audit` excuses a grep of named Swift files as a search the hook let run (`named`) only where the hook
  itself reads the line so, through the hook's own parser: `grep -n Depot A.swift B.swift 2>/dev/null` is no longer
  counted as a miss, and an `rg`, an `egrep`, a flag the hook does not read or a bare number among the operands is no
  longer excused.
- The `totals:` line of a `sift run` that read per-test results states the skip count, `0 skipped` included, and each
  skipped test is named under it as `skipped: Suite.test — reason` (ten at most, then `skipped: +N more`), so a gate
  whose rule is that a skip blocks a pass no longer greps the log for them.
- The bundle's `install.sh` records each install as one line in `~/.sift/deploys.jsonl` (time, version, commit, tree
  state, binary size; the build's details come from a `BUILD_INFO` file in the bundle), and `sift report --deploys`
  lists them, newest last, so a measurement can be split at the real moments the binary changed.
- The hook lets a whole read of a smaller Swift file through without building its answer, where no answer could
  be worth the turn, so such a read no longer waits on the index; its logged reason is `notWorthTheTurn`, where it
  was sometimes `notSmaller` or `parseError`.
- The hook answers a whole read of a Swift file with its digest only above a somewhat larger file size (about 10.8 KB at the
  median context, from about 8.2 KB), because the follow-up cost is now the measured one: the median ranged follow-up
  after such an answer is 1,330 tokens, where 700 had been assumed.
- The hook lets a ranged `Read` of a Swift file (an `offset`/`limit` over less than three quarters of it) run
  where its answer would spare less than the identical re-run is expected to cost, since nearly half of such
  answers were followed by that re-run; the let-through is logged as `notWorthTheTurn`. `sed -n` windows are
  answered as before.
- A window of a Swift file the hook lets through because an index call located the file now writes a
  `locatedWindow` row to `suppressions.jsonl`, and a window over 200 lines let through on the file's whole digest a
  `digestHeldWindow` row, so how often each happens is a count rather than a transcript search. `--verdict` and a
  replay name the call by that rule where they said `noLookup`; what the hook prints is unchanged.
- The `raw:` line of a `sift run` answer opens with the tree and commit the run happened in, in the `tree:`
  header's words (`raw: Widget @ cc94af6 (clean) · .sift/runs/…`), so a suite run in the wrong checkout no longer
  reads as the merge gate.
- The hook's in-place answer names the files its stripped `| tee` stages would have written in the order they are
  written on the line, a tee inside a nested `$(…)` before the one ending the line around it.
- The hook's grep walk skips the version-control directories and sift's binary database only for Claude Code, whose `grep` is `ugrep`; under
  Cursor and Codex, whose shells run the system grep, it reads both, so a sweep matching the database is let through
  instead of answered without the `Binary file … matches` line that grep prints.
- `test --analyse` and the test inventory keep naming a test target as its build file spells it (`Demo Spaced Tests`) now that
  the module the index attributes its files to is spelt as the build spells it (`Demo_Spaced_Tests`), so a plan still matches it.
- Module resolution reads a target's `PRODUCT_MODULE_NAME` and `PRODUCT_NAME` settings, in XcodeGen specs and
  `.xcodeproj` alike (`PRODUCT_NAME: My-App` builds `My_App`), and a rename it cannot expand leaves the target's files
  guessed, so `where` no longer drops an extension written through a renamed module's real name. Each setting is
  read from the level Xcode reads it from (target settings, its xcconfig, the project's settings and xcconfig), and a
  name is spelt as Xcode spells it, measured: Unicode letters kept, a leading digit replaced (`Café Ünï` builds
  `Café_Ünï`, `3D` builds `_D`), which also corrects the test-log module name for such targets. A target no setting renames is
  spelt the same way, in XcodeGen specs and SwiftPM packages too. An xcconfig a name
  is read from is watched like the build file naming it, so editing it, or writing one the build file names but
  that is not there yet, re-attributes the files on the next query.
- A file whose build file renames its module through a setting sift cannot read carries a banner saying so, not
  that no build file declares it, and `init` lists it apart with no proposed module rather than proposing the
  target's own name, the one the build replaces. `where`'s count of extensions in other modules, and its reason for
  keeping an alias, say so too rather than that the module was guessed from the path.
- `search` reads a dotted `calls:`/`uses:` value (`calls:Parser.parse`, `calls:.parse`, `calls:Parser.parse(source:)`) as its base name and says on a note line that the qualifier was dropped, where it answered "removed all" or refused.
- A deeply nested Swift file no longer crashes every command with a stack overflow: every parse and every read of
  its tree runs on a 64 MB thread, nesting past the parser's cap of 256 is indexed with that one parse error, and
  only what the parser takes minutes or unbounded stack on is indexed as one parse error with no declarations: a
  run of more than 10 `[`, generic arguments nested past 512, more than 4096 `try`/`await`-style keywords in a row,
  function arrows in one declaration or `else if` arms in one block, and `#if` nested past 256. Shifts and `<=`
  written without spaces no longer count as generic arguments, and a regex literal after `return`, `in`, `case` or
  `throw` is read as one.
- A Swift file with thousands of syntax errors no longer stalls indexing for minutes: past 100 errors they are
  counted in one walk of the tree instead of each being worded, and the edit check lists them as one error naming
  the count, at the first.
- `doctor` takes a configured hook command for sift's only when its program word is sift (after any environment
  assignments, `exec` or `env`) and the next word is a hook subcommand, so `cd ~/sift && make` and
  `foo --name sift` no longer count as sift's hooks.
- The hook reading a command run through `sh`, `bash` or `zsh` ends the shell's options at a bare `--`, as a POSIX
  shell does: `sh -c -- 'cmd'` runs `cmd`, while `sh -- -c` names a script file called `-c`. A lone `-` ends them
  too, as each of those shells does: `sh -c - 'cmd'` runs `cmd`.
- A grep answered in place with a `where` whose per-file cap cut some sites now counts them as "N more sites past the
  per-file cap" in its closing note, rather than as lines "no site accounts for", which stays for lines no site could be.
- `digest --signatures-only` serves a stored property with a closure initialiser and observers as its declaration
  through the initialiser, without the observers, instead of whole.
  A quoted brace inside a string interpolation in that initialiser (`"\(f("{"))"`) no longer hides the observers.
- A `where` answer for a bare name several unrelated owners declare now says how many extensions of the name are written through a qualified path and so listed under no owner ("extensions: N more written through a qualified name, not listed here — …"), pointing at each owner's own query that lists them (`where Outer.Configuration` for a nested owner); bare extensions already listed as rows, and extensions of a type that is not one of the owners, are not counted, and none unlisted prints nothing.
- The hook's walk of a grep skips a version-control directory (`.git`, `.svn`, `.hg`, `.bzr`, `.jj`, `.sl`) for
  every search shape, as the agents' `ugrep` does, so a large `.git` no longer counts toward the walk's file limit or
  gets read; it passes over sift's own binary database too, which `ugrep -I` prints nothing from, so a word-anchored
  sweep of a whole indexed repository (`grep -rnw Name .`) is answered in place instead of let through.
- A `where` answer from the several-owners path, a diff's callers or a property wrapper's attribute sites now says
  how many sites it set aside as recorded only by a build older than the file's last edit, as the per-declaration
  answer already did; a single-owner answer about a wrapper's initializer counts its set-aside attribute sites too.
- A property wrapper's set-aside attribute site is counted even after an edit added or removed lines above it: each
  file counts its attributes no store records against the lines the older build recorded there, up to the smaller.
- A property wrapper's moved set-aside attribute site is counted only against a line where the older build recorded a
  call of one of the wrapper's initializers, so a debug-only `let probe: Clamp?` beside an attribute added since no
  longer reads as `1 site … set aside` for each of `Clamp`'s initializers.
- A diff touching two property wrapper types gives each type's initializer report only the sites set aside for its own type.
- One site recorded by two stale configurations' stores counts once in the `N sites set aside` line, not twice.
- A lower-bound `where` searches every changed or outside file for the name's bytes and reads only those that hold
  it, so a tree with more files than the scan cap no longer prints "N files not scanned" when nothing matched, and a
  mention past the cap is found; on the several-owners path a file the store holds takes no slot.
- `where --refs` prints the unbuilt-mentions line and the new-since-last-build line on the first page only, and its
  references heading says how many macro-generated lines it set aside ("N more lines a macro generated, not listed"),
  counting those of the typealiases folded into a type; a later page repeats neither the "changed since last build,
  written since the build, by name" line nor an empty "not code" heading.
- `digest` of a declaration served whole cites its range from the first line served (its doc comment or
  attributes), and the repository overview hints `digest <Module>/` for a module that shares its name with a type.
- `digest --signatures-only` no longer serves the observer bodies of a stored property that has an initial value, keeps
  the accessor clause of a property whose attribute string mentions an initializer, and stops a custom operator whose
  last character is a non-ASCII operator character before its body.
- The root `grep -rn Name .` the hook answers is counted even when git's index holds the name (a tracked file named
  for it): version-control directories are left out of the names-search check, as the agents' grep leaves them out.
- A split xcodebuild gate whose test leg runs inside `bash -c`, `bash -lc` or behind `env`/`nohup`/`exec` is read as
  a split gate, so its build-for-testing leg is not wrapped as a lone build.
- `sift install --allow-run` (or `--allow-lookups`) without Claude Code among the agents says the flag was ignored;
  the no-terminal note names the command as it must be typed (the binary's path when its directory is not on PATH);
  and `install-hook` with both allow flags adds the run rules even when the lookup rules are already there.
- `sift usage`'s gross note says an answer is taken back only by a re-run or whole read the hook let through.
- `where` no longer lists an extension of a framework type's nested name (the session type's configuration) under a local nested type of that name, as long as every module name of the tree is declared; a tree whose module names are guessed still lists it as one that may extend.
- The paste lines `sift affected` prints to run what it lists are runnable and select exactly what they list: a
  target whose tests are all affected, and a list collapsed to its target, each print a line of their own that runs
  the whole target, and the filters for a target, a suite and a test are anchored at both ends, so one that is named
  like another's suffix or prefix is no longer run along with it.
- `sift doctor` counts a hook command as sift's only when a word of it ends in the binary's exact name, or the name with an at-sign and a version (a pinned npx package), so a path that merely contains the letters no longer counts; its index-store check probes the package directories an engine passes, and the discovery note in help reads as a clause.
- The release bundle's link rewrite keeps a link's title and leaves code spans and fenced code blocks as written, and its link check reads Windows line endings, ignores a triple-backtick span at the start of a line, and warns when a fence is never closed.
- The release bundle's link rewrite and link check read a document by its Markdown blocks, one shared reader: a code span may run across the lines of a paragraph but not past a heading, list item, table row, quote, break or indented code block, a list item's paragraphs are placed by the item's content column, a fence line indented as code opens no fence, a heading, fence or indented code block may start on a list item's marker line, and an indented code block is left as written.
- `sift run -- xcodebuild test` (or `test-without-building`) on an `id=` destination reads the simulator's
  accessibility flag before the run and, if it is off, prints `accessibility: off on <udid> — the first launch
  will draw an empty tree; arm it and reboot the simulator first` before the command starts. Nothing is armed or
  rebooted; an unreadable flag, or a named destination, prints nothing new.
- An `affected` range says how many uncommitted .swift files it left out ("N uncommitted .swift files are not in this range; drop --from to include them, or commit first."), so an empty range no longer reads as a change that affects nothing.
- A Swift lookup piped into a `tee` that ends its pipeline (`grep -rn Name . 2>&1 | tee notes.txt`) is answered and
  counted as the lookup alone, since the lines still reach the context; a `tee` onto a Swift source file, one whose
  output is redirected, or one with stages after it still reads as a write (a redirect of the `tee`'s own stderr, a
  process substitution operand or a `.swift.bak` backup copy is not one). The answer ends its opening line with
  `(not run: out.txt was not written)`, since the command never ran. The same reading applies to a teed lookup
  re-run to get the file written (counted as a read anyway) and to a teed `sift where`/`sift search` (its files are
  located), and to a `tee` inside a command substitution.
- `sift run -- swift test` of a nested package, named by `--package-path` (either spelling), `-C` or run from
  its own directory, prints the `inventory:` line for that package's manifest and tests instead of nothing.
- The `inventory:` line of a root `sift run -- swift test` no longer counts a nested package's test target as
  "outside this run's scope": a test under a directory holding its own `Package.swift` is left out of the root
  run's counts, unless the root manifest declares its target, by name or by a `path:` into that directory, in which
  case it stays the root's. A run that names the nested package with `--package-path` declares that package's test
  bundles, a package directory spelled through a shell variable prints the "not checked" form, and
  `--package-path` wins over `-C` in either order.
- Answers open with one header line and stop repeating the call: `digest`'s header drops `semantic:` (it never
  consults the store, so the field always read `syntactic-only`); `search` and `strings` read `source: live`;
  `where` and `strings` no longer echo the query, and `search` echoes it only where the parse read it as other
  than sent (an alternation, a regex, a bare word as `name:`); `strings` heads its literals `source literals:`.
  A `where` with no store says which in its header: `none (no index store in this worktree)` or `none (no
  index store for this tree yet)`. The hook's answer for several names labels each part `where <name>`.
  Measured on this repository: a `digest` 1,099 → 1,073 B, a `search` 382 → 297 B, a `strings` 615 → 475 B.
- A `where` whose store's relations are withheld (no store, still loading, failed to open, `--syntactic`, `--at`)
  carries one note under its header saying why, what was withheld and the remedy, in place of the `mode:` line, the
  `NOT ANSWERED` notice and the `references:` lines; "by written name" is said only above a list matched that way. A
  `stores:` note appears only when more than one store answered, one is still loading, or a setting was passed over.
- What holds of every answer is said once per session, not on each answer: the references boundary ("this repo's
  own build only" and the `not code` pointer), the property and case "written code only" lines, "split on the
  XCTest or Testing import, never the path", "which is not use", the `not code` heading's "over the working tree,
  never stale" and `search`'s caveat line leave the answers, and one text carrying them, with the written-name
  limits ("may miss protocol, closure, unfolded-typealias uses", "an empty list is not proof it is unused"), goes
  into the session-start primer, the `where` and `search` tool descriptions and `sift help answers`. A no-store
  type answer keeps "an empty list is not unused". The primer grows by 684 B. Nor is a site said twice: a
  function's `where --refs` lists under `references to` only the lines `callers of` did not show, headed `N in M
  files, K of them the call sites above`, and pages over the rest (three callers and one function handed on
  unapplied: 861 → 712 B).
- `where` with an index store no longer drops a site in a file written since the last build that the store cites
  nothing in, such as a new, untracked file calling the function: such a file's lines that write the name are listed
  as `changed since last build, not in the store, mention the name: <path>:<line>`, under the default answer,
  `--refs` and the several-owners answer alike, and the header's stale count includes
  the file. A changed file the store holds is listed only where it now refers to the name more often than the
  store recorded, as `written since the build, by name: :6` under its `(file changed since last build)` mark, so a
  name common across unrelated edited files, bound in a tuple pattern or labelling a tuple's element, or in a file
  only touched, lists none of them; where a cited line has moved, the surplus is given as `1 more than the build
  recorded, among :3, :7`. A new file writing the name only in a string or a comment is neither listed nor counted.
- `where --refs` on a type no longer lists an `@Observable` attribute line as a reference, nor counts it as a
  production use: the storage and observation accessors the macro generates name each property's type there,
  with nothing written to rename. A mention written on that line, such as a conformance, is still listed.
- `strings` matches Swift string literals ignoring case, as it already did catalog values: the smart-case rule (an
  uppercase letter in the query made the match case-sensitive) is gone, so `strings "Warnings"` finds the
  on-screen `"WARNINGS"` and `"Many warnings"` in one call instead of answering "no Swift string literal
  contains it".
- `digest <Type>` for a small type, which serves source instead of a digest, now includes the type's doc comment and
  attributes (it served the declaration alone, dropping the one paragraph saying what the type is), counts them in the
  size comparison, and says "the declaration's source follows" rather than "the source itself", since the file's header
  and imports are not served. A whole-file digest that is served keeps its wording.
- `where --refs` is now a complete rename sweep: with an index store it lists every line of every file instead of
  capping a file at 30 and sending the rest to a grep, and its not-code section reads the Markdown under hidden
  directories (`.agents`, `.github`, `.claude`), not only visible ones. `.git`, `.build`, `.swiftpm` and `.sift`
  are still skipped, and Swift in a hidden directory is still never indexed.
- Discovery finds the index store of a SwiftPM package nested below the repo root (`swift build --package-path
  Kit --build-tests` leaves it at `Kit/.build/out`) with nothing to configure: `status` reports it
  and `where` answers semantically, where it took an `indexStorePath` in a hand-written `.sift.json`. The nested
  package is probed at the paths the root package is, after DerivedData and only where the root's `.build` holds none. The builds `where`, `affected` and `status` tell
  you to run for it carry `--package-path Kit` (SwiftPM finds no manifest from the root), and `status` labels the store `Kit/.build`.
- `sift run`'s `raw:` line now says how long its log lives (`kept for the next 4 runs`, or `kept until it passes or 5
  newer failures`), and the log of a run that built and failed is kept in a pool of its own until a later run of the same
  command passes or five newer failures push it out, so a path cited in a prompt no longer dangles after five more runs.
  Logs are kept in the order their runs finished, so a slow run's log is no longer the first pruned by quick runs that
  finished during it; a run that ran nothing (exit 4) is not kept as a failure.
- `sift run` shows every warning and every `error:` line a tool logs with a timestamp while the build runs
  (`<date> <time> tool[pid:tid] error: …`), which it used to drop: listed under `tool log (N):` as `tool: error: …`,
  the timestamp and pid gone, deduplicated and capped at twenty. They are shown, never judged: no verdict, exit
  code, selector check, proof or explanation of a failure reads them, and the same shape printed once a test has
  started (a line a test logged itself) is left to the raw log.
- A failing test's expectation message, with its expansion, is shown whole up to 1 KiB (it was cut at 240 bytes);
  past that it is truncated with the same pointer to the raw log. Notes and arguments keep their 240-byte cap.
- The answer to a filtered run that matched nothing (exit 4) is its headline and the `raw:` line: the `totals:`
  line, the tool's `Build complete!` and its own `No matching test cases were run` no longer repeat it.
- A whole-file `Read` the hook answers is answered with the file's whole digest, not its first sixty member lines
  and an `offset` cursor: the agent no longer needs a second call to see the rest of the type it was denied. The
  saving floor is weighed against the whole digest, so a file whose full digest does not save enough runs; a
  digest past the 10 kB budget is still cut to fit, unless it is at most two fifths of the file's bytes (24 kB at
  most), when it is served whole. `sift digest` and the MCP `digest` keep their paging.
- `usage` and `audit` say what they counted in the same terms: both headers name `1 session (+2 subagents)`, a parent
  with its subagents beside it, `audit`'s adds how many of its Swift lookups sift served, and `usage` adds a `counted:`
  line saying a call is one logged answer, failures and Markdown outlines included, where `audit` counts lookups by any
  route. A trial had read "13 calls by 2 subagents" against "1 session, 28 Swift lookups" as the two disagreeing.
- `where` keeps a type's references and its usage line when five or more of its extensions sit in files that
  sort before the type's own: an extension no longer takes one of the five places semantic relations are
  resolved for, and a declaration left past them is named in the note, with the query that resolves it.
  Overloads sharing one qualified name are resolved together, never split by the five (a set larger than one
  answer resolves is given by file and line, since no query narrows it); an extension of a type the tree does
  not declare keeps its place; and a name several owners declare counts the declarations those places pick.
- `affected` right after an edit, before a rebuild, seeds each file the store refuses from the declarations the
  diff touched (a removed or renamed one by its old name) and walks to their call sites as syntactic `where` finds
  them, labelled `syntactic, lower bound`, instead of name-matching every declaration in the file: a three-call-site
  rename in a 354-test target now names its 4 tests at depth 1 and 6 at depth 2, where it named 283. A target the
  walk still cannot narrow (half its tests or more, past the list cap) is said to be one in two lines with the names
  and the command, not listed. That collapse now applies on every path (resolved, name-matched, after-edit), a
  target named by its own commands is not repeated in the `xcodebuild` and `swift test` sections, and the limits
  block is two lines (how the answer was made, that it is a lower bound, and what is specific to it); the standing
  list of what the index cannot see is `sift help affected-limits`. The walk still reaches what no site calls by
  name: an operator, a witness the language calls (`description`, `hash(into:)`, `wrappedValue`) or a stored
  property seeds its type too, a typealias or associated type is followed where it is written as a type, a function
  handed on as a value (`map(T().f(x:))`) counts at every hop, and a file left with no name to scan is seeded whole.
  Beside a target named by its own command, the `xcodebuild` and `swift test` lines say they cover the listed
  targets only.
- `where`, `affected` and `diff` no longer list a caller, reference or conformance at a line the file held
  before its last edit: where a store keeps several builds of one file (an Xcode store's simulator builds for
  two architectures, debug and release units in one native store), a unit built before the file last changed
  no longer answers beside one built after it. Every build made since the edit still answers, so a call only
  one configuration compiles is still listed.
- `usage`, the report page and `audit` price a saving only where the counterfactual was observed: a read the advice hook
  intercepted and answered in place, a whole file (the bytes of its first 2,000 lines, what one `Read` returns, as the hook
  measured them) or a window of lines, less the answer served. Every other call, a grep the hook answered and every
  voluntary `digest`, `where`, `search` and `strings`, is counted and its served bytes stated, never priced; hook lines
  logged before the field their pricing needs are unpriced. An answer read anyway is taken back: when the hook lets the
  same context re-run the command it answered, or read the file whole, it writes a `readAnyway` line naming the answer's
  call id, and that answer is left unpriced. The headline reads `~2.5k tokens saved on 2 intercepted reads (file or window
  asked for − answer served); 1 read anyway, 4 other calls unpriced`, and no longer claims the figure leans high.
  Markdown outlines stay on a line of their own. `audit` no longer prints a saving of its own beside the read-anyway rate.
- `where --refs` ends with a `not code` section: the DocC links, doc comments, comments, string literals, Markdown
  lines and file names that write the name, read from the working tree's Swift and Markdown files, one row per file
  paged on the answer's offset. A rename no longer has to grep for them; nothing found says which files were read.
- `install.sh` and `sift install` take `--allow-run` and `--allow-lookups`, so "install sift and allow it" is one command
  where nothing can be asked (an agent's shell), and the permissions line printed there names the exact command to run,
  and the form to type it in from Claude Code (`! sift install-hook --allow-run`).
- The release bundle's documents no longer carry dead links: the README opens its Install section with the
  release routes (Homebrew, npm, the bundle's `sh install.sh`) before the source build, `make-dist.sh` rewrites a
  relative link to a document the bundle does not ship (Design.md, Benchmarks/) into a link to the public repository
  at the release tag, and fails the build on any relative link in the staged bundle that does not resolve.
  INSTALL.md now describes the installer as copy-to-a-temporary-name-then-rename, which is what it does.
- `affected` names a target whose every test is affected in one line with its count and both runners' commands
  (`LibTests: all 661 tests — --filter 'LibTests' — -only-testing:LibTests`) instead of listing its suites; a
  partly affected target past the suite cap prints its heading, an over-cap line and one command per runner
  (`swift test --filter …`, `xcodebuild test -only-testing:Target/Suite …`) that runs exactly the affected suites,
  with no per-test rows, suite list or `truncated:` line. A changed file the store refuses is no longer expanded
  into its declarations: the answer counts the declarations the name match used.
- Discovery finds an `xcodebuild -derivedDataPath <Pkg>/.build/DerivedData` build, for the repo root and
  each SwiftPM package in the tree, after every other probe, so `status`, `affected` and `where` answer from
  it with nothing set where they used to say `index store: none found`. The no-store hint names the places
  searched, no longer implies a store in any ignored directory is found, and gives the `.sift.json` line for
  anywhere else.
- A paged answer whose `--offset` skips every item now says so: `search` and `where --refs` (with or without an
  index store) print `offset 5000 is past the last of 80 matches — drop offset to see them` in place of the
  `(…80 matches skipped)` note under an empty page, which read as an answer.
- `sift doctor` no longer fails a correct Claude-only install on a machine that also has Cursor or Codex: an agent
  found with nothing of sift's in it prints `found, sift not installed — sift install --agent <name> adds it` and
  isn't counted, while one with any piece installed but something missing still fails, and `--agent` still
  checks the agent it names. When no agent found has sift installed at all, doctor fails and says so.
- The hook wraps a lone `xcodebuild build-for-testing` in `sift run --` like any other build: in a package
  that builds only for a simulator it is the everyday build, and it used to run raw. `test-without-building`,
  and a line running both actions (a split gate), are still left alone and logged as `gateLeg`, including
  when the `test-without-building` leg is written behind a wrapper (`xcrun xcodebuild …`, `env FOO=1 …`, `time …`).
- `sift run -- xcodebuild build-for-testing -scheme X -derivedDataPath build` reports a green build as a pass:
  the value of an option known to take one (`-derivedDataPath`, `-scheme`, `-configuration` and the rest of
  `xcodebuild -help`'s) is never read as the action, where it used to draw `⚠ … could not tell which verdict
  the command owed`. An action word behind an option no table names still refuses.
- `digest` with `--signatures-only` (`signaturesOnly` on the MCP face) on a `Type.member` target now serves the
  member's header and its declaration through the signature, up to the body's opening brace, and no body. It used
  to serve the whole body, so asking for the signatures of several members to choose one returned every body.
- `digest Name` serves the type where `Name` is both a module and a type, with one closing line (`a module named
  Name also exists — digest Name/ serves it`); `digest Name/` is the explicit module spelling, on the CLI and
  over MCP. A name that is only a module is unchanged; several types of the name keep the ambiguity answer plus
  the same module line.
- `sift audit` leaves out sessions recorded in scratch roots (temporary directories, `~/Library/Caches`, any
  `.build` directory) as `usage` and `report` already do, with a line saying how many sessions, and takes
  `--include-scratch` to count them. Its share and its logged saving no longer count a probe repository's
  lookups.
- A grep answered in place with a `where` counts the matching lines the answer does not show under the paths
  searched, `7 comment lines under Pkg/Sources also match, not shown here — re-run the identical command to see
  them`, where they used to be left out in silence; and an answer showing sites outside the paths searched says
  so, `answered across the tree: 1 of 11 sites shown is under Pkg/Sources`, rather than reading as theirs, naming
  a `Grep`'s path as it was given. A matching line is counted once however many operands print it, a comment only
  in a Swift or C-family file, and not at all where the answer shows its doc summary; where the lines cannot be
  counted (a `Grep`, a cut whose order grep leaves unfixed, a search past the print limit) the answer says so
  rather than reading as though nothing else matched, and sift's own `.sift/` no longer leaves a search of the
  whole repository uncounted.
- `where` names the lines its lower bound leaves out: where a test build ran and test files still have no unit
  in the store (a test target the build skipped, or a file outside any built target), it scans those files
  alone for the symbol's name as a whole word, in code or strings, not comments, and adds `not in the build, mention the name: Tests/Fixtures/GizmoTests.swift:48,176 · …`, ten files at
  most, the rest counted; it reads at most 200 such files and counts the rest as not scanned. A rename trusting `where --refs` used to miss those lines behind an honest but
  unactionable `a lower bound (24 test files outside any built target)`.
- The hook answers a grep sweep for a name in place in a tree with no index store (a fresh install, an agent
  worktree, an app whose build has not run), with the syntactic `where`, under the same rules as a built tree:
  every line the grep prints must be a line the answer shows, and the whole refusal must be smaller than what
  the grep prints. Such a sweep used to run unanswered, logged as `noStore`.
- A line of several sweeps answered in place is weighed whole: its refusal must be smaller than what all its
  greps print together, as well as each answer smaller than its own grep, or the line runs as not smaller.
- `sift help refusals` says what a command the hook lets through means: no smaller answer was found for that
  call, not a recommendation of the whole read, and `digest` and `where` are still the cheaper first call.
- Tests: the shell's sample of a function's name-matched sites is pinned to say how many it cut off for the
  places the name is written with no call, as it already was for the calls. A reviewer's "callers cut short,
  no marker" on `where` was a marked cut (`truncated: N more`) that sits under the last file's rows.
- `strings` lists a line of a multiline block literal as a key's literal occurrence when the line, its
  indentation stripped, spells the key: `Hello \(x)` inside a `"""` block now matches the key `Hello %@`, as it
  already showed under the source literals.
- `strings` finds a plain catalog key holding a quote, a backslash or a control character at the literal that
  escapes it: the key `He said "hi"` is listed at `String(localized: "He said \"hi\"")`, where it used to be
  reported as referenced through a generated accessor because the scan looked for the key's unescaped text.
- `strings` reads the `\'` escape in a Swift literal as the apostrophe it prints: a key such as `it's %@` is
  listed at the interpolated literal `"it\'s \(x)"` rather than as referenced through a generated accessor, and
  `sift strings "it's"` lists that line among the source literals.
- `sift run` no longer reads a line a test prints in a diagnostic's shape as a failure or a compiler error:
  `/bin/echo said /x/T.swift:12: error: -[T.A b] : …` failed no test and `said /x/T.swift:13: error: boom`
  listed no error. A diagnostic counts only where its path opens the line: a relative path holding no space,
  or one absolute path with no second one after a space, so a real path such as `/Users/x/My Project/…` still
  counts.
- `where` counts a clause written through a typealias as written through it: a subclass alone in its file
  through the class's alias no longer counts as a line of the class's own name, losing its "written as", nor
  is it listed in the class's `--refs` sweep, and one written through an alias of an alias is written as the
  alias it spells only. The store's reference queries (callers, uses, references, overrides, extension sites)
  no longer drop an implicit occurrence in no declaration as a copy of an unrelated one written beside it.
- `digest Module.Type` no longer lists, or counts in `(+N extensions)`, an extension of another module's type
  of the same name: its extensions are placed the way `where` places them, and one the code cannot place is
  listed with `where`'s "may extend another module's" mark. A member miss ranks no member of another module's
  extension, and an external-type answer attributes each local extension to the type it extends.
- The hook's short cold-start back-off arms only where the first index build is what ran out of time: a
  document outline, or a search still running before the index is touched, that overruns in a repository never
  indexed now holds its shape off for the full window, as it does anywhere else.
- Audit: the replay's own tally names the lookups the hook stood aside from, as the scan's does, and the scan
  dump and scan diff count batched and stood-aside windows as the cold misses they are: a context that could not
  reach the index relabels them `unreachable`, and the diff's cold summary includes them.
- A sibling repository whose first index build was stopped partway no longer answers the hook's "the one file
  declaring this name" from the files stored so far: it names no file until a build has finished, since a
  name seen once may be declared again in a file not yet reached.
- The hook answers a grep sweep for a name in place (`grep -rnw Name Dir`, `grep -rn Name Dir`) only where
  its whole refusal is smaller than what the grep prints after its `head`, `tail` or `sed -n` cut; otherwise
  the grep runs, logged as not smaller. Measured, answered sweeps cost 2 to 3.5 times the output they replaced
  and saved too few follow-ups to pay for it. A names search over a tree past the walk's file or byte
  limit is answered unweighed, as before, since what it prints was never measured.
- The hook weighs a window that prints at least three quarters of a Swift file's lines (`sed -n '1,200p'`,
  `head -n 200`, a `Read` with a range past the file's end) as it weighs a whole read of the file: where the
  digest spares less than the further turn it costs, the read runs, as the whole read of the same file already
  did. A narrower window is judged as before.
- `where` with no index store shows a function's name written with no call (`let r = restock`) beside the list
  of its calls, not only when no call is listed, plain and under `--refs`: a sweep for a rename or delete no
  longer misses the reference a store's answer lists as `referenced, not called`.
- `sift diff` does the same for a changed function: a name written with no call is shown beside its calls,
  where it used to show only when no call was listed.
- A first index build cut off partway, as the hook's in-place answer does at its time budget, is resumed by
  the next build rather than started again: each batch of parses is stored as it lands, and the next build
  keeps every stored file that still matches and parses only the rest. `index --full` still parses every file.
- The hook backs off for one minute, not five, after an answer runs past its time budget in a repository whose
  index has never finished a build, so a first build gets another chance soon. Its `overTime` log row names
  the shapes it charged and the back-off it armed.
- `sift audit` names the lookups the hook stood aside from under cold, backed off or over time, with the
  overruns behind them, counted within the audited span and root.
- A first index build resumed after the hook stopped it re-attributes its stored rows once per module
  resolver, recorded in the store, rather than on every attempt, and reads and hashes the rows it keeps in
  parallel: on a throttled 3,236-file app repository an attempt with nothing left to parse spends about a
  second less before it writes the head. What every attempt still pays first (the build files, git's listing
  and status) can on its own fill the hook's three seconds there, and then the head waits for a call with no
  deadline, as before.
- A `where` for a type lists the type's own declaration first, above its extensions, where it used to sit
  wherever its file sorted: a long list of extensions read from its head no longer hides the row that says
  what the name is.
- A nested package's store answers only for that package's files: a `where` about declarations outside it
  takes the no-store path, its note naming the store passed over (`Kit/.build answers only for files in Kit`),
  where it once judged them against that package's build and could resolve a root file to the package's file
  of the same trailing path. The header now reads `none (no index store covers these files; Kit/.build answers
  only for files in Kit)`; `diff` and `affected` match such a declaration by written name instead of listing
  the package's callers as resolved; a bare-name `where` refuses it as outside the store's package with no
  rebuild advice; an `xcodebuild` store in a nested package's `.build` is scoped to that package too; and a
  declaration is matched to the store's occurrences by its exact path, so a dependency's file of the same
  trailing path no longer answers for it.
- `install-hook` registers a binary started by a path under `/private` (`/private/tmp/…`) with that spelling, where
  it used to write `/tmp/…`.
- An audit scans its transcripts on up to eight threads at once, so a fortnight's window that took minutes
  finishes in under one, and files of one name in different directories are listed in the order of their
  paths, so two runs over the same transcripts print the same report.
- An extension written through a framework its file imports, which the tree neither declares as a module
  nor writes as a type, is that framework's type: `where` leaves it out of the tree's type of the same name,
  as a type digest already did, instead of listing it as one that may extend another module's. Only where a
  build file named every file's module: a module named from its directory, or a qualifier that is a module's
  name as the compiler spells it (a hyphen as an underscore), keeps the extension listed and marked.
- An audit holds about a third of the memory it did: each transcript is scanned a line at a time instead of
  read whole, and the working directory read from every transcript's opening lines is let go as soon as it
  is read rather than when the audit ends.
- A semantic `where` for a function or an initializer lists, in its by-name lines for files outside the build
  or written since it, only the lines that call it or reference it with its labels: the base name followed
  by `(` and an argument label it takes, `(` alone where that argument is unlabelled, `()` where none need
  passing, `{` or `() {` for a trailing closure, or after a `.` as an unapplied reference through a type, `self` or `Self`, never through a lowercase value; comments inside the
  parenthesis are skipped, and an initializer is also found through its type name, `Box(label:)`. A local or a
  word spelling the same name is no longer listed; a property, case or type keeps its bare-name match. A file
  written since the build counts the build's references over the same shapes, so a reference the scan cannot
  see no longer cancels a new call.
- A green run no longer stands for a tree that differs from it in a build setting, a C, Objective-C or Metal source, a version-specific package manifest, an Xcode workspace or project file, or a resource a build compiles (a plist, an asset catalog, strings, a storyboard, a Core Data model), so `sift stop` asks for a build after such a change; notes, docs and loose images still do not. `sift stop` also asks when the only files a context edited were such inputs (an xcconfig, a plist, a C source), naming them "build inputs" where it names Swift files otherwise.
- Every file an answer cites is judged against its own build, not the store's newest one, so a partial build (one
  target built after another's file was edited) no longer answers fresh for a file it skipped. The stale header
  counts the files by kind, `stale since last build (1 file changed: <path>)`, `(2 new files)`, `(4 files: 1
  changed, 1 deleted, 2 new)`, and `affected` and `diff` count them the same way; a refusal after a partial build
  names the module the build skipped. `status` still judges from the store's newest build and says in its note
  that a file a partial build skipped shows only on a query.
- `sift stop` no longer asks for a build while a `sift run` of the tree as it stands is in progress, judged by the run's process being alive rather than its heartbeat being recent; a run whose process is gone is ignored.
- A crashed full `swift test` run names the test bundle and the signal (`SiftMCPTests test process exited on signal 5 (SIGTRAP)`), also when SwiftPM's signal line is glued to the end of a test-case line, and lists the last five tests that started there and never ended instead of thousands.
- A build the hook rewrites to `sift run -- …` no longer ends in `--sift-rewritten`: the notice that the hook ran the build rides in the hook's own output as context beside the replaced command, so an older `sift` first on the shell's PATH can no longer reject it, and the allow rules `install-hook` writes (and exact rules for the plain wrapping) match the rewrite as before. `sift run` still accepts the flag from an older hook.
- A search that overflows its page prints the names past it grouped by path once, in order of first appearance, and an extension there carries its line range, so a follow-up digest of that range serves it.
- `sift install` with both `--allow-run` and `--allow-lookups` and no Claude Code names both flags in its "ignored" note, not only `--allow-run`.
- The no-terminal permissions note prints the bare `sift` only where the first `sift` on the PATH is this binary; behind a different `sift` earlier on the PATH it prints the absolute path.
- The first `sift` on the PATH is looked up as the shell does: a relative entry, and an empty one anywhere in the list, is taken against the current directory, so the no-terminal note prints the bare `sift` where `PATH=.:…` runs this binary and the absolute path where it runs another.

## 0.1.3

- `sift install` no longer hangs on `claude mcp add` until its 60-second deadline: every child sift spawns
  reads the null device instead of the terminal the install asked its questions on. A failed `claude` or
  `codex` call is reported with its `Caused by:` chain, not only the line above it.

## 0.1.2

- `sift run` lists a build's or test run's warnings that repeat one signature once, with `×N`, at the first
  occurrence: a release build's 73 `<Module>-<hash>.pcm: No such file or directory` warnings are one line, not
  twenty and `+53 more`. Warnings at different lines whose text differs never merge, an unlocated warning
  reported against a file groups only with others against that file, and a run where nothing repeats lists
  as before.
- Sift installs with Homebrew (`brew install agulhas-labs/tap/sift`, in full: homebrew-core's `sift` is an
  unrelated tool) and npm (`npm install -g @agulhas-labs/sift`, or `npx -y @agulhas-labs/sift`), and the
  documentation says so.
- The release scripts: the Homebrew formula has no redundant `version` line, `homebrew/build.sh` runs
  `brew audit --strict` on the formula it generates (in a throwaway local tap), and `release-notes.sh` writes
  the GitHub release notes from a version's CHANGELOG section and prints the `gh release create` command.

## 0.1.1

- `sift run --without` removes the build it made without your change once the change is back, and says so;
  `--keep-without-build` keeps it for the next proof. A run that could not put the change back removes nothing,
  and a `.sift` reached through a symbolic link is refused before anything is set aside.
- `sift run` names each failing test in full once, with a back-reference under every other signature it failed,
  so each signature's lines add up to its count; parameterised cases are listed in a stable order. A test's
  result line glued behind printed output under `xcodebuild` is counted, and an XCTest failure or run summary
  quoted inside another line no longer turns a green run red. After a crash, a trap raised in the crashed
  test's own body is listed first.
- `affected --reached` can be repeated, one answer per name.
- `digest` serves a path with a space in it as one file, never the words of it; a file target that matches no
  file is logged as a miss; a `File.swift:N` window shows the member's declaration once, whole, with one
  marker per gap.
- `where` lists an extension written with generic arguments or a module name (`extension Box<Int>`,
  `extension App.Box<String>`) as an extension of the type, gives a qualified query the same extensions as the
  bare one, and leaves out or marks extensions of another module's type of the same name. With an index store,
  a conformer whose edited file no longer writes the conformance is labelled as such, and a clause the store
  resolves to another declaration of the name says so instead of counting as direct.
- `search` reads each alternative of `a|b` as its field reads one value: a repeated label (`file:A|file:B`),
  regex alternatives (`/a/|/b/`) and a regex holding a space work, and a mix it cannot read one way is refused
  with the spelling to use.
- `strings` escapes backslashes and control characters in values and the echo, finds a key's interpolated
  spelling through escapes, and bounds the one-word fallback in total, leaving out stop words.
- Signatures print without the space a collapsed line break left inside a bracket; a `diff` whose signature
  changed only in spacing says so.
- The build rewrite stands aside for a settings file it cannot read or that names a key twice, reads a rule on a
  `case` arm or function body, and lets an incomplete line through untouched.
- `sift stop` asks nothing about an edited file that is no longer in the working tree, and reads a green run
  written across a line continuation or followed by a comment.
- `sift uninstall --settings` says it skipped the band step.
- The release bundle names the source tree (or the public commit) it was built from, never a private one.

## 0.1.0

The first release of Sift, a Swift code index for AI coding agents and a wrapper for the builds and tests they run.

- **Reading code.** `digest` lists a type, file or module's members, each with its line range, and serves one
  member's source; `where` finds declarations, extensions, conformers, overrides and callers; `search` finds
  declarations by structural shape; `strings` traces on-screen text to its localization key and code. `similar`
  and `dupes` find code shaped like code you have. Without an index store the answers are syntactic; with the
  one your build writes, `where` resolves callers and `diff` reviews a change declaration by declaration. Every
  answer opens with a line saying which tree it describes and how fresh it is.
- **Running builds and tests.** `sift run` wraps `swift build`, `swift test` and `xcodebuild`, prints what
  failed, and keeps the full log under `.sift/runs/`. An unfiltered `swift test` is checked against the tests the
  index declares (the `inventory:` line); a run whose filter matched no test exits 4 and names it.
  `--without <pathspec>` runs named tests with and without your change, `--since <rev>` does so for a change
  already committed, and `--without-line <file>:<line>` does so for one line; `--proved` and `--coverage` report
  whether a command passed on this exact tree and which changed lines the tests ran. `sift test` shards a scheme's
  tests across simulators, and `sift build --analyse` ranks what the compiler spent longest type-checking.
- **Impact.** `affected` names the tests that reference what a diff changed, with their `-only-testing:`
  arguments; `diff` shows declarations added, removed or changed, their callers and the tests that reach them.
- **Usage.** `audit` finds Swift lookups in your Claude Code transcripts that went around the index, `usage`
  summarises index calls, and `report` writes one self-contained HTML page. The savings they print are an
  estimate of source not read, not a measured token saving.
- **The Claude Code hook.** A session primer; a Swift lookup (a grep, a glob, a whole-file read) the index can
  answer more cheaply is answered in place, and the identical re-run is let through; bare builds are pointed at
  `sift run`; and a check after an edit blocks unparseable Swift.
- **Install.** `sift install` sets up the MCP server and hooks in Claude Code, Cursor and Codex (Cursor and Codex
  are experimental), asking once for each; `install-hook`, `uninstall-hook` and `uninstall` undo or adjust it.
  Nothing leaves your machine.
