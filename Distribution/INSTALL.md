<!-- Bundle-facing install guide. `make-dist.sh` copies this into the tarball, replacing the
     PROVENANCE placeholder below with the real build facts. Evergreen — what changed in a release
     goes in CHANGELOG.md, which ships beside this. -->
# sift — install

A Swift toolkit for AI coding agents: an index of your code (type digests, symbol resolution,
member source, reference sweeps, structural search, string-catalog tracing), builds and tests that
tell the truth, and checks on every change — as a CLI and an MCP stdio server for Claude Code.

<!-- PROVENANCE -->

## Is it earning its place?

Two commands, both read-only and local, meant to be pasted into a Claude session:

```sh
sift audit --since today     # the share, and every lookup that went around the index, named
sift usage --since today     # what was called, how fast, and what failed
```

`audit` answers "was this worth having"; `usage` is the call log behind it. Both are **pseudonymised
by default** (names become stable salted pseudonyms, counts stay), so a report is safe to paste anywhere;
`--unredact` prints the real names.

## What changed

`CHANGELOG.md`, in this bundle.

## License

Apache License 2.0 — `LICENSE.txt` in this bundle carries the text; the source is public. The
open-source components the binary links, and their licenses, are listed in `THIRD-PARTY-NOTICES.txt` beside it.

## What's in here

| File | |
|---|---|
| `sift` | the binary — one file, no runtime, no package manager |
| `install.sh` | copies it to `~/.local/bin` and registers the MCP server at user scope (per-repository `--scope local` is the alternative, see the README) |
| `Sift.md`, `README.md` | the agent guide and the overview |
| `Docs/Guide.md` | the full reference: config, indexing, freshness, troubleshooting, every command |

## Requirements

- **Apple Silicon Mac, macOS 13+.** This build is arm64-only by design — no Intel slice.
- **Xcode or Command Line Tools.** Not for running the binary, but the semantic half resolves
  `libIndexStore.dylib` via `xcrun --find swift` at query time.
- **git.** A non-git directory is refused outright.

## Install

```sh
sift install
```

With `sift` on your `PATH` (Homebrew and npm put it there; from this bundle, `sh install.sh` below does),
`sift install` is the one command for all three agents. It looks for Claude Code (`claude` on the `PATH`, or
`~/.claude`), Cursor (`~/.cursor`, or Cursor.app) and Codex (`codex` on the `PATH`, `$CODEX_HOME`, or
`~/.codex`), lists what it found and the files it would write there, and asks once per agent found (default
yes). It runs the same installers as `install-hook`, so nothing new is written:

- **Claude Code:** the hooks in `~/.claude/settings.json`, the MCP server at user scope
  (through `claude mcp add`), and the agent rule at `~/.claude/rules/sift.md`. Then start a **new** session.
- **Cursor:** `~/.cursor/mcp.json` and `~/.cursor/hooks.json`. Then restart Cursor.
- **Codex:** `hooks.json` in the Codex home and the MCP server (through `codex mcp add`). Then restart Codex; it
  shows a trust prompt for the hooks the first time it opens, and they run once you approve it.

| Flag | Does |
|---|---|
| `--yes` | install into every agent found, without asking |
| `--all` | install into all three, found or not, without asking |
| `--agent claude\|cursor\|codex` | install into that one, found or not, without asking; repeat for more |
| `--dry-run` | say what was found and what would be written; write nothing and run nothing |

Where it installs Claude Code's hooks on a terminal, it also asks two questions about allow rules, the same two
`install-hook` asks: whether `sift digest`, `where`, `search` and `strings` may run without a permission prompt
(`[Y/n]`, default yes: they write only sift's own index and caches, the
repository's `.sift/` (and its `.git/info/exclude` entry) and `~/.sift`, and run git with the repository's fsmonitor and git hooks switched off; a no is remembered in `~/.sift`, and the question then defaults to no until a yes or `--allow-lookups`), then whether `sift run -- swift build`,
`swift test`, `xcodebuild` and `swiftlint` may (`[y/N]`, default no: a build runs package manifests and build
plugins). Each adds only its own block. With no terminal neither is asked and nothing is added; the Claude Code
section names `sift install-hook --allow-run` (both blocks) and `--allow-lookups` (the lookups alone), and
`--no-allow-run` adds neither. `sift install` takes none of those flags.

