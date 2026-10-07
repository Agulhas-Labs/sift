# Coding guidelines — Sift

Formatting and mechanical style are enforced by SwiftFormat and SwiftLint (`.swiftformat`,
`.swiftlint.yml`) and are not restated here. What follows is what those tools cannot check — the rules
the design depends on, carried over from [../Docs/Design.md](../Docs/Design.md):

- **Never retain syntax trees.** Parse a file, walk it once, emit compact value records, discard the
  tree before the next file (holding trees is the memory cliff at monorepo scale).
- **Layering is one-way.** `SiftCore` knows nothing of CLI or MCP concerns; both front ends stay
  thin. Anything reusable belongs in Core.
- **stdout is sacred in the MCP server.** JSON-RPC framing only; all logging goes to stderr or a file.
  `print(` is banned repo-wide (the `no_print` SwiftLint rule).
- **Refuse over guess.** Every freshness or resolution ambiguity resolves toward refusing to answer
  with instructions, never a fast wrong answer. Output states which mode (syntactic/semantic) produced
  it.
- **Honesty markers are load-bearing.** Macro-generated and synthesized members the parser cannot see
  are declared as gaps in output, never silently omitted.
- **A shared marker names what it counts, never what its first caller counted.** Reused by a new answer
  shape, a truncation marker, paging cursor or floor note takes that shape's noun ("heading lines") as a
  parameter; parameterise at the first reuse.
- **SQLite discipline.** `PRAGMA foreign_keys = ON` on every writing connection; per-file reindex is
  delete-then-insert in one transaction; schema mismatch → drop and rebuild, never migrate.
- **One argument, one directory; canonicalise at comparison time, never at write.** An argument that
  narrows more than one record (`--root` narrows `usage.jsonl` *and* `run.jsonl`) is resolved once,
  against the union of everything it could name, and the result handed to each reader. Compare through
  `CanonicalPath.of`; a log records what happened, so normalising on the way in rewrites the record.
- **Tests make temporary directories only through `TemporaryDirectory`.** `make` files each one with the
  test case's scope (the suite carries `.temporaryDirectories`); a fixture that runs SwiftPM points `TMPDIR`
  into that scope, because SwiftPM's lock files outlive the package path. `TemporaryDirectoryTests` fails
  on any other route to the temporary directory from `Tests/`.
- **A doc comment carries no issue number and no date, and each of its paragraphs is one line.**
  `CommentHistoryTests.noCommentInTheTreeCarriesADateOrAnIssueNumber` fails on any `#NN` or date in a Swift
  or shell comment, and the AST linter rejects a hard-wrapped `///` paragraph. The issue number goes in the
  commit message and, where the decision is one, in `Docs/Design.md`.
- **A test that asserts on a *resolved* semantic answer waits for the store first.** `try await
  engine.awaitSemanticStore()` (`Tests/SiftCoreTests/SemanticStoreWarmUp.swift`), once per engine after the
  last build, not around each query (the opened store is cached on the engine). Without it the assertion
  races the load and reads `semantic: warming`, indistinguishable from a real staleness bug. The wait is
  test-side only; bound it with a deadline that throws, and never loosen an assertion so `warming` passes.
- **A test calls the in-place answerer, the hook, or a replay off the concurrency pool.** The answerer
  blocks its caller on a semaphore; an `async` test calling it directly starves the pool and every answer
  in flight runs out its budget as `overTime`. Go through `InPlaceAnswerTests.onItsOwnThread` (the replay
  helpers in `TranscriptAuditReplayTests` already do), with a scratch back-off and the `roomy` budget unless
  the budget or back-off is the subject.
- **A test never raises a signal at the test runner, or changes how the runner takes one.** Signal
  disposition and the main thread's mask are process-wide and other suites run beside yours; `.serialized`
  cannot rule it out. Arming a watch, `kill(getpid(), …)`, `pthread_kill` and `pthread_sigmask` go in a
  scenario run in a child that runs nothing else (`Tests/SiftMCPTests/SignalScenarioProcess.swift`, an exit
  test). A signal sent to a process the test started is fine.
- **An answer's outcome wording is never a substring of a line every answer carries, and a number that
  decides an answer is asserted where it is rendered.** Assert on wording only that outcome prints, and
  render at least one answer of each outcome that carries a number.
- **A ranking's weights are judged from two probes of a real tree, not from the diff**: the evidence the
  feature exists for, and a deliberately weak target.
- **A test that borrows another suite's fixture inherits its obligations.** The population for a rule like
  the semantic-store wait is every test that *reaches* a built store, whoever built it: sweep from the
  fixture's call sites, not from a list of suites.
- **A fixture that drives a shell script clears that script's own environment switches** rather than
  inheriting them from the caller (e.g. `SIFT_PRE_PUSH_RAW=1`): set each switch the script reads to a value
  the test chose, `nil` included.
- **Set-aside proofs diff the patch against the branch's own HEAD, not the default branch, where the change
  adds a file; where it deletes a function, set aside a hand-written, compiling inverse of the one property
  the test pins, never the whole diff.** Read the build line first: a compile error proves nothing.
- **The privacy gate reads identifier-shaped fragments out of string literals**, so a fixture never spells a
  name with `\b` around it (anchor with `\<` and `\>`), and a documentation link to a new member is made to
  its type, not `Type/member(label:other:)`. Both fail only at full-suite time.
- **A closure parameter added to an existing function is declared behind the closures already there.** An
  unlabelled trailing closure binds to the first parameter that can take one, so inserting one ahead
  silently re-points every call site's trailing closure; nothing fails.
- **A CLI command writes its answer through a `CommandOutput`, never straight to `StandardStreams`.** The
  command holds `var output: CommandOutput = .standard`; its tests inject a `RecordedOutput`
  (`Tests/SiftMCPTests/`) and read what it printed.
- **What spills out of an over-long file becomes a type of its own, never a second file extending the old
  one.** The AST linter names an extension-only file after the type it extends and SwiftPM refuses two files
  of one name in a module. Move a cohesive group into a new type in a file named after it
  (`WhereStoreLines`, `RefusedCallShapeClassifier`); a private helper can move into the file's trailing
  extension.
