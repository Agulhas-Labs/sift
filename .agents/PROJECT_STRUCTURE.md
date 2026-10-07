# Project structure — Sift

A single SwiftPM package. No app target, no XcodeGen. For the live structure run `sift digest .` (repo
overview) or `sift digest <Module>`; this file keeps only what no command gives.

- `Package.swift` — products `SiftCore` (library) and `sift` (executable); `.macOS(.v13)` floor (a dev tool
  keeps a low floor); Swift 6 strict, warnings as errors; swift-syntax (exact pin), swift-argument-parser,
  Yams (`project.yml` module mapping).
- `Sources/SiftCore/` — parsing, storage, query; no I/O framing, no CLI/MCP knowledge.
- `Sources/SiftCLI/` — the ArgumentParser front end: one file per command.
- `Sources/SiftMCP/` — the MCP stdio server, and what both faces share above Core.
- `Tests/SiftCoreTests/` — Swift Testing (`@Test`/`#expect`), one suite per file. `Fixtures/` files are `.txt`
  so format and lint never touch them; `Fixtures/RunOutput/` holds real captured build/test transcripts,
  provenance in `PROVENANCE.md` beside them.
- `Tests/SiftMCPTests/` — pipe-driven protocol tests, and the CLI command tests (it `@testable import`s SiftCLI).
- `Docs/` — Design (spec), Guide (user reference), Contributing, AnswerContract, ProgressContract.
- `Distribution/` — what ships (`make-dist.sh`, `install.sh`, `npm/`, `homebrew/`), the privacy gate
  (`verify-private.sh`, `verify-tree.sh`, `private-terms.txt`) and the permit list `example-names.txt`.
  `mod/` is a prototype Claude Code mod (TypeScript, `claude plugin validate|test Distribution/mod`, loaded
  with `--plugin-dir`) that points the Read/Grep/Glob descriptions at sift in a Swift repository.
- `githooks/` — the `core.hooksPath` target (see Contributing).
- `ValidationProjects/` — sample projects that sift's test-running features are validated against; never
  touched by `swift test`; see its own README.md.
