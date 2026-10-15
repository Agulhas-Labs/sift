# Sift

**Two tools in one binary for AI coding agents working in Swift: build and test output an agent can afford
to read, and semantic lookups for when grep is too noisy.** Everything runs on your machine.

```sh
brew install agulhas-labs/tap/sift && sift install
```

macOS 13+ on Apple silicon. Give Homebrew the full name: its plain `sift` is an unrelated grep alternative.
`sift install` finds Claude Code, Cursor and Codex, asks once for each, and adds the MCP server and hooks;
then start a new session (`sift doctor` checks it). npm, a release bundle and building from source:
[INSTALL.md](Distribution/INSTALL.md) and [the guide](Docs/Guide.md#2-install).

## What pays from the first command

**`sift run`** wraps `swift build`, `swift test` and `xcodebuild` and prints the verdict and what failed, not
the log:

```
$ sift run -- swift test
✘ swift test — exit 1
  aFailingTest() — Tests/SiftCoreTests/DepotStoreTests.swift:11 (body :8-12)
    Expectation failed: depot.count == 2 → false depot.count → 1
totals: ✘ failed · Swift Testing 3 tests in 1 suite, 1 failure, 0 skipped
inventory: 3 declared, 3 reported
raw: Depot @ ec26cde (Swift dirty: 1) · .sift/runs/failed-8dd8a8d4-run-20260929-090807Z-1b642cfb.log (25 lines in, 6 out), kept until it passes or 5 newer failures
```

Errors keep their file, line and column; sites of one warning message fold into the first with `×N` (the rest are in the raw log); the full log is kept and named on the last
line. On the 20 build and test outputs we benchmarked, it cut the bytes by a median 94% and no answer there was
larger than its log ([Benchmarks](Benchmarks/RESULTS-run-compression.md)). End to end, on one private codebase, 0.1.5
cut the pooled cost of a session by 9.5% over 216 paired runs (four tasks cheaper, two dearer, three no detectable difference)
([results](Benchmarks/RESULTS-live.md)). A filtered run that ran nothing
fails instead of passing, and an unfiltered `swift test` is counted against the tests the index declares.

**The hooks** `sift install` adds to Claude Code:

- a whole-file Read of a large Swift file is answered in place by its digest (each member's signature and line
  range, a fraction of the file), so the next read can be a ranged one. This is the `Read` tool; a whole-file `cat` or `sed` is
  answered only when the digest spares more than the turn costs, and small files are let through. The same Read again always
  goes through ([the rules](Docs/Guide.md#the-shell-and-why-advice-was-not-enough));
- an edit that leaves a `.swift` file unparseable comes straight back with its errors, once per broken version of the file;
- a bare `swift build`, `swift test` or `xcodebuild` is pointed at `sift run` (a build whose output is redirected to a log is let through as a gate leg, and a piped one is let through too, as a caller trimming the output), and a session that edited Swift
  is sent back, once, to build before it stops.

## Semantic lookups, for when grep is too noisy

These answer from an index of your code (and, after a build, the compiler's own index store), with a first line
saying which tree they describe and how fresh it is. On a small answer grep is often shorter; they pay where
grep can't tell a call from a comment or a same-named method.

- **`where`**: the real callers, a property's reads and writes, conformers and overrides, each site with its
  enclosing function; `where --refs` for a rename or delete sweep, comments, strings and Markdown included.
- **`search`**: code by shape, like tests that start a `Task` and never await it:
  `sift search 'kind:func attr:Test calls:Task !has:await'`.
- **`strings`**: on-screen text to its localization key and the code that shows it.
- **`digest`**: a type, file or module as its members with line ranges; `Type.member` for one member's source.
- **`sift affected`**: the tests your diff can reach, with ready-to-paste `--filter` and `-only-testing:`.

The server exposes only the query tools (`digest`, `where`, `search`, `strings`).
Everything else stays on the command line, including `sift run --without` (does this test fail without my
fix?), `sift diff`, `sift build --analyse` and `sift test` (a scheme sharded across simulators).

## More

- [The guide](Docs/Guide.md): setup, configuration, freshness, `sift run` in depth, every command.
- [The DocC catalog](Docs/Sift.docc/): getting started, the four tools, builds and tests, the hooks.
- [Sift.md](Sift.md): the rule an agent reads. [Docs/Design.md](Docs/Design.md): how it works and why.
- [Docs/AnswerContract.md](Docs/AnswerContract.md): what every answer promises about itself.
- [Benchmarks/](Benchmarks/): what was measured and how it was run; a rerun needs your own corpus and tasks file (`bench.py run --corpus <repo>@<commit> --tasks <file>`; `Benchmarks/tasks.example.json` is the template), since the measured commit is not in this repository's history. [CHANGELOG.md](CHANGELOG.md).

Nothing leaves your machine. The index is a SQLite file at `.sift/index.db`, kept out of `git status`;
`sift install` copies each settings or rule file it rewrites to `.bak-sift` first (what `claude mcp add` and `codex mcp add` write is theirs), and `sift uninstall` takes it all
back out. [What it touches](Docs/Guide.md#10-what-it-touches) lists every file.

## License

Apache 2.0. See [LICENSE](LICENSE).
