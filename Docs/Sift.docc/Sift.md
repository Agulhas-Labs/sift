# Sift

@Metadata {
    @TechnologyRoot
}

Two tools in one binary for AI coding agents working in Swift: build and test output an agent can afford to
read, and semantic lookups for when grep is too noisy.

## Overview

Sift is one binary, `sift`. It is a command-line tool, and it is an MCP server for the agent you already use.
It installs hooks for Claude Code, and experimentally for Cursor and Codex.

What pays from the first command:

- **Build and test output without the log.** `sift run` wraps `swift build`, `swift test` and
  `xcodebuild` and prints the verdict and what failed, not the log.
- **Answers in place, from the hooks.** A whole-file Read of a large Swift file is answered with its
  digest, and an edit that leaves a `.swift` file unparseable comes straight back with its errors.

Semantic lookups, for when grep is too noisy:

- **`where`** finds declarations, conformers, overrides and the real callers.
- **`search`** finds code by a shape that grep cannot express.
- **`strings`** traces on-screen text to its localization key.
- **`digest`** lists a type's members, each with its line range, so an agent can read the lines it needs.
- **`affected`**, with an index store, names the tests a diff reaches.

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

The Claude Code plugin does not exist yet, so `sift install` is the route that sets `sift` up in Claude Code
today.

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
