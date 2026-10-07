# Contributing

The build, test, lint and hook commands, and what each hook and gate does.

```sh
sh setup.sh     # first time: installs SwiftLint and SwiftFormat, activates the git hooks
swift build
swift test
```

Style is enforced by two tools, both configured at the repo root:

```sh
swiftformat Sources Tests --lint    # drop --lint to apply
swiftlint lint --strict             # the form the hook runs: a warning fails the run
```

## Hooks

`setup.sh` points `core.hooksPath` at `githooks/`.

- **`pre-commit`** runs an optional, gitignored `githooks/pre-commit.local` first, for anything
  machine-local, then SwiftFormat and SwiftLint over the staged Swift files.
- **`pre-push`** refuses unless `sift run --proved -- swift test` says this exact tree passed: run
  `sift run -- swift test` after your last edit, then push. `SIFT_PRE_PUSH_RUN=1` runs the suite inside the
  push; without `sift`, or with `SIFT_PRE_PUSH_RAW=1`, the hook runs `swift test` bare. A push that only
  deletes refs skips both gates. It then runs the privacy gate `sh Distribution/verify-tree.sh`, which reads
  every tracked file plus every file git neither tracks nor ignores for a short list of generic terms, the
  builder's identity and the names of sibling projects (discovered at run time, not committed). A finding
  (exit 1) blocks the push: remove the name or `.gitignore` the file. Exit 2 means no siblings to learn
  names from; the push continues, so re-gate before publishing.

## Cutting the public repository

`sh Distribution/cut-public-repo.sh [--at <rev>] <target-dir>` makes a new one-commit repository from
`git archive` at a commit, authored as `Agulhas Labs <developer@agulhaslabs.dev>` (`--author` to change).
It refuses unless `verify-tree.sh` passes in a detached worktree over exactly the files committed, and
re-cuts an earlier unpublished cut by amending. It pushes nothing; it prints the publish commands.

## Running a server by hand

A `sift mcp` started from a shell or a test appends to the logs a person reads unless it is told not to:
give it `SIFT_SERVER_LOG` and `SIFT_USAGE_LOG` naming files of its own, and leave `CLAUDE_CODE_SESSION_ID`
out of its environment, so its calls are filed under no conversation. **Stop it by its pid** (`kill $!`),
never `pkill` by pattern (Design.md, *Server lifecycle*).

**Probing `sift run` by hand, set `SIFT_RUN_LOG` to a scratch file, or run it under a scratch `HOME`** —
every per-user path follows `CFFIXED_USER_HOME`, then `HOME` (`SiftPaths.userHome`), so a probe given
neither lands in the real `~/.sift/run.jsonl` that `usage` and `flakes` read.

## The permit list

`swift test` includes `ExampleNamesTests`, which fails on any compound identifier — a camel-cased name
such as `RecordDetailView` — standing in an example position (a fixture, a string literal, a comment, a
document) that `Distribution/example-names.txt` does not carry. It reads untracked files too, so a new
fixture fails the day it is written rather than the day it is staged. Names the code itself declares are
exempt; the compiler governs those. When it fails, the message names the file, the line and the name.
The two repairs:

- **Rename to an existing placeholder** from the list — usually the right one.
- **Add a genuinely new invention**: one name per line, in sorted order, in the same change as the file
  that uses it. The list is published, so it may only ever hold invented placeholders and public
  framework API — never a real product, person or codebase. A line nothing uses any more fails the suite
  too, so remove it with its last use.

The reasoning behind both gates is in [Design.md](Design.md) §9.
