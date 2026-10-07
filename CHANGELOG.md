# Changelog

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