With no terminal to ask on, it installs nothing unless `--yes`, `--all` or `--agent` says what to install into,
and says so. One agent's failure is reported and the others are still installed; the exit status is 1 when any
failed. It ends with one summary: what was written for each agent, the manual step above, and what is
unsupported there. Re-running is idempotent (a second run says there is nothing to do) and is the upgrade path.

The per-agent commands (`install-hook`, with `--agent cursor` or `--agent codex`) stay for scripting; the
sections below are their reference.

If you already manage Claude Code through plugin marketplaces, a sift plugin for Claude Code is the other
route. It is not published yet, so `sift install` is the one that works today.

### From this bundle

```sh
sh install.sh
```

Re-running it is the upgrade path. On a terminal its `install-hook` step asks the two allow-rule questions above
(lookups default yes, or no after a remembered no; builds default no); the script passes no flag of its own. It registers Claude Code only; run `sift install` afterwards for Cursor and
Codex. It strips the quarantine flag (the binary is ad-hoc signed, so an AirDropped copy would be refused), removes any previous
binary **before** copying (never copy over the old inode: macOS SIGKILLs the result, exit 137,
silently; `rm` first, then `cp`), refreshes the user rule, and **removes any existing `sift` MCP
registration before adding this one** (at user scope; for a per-repository registration use the README's `--scope local` command instead), since `claude mcp add` fails outright on a name that already
exists.

If an older install left a sift status line or the `sift-band@sift` plugin, `install.sh` removes them (the plugin
through `claude plugin uninstall` and `claude plugin marketplace remove`), then deletes the folder the band was
copied to (`~/.local/share/sift/sift-mod`) and the marketplace file beside it that named the band. If `claude` is missing or a `claude plugin` command fails, the installer
still succeeds and prints the commands to run by hand.

Then start a **new** Claude Code session (a running one keeps its old server). In any Swift repo:

```sh
sift status     # freshness, counts, module map, index-store discovery — the doctor
```

The first query indexes the repo (once, and longer on a large tree); there is no separate
setup step. On a large codebase, `sift init` reports which files got their module from a
directory-name guess rather than a build file and proposes the `moduleMap` entries that fix it; run it
before trusting `digest <Module>`.

## The agent guide — nothing to wire, nothing to commit

`install.sh` puts `Sift.md` at `~/.claude/rules/sift.md`. It applies to every repo on the machine, and
its frontmatter (`paths: ["**/*.swift"]`) keeps it out of context unless Swift is in play. To share it
with a team instead, copy it to `.claude/rules/sift.md` inside a repo and commit it.

### The session primer

The rule arrives on contact with a `.swift` file, one step *after* the raw read it exists to replace.
So `install.sh` also registers a `SessionStart` hook (`sift session-start` in
`~/.claude/settings.json`) that Claude Code runs before the model's first turn. It prints nothing
unless the session is inside an indexed root, above several of them, or in a Swift repo that has never
been indexed; above several roots it names the ones a query can pass as `root:`.

```sh
sift session-start --cwd .    # see what this directory would get
sift install-hook             # re-register by hand (idempotent; re-run after moving the binary)
sift uninstall-hook           # take it back out (--only-advice keeps the primer)
```

The hooks run the binary `install-hook` was started as: the path you typed, or for a bare `sift` the one
your shell found on PATH, a link kept as the link (Homebrew's `/opt/homebrew/bin/sift`, which survives an
upgrade, not the Cellar copy behind it), provided that is the file actually running; if PATH leads to a different `sift`
(a relative PATH entry, a wrapper), the running binary's own path is used. Run it as the binary you want the hooks to use. A path with a
space in it (a `SIFT_DEST` under `~/Library/Application Support`) is written single-quoted, so the shell
Claude Code runs each hook through reaches it; re-running `install-hook` repoints an older unquoted entry.
Run through `npx` it refuses, since a binary in npx's cache is replaced per version and the hooks would then exit 127:
install the binary (a source build, `install.sh`, Homebrew or
`npm install -g @agulhas-labs/sift`) and run `sift install-hook` from that.

The merge into `settings.json` is done by the binary: it preserves every other key and hook, refuses
a file that will not parse, and copies it to `settings.json.bak-sift` first (rewritten on every run
that changes something). Both commands write atomically. A `settings.json` that is a **symlink** (into
a dotfiles repository, say) **stays a link**: the file it leads to is the one rewritten, keeping its
permissions, with its `.bak-sift` copy beside it, and the answer names both paths. A link that leads to
nothing is refused and nothing is written. If your machine manages `settings.json` centrally, keep the
rule and run `sift uninstall-hook`, which leaves every other hook alone.

Cursor imports the hooks in `~/.claude/settings.json` by default, but it shows a hook's refusal to you
rather than the model. So every sift hook recognises Cursor's payload and prints nothing there (that empty output lets the call through in Cursor is unconfirmed; Settings → Agents → Third-Party Imports turns the import off).

## Cursor (experimental)

```sh
sift install-hook --agent cursor      # register the server and the hooks in ~/.cursor
sift uninstall-hook --agent cursor    # take exactly those back out (sift uninstall does this too)
```

It writes two files and nothing else: `~/.cursor/mcp.json` (server `sift`, the binary's absolute path, args
`["mcp"]`) and `~/.cursor/hooks.json` (`sessionStart`, `preToolUse` and `postToolUse` entries, each running
`<binary> <subcommand> --agent cursor`). A `.bak-sift` copy of a file is kept before any rewrite, entries that
are not sift's are left alone, and re-running is idempotent. Restart Cursor to load it. `--cursor-dir <dir>`
names a location other than `~/.cursor`.

Not supported on Cursor, and the install says so: `sift audit`, a subagent primer, and a
machine-wide Swift-scoped rule (Cursor's rules are per project).

**Cursor support is experimental** until a live test is finished. It was probed on Cursor Agent
CLI 2026.09.28; the IDE was probed only for allowed calls.

## Codex (experimental)

```sh
sift install-hook --agent codex      # register the hooks and the server in the Codex home
sift uninstall-hook --agent codex    # take exactly those back out (sift uninstall does this too)
```

The Codex home is `--codex-dir <dir>`, then `$CODEX_HOME`, then `~/.codex`, and the answer names the directory
it wrote. Some setups, such as an app-managed `CODEX_HOME`, may rewrite that directory: check the printed path.

It writes `hooks.json` there (`SessionStart`, `PreToolUse` and `PostToolUse` groups, each running the plain
`<binary> session-start`, `pre-tool-use` or `post-tool-use`) and registers the MCP server through
`codex mcp add sift -- <binary> mcp`, or prints that line when `codex` is not on PATH. A `.bak-sift` copy of
`hooks.json` is kept before any rewrite, entries and servers that are not sift's are left alone, and re-running
is idempotent.

Codex will not run the hooks until you trust them: restart Codex, and it asks you to trust the sift hooks the first
time it opens; approve them in that prompt, or later in `/hooks`, where they can be reviewed. It asks again after the binary is repointed;
removing our group ahead of a foreign one shifts the foreign one's trust position too. Under
`codex exec`, MCP calls need approval (`requires approval, but approval policy is never`), so headless use needs
an approval mode that allows them.

Not supported on Codex, and the install says so: `sift audit`, a Swift-scoped rule (Codex's
`AGENTS.md` is machine-wide, so none is written), the subagent primer, and the post-edit note for a file
`apply_patch` moves (no payload of a move has been captured; one it adds or updates is checked). A lookup the
Codex CLI runs inside its sandbox is not counted in the usage log: the `workspace-write` sandbox cannot write
`~/.sift`, and the CLI says nothing about it, so `sift usage` and `sift report` undercount Codex use.

**Codex support is experimental** until a live test is finished.

## Uninstall

```sh
sift uninstall            # hooks, MCP server, agent rule (and a legacy status line or band plugin); lists the .sift/ directories left
sift uninstall --purge    # the same, and deletes those directories: every index, run log and usage log
```

It takes out what `install.sh` put in: the hooks in `~/.claude/settings.json` (as
`uninstall-hook` does, which also removes a legacy sift status line), the MCP server at user scope and, run in each project's directory, at local scope (through `claude mcp remove sift`), a legacy band plugin and its marketplace (through `claude plugin uninstall
sift-band@sift` and `claude plugin marketplace remove sift`, when registered), and `~/.claude/rules/sift.md`. Without `--purge` it deletes nothing from a repository; it lists each `.sift/`
it knows of, and `~/.sift`. The binary stays, because a running binary does not delete itself; the last
line is the command that removes it: `rm`, `brew uninstall` or `npm uninstall`, by how it was installed. Running it again says `uninstall: nothing to do`.

## Configuring a large codebase

Everything works with **no config file at all**; reach for `.sift.json` at the repo root when the
defaults misjudge the repo. Every key, and what it does, is in
`Docs/Guide.md` §9:

```json
{
  "roots": ["Modules/Foo", "Apps/Bar"],
  "exclude": ["Generated/", "Legacy/"],
  "moduleMap": { "Modules/Foo/Sources": "Foo" },
  "indexStorePath": "/path/to/Index.noindex/DataStore"
}
```

On a large monorepo `roots` is the main lever on first-index time. `.sift/` is added to
`.git/info/exclude` automatically on first use, so the cache never needs a committed change.

## What the answers promise

Every answer opens with a header that never claims more than it knows; `sift help answers` gives
the full promise.

- **Syntactic answers** (digests, declarations, member source) are never stale. **Semantic answers**
  (callers, overrides, references) come from the build's index store, and only a *build* refreshes
  that: a symbol whose file changed since the last build is refused with "build the project".
- **One store holding two configurations is the exception, and nothing marks it.** Native debug and
  release builds that pass one `-index-store-path` share a store, and a call the debug build no longer
  makes can still answer `fresh` from the release build's unit. Build the other configuration again, or
  delete the store and build once; the default layouts keep the two apart.
- **Dependencies and SDKs are not indexed**, only repo sources.

## Troubleshooting

**It dies instantly with no output (exit 137).** A new binary was copied over an installed one in
place; see Install. `rm` first, then `cp`.

**"no index store for this tree yet".** The semantic half needs a real build: `sift run -- swift build`
for a SwiftPM package, or `sift run -- xcodebuild -scheme <Scheme> build` for a macOS project (add
`-workspace <W>.xcworkspace` when there is one; a bare `xcodebuild build` with no scheme builds into
`./build/` and is never discovered). An iOS project also needs a destination, or it targets a generic
device and fails to sign: `-destination 'generic/platform=iOS Simulator'`. Then `sift status` reports
which store it found, or names an `indexStorePath` it read and rejected. A package nested below the
repo root, or a custom `-derivedDataPath`, needs `indexStorePath` set in `.sift.json`, pointing at the
store directory itself — the one holding `v<N>/units`, relative to the repo root: `<Pkg>/.build/out`
for a package in `<Pkg>` (`<Pkg>/.build/debug/index/store` under `--build-system native`), not
`<Pkg>/.build` itself. The discovery order is in `Docs/Guide.md` §7.

**MCP server not appearing in Claude Code.** Start a new session first, then check `claude mcp list`.
When registering by hand, `--scope` must come *before* the `--`, or the binary receives it:

```sh
claude mcp remove sift
claude mcp add --transport stdio --scope local sift -- sift mcp   # from the repository's root
```

**Answers look thin right after an upgrade.** An upgrade can change the index's format, as the one that
reads a backticked declaration by its bare word did. An index written by an earlier version is dropped and
rebuilt once, on its repository's next query; until then that repository gives reduced answers. `sift index`
in it rebuilds it up front.

**First index feels slow, or `git status` is the bottleneck.** Narrow `roots` first. If `git
status` itself exceeds ~200ms on your repository, git's `fsmonitor` will not help sift: every git the tool
runs switches the repository's fsmonitor hook off, so a hook named in a repository's config is never started by a
lookup.

**Everything is refused as stale.** The build is older than your edits. That is the contract
working, not a bug.

**`where` says the store is "still warming".** A large store takes minutes to read the first time,
so the query answers with declarations rather than blocking. It is not the staleness refusal: no
build and no reindex will speed it up. The read continues in the background; ask again in a moment.
