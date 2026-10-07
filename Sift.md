---
paths:
  - "**/*.swift"
---

**Prefer sift over grepping, globbing or reading Swift source by hand: answer from the index before reading a file,
`where` instead of grep, every build and test through `sift run --`.**

| Reach for | When |
|---|---|
| `digest` | before the first look at a Swift file: a type, file path, module, `<file>.md`; known members: `Type.member`, several per call (outline first is a second turn); `digest .` in a cold repo; what every answer promises: `sift help answers` |
| `where` | where X is defined, who conforms, what calls or overrides it; `where --refs` for a rename or delete sweep, code occurrences only, so grep for a doc comment or string literal too |
| `search` | code by shape rather than name (`sift help queries`); before writing a helper, by the callee it cannot avoid |
| `sift similar` / `sift dupes` | then, near-duplicate bodies of that helper: a lower bound, never a verdict |
| `strings` | UI text, to a localization key or the Swift literal holding it |
| `sift run --` | any `swift build` / `swift test` / `xcodebuild`, from Bash |
| `sift affected` | which tests your change could have broken (working tree, or `--from`/`--to`): **a lower bound, never a green light** |
| `sift test` | a slow simulator suite (`--shards N`), or what is not being run (`sift test --analyse`) |
| `sift build --analyse` | which code is slow to compile |
| `sift audit` | which Swift lookups missed the index |

Read on: a denial → *The hook*; a build or test → *Running*; no tools → *If the tools aren't there*; a worktree →
*In a git worktree*. Every verb has `sift <verb> --help`; the long form is *Agent guide: situations* in
`Docs/Guide.md` of the Sift source repo.

## Reading code

Reach for `digest` before the first look at a Swift file, and the shell is where they are most often skipped
(`grep -n`, `sed -n '/pattern/p'`, `grep -rn Symbol Sources/`). Digest to locate, then a *ranged* Read of only the
members that matter. **A cited location is not already located**: a `File.swift:120` or `:95-135` handed over by an
issue, a review or a build error goes to `digest File.swift:120` (or `:95-135`), not a guessed `sed -n '95,135p'`
window. Already making a Bash call for `git` or `gh`? `sift digest …` and `sift where …` go in the same line. Never
judge the size first: below about 60 lines `digest` returns the source itself, and for a larger file the digest is
usually the smaller answer. Reaching for Read because a file "looks small" is the one case that is always wasted. Grep
cannot answer these reliably because the pattern spans nesting and line breaks: use `search`.

## The hook

**A lookup of Swift source is answered in place, or let through** — a shell command, a Grep, a Glob, or a whole-file
Read. A denial is not a wall and not a permission problem: re-run the same lookup and it is allowed. Take the
suggestion when it fits — usually it is the shorter path anyway — and re-run when it does not. **A re-run is never
held against you.** Don't work around it by reading the file whole instead, or by re-asking through a different tool;
both cost more than the command did. Never interrupted: a ranged `Read` of a file whose digest you hold, a
fixed-string search (`-F`, `fgrep`) for anything but a name, a merge's conflict markers (`<<<<<<<`, `=======`,
`>>>>>>>`). A raw `swift test` is rewritten to `sift run -- swift test`, or refused once with that call.
`sift help refusals` has the full accounting.

## Running

`sift run --` runs bare, never piped or redirected: verdict and failures, ending with the raw log's path in `.sift/runs/`; exit code passed through, except 4 (a
`--filter` run that executed no test) and 5 (such a run that did not build), which are sift's.
`inventory: N declared, M reported`, not `swift test list | grep -c`, is discovered vs run; only an unfiltered, serial
root-package `swift test` prints it (`inventory: not checked — …` is another outcome). **Proving a test fails without
your change**: `sift run --without Sources -- swift test --filter …` in one call (a committed fix: add `--since <base>`),
never a hand-rolled revert; `--without-line Sources/X.swift:42` when the fix cannot build set aside. Reading the answer:
`sift help run-output`, `sift help test-output`, `sift help build-output`.

## If the tools aren't there

**If no `sift` tools are present, use the Bash CLI if `sift` is on PATH, else ignore this file and use Read/Grep** — a
missing server is not a problem to report or fix. **If the index tools vanish mid-session, the CLI keeps working — use
it, don't fall back to Grep**, since the CLI does not depend on the server at all: `sift digest <Type>`,
`sift where <Symbol>`, `sift search '<query>'`, `sift strings "<text>"`. **Stop a sift server by its pid
(`sift servers`), never by a pattern** — `pkill -f "sift mcp"` ends every other session's server too.

## In a git worktree

Pass `root:` with your worktree's path (`--root` from Bash, on queries; `sift run` takes none, so `cd` there) and check that the header's `tree:` names the worktree
(`tree: Sift (worktree agent-1a2b3c4d)`, not a bare `tree: Sift`). **Build once before relying on `where`'s callers,
overrides and references**: until then `where` and `affected` fall back to name-matched leads (`sift help worktree-index`).
