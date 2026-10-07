# Agent guidelines — Sift

The index to working in this repo. Read the files it links before starting a task.

## Project docs
- [.agents/Project.md](.agents/Project.md) — what Sift is and its scope boundary (read this first).
- [.agents/PROJECT_STRUCTURE.md](.agents/PROJECT_STRUCTURE.md) — the layout, one line per directory.
- [.agents/CodingGuidelines.md](.agents/CodingGuidelines.md) — conventions specific to this repo.
- [Docs/Design.md](Docs/Design.md) — the authoritative spec.
- [Docs/Contributing.md](Docs/Contributing.md) — build, test, lint, hooks and privacy gates. Read it before
  the first commit: `swift test` fails on a new example name the permit list does not carry (untracked
  files included), and `pre-push` reads every file that is not gitignored.
- [Sift.md](Sift.md) — how an agent should *use* the tool. At the root because consuming repos
  `@`-import it.
