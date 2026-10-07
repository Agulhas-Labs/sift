# Sift — the project

A developer tool that cuts the context cost and error rate of AI-assisted work on Swift codebases by
serving compressed, structurally accurate views of code. One binary, two faces: the `sift` CLI and an MCP
stdio server. Four query tools: `digest` (a type's declaration surface), `where` (declarations, conformers,
callers), `search` (declarations by structural shape), `strings` (display text ↔ localization key).
Everything else exists to make those four honest and fast.

The authoritative spec is [../Docs/Design.md](../Docs/Design.md), and its boundaries are binding: syntactic
index via SwiftSyntax + SQLite; semantic augmentation only from an existing index store; explicit
freshness on every query answer; no daemon, no LSP reimplementation, no writes to source, no network, one repository
per index. It must scale from a ~200-file personal project to a 5,000+-file large monorepo — the large
profile is a hard requirement that drives storage and memory decisions.

The binary assumes nothing about a repository beyond plain git: it is `core.hooksPath`-aware and keeps
its cache out of the tree through `.git/info/exclude`. Whatever conventions, hooks or linters a repo
carries are that repo's business — including this one's, which are dev-time only and never something
the shipped binary looks for.
