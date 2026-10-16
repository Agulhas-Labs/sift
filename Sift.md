---
paths:
  - "**/*.swift"
---

**Prefer sift over grepping, globbing or reading Swift source by hand: answer from the index before reading a file,
`where` instead of grep, every build and test through `sift run --`.**

| Reach for | When |
|---|---|
| `digest` | before the first look at a Swift file: a type, path, module or `Type.member`, several per call |
| `where` | where X is defined, who conforms, what calls or overrides it; `where --refs` for a rename or delete sweep (code sites, then `not code`); `where --files` when the question is only which files; `where --decl` when the question is only where it is declared |
| `search` | code by shape, not name (`sift help queries`) |
| `strings` | UI text, to its key or Swift literal |
| `sift run --` | any build or test, from Bash, bare, never piped |

`sift affected` (which tests a change could break), `sift test`, `sift similar`/`dupes`, `sift build --analyse`, `sift audit`: `sift <verb> --help`; `sift help` lists the topics.

A cited `File.swift:120` or `:95-135` goes to `digest File.swift:120`, not a guessed `sed -n` window; then Read only the members that matter. Below about 60 lines `digest` returns the source.

The hook answers a Swift lookup in place or lets it through. A denial is not a wall: re-run the same lookup and it is allowed, and a re-run is never held against you.

In a git worktree, pass `--root` to lookups, not to `sift run`. No `sift` tools present: use the CLI if `sift` is on PATH.
