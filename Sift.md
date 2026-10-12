---
paths:
  - "**/*.swift"
---

**Prefer sift over grepping, globbing or reading Swift source by hand: answer from the index before reading a file,
`where` instead of grep, every build and test through `sift run --`.**

| Reach for | When |
|---|---|
| `digest` | before the first look at a Swift file: a type, path, module or `Type.member`, several per call; what every answer promises: `sift help answers` |
| `where` | where X is defined, who conforms, what calls or overrides it; `where --refs` for a rename or delete sweep: the code sites, then comments, strings, Markdown and file names under `not code` |
| `search` | code by shape, not name (`sift help queries`); before writing a helper |
| `sift similar` / `sift dupes` | then, near-duplicate bodies: a lower bound, never a verdict |
| `strings` | UI text, to its key or Swift literal |
| `sift run --` | any build or test, from Bash |
| `sift affected` | which tests your change could have broken: **a lower bound, never a green light** |
| `sift test` | a slow simulator suite, or what is not being run (`--analyse`) |
| `sift build --analyse` | which code is slow to compile |
| `sift audit` | which Swift lookups missed the index |

Every verb has `sift <verb> --help`; `sift help` lists the topics.

## Reading code

Digest before the first look at a Swift file, then a *ranged* Read of only the members that matter. **A cited location is not already located**: a `File.swift:120` or `:95-135` from an issue, a review or a build error goes to `digest File.swift:120` (or `:95-135`), not a guessed `sed -n '95,135p'` window. Never judge the size first: below about 60 lines `digest` returns the source.

## The hook

**A lookup of Swift source is answered in place, or let through.** A denial is not a wall and not a permission problem: re-run the same lookup and it is allowed, and **a re-run is never held against you**. A raw build or test is rewritten to `sift run --`, and the answer's first line says so; `sift help refusals` has the full accounting.

## Running, no tools, worktree

- `sift run --` runs bare, never piped (`sift help run-output`, `sift help test-output`, `sift help build-output`).
- No `sift` tools present: use the CLI if `sift` is on PATH, else plain tools.
- In a git worktree: pass `--root`, and build once before trusting `where`'s callers (`sift help worktree-index`).
- `sift affected` opens with two lines of limits specific to its answer; the standing list of what it cannot see is `sift help affected-limits`.
