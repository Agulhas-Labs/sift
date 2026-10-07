# Claude Code Configuration — Sift

Start at **[AGENTS.md](AGENTS.md)** — the index to all agent guidelines (project structure, build/test,
coding rules). Read the files it links before starting a task.

## Always
- **A defect found in the index is fixed, not reported.** Finding a bug while doing something else —
  reading a transcript, checking a number, answering a question — is not a reason to hand it back as an
  offer (this overrides the general don't-fix-outside-scope rule). Fix it in the same change, pin the fix
  with a test that fails without it, and say what changed.
- **The full suite runs once, at merge.** It takes 3–8 minutes. While you work, run the tests covering
  your change (`sift run -- swift test --filter …`, plus every suite `sift affected` lists); when the work
  is split across several agents, only the one that merges runs the whole suite, and the others say in
  their report that it is still owed.
- **Verify before concluding**: `swift build` and `swift test` pass, `swiftlint lint --strict` is clean,
  `swiftformat Sources Tests --lint` reports nothing, and every changed file conforms to
  [.agents/CodingGuidelines.md](.agents/CodingGuidelines.md). The pre-commit hook and the pre-push hook
  (`sift run --proved -- swift test`, then `Distribution/verify-tree.sh`) are the backstop; the pre-push
  refuses an unproved tree, so run the suite last, then push.
- **Get a design review before changing the MCP output shape.** It is a contract other tools consume
  ([Docs/AnswerContract.md](Docs/AnswerContract.md)); design changes land in `Docs/Design.md` first.
- **Commit on a branch, with a clear message.** When a logical, self-contained unit of work is complete
  and verified, commit it: never broken or half-finished, and unrelated changes in separate commits.
  A branch merges to `main` once its gates are green; a red or unfinished branch is never merged. After a
  merge, deploy (`Distribution/make-dist.sh` + the bundle's `install.sh`) and delete the merged branches.

## Project shape
One binary, two faces: `sift` is a CLI for humans and an MCP stdio server for Claude Code, serving
compressed structural views of Swift codebases — type digests, symbol lookup, structural search —
with an explicit freshness contract on every answer. `SiftCore` owns parsing (SwiftSyntax), storage
(SQLite), and query; both front ends stay thin. The authoritative spec is
**[Docs/Design.md](Docs/Design.md)** — scope boundaries and the data-lifecycle rules live there, and
design changes land there first. Two rules from it are carved in stone: never retain syntax trees
across files, and the MCP server's stdout carries JSON-RPC only.
