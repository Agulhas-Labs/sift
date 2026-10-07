# Sift

@Metadata {
    @TechnologyRoot
}

A Swift code index for AI coding agents, and a wrapper for the builds and tests they run.

## Overview

Sift is one binary, `sift`. It is a command-line tool, and it is an MCP server for the agent you already use.
It installs hooks for Claude Code, and experimentally for Cursor and Codex.

What it is for:

- **Compact structural views of Swift code.** `digest` lists a type's members, each with its line range,
  so an agent can read the lines it needs instead of the whole file. `where` finds declarations,
  conformers, overrides and callers. `search` finds code by a shape that grep cannot express.
- **Build and test output without the log.** `sift run` wraps `swift build`, `swift test` and
  `xcodebuild` and prints what failed.
- **Semantic answers from your build.** With an index store, `where` resolves callers, `affected` names
  the tests a diff reaches, and `diff` reviews a change declaration by declaration.

Every answer opens with a line saying which tree it describes and how fresh it is, and it says so when it
cannot be sure.

### What it does not claim

Sift does not promise to save tokens. Measured end to end on nine tasks, it made no detectable difference
to the pooled cost of a session: cheaper on some tasks, dearer on others, plus a small fixed start cost.
Those are runs on one codebase with one model, not a promise about yours. The numbers, the method and
the limits are in the
[README](https://github.com/Agulhas-Labs/sift/blob/main/README.md#what-we-measured) and the repository's
`Benchmarks/` folder, and the weaker spots are listed under
[Known gaps](https://github.com/Agulhas-Labs/sift/blob/main/README.md#known-gaps).

### Requirements

An Apple silicon Mac on macOS 13 or later, and git: a directory that is not a git repository is refused.
The semantic half also needs Xcode or the Command Line Tools. Building from source needs Swift 6.2 or later.

### Not published yet

The public repository (`Agulhas-Labs/sift`), the Homebrew tap, the npm package and the Claude Code plugin do
not exist yet. Until the release, every link into that repository from these articles, and the clone URL in
<doc:GettingStarted>, leads nowhere, and so does the Homebrew and npm install. The source tree is the only
way to get `sift` today.

### The full reference

These articles are short and follow tasks. The complete reference, with every command, option, setting and
environment variable, is
[the guide](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md), and each article links to
the part it summarises.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Installing>

### Using Sift

- <doc:TheFourTools>
- <doc:RunningBuildsAndTests>
- <doc:HowTheHooksBehave>

### When something is wrong

- <doc:Troubleshooting>
