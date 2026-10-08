# Changelog

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
