# sift

A Swift code index for AI coding agents. Instead of reading whole files to learn what a type does, or
grepping and then opening half the matches, your agent asks sift: the shape of a type with a line
range for every member, where a symbol is declared and who calls it, or every function that matches a
structural pattern. It reads the few lines it needs next and skips the rest.

## Use it with Claude Code

From the root of a Swift repository:

```sh
claude mcp add --transport stdio --scope local sift -- npx -y @agulhas-labs/sift mcp
```

Its tools load up front only where Swift is in view, so `--scope user` works too; the
[README](https://github.com/Agulhas-Labs/sift#use-it-with-claude-code) covers the scopes, including a
committed `.mcp.json` with `--scope project`.

`npx` fetches the package when the server starts, so you're always on the latest release. Flags go
before the `--`; anything after it is passed to `sift`.

Then try it in a Swift repository. The first query builds the index:

```sh
npx -y @agulhas-labs/sift status
npx -y @agulhas-labs/sift digest MyViewModel
```

To set it up in every agent you use (Claude Code, Cursor, Codex) in one step, install the package and run
`sift install`; it finds each agent, asks once, and says what it wrote:

```sh
npm install -g @agulhas-labs/sift
sift install
```

For the hooks that get agents to use it by default, the usage, audit and report commands and the rest of the CLI, see
the [README on GitHub](https://github.com/Agulhas-Labs/sift#readme).

## Requirements

macOS 13 or later on Apple silicon, and Node 18+ to launch it. The binary comes in a platform package
installed as an optional dependency.

## What it touches

sift makes no network calls. `npx` does contact the registry before sift starts, which is how it keeps
you current; install with Homebrew (`brew install agulhas-labs/tap/sift`) if you'd rather it didn't.
Inside a repository, sift writes a `.sift/` cache and adds one line to `.git/info/exclude`. Outside
it, it keeps its logs and settings in `~/.sift/`. None of it leaves your machine.

## License

Apache 2.0. The license text is in `LICENSE.txt`, and the open-source components the binary links are
listed in `THIRD-PARTY-NOTICES.txt` in the platform package, next to the binary.
