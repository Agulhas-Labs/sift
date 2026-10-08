# The Sift guide

Everything about installing, running and trusting `sift`, in one place. The [README](../README.md) is
the short version; this is the one to search when something surprises you.

---

## 1. Requirements

- **macOS 13+ on Apple silicon.** The binary is arm64 only.
- **Swift 6.2+** (Xcode 26, or the matching toolchain) to build it from source (§2).
- **Node 18+**, only if you install it through `npx` (§2).
- A **git repository** to point it at: it answers about checked-out source, and says so rather than
  guessing anywhere else.

It makes **no network calls**, ever. See [§10](#10-what-it-touches) for everything it writes.

## 2. Install

Today you build it from source, which needs Swift 6.2 or later. Put `~/.local/bin` on your `PATH` first:
agents run `sift` from the shell, and `sift install` registers the binary you run it from.

```sh
git clone https://github.com/Agulhas-Labs/sift.git
cd sift
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/sift ~/.local/bin/sift.new && mv -f ~/.local/bin/sift.new ~/.local/bin/sift
sift --version
```

Copy to a new name and then rename, as above: macOS kills a binary rewritten in place, with exit 137 and no
message. To upgrade, `git pull` and repeat the last four lines.

Homebrew puts it on your `PATH`, which is what you want for the CLI:

```sh
brew install agulhas-labs/tap/sift
sift --version
```

Give the full name: homebrew-core has an unrelated formula called `sift` (a grep alternative), so
asking Homebrew for plain `sift` installs the wrong tool.

npm is the other half, and the better one for the MCP server: `npx` resolves the package when the
server starts, so it is always the current release and there is no upgrade to remember.

```sh
npx -y @agulhas-labs/sift --version
```

Both carry the same binary and both faces of it. They differ only in who does the updating — you, or
the launch.

### `sift install`

With `sift` on your `PATH`, one command sets it up in every agent you use:

```sh
sift install [--agent claude|cursor|codex]… [--all] [--yes] [--dry-run]
```

It detects Claude Code (`claude` on the `PATH`, or `~/.claude`), Cursor (`~/.cursor`, or Cursor.app) and Codex
(`codex` on the `PATH`, `$CODEX_HOME`, or `~/.codex`), lists what it found and the files it would write, and on a
terminal asks once per agent found (default yes). `--yes` installs into every agent found without asking; `--all`
into all three, found or not; `--agent` into the ones named, found or not (repeat it for more); `--dry-run` says
what would be written and writes nothing and runs neither `claude` nor `codex`. With no terminal and none of
`--yes`, `--all` or `--agent`, it installs nothing and says what to run.

Each agent goes through the installer `install-hook` uses (Claude Code: the hooks, user-scope MCP
server and agent rule; Cursor: `mcp.json` and `hooks.json`; Codex: `hooks.json` and the MCP server), so the
guarantees are the same: a `.bak-sift` copy before a rewrite, entries that are not sift's left alone. One agent's
refusal is reported and the others still run. It ends with a summary of what was written, the one manual step
(a new Claude Code session; restart Cursor; restart Codex and approve the trust prompt it shows) and what is
unsupported. Re-running is idempotent and is the upgrade path. Exit status: 0 on success, when there was nothing to
do, or when it needs a flag; 1 when any agent's install failed.

If you already manage Claude Code through plugin marketplaces, a sift plugin for Claude Code is the other route.
It is not published yet, so `sift install` is the one that works today.

An upgrade can change the index's format, as the one that reads a backticked declaration by its bare word
(`where settle` finding a func named with backticks) did. An index written by an earlier version is dropped and
rebuilt once, on its repository's next query; until then that repository gives reduced answers. `sift index` in
it rebuilds it up front.

<details>
<summary>From a downloaded bundle</summary>

`install.sh` in the tarball copies the binary, installs the agent rule, registers the hooks,
re-registers the MCP server and removes a legacy sift status line and band plugin if an older install left one. It is safe to re-run, which is how it upgrades.

**It removes the old binary before copying** — never `cp` over one in place, or the new code is SIGKILLed on launch (exit 137, no message).

</details>

### `sift doctor`

```sh
sift doctor [--agent claude|cursor|codex]… [--cursor-dir D] [--codex-dir D] [--json]
```

Proves each agent found runs what the install wrote, one line per check, and exits 1 when any check failed.
With no `--agent`, only the agents found on this machine (the detection `sift install` uses) are checked; one not
found prints a skipped line and is neither counted nor failed, while one found without sift installed still fails.
`--agent` names the agents to check, and checks each whether or not it was found. For every agent it reads the registration
from the files the install writes, resolved from the same paths, then: the registered binary runs and prints its
version (a version other than this binary's is said, never a failure); each hook, fed a canned payload in that
agent's shape in a scratch directory, exits 0 and prints nothing or only what the agent reads; and the registered
MCP server starts and lists every tool. A registration missing says which `sift install --agent …` to run.

- **Claude Code**: the hooks in `settings.json` (a registration that is not the one this version writes, such as
  a matcher an upgrade changed, fails the hooks check, as `sift status` says of it), the user-scope server in `~/.claude.json`, each hook fed Claude
  Code's payload (a `SessionStart` or `SubagentStart` hook may answer in text, every other only in JSON).
- **Cursor**: the hooks in `hooks.json` and the server in `mcp.json` in `~/.cursor`, or the directory
  `--cursor-dir` names (given, Cursor is checked whether or not it was found). Each hook is fed Cursor's payload
  (`preToolUse` a `Shell` call) and must answer in JSON or not at all, since that is all Cursor reads.
- **Codex**: the same shape over the Codex home's `hooks.json` and `config.toml`, with the hooks' trust where it
  is readable.

`--json` prints the same answer as one object: the verdict, every check with its line, and the agents skipped.

## 3. Register with Claude Code

From the root of each Swift repository:

```sh
claude mcp add --transport stdio --scope local sift -- npx -y @agulhas-labs/sift mcp
claude mcp list        # expect: sift ✓ connected
```

Point it at an installed binary instead — `-- sift mcp` — if you would rather pin the version and
upgrade it yourself.

`--scope local` registers it for that repository alone, privately, and is still the tidy choice. The four
tools load with the tool list rather than behind a tool search, about 1k tokens in a session, but only
where Swift is in view: `--scope user` registers the server for every project on the machine, and
outside Swift repositories it leaves the tools deferred to their names, so a session with no Swift in it
pays almost nothing for them. `--scope project` does the same through a
committed `.mcp.json`, if your team shares the setup. `sift install-hook` stays machine-wide, since
it prints nothing in a session with no Swift in view. **Flags must come before the
`--`** — anything after it is passed to `sift` instead of to `claude`, which fails confusingly.

The server exposes only the query tools (`digest`, `where`, `search`, `strings`). Lifecycle commands
stay on the CLI deliberately: every exposed tool costs description tokens in every session. The four are
marked to load with the tool list (`anthropic/alwaysLoad`), because Claude Code otherwise defers an MCP tool
to a bare name that takes a `ToolSearch` turn to load — one step more than a shell call, which is the
detour agents took instead.

## 4. Teach the agent to actually use it

Registering the server makes the tools *available*; it does not make an agent *prefer* them over
reading files and grepping. [`Sift.md`](../Sift.md) is the canonical guidance — which tool to
reach for, how to handle a refusal, and what to do when the server isn't there. It points at
`sift help <topic>` for the rest: reading a red `run` block, `flakes`, the parse-error banners, root
resolution, per-tool depth, and the hook's accounting rules.

`install.sh` copies it to `~/.claude/rules/sift.md` (leaving a symlink already there), or do it by hand:

```sh
mkdir -p ~/.claude/rules
ln -s /path/to/Sift/Sift.md ~/.claude/rules/sift.md
```

It is a user-level rule, so no repo commits anything, and it is path-scoped (`paths: ["**/*.swift"]`),
so it costs nothing in a session that never touches Swift. The MCP tool descriptions, which load up
front, are written as trigger conditions ("call this instead of Grep"). (Rationale: Design.md §4.)

### The session primer

Path scoping makes the rule cheap and also **late**: it fires when a Swift file is touched, one step
after the read it exists to replace. So the guidance also ships as a `SessionStart` hook, which Claude
Code runs before the model's first turn, and as a `SubagentStart` hook, since subagents get neither a
session start nor the rule. The subagent's copy adds a line for its case: `digest` each of several types
rather than opening the files. Both, and every lookup refusal, say that where the MCP tools are missing
the CLI answers the same queries from Bash:

```sh
sift install-hook     # registers `sift session-start` in ~/.claude/settings.json
```

Under `CLAUDE_CONFIG_DIR`, the settings, the rule and the MCP entry all follow it: `install-hook`, `uninstall-hook` and `uninstall` use `$CLAUDE_CONFIG_DIR/settings.json`.

It keeps the cost property that path-scoping was protecting by resolving what the session is sitting in
and **printing nothing** unless Swift is genuinely in view:

| Session is… | Primer says |
| --- | --- |
| at or under an indexed root, or in a repository whose index is on disk | use the tools; no `root:` needed here |
| **above** the roots (a portfolio session) | use the tools; pass `root:` for a direct answer — and here are this machine's roots |
| in a git repository with Swift sources and no usable index on disk | use the tools; the first query indexes it, no setup step |
| anything else | *(nothing at all)* |

A rootless query above the roots is not fatal — `digest`, `where` and `search` resolve the name against
the indexed roots and say which one answered, and a folder holding exactly one indexed repository
resolves to it (see **Root resolution**) — but naming the root skips that search and is never ambiguous.

Run it by hand to see what a given directory would get:

```sh
sift session-start --cwd ~/Developer
```

### The shell, and why advice was not enough

`install-hook` registers a third hook, `PreToolUse`, matched to every tool that can read Swift source —
`Bash`, `Read`, `Grep`, `Glob` and the Xcode server's `XcodeRead`/`XcodeGrep`/`XcodeGlob` — and to this
server's own tools, which it only writes down. The metric counts them by the identical rule.

The shell half is the part nothing else can reach: a `grep -n` or `sed -n` on a `.swift` file never
opens a file as far as the harness is concerned, so the path-scoped rule never fires for it. The hook
**refuses the command** and names the call that answers it:

```
grep -n "classifyEdgeWear" -A20 CrateClassifier.swift
  → denied: digest CrateClassifier.classifyEdgeWear
            that member's current source

Read(SummaryState.swift)
  → denied: digest SummaryState
            every member with its exact line range

Glob("**/*.swift")          → denied: digest .
Glob("**/*Store.swift")     → denied: search path:Store
```

A read is only interrupted when interrupting it could save something. A **ranged** read of a file
whose digest the same context already holds passes untouched, and so does any file below the compression
floor and a whole read of a file the same context has already had digested. Any other window (a ranged
`Read`, `sed -n 95,215p`) is answered only where the answer saves at least 4 KiB against the lines it
asks for; when that answer leaves out the lines you needed, the identical re-run goes through. A Read that is really the precondition for an Edit or Write is answered
like any other Read, and the identical re-run the answer invites is allowed: it costs a round trip and the file it reads.
A `grep -n` for a name in files it names is answered with that name's `where` only where every line the grep
prints spells the name in code; a line spelling it only in a comment or a string literal, a file holding a lone
carriage return, or more than 2 MiB of source in all lets the grep run.

A raw build or test — `swift build`, `swift test`, `xcodebuild` — is the one call the hook can take for
the agent rather than name. Where no permission prompt can follow, it is **rewritten in place** to its
`sift run --` wrapping and runs, filtered, in the same turn: in a session whose permission mode is `auto`
or `bypassPermissions`, or where the allow rules in your settings already cover `sift run -- …` for every
statement the wrapping prefixes (a `Bash(swift test:*)` rule does not cover `sift run -- swift test`).
Everywhere else — and wherever an ask or deny rule matches a wrapped statement — the build is refused once
with the wrapped form named, and the identical re-run goes through. Where an ask or deny rule of yours
matches anything on the line as you wrote it, the hook stands aside, and it stands aside from a line the shell
could not run as written too (`swift test &&`), naming no wrapping of it. It stands aside from every build
while a settings file of yours has something in it the hook cannot read as JSON (a Latin-1 byte, say), since a
rule there is one it cannot see. Either way the whole log is kept under
`.sift/runs/`. `install-hook` offers four allow rules — `Bash(sift run -- swift build:*)`, `swift test`,
`xcodebuild` and `swiftlint`, never `Bash(sift run:*)` — and four for the read-only lookups, `Bash(sift digest:*)`,
`where`, `search` and `strings`, so a context whose sift tools are deferred can use the CLI without a prompt: asking
as two questions on a terminal, the lookups first (default yes: they write only sift's own index and caches, the
repository's `.sift/` (and its `.git/info/exclude` entry) and `~/.sift`, and run git with the repository's fsmonitor and git hooks off; a no is remembered in `~/.sift`, and the question then defaults to no until a yes or `--allow-lookups`), then the builds (default no: they run package manifests and build plugins), each asked
only where its block is missing, and each adding only its own block. `sift install` asks the same two where it installs
Claude Code's hooks; with no terminal neither asks and nothing is added. `--allow-run` adds both without asking,
`--allow-lookups` only the lookups, `--no-allow-run` neither, and `uninstall-hook` removes the last block of each set. The session primer points a context at the CLI only where those four are allowed.

Refusals never trap you:

- **A retry always passes.** The same command is denied once and allowed the second
  time, so nothing is ever unavailable and the worst case is one round trip. The re-run spends no budget.
  A refusal whose record does not land is not issued, and a session's ledger ages out after a week.
- **It stops on a runaway.** A hundred *distinct* denials in one stretch open a quiet spell of fifteen
  minutes, doubling each time up to two hours, after which the advice comes back with a full cap. The
  count is per spell and shared by every subagent.

(Rationale for the ledger, lock, cap and spell: Design.md §4.)

A sweep across a directory — `grep -rn UsageWindow Sources/` — names no `.swift`, so the target is
resolved from the session's working directory: a search of a tree that holds Swift for something
symbol-shaped is a lookup.

### What it deliberately stays quiet about

The judgement is the hook's, not the caller's, and it errs toward silence: a nudge withheld costs one
missed opportunity, one that fires wrongly costs a doubled invocation and the credibility of the next.
Where a rule withholds a suggestion, the metric asks the same question, so the reported share never
counts what the hook rightly declined (rationale: Design.md §4). Every silencing is written to
`~/.sift/advice/suppressions.jsonl` with the rule that made it. The hook stays quiet for:

- **A command's payload** — `gh issue create --body …`, `git commit -m …`, a heredoc: text being
  written, not a file being read.
- **A count** — `grep -c`, `rg --count`, a `wc` stage: text volume is what a symbol index does not
  measure. It is read off the pipeline the lookup is in, never the whole line.
- **A listing** — `ls`, `find`.
- **A tree-wide search whose pattern names nothing at all** — no identifier anywhere in it, such as a
  version literal. `final class` and `@Test func` name no symbol either, but they are exactly what
  `search` serves. A pattern with a space is never taken as one name, and where one file is named a
  search for prose is withheld too.
- **A search across a tree that no index call answers.** Otherwise it is refused and counted as a miss:
  one name in Swift-shaped company is a `where` (`": UsageWindow"`, `.order`, `Task {`); a pattern of
  declaration vocabulary is a `search` (`@Observable` as `search attr:Observable`, `class .*Store` as
  `search kind:class name:Store`); an alternation is one `where` per declared name, at most five, with
  prose branches named as left out; a read of several files is a `digest` of each. Only a phrase of
  ordinary words, or an alternation whose every branch is prose, is left alone and scored out of the
  share with the text searches.
- **A gate leg** — `xcodebuild build-for-testing`, `test-without-building`, or any command already
  redirecting to a log of its own draws no `sift run --` wrapping.
- **A quiet linter** — `swiftlint --quiet` draws no wrapping; another toolchain command on the same line
  keeps its own.

`SIFT_NO_ADVICE=1` turns it off without touching `settings.json`.

### After an edit

The `PostToolUse` hook runs after every Write, Edit or MultiEdit of a `.swift` file (under Codex, after an
`apply_patch`, for each `.swift` file it adds or updates, with one answer for the patch). It parses the file,
and if the edit left it unparseable it blocks with the errors, each as `Path.swift:line:col message` (five
at most, then a count of the rest). Claude Code shows that to the model as feedback on the edit, so the
next turn fixes the file instead of the next build finding it several edits later. The same content is
blocked once per session, so a file the model leaves broken on purpose goes through the second time, and
a file that was already broken is blocked only for the errors the edit added, so a parser fixture can be
edited without one (an error is taken for a rewritten old one only within the same hunk of the edit, so
fixing one error and adding another of the same kind in another hunk, that is more than six unchanged lines
from the fix, is blocked). A
clean parse prints nothing; so do a file it cannot read and an overrun of its one-second budget. This
checks syntax only: a type error still needs a build. Otherwise the hook stays quiet unless the edit
added a function shaped like one that already exists, which it names in one line.

### Before stopping

The `Stop` and `SubagentStop` hooks run `sift stop` when the session or a subagent ends its turn. If that
context made a successful Write, Edit or MultiEdit of a `.swift` file since its own last green `sift run`
build or test in that repository, and no green `sift run` is on record for the repository's tree as it
stands, it blocks the stop once with the build to run: `sift run -- swift build` where `Package.swift`
sits at the root, else the `sift run -- xcodebuild … build` command that context already ran, as it wrote
it. It never guesses an `xcodebuild`, and an edit to a file the index leaves out (a git-ignored path) does
not count. A green `sift run` build or test records the tree it built in the checkout it built (the one a
`--package-path` or `-project` names; a run that skips the build, `swift test --skip-build` or
`xcodebuild test-without-building`, built nothing and records nothing), so a piped run (`| tail`) counts, and a logged one
(`> log; echo $?`) counts where the log is outside the tree or ignored: a log written into the tree
changes it during the run, and nothing is recorded. A build in another repository or worktree does not
count; a green `sift run -- swift test` in a sibling worktree with an identical tree does, since that
content was tested. A `sift run` of the tree as it stands that is still going (its progress file in
`.sift/progress/` has a heartbeat under 5 s old) lets the stop through silently, so a suite started in the
background and waited on is never answered with a second build; a live run of an earlier tree turns the advice
into "run it again once that ends". It says nothing for a context that edited no Swift, a stop already continued by a
hook, a second stop on the same tree, anything it cannot read, and past its one-second budget.

### Finding a blind agent before it costs anything

An agent spawned with an explicit `tools:` allowlist that leaves this server out is refused every time it
reaches for the index and can do nothing about it, when the cause is already sitting in a file. `sift
status` and `sift install-hook` both read the agent definitions in
scope — `.claude/agents/*.md` in the repository and `~/.claude/agents/*.md` — and name any whose
`tools:` frontmatter is an explicit allowlist this server is not in:

```
agents: 1 of 5 definitions has a tools: allowlist without sift in it
  catalogue-reviewer  .claude/agents/catalogue-reviewer.md
                      tools: Read, Grep, Glob, Bash
  an explicit tools: list drops every MCP server, so a context spawned from one of these is
  given this tool's guidance and holds nothing it names. Add these four to the line — or take
  the line out, since an agent that names no tools inherits them all:
      mcp__sift__digest, mcp__sift__where, mcp__sift__search, mcp__sift__strings
  (searched .claude/agents and ~/.claude/agents; a definition with no tools: line at all is not counted)
```

Only an explicit allowlist is named: a `tools:` line that is absent inherits every tool and is correct,
and so is `tools: "*"`. Where the reading is uncertain (a wildcard over the prefix, the bare server
name) the file is read as naming the tools. Nothing is printed when nothing is found.

`sift uninstall-hook` is the exact inverse: it removes the SessionStart, SubagentStart, PreToolUse,
PostToolUse, Stop and SubagentStop entries whose command runs this binary, and a legacy status line if this tool registered one; another tool's
hooks and every other key survive. A command is this binary's when its executable is named `sift`, at any
path, and runs the subcommand alone: a hook whose path merely contains `sift` is left alone by the
install and the uninstall. `--only-advice` removes just the PreToolUse hook. Neither touches
`~/.sift/`; delete it yourself to discard the usage log.

`sift uninstall [--purge]` takes the whole tool back out. It runs `uninstall-hook`, removes the MCP server
at user scope (`claude mcp remove sift --scope user`) and at local scope (`claude mcp remove sift --scope
local`, run in each project's directory), each only when `~/.claude.json` holds a `sift` server there that
runs this tool: `sift mcp` as `install.sh` registers it, or `npx -y @agulhas-labs/sift mcp` as §3 does; a
server of that name that runs something else is named and stays. A removal is reported only once
`~/.claude.json`, read back, no longer holds it. It deletes the rule `install.sh`
copied to `~/.claude/rules/sift.md` (a symlink there is left, as `install.sh` leaves one). It then lists every
`.sift/` directory it knows of: each repository's that `~/.sift/roots.json`, `usage.jsonl` or `run.jsonl` names,
and `~/.sift` itself (a recorded root that is not an absolute path is counted and skipped, never resolved
against the working directory, for its `.mcp.json` as for its `.sift/`). `--purge` deletes them, a repository's through
the same path as `sift reset`, so one holding an unrestored `sift run --without` set-aside is refused and
named. It lists the `.bak-sift` copy kept beside each file it rewrites — `settings.json`, Cursor's `mcp.json`
and `hooks.json`, Codex's `hooks.json` — and `--purge` deletes those too. This tool's local-scope server in a project whose directory is gone, is reached through a symlink, lies
inside another git repository or is a linked worktree (Claude Code keys those by another path, so `claude` run
there could remove another entry), and its server in a recorded repository's `.mcp.json` (never edited: it is
the repository's file), are named with how to remove them and counted as not removed. So is a removal during
which any other server entry in `~/.claude.json` changed, with the entries to check. After a purge, the line
naming such a `.mcp.json` also says a later run will not find it, since the record naming its repository is
gone, and the answer says that sessions already running can recreate `~/.sift` until they end.
The last line is what removes the binary, since a running binary does not delete itself: `brew uninstall`
or `npm uninstall` where the path, links resolved, is in Homebrew's Cellar or a `node_modules` (npx's cached
copy is named with its directory), else the `rm` of the path that ran. A second run answers
`uninstall: nothing to do`. The exit status is 1 when anything named was not removed or was refused — the
verdict opens with how many — and 0 otherwise, so a script can tell a partial uninstall from a whole one.

Cursor imports the hooks in `~/.claude/settings.json` by default, but it shows a hook's refusal to you
rather than the model. So every sift hook recognises Cursor's payload (it carries `cursor_version`,
`conversation_id`, `generation_id` or `workspace_roots`) and prints nothing there. That empty output lets the
call through in Cursor is unconfirmed until probed on a real Cursor; Settings → Agents → Third-Party Imports
turns the import off.

### Cursor: `sift install-hook --agent cursor` (experimental)

Instead of leaning on that import, register sift with Cursor itself: `sift install-hook --agent cursor` writes
the `sift` MCP server into `~/.cursor/mcp.json` and `sessionStart`, `preToolUse` and `postToolUse` hooks into
`~/.cursor/hooks.json` (`--cursor-dir` names another directory); `sift uninstall-hook --agent cursor` and `sift
uninstall` take them out. The hooks are the session primer and the refusals: a refusal's redirect text reaches
the model through Cursor's `user_message` field. `sift audit`, the subagent primer and a
machine-wide Swift rule are not available on Cursor. Support is experimental until a live test is
done; the mechanics are in [INSTALL.md](../Distribution/INSTALL.md).

### Codex: `sift install-hook --agent codex` (experimental)

`sift install-hook --agent codex` writes `SessionStart`, `PreToolUse` and `PostToolUse` hooks into `hooks.json`
in the Codex home (`--codex-dir`, then `$CODEX_HOME`, then `~/.codex`; the answer names the directory it used)
and registers the `sift` MCP server with `codex mcp add`, or prints that command when `codex` is not on PATH.
`sift uninstall-hook --agent codex` and `sift uninstall` take them out. Codex runs a hook only after you trust
it: restart Codex, and it asks you to trust the sift hooks the first time it opens; approve them in that prompt,
or later in `/hooks`, where they can be reviewed. `sift audit`, the subagent primer and a
Swift-scoped rule are not available on Codex, and a lookup the Codex CLI runs inside its sandbox is not counted in
the usage log: the sandbox cannot write `~/.sift`, and the CLI says nothing about it. An `apply_patch` gets the post-edit check for each `.swift` file it adds or updates; a file it deletes
leaves nothing to check, and a file it moves, or a patch that failed, is not read until a payload of one has been
captured. Support is experimental until a live test is done; the mechanics are in [INSTALL.md](../Distribution/INSTALL.md).

### Agent guide: situations

The long form of what [`Sift.md`](../Sift.md) keeps to one line each. The rule is installed into repositories
that do not carry this file, so it sends a reader to `sift <verb> --help` first and here second. How the hook
treats a raw build or test is under *The shell, and why advice was not enough* above, and what it does after an
edit and before a stop under *After an edit* and *Before stopping*.

**If the index tools vanish mid-session, the CLI keeps working — use it, don't fall back to Grep**, since the
CLI does not depend on the server at all: `sift digest <Type>`, `sift where <Symbol>`, `sift search '<query>'`,
`sift strings "<text>"`, `--root <path>` in place of `root:`. `sift status` reports the servers it can
confirm are running, by checking each recorded process against the start time the kernel holds for it, plus
when and why the last one stopped. **Stop a sift server by its pid (`sift servers`), never by a pattern** —
`pkill -f "sift mcp"` ends every other session's server too.

**A lookup of Swift source is answered in place, or let through** — a shell command, a Grep, a Glob, or
a whole-file Read, through whichever MCP server. Where the index's answer is proven to account for
everything the command would have printed, the call is denied and that answer comes back in its place. A
symbol search across a tree is answered too, but handed over *unproven*: the offer's own `where` per name.
Everything else runs; you are never interrupted merely to be told a call you could have made, though the
miss is still counted for `sift audit`. A whole read of a Markdown document over 8 KiB gets its heading outline.

A denial is not a wall and not a permission problem: re-run the same lookup and it is allowed (for a shell
command, the reading stage alone, so a changed `echo` label still counts as the identical re-run). Take the
suggestion when it fits — usually it is the shorter path anyway — and re-run when it does not. **A re-run
is never held against you.** Don't work around it by reading the file whole instead, or by re-asking through a
different tool; both cost more than the command did. Never interrupted at all: a ranged `Read` or shell
window of a file whose digest you hold, text you are writing, a count, a directory listing, a search
printing only file names (`grep -l`, a Grep in its default mode), a
fixed-string search (`-F`, `fgrep`) for anything but a name, a merge's conflict markers (`<<<<<<<`,
`=======`, `>>>>>>>`), a tree no index holds such as `.build/`. `sift help refusals` has the full accounting.

A `post-tool-use` line may suggest `sift similar` when a declaration you added resembles an existing one.

#### Which tool, and when

- **An unfamiliar repo, cold** — `digest .`, the repo overview; `digest <Module>` then opens the module
  that matters. Start there instead of a directory listing.
- **A type's shape, a view's structure, or where in a file something lives** — `digest`, which takes a
  type, a repo-relative file path, or a module. Digest to locate, then a *ranged* Read of only the members
  that matter. **A cited location is not already located**: a `File.swift:120` or `:95-135` handed over by
  an issue, a review or a build error goes to `digest File.swift:120` (or `:95-135`), which returns the
  members that line or range falls in — not a guessed `sed -n '95,135p'` window. Already making a Bash call
  for `git` or `gh`? `sift digest …` and `sift where …` go in the same line. A `some View` member comes back
  with an outline of what it builds. Never judge the size first: below about 60 lines `digest` returns the
  source itself, and for a larger file the digest is usually the smaller answer. Reaching for Read because a file "looks small" is the one case that is always wasted.
- **One member you can already name** — `digest Type.member` (or `Type.save(_:to:)`) returns its current
  source; a long body truncates with the ranged Read that finishes it.
- **A large document** — `digest <file>.md` (exact path, `Docs/Design.md`, not `Design.md`) gives a
  heading outline with line ranges and sizes; then a ranged Read of the section.
- **"Where is X defined, who conforms, what calls or overrides it"** — `where`, not Grep. `where refs`
  lists every reference site for a rename or delete sweep, code occurrences only, so grep for a doc
  comment or string literal too.
- **Code by shape rather than name** — `search`; Grep cannot answer these reliably because the pattern
  spans nesting and line breaks: "every `@Test` function that wraps a call in an unstructured `Task`".
- **About to write a helper** — `search` first, by the callee it cannot avoid (`kind:func calls:rename`;
  one callee per query, terms are ANDed). `sift similar Type.member` and `sift dupes [path …]` from Bash
  rank near-duplicate bodies; a lower bound, never a verdict. `sift help queries` has more.
- **Tracing UI text** — `strings`, from wording to a localization key, or to the Swift literal holding it
  (or the literals a `+` joins, shown as `"the build did " + "not complete"`).
- **Building or testing** — wrap `swift build` / `swift test` / `xcodebuild` in `sift run --` from Bash:
  failures without the noise, raw log in `.sift/runs/`, exit code passed through, except 4 (a
  `--filter` run that executed no test) and 5 (such a run that did not build), which are sift's; 4 too
  where one of several `--filter`s matched no test, named on the `totals:` line, and for an unfiltered
  `swift test` that executed no test in a package declaring test targets.
  `sift help run-output` reads a red block. `inventory: N declared, M reported`, not
  `swift test list | grep -c`, is discovered vs run; only an unfiltered, serial root-package `swift test`
  prints it (`inventory: not checked — …` is another outcome).
- **A slow simulator suite** — `sift test --scheme … --device "iPhone 17" --shards N` from Bash;
  `sift help test-output` reads the answer.
- **"Is anything not being run?"** — `sift test --analyse` reads the index and `.xctestplan` files, builds
  nothing, and names the residue (an unplanned test target, a switched-off test, a dead exclusion).
- **"Which code is slow to compile?"** — `sift build --analyse` from Bash; `sift help build-output`.
- **Proving a test fails without your change** — `sift run --without Sources -- swift test --filter …` in
  one call, never a hand-rolled revert; it leaves the tree as it found it. A committed fix takes `--since <base>`
  beside `--without`. A fix that is a new file or adds API a test names can only "not build" set aside: use
  `sift run --without-line Sources/X.swift:42 -- swift test --filter …` on one guarding line whose removal
  still compiles.
- **"Which tests could my change have broken?"** — `sift affected` from Bash, over the working tree or
  `--from`/`--to`, with `--filter` arguments ready to run. **A lower bound, never a green light**: a test
  can depend on your change by routes the index cannot see.

#### In a git worktree

Pass `root:` with your worktree's path (`--root` from Bash) so a query answers about your tree rather than
your parent's, and check that the header's `tree:` names the worktree (`tree: Sift (worktree
agent-1a2b3c4d)`, not a bare `tree: Sift`). **Build once before relying on `where`'s
callers, overrides and references**: a fresh worktree has no index store until a build creates one, and
until then `where` and `affected` fall back to name-matched leads. `sift help worktree-index` has the
build command and why the parent checkout's store is never borrowed.

## 5. Getting it indexing

**There is no setup step.** A repository indexes itself on its first query. If you'd rather pay that
cost up front:

```sh
sift index          # incremental refresh (or first build)
sift index --full   # rebuild from scratch
sift status         # the index's health — freshness, counts, module map, index-store discovery
```

`status` is the first thing to run when something looks wrong:

```
tree: Sift  head: bf1d43a  clean  semantic: syntactic-only
root: /Users/you/Developer/Sift
files: 291  symbols: 4098  db: 1.6 MB
modules (5): SiftCLI SiftCore SiftCoreTests SiftMCP SiftMCPTests
config: none (defaults)
index store: .build — /Users/you/Developer/Sift/.build/out
```

How it stays current, and why there's no daemon:

- **The cache lives at `.sift/index.db`** (SQLite, WAL) inside the repo; the tool adds `.sift/` to
  `.git/info/exclude` itself. `sift reset` deletes the whole directory: the index, the semantic cache
  (rebuilt by the next query) and the raw logs `sift run` keeps under `.sift/runs/` (not rebuilt). A
  `.sift` that is a symlink, to a directory or to nothing, is refused: the link stays, nothing is deleted
  through it, and `sift reset` exits 1 naming it, so remove the link by hand. Git
  worktrees each get their own.
- **Invalidation happens at query time**, not through hooks or a file watcher. Every query runs
  `git rev-parse HEAD` plus `git status --porcelain` and reparses whatever is dirty before answering:
  tens of milliseconds, so syntactic answers are never stale, including the file you edited two seconds
  ago.
- **Files are enumerated with `git ls-files`**, so anything gitignored is outside the tool. **Hidden
  directories are never indexed** (anything whose name starts with `.`, tracked or not), nor are `Pods/`,
  `Carthage/`, `DerivedData/` and `node_modules/`.
- **The first query on a repo builds the index inside that call** — a few seconds of extra latency on a
  large repo, once, not an error.

## 6. What an answer promises

Every answer from the query tools — `digest`, `where`, `search` and `strings`, on the CLI and over MCP —
opens with a header, and so do `sift status` and `sift affected`; any note the answer carries, such as
the root it picked, sits on the line under it. The header never claims more than it knows. `search` and
`strings` read the working tree live, so theirs names the tree and says so (`source: working tree, read
live — nothing stored to go stale`) instead of carrying the freshness fields below. `sift index` and `sift
reconcile` say which repository they picked before they start work, and put the header after it; the
reports (`usage`, `audit`, `run`, `servers`, `flakes`, `report`) open with lines of their own. `sift
uninstall` describes no tree, so it opens with its verdict instead.

In a checkout you cannot write — a vendored package, a read-only mount, another user's tree — nothing is
created in it. `search`, `similar`, `dupes` and `strings` answer as anywhere else. `digest`, `where` and
`status` keep their index in memory instead of under `.sift/`, so each CLI command parses the whole tree
again (the MCP server keeps it for the session); `digest` and `where` say so on the line under the header
(`index: in memory — this tree cannot be written, …`) and `status` prints `db: in memory`. `sift index` and
`sift reconcile` refuse there in one line, since there is no stored index for them to build. The hook, which
is a new process on every call, does not parse such a tree to answer a Read or a grep in place: it lets the
call run, and logs it as `treeNotWritable`.

**It opens with the tree it was measured against.** `tree: Sift` is a repository's own checkout;
`tree: Sift (worktree agent-1a2b3c4d)` is a linked worktree of it — a name, never a path. A worktree and
its checkout share `head:` and hold the same symbols, so without it an answer from the wrong tree looks
like the right one.

Freshness has **two independent axes**:

| Axis | Self-heals? | Behaviour |
|---|---|---|
| Index vs working tree (**syntactic**) | Yes | Dirty files are reparsed before answering, so digests and declarations are never stale |
| Index store vs working tree (**semantic**) | No | Only a build refreshes it, so affected symbols are **refused**, per symbol |

**In a git worktree the semantic axis is always off**, because a worktree has no build directory of its
own, and the parent checkout's store is not borrowed (it describes a different tree). The answer says how
to leave that state: build in the worktree, or query the repository's own checkout.

Every answer built without a store also says what an empty result does not mean. The fallback matches
written *calls* (for a property, every expression spelling its name), so a type in an annotation, a
conformance, a `#selector` or a name in a string is not in it, and a type has no calls at all. Read a
short list as "no call of that name was found", never "nothing uses this"; a rename sweep needs
`where --refs` and a built store.

**`semantic:` is the mode that produced *this* answer, not a property of the tree**, so two commands can
differ on one tree without either being wrong. `digest` never opens the store and says `syntactic-only`;
`status` judges from file timestamps and may say `stale (2 files changed since last build)`; `where`
consults the store and may say `fresh`. Run all three after editing two files and you can see exactly
that: `status` stale, `digest` syntactic-only, `where` fresh, because the symbol you asked it about lives
in a file neither edit touched. In a tree with no index store yet, such as a fresh worktree, `digest` still
says `syntactic-only` and `where` says `none (no index store — see note)`: `digest` never asked for the
store, `where` asked and found none. Read the header on the answer you are about to act on.

On `semantic: stale (2 files changed since last build)` and a refusal, take it literally: **build the
project, then retry.** A file counts as changed when its contents or its file status moved past the build, so a copy that
preserves modification times still reads as changed. Re-running the query won't help and neither will `sift index`. Symbols in
untouched files still answer normally, and `parse_errors` in the header means some answer came from a
file that didn't parse cleanly.

### Root resolution

Every query runs against one repository root: `--root` (CLI) or `root:` (MCP), defaulting to the repo
enclosing the working directory. From a directory that encloses **no** repository — a portfolio folder
holding many repos — `digest`, `where` and `search` resolve the target name against the roots in
`~/.sift/roots.json` and name the root they picked on the line under the header:

```
$ sift digest RecordDetailView          # run from ~/Developer, which is not a repo
tree: app  head: 3f2a91c  clean  semantic: syntactic-only
(no repository encloses /Users/you/Developer — resolved to /Users/you/Developer/Orchard/app, the only
 indexed repository declaring RecordDetailView)
…
```

The probe is read-only and never creates or upgrades another repo's index. A name declared in several
indexed roots is reported with just those roots, never guessed. `search` resolves on its `name:` term
(a bare term counts, since that is read as `name:`); a query asking only about shape has no name to
resolve on, and neither does `strings`.

When nothing resolves that way, the directory itself decides: a folder holding exactly **one** indexed
repository resolves to it, whatever was asked. That is the product-container case — `Orchard/` holds
`app/` and `web/` — and it covers what a name probe cannot: `digest .`, a symbol
written since the last index, and a name no indexed root has:

```
$ sift digest .                         # run from ~/Developer/Orchard, which is not a repo
tree: app  head: 3f2a91c  clean  semantic: syntactic-only
(no repository encloses /Users/you/Developer/Orchard — resolved to
 /Users/you/Developer/Orchard/app, the only indexed repository under it)
…
```

A name that lives in a repository *outside* the folder still resolves there. A folder holding several
indexed repositories keeps the error listing every root; two worktrees of one repository collapse.

All of this is for a call that names no root. A `--root` / `root:` you pass is the tree you are asking
about, so one that is not a git work tree (a plain folder of Swift files) is refused in a line naming the
folder (`<folder> is not a git work tree …`), never answered from another repository. A named folder that
*holds* indexed repositories still resolves to the one it holds, as above.

### The root follows the caller, not the server

The MCP server binds its default root to its own launch directory, and a subagent shares its parent's
server, so a subagent in a git worktree would be answered from the **parent checkout** — another tree,
with nothing in the answer saying so. With the hook installed, an index call that names no `root:` is
amended to name the repository the caller's own working directory sits in (the worktree, not its
checkout). A `root:` you passed always wins, a call from a directory inside no repository is left to the
resolution above, and the amendment carries no permission decision. Without the hook, the header's
`tree:` names the tree every answer came from.

### Digests of small code

A digest only compresses what is big enough to compress. Below roughly 60 lines the summary usually
costs as much as the code, and on the smallest types more, so where a digest would summarise little,
`digest` serves the source instead and says so:

```
AxisRail — Lib — …/AxisRail.swift:10-52
(43 lines; a digest would cost 54% of the source, so the source itself follows)
```

Below the crossover a short file dense with code keeps its digest. The comparison is against the type's
own declaration sites (primary plus extensions), and it never serves more than 200 lines. `--offset` and
`--signatures-only` keep the digest.

### Digests of views

A declaration surface is the wrong *kind* of compression for view code: `var body: some View` and a
member list say nothing about the screen. So a `some View` property or method — `body`, and every
`private func card(…) -> some View` beside it — carries an outline of what it builds:

```
  public var body: some View  :18-36
    NavigationStack :20
      ScrollView :21
        VStack :22
          hero :23
          sections :24
          if :25
            FlaggedCard :26
```

The rule is structural: **every statement in a view-builder block is a view**, so `hero` counts exactly
as `VStack` does. Modifier chains collapse into their root (`Text("x").padding()` is a `Text`),
`if`/`switch`/`for` appear as themselves, and action closures (`.task { }`, `.onAppear { }`) are left
out. It is a syntactic guess, truncated past 40 entries; `--signatures-only` omits it.

## 7. Semantic answers need a real build

`where` always resolves declarations, extensions, and conformers-by-name from its own index. Callers
(for a property or subscript, its reads and writes; for an enum case, its uses), overrides, and store-recorded conformers additionally need your build's **index store**, discovered in
this order:

1. `indexStorePath` in `.sift.json`
2. `buildServer.json` at the repo root (xcode-build-server)
3. SwiftPM's `.build`: `.build/out` (Swift Build, the default build system as of Swift 6.4), or
   `.build/index/store` and `.build/{debug,release}/index/store` (`--build-system native`, and older
   toolchains) — whichever of these holds the newest unit wins, since the others are left from earlier
   builds, and that includes a release store indexed after the last debug build. The newest unit is one
   file, so a partial build (`--target`) into a store left behind makes it win with older units beside it
4. `~/Library/Developer/Xcode/DerivedData/*/info.plist` matched to this repo, then `Index.noindex/DataStore`
   — passing over an entry whose workspace no longer exists, one under a hidden or vendored directory,
   and one inside a nested checkout such as a linked worktree, since each of those describes another tree

A candidate counts only if it has a store's shape — a `v<N>` directory holding `units`. `status` prints
which one it found, and names an `indexStorePath` it read and rejected. If none exists, semantic queries
say so plainly, and `where --syntactic` skips the store; `digest` is unaffected either way.

**One store holding two configurations can answer for the one built earlier, and nothing marks it.**
Native builds of both configurations that pass one `-index-store-path` write debug and release units into
the same store, so a call a later debug build no longer makes can still answer `fresh`. Build the other
configuration again, or delete the store and build once.

**Opening a large store is slow the first time, and `where` will not wait for it.** The first semantic
query against a cold store answers with declarations and reports the store as *still warming*; the read
continues in the background, so just ask again shortly. This is not the staleness refusal below and needs
no build.

Where the store cannot answer — a refused symbol, or no store at all — `where` falls back to
**syntactic call sites**: calls matched by written name in the working tree, tagged with the declaration
each sits in. This is a labelled approximation: same-named members of unrelated types and local variables
of that name are included, and dynamic dispatch is missed (`sift help answers` has the full caveat). It
leaves the header's semantic verdict untouched.

## 8. Finding code by shape — `search`

`search` answers the questions `where` and `digest` structurally cannot, because they are about form
rather than name: which `@Test` functions wrap a call in an unstructured `Task`, which subclasses
force-unwrap, which async functions never await. It parses the working tree at query time, so it is
never stale and never refuses.

```
$ sift search 'kind:func attr:Test calls:Task !has:await'
```

Terms are `field:value`, ANDed, negated with a leading `!`:

| Field | Matches |
|---|---|
| `kind:` | `func` `struct` `class` `actor` `enum` `protocol` `extension` `init` `var` `subscript` `deinit` `case` `typealias` `associatedtype` `operator` `precedencegroup` `macro`; `case` is an enum case, one per name of `case a, b` |
| `attr:` | an attribute on the declaration, without the `@` — `Test`, `MainActor` |
| `name:` | substring of the declaration's name, case-insensitive; `a\|b` any of several, `/regex/` a pattern |
| `calls:` | a call in the declaration's subtree, matched on the callee's base name |
| `uses:` | any identifier in the subtree — a superset of `calls:` |
| `inherits:` | a written conformance or superclass |
| `modifier:` | `static` `private` `public` `final` `override` `nonisolated` … |
| `effect:` | `async` `throws` |
| `has:` | `closure` `await` `try` `forceUnwrap` `forceTry` `forceCast` `optionalChain` |
| `sig:` | substring of the declaration's signature as written, case-sensitive; `/regex/` a case-insensitive pattern |
| `path:` | substring of the file path, case-sensitive, applied before the file is parsed; `/regex/` a case-insensitive pattern |
| `owner:` | the type a member is declared in, its extensions included — exact name or `Outer.Inner` |

Every field takes `a|b`, matching when any alternative does, each read exactly as the field reads a
single value (`kind:struct|enum`, `owner:Alpha|Beta`); `kind:struct|kind:enum` is the same question, and
`!kind:struct|enum` matches neither. A `/regex/` is read by `name:`, `path:` and `sig:` only: the rest
refuse it. Values are otherwise literal: `sig:` and `path:` match a substring, the rest match exactly,
and a value written as a pattern (`path:~fresh`, `sig:Fresh*`) is refused with the syntax the field reads
rather than answered as an empty search. `name:` reads three forms: a substring (`name:fresh`), any of
several substrings (`name:open|close`), and a case-insensitive, unanchored regex (`name:/^open|close$/`);
`path:` and `sig:` read the same regex (`path:/Affected|Search/`, `sig:/FileRow\]/`).
Under either pattern form, the declarations whose whole name it matches (`open()`, not `reopen()`) are
listed first and the summary line says how many (`; the <k> whose whole name matches come first`); the rest
follow. An operator's own name (`name:==`, `name:||`) is literal and works.

Two things to know about what a hit means. `calls:`/`uses:` match **written names, not resolved
symbols**, so confirm a specific hit with `where`. And a body term on a *container* covers everything
it holds — `kind:class calls:fetch` matches a class one of whose methods calls `fetch`.

## 9. Configuration — `.sift.json`

Optional, at the repo root. Everything works with no config file at all. (Note the deliberate
near-collision: the **file** `.sift.json` configures; the **directory** `.sift/` caches.)

| Field | What it does | When you need it |
|---|---|---|
| `roots` | Directory allowlist, relative to the repo root | Monorepos — index only the subtrees you work in |
| `exclude` | Extra path substrings to skip | Generated Swift, which inflates the index and rarely digests usefully |
| `moduleMap` | Longest-prefix path → module name | When module names come out wrong (see below) |
| `indexStorePath` | Explicit store location | When discovery misses |
| `linters` | Extra executable names `sift run` filters as linters, beside `swiftlint` | A linter of your own whose output should be filtered |

A key this version does not model is read past, not rejected, and is left exactly where it is by
anything `sift init` writes.

Module names are resolved from SwiftPM manifests (declared target paths, plus `Sources/<Target>/` and
`Tests/<Target>/` by convention), XcodeGen specs and `.xcodeproj` target mappings. All three are discovered by walking the tree — a spec is identified by its shape, so it may
be named anything, and `include:` and `targetTemplates:` are followed. A project built any other
way falls back to each file's first path component — that's the signal you need a `moduleMap`.

If you'd rather not commit the file in a shared repo, add it to `.git/info/exclude` and it stays
yours alone.

## 10. What it touches

Worth knowing before pointing it at a codebase that isn't yours:

- **No network calls at all** — a hard scope constraint, not a default.
- **Inside the repo:** `.sift/` (the index database, the semantic cache, and `runs/` once you use
  `sift run`), one line appended to `.git/info/exclude`, and `.sift.json` only if you create one or run
  `sift init --write`. It never modifies a committed file on its own. The one command that touches your
  working tree is `sift run --without`, which takes your uncommitted changes under a pathspec out for one
  test run and puts every byte back, checked by content hash, keeping a record and copies under
  `.sift/set-aside/` until it has (§12). A green `sift run` records the tree it proved in
  `sift/proved-runs.json` under the repository's shared git directory (`git rev-parse --git-common-dir`),
  one ledger for every worktree, so it survives `sift reset` and dies with the repository; a red run of
  tests is filed beside it in `sift/failed-runs.json` and deletes the green record of the same run, so a later
  failure on the same content revokes the proof.
- **Outside the repo, under `~/.sift/`** (no source content, and nothing leaves the machine):

| Path | What it holds |
|---|---|
| `usage.jsonl` | one line per index lookup (MCP, shell or hook): timestamp, tool, target symbol, repo root, duration, success, face served, first line of any error |
| `run.jsonl` | one line per `sift run`: timestamp, command kind, exit code, lines shown and total, repository, duration, names of failing tests (distinct, sorted, capped at 50) |
| `roots.json` | the indexed roots |
| `advice/<session>.json` | which shell commands this session was already advised on |
| `advice/suppressions.jsonl` | each nudge the hook withheld and the rule that withheld it |
| `advice/answered.jsonl`, `advice/answers/` | each call the hook answered in place, by `tool_use_id`, and a marker per call, kept for a day |
| `callers/<session>.json` | a short-lived note the `PreToolUse` hook leaves naming the context about to make an index call; the server reads and deletes it |
| `server.jsonl` | one line when an MCP server starts and one when it stops |
| `redaction-salt` | keeps report pseudonyms stable |
| `report.html` | written by `sift report`, overwritten each run; self-contained, fetches nothing |

- `~/.claude/settings.json`, only when you run `install-hook`: it registers the SessionStart,
  SubagentStart, PreToolUse and PostToolUse hooks, copies the file to `settings.json.bak-sift`
  before every rewrite that changes it, and removes a legacy sift status line.
  `status` **reads** it back, nothing else, to say when a re-run of `install-hook` is owed.
- `sift status` and `sift install-hook` **read agent definitions** — `.claude/agents/**/*.md` in the
  repository and `~/.claude/agents/**/*.md` outside it — taking `name` and `tools` from the frontmatter
  and writing nothing.
- `sift audit` and `sift report` read every transcript under `~/.claude/projects` (or the window you
  give), tool names and `.swift` file names only; `report` also reads the index of each registered root,
  strictly read-only. Both look outside the repo you are standing in, so on a shared machine know that
  before you run them.

## 11. Command reference

| Command | Purpose |
|---|---|
| `sift init [--write] [--force]` | Inspect the repo layout and propose `.sift.json` |
| `sift index [--full]` | Build or refresh the index |
| `sift status` | Freshness, counts, module map, index-store discovery; names any agent definition whose `tools:` allowlist shuts these tools out |
| `sift help [<topic>]` | Reference for rare moments, in seven topics: `run-output` (reading a red `run` block, what `flakes` counts), `answers` (the parse-error banners, semantic staleness, root resolution), `queries` (per-tool depth), `refusals` (the hook's accounting rules), `test-output` (reading `sift test`), `worktree-index` (a store in a linked worktree) and `build-output` (reading `build --analyse`); a name that is a subcommand instead prints that subcommand's usage; omit the topic to list them |
| `sift digest <target>… [--all] [--signatures-only, or --signaturesOnly] [--offset N] [--at <rev>]` | Declaration surface of a type, file, or module, one member's source given `Type.member`, or a `File.swift:12-40` line range; several targets each answer in one call. A `.md` path answers with its heading outline and line ranges, read live. `--at` answers as of a commit, branch or tag from a syntactic parse of that revision read through git (never the index or the working tree; a module, `.` or `.md` is refused) |
| `sift where <symbol> [--syntactic] [--refs] [--offset N] [--at <rev>]` | Resolve a symbol: declarations, extensions, conformers, callers (a property's reads and writes, an enum case's uses), overrides; `--refs` adds every reference site, paged with `--offset`; `--at` answers as of a revision, declarations from that revision's files and call sites by name only. Where the index store does not answer a function's callers, the call sites matched by name come as their count and the first five, where the MCP tool lists up to 40 |
| `sift search <query> [--offset N] [--count]` | Find declarations by structural shape — `kind:func attr:Test calls:Task !has:await`; `--count` prints the totals and a per-module breakdown, no listing |
| `sift similar <target>` | Rank the declarations whose syntactic shape is closest to one you name — does this helper already exist? |
| `sift dupes [<paths>…] [--min <overlap>] [--offset <n>] [--tests \| --no-tests]` | Group declarations whose bodies are near-duplicates, across the tree or under a path; copies first, test and preview code last, ten groups a page |
| `sift strings <query>` | Trace display text to its localization key (or a key to its text) across `.xcstrings`/`.strings` catalogs, with literal Swift call sites, and to the Swift string literals that hold the text |
| `sift build [--analyse] [--top N] [--build-tests]` | Build a SwiftPM package clean and rank the code slowest to type-check; `--build-tests` includes the test targets in the build and the ranking |
| `sift test --scheme S --device D [--os V] [--plan P] [--only T]… [--skip T]… [--shards N] [--shard-timeout S] [--project P \| --workspace W] -- <xcodebuild arguments>` | Run a scheme's tests across several simulators at once, creating and deleting the simulators it uses. `--only`/`--skip` take `Target`, `Target/Class` or `Target/Class/test` and repeat; `--shards` defaults to what the host can run at once; `--shard-timeout` is the floor under a shard's bound, 600 seconds by default and refused below 30 |
| `sift test --analyse [--plan P] [--against <log>]` | How many tests are supposed to run, from the index and the test plans — declared, in a plan, never run, conditional — building, booting and running nothing; `--against` reconciles a finished run's output (the file `swift test` wrote, or a log under `.sift/runs/`) against that inventory: tests missing or reported twice |
| `sift test --sweep` | Delete the simulators this checkout's dead runs left behind, and run nothing |
| `sift run [--coverage [--from R]] -- <command>` | Run `swift build` / `swift test` / `xcodebuild` and print only what failed. `--coverage` runs `swift test` or `xcodebuild test` with coverage on and says which lines of each changed declaration ran and which did not, measured from `--from` (default `HEAD`) to the working tree |
| `sift run --proved -- <command>` | Run nothing: answer whether this command already passed on this tree's exact content. Exit 0 proved, 1 no such run on record (running it would fix that) or a later run on this content failed, 2 the question cannot be put (the ledger is off, or no repository, tree or toolchain to name) |
| `sift run --without <pathspec>… [--since <rev>] [--keep-without-build] -- <tests>` | Run the named tests with your uncommitted changes under the pathspec set aside, then with them back: one line per test on whether it fails without the change and passes with it. The flag repeats, one pathspec per flag, and everything it names is set aside as one unit; `--since` sets aside what the commits since that revision changed under it instead, for a fix already committed. The build made without the change is removed once your changes are back; a run that could not put them back leaves it (and says so), for the next run to clear. `--keep-without-build` keeps it for the next proof to build on |
| `sift run --without-line <file:line> -- <tests>` | The same proof for a fix that cannot build without its own change: comment out that one line, run, put it back, run again |
| `sift run --restore` | Put back a set-aside whose run was killed along with its watcher, checked by content hash |
| `sift affected [--from R [--to R]] [--depth N] [--reached NAME]...` | Which tests reference what a diff changed, with the `-only-testing:` and `--filter` arguments — it reports, it never runs and never decides what to skip |
| `sift diff [<range>] [--member <Type.member>] [--offset N] [--coverage]` | A structural digest of a change for review, in place of the raw `git diff`: every touched file, declarations added/removed/changed with before → after signatures, what changed outside them, callers of changed signatures, test names, and the tests reaching the changed files. `<range>` is a single commit (its own change), `A..B`, `A...B` (against the merge-base), or omitted for the working tree vs `HEAD`. `--member` prints one declaration's before/after; its header ends in an address `path#Type.member:line` (the file, the declaration's label, and its line after the change; `path#Type.member:before:line` for a declaration the range removed, which has no after side), and that whole address can be passed back to `--member`, as the ambiguity refusal's list does. `--coverage` adds what the last `sift run --coverage` measured, where it measured this very tree, and says so where it is stale or absent |
| `sift usage [--since W] [--root R] [--unredact] [--all-roots] [--include-scratch] [--file P] [--run-file P]` | Summarise the index usage log — calls by tool, root and day, latency, top targets; `--all-roots` lists every root rather than the top five; `--file`/`--run-file` read other copies of `usage.jsonl` and `run.jsonl` |
| `sift flakes [--since W] [--root R] [--unredact] [--file P]` | For every test that has both failed and passed across wrapped runs: how many named it, out of how many, and when one last did; `--file` reads another copy of `run.jsonl` |
| `sift audit [--since W] [--until W] [--all] [--transcript P] [--projects D] [--unredact] [--progress] [--replay [--sample N] [--shapes P] [--against <binary>]] [--scan-diff --against <binary> [--all-windows]] [--summary \| --share]` | Audit transcripts for Swift lookups that went around the index, named file by file; `--until` bounds the window above, `--projects` reads another transcript directory. `--replay`, `--against`, `--scan-diff`, `--summary` and `--share` are described under **Auditing the misses** |
| `sift report [--since W] [--root R] [--out P] [--include-scratch] [--no-open] [--progress] [--file P] [--run-file P] [--projects D]` | Write a self-contained HTML page — conditions awaiting you, index share, estimated savings, failures — and open it; `--file`, `--run-file` and `--projects` read other copies of the usage log, the run log and the transcripts |
| `sift reconcile` | Diff index against working tree and fix divergences |
| `sift reset` | Delete `.sift/`; the proved-run ledger, `sift/proved-runs.json` in the shared git directory, is one for every worktree and stays (with `failed-runs.json` beside it), and the answer names it where there is one |
| `sift install [--agent A]… [--all] [--yes] [--dry-run]` | Detect Claude Code, Cursor and Codex and install into each one chosen, asking once per agent found; `--yes` takes every one found, `--all` all three, `--agent` the ones named, `--dry-run` writes and runs nothing. Exits 0 on success, nothing to do, or needing a flag (no terminal); 1 if any agent failed |
| `sift doctor [--agent A]… [--cursor-dir D] [--codex-dir D] [--json]` | Check that each agent found runs what the install wrote (`--agent` checks the agents it names, found or not): the registration, the registered binary and its version, each hook fed a payload of that agent's shape, the MCP server's tool list; one line per check, agents not found skipped. `--cursor-dir` checks that Cursor directory; `--codex-dir` checks that Codex home, found or not (trust is reported where readable, not compared). Exits 1 if any check failed |
| `sift install-hook [--allow-run \| --no-allow-run \| --allow-lookups] [--agent claude\|cursor\|codex] [--cursor-dir D] [--codex-dir D] [--settings P] [--command C]` | Register the SessionStart/SubagentStart primer, the PreToolUse shell hook, the PostToolUse edit check, the Stop/SubagentStop build check (`sift stop`, which Claude Code runs, not you: it blocks a stop once when Swift was edited with no green `sift run` build since); removes a legacy sift status line and band plugin; names any agent definition whose `tools:` allowlist shuts these tools out. `--allow-run`, `--no-allow-run` and `--allow-lookups` answer the two allow-rule questions (the four lookups, default yes; the run rules, default no) without asking: both blocks, neither, or the lookups alone; `--agent` picks Cursor or Codex instead (§4), `--cursor-dir` and `--codex-dir` naming their directories; `--settings` edits another settings file, `--command` registers another hook command than this binary's path |
| `sift uninstall-hook [--only-advice] [--agent A] [--cursor-dir D] [--codex-dir D] [--settings P]` | Take those registrations back out; `--only-advice` removes just the PreToolUse hook; the other flags as for `install-hook` |
| `sift uninstall [--purge] [--settings P]` | Take the tool back out: the hooks, a legacy status line, the MCP server at user and local scope, the Cursor and Codex registrations too, a legacy band plugin and its marketplace (through `claude plugin`, which edits the user's own settings, so left out when `--settings` is given), the agent rule; list every `.sift/` directory and every `.bak-sift` backup (settings, Cursor, Codex) it left, deleting them with `--purge`; print what removes the binary (`rm`, `brew uninstall` or `npm uninstall`) |
| `sift pre-tool-use [--command C] [--cwd D]` | Offer the index call that answers a shell lookup (run by the PreToolUse hook) |
| `sift mcp` | Run the MCP stdio server |
| `sift servers [--stop --pid N \| --root R] [--yes] [--file P] [--usage-file P]` | The MCP servers this machine believes are running, and the one sanctioned way to stop one — it stops nothing it selected for you (a `--root` at or above `$HOME` is refused), nothing until `--yes`, and never this session's own, one in this process's ancestry, or one with a sign of life in the last ten minutes. Every answer names the two logs it read; `--file`/`--usage-file` point it at other copies of them |

All take `--root` to target a repo other than the one enclosing the current directory — except `run`,
which wraps a command in the directory you are standing in and does not touch the index at all, and
`help`, which is static reference text with no repository to target.

To stop a server: `sift servers --stop --pid N` prints the plan, and the same line with `--yes` sends the
signal.

### Environment variables

| Variable | Effect |
|---|---|
| `SIFT_NO_ADVICE` | Non-empty: the hooks that act on a call stay silent (§4); the session primer still prints |
| `SIFT_RUN_LEDGER` | `0`: the proved-run ledger is off — no green run is recorded, and `sift run --proved` answers 2; a red run of tests still revokes the tree's proof |
| `SIFT_PROGRESS` | `off`: `sift run` keeps no live progress file in `.sift/progress/` ([ProgressContract.md](ProgressContract.md)) |
| `SIFT_USAGE_LOG` | Writes the usage log to this file instead of `~/.sift/usage.jsonl` |
| `SIFT_RUN_LOG` | Writes the run log to this file instead of `~/.sift/run.jsonl` |
| `SIFT_SERVER_LOG` | Writes the MCP server's start and stop lines to this file instead of `~/.sift/server.jsonl` |
| `SIFT_ADVICE_DIR` | Keeps the hook's ledger, suppression log and back-off in this directory instead of `~/.sift/advice` |
| `SIFT_HOME` | An absolute path: everything the tool keeps per user (roots registry, usage, run and server logs, advice, caller slips, salt) lives in this directory instead of `~/.sift`. Relative or empty is unset; `SIFT_USAGE_LOG`, `SIFT_RUN_LOG`, `SIFT_SERVER_LOG` and `SIFT_ADVICE_DIR` still win for their own file |
| `SIFT_PART_MARKER` | `1`: keeps the marker a CLI answer carries so `audit` can credit it when read back from a transcript; on by default under Claude Code (`CLAUDECODE`), stripped elsewhere |

The log and directory overrides exist so a probe or a test driving the binary leaves no trace in the
records you read; an empty value is unset. `CODEX_HOME` is Codex's own (§4).

### Reading the usage log

The log is **per-user, not per-repo** — `~/.sift/usage.jsonl` — so `usage` reports every repository from
wherever you run it, with a `by root` breakdown. Narrow it:

```sh
sift usage --since today                     # today, yesterday, 7d, or YYYY-MM-DD
sift usage --since 7d --root Orchard/app   # a unique trailing path fragment is enough
```

Both filters are named in the header, so a scoped count can't be misread as a global one. A `--root` that
matches nothing says so and lists the roots the log holds.

**Scratch roots are not counted.** A call whose repository root lies under the system temporary directory
(`/tmp`, `/private/tmp`, `/var/folders`, `$TMPDIR`), under `~/Library/Caches`, or inside any `.build/`
directory is a probe, not use: it is left out of every figure and table, and one line says how many were
(`N calls against scratch roots (temporary, cache or .build directories) not counted`). `--include-scratch`
restores the old totals. A repository merely named `build` is real.

**The call count is index lookups, whichever face served them**: MCP tools, `digest` / `where` / `search`
/ `strings` from a shell, and answers the hook gives in place. A line names its face in `via` (absent for
the server, `hook` or `cli` otherwise); CLI and hook lines are counted in the tallies and left out of
p50/p90, and the report says so. `sift run` keeps its own record, `~/.sift/run.jsonl`, reported in a
`runs` section below the call breakdown; the two are never added. `sift flakes` reads that log too.

A line also names the **subagent** that made the call, where the hook was there to say so. Read the
figures as a **floor**: no agent on a line means only "not attributed to a subagent", and one line is not
evidence about one caller (two subagents making the same call at the same moment leave one note between
them).

A call count is only the numerator — it cannot see the raw file reads that happened *instead*. That is
what [`sift report` and `sift audit`](#seeing-what-sift-did) are for.

### Which tests have failed inconsistently

`sift flakes` reads `~/.sift/run.jsonl` and lists every test that has **both failed and
passed** across the runs that recorded which tests failed — how many named it, how many runs that is
out of, and the day one last did.

```sh
sift flakes                      # every repository this machine has wrapped a run in
sift flakes --since 7d --root Orchard/app
sift flakes --unredact           # real test names; pseudonymised by default
```

**Read it as counts and nothing more.** A test named by 3 of 20 runs may fail at random, or may have
been failing on a change that was present for exactly those 3 runs — the log cannot tell you which,
and the report does not pretend to. The denominator is the runs of the same command kind that
recorded their failures, not the runs of that test: nothing in the log says which tests a run
executed. Runs written before the log kept failure names, passed through unfiltered, or failed for a
reason the filter could not explain are reported as **unknown** and counted in nothing — never as
runs in which nothing failed.

`--root` takes the runs in every worktree of the repositories it names, wherever each worktree was
cut, so a failure in an agent's worktree and a pass in the checkout are one test's history. Runs
recorded before the log kept a repository key are scoped by their directory alone.

### Seeing what sift did

Sift draws nothing in Claude Code itself. Three commands show what it did:

- `sift report` writes an HTML page: the conditions, the index's share of the Swift lookups, the estimated savings and the failures.
- `sift audit` names the lookups that went around the index (below).
- `sift usage` counts calls by tool, root and day.

The share is how often the agent *reached for* the index, not how well the index did. **It is not a success rate**: the rest are lookups that went somewhere else (a whole-file `Read`, a `grep`, a `cat`), and a call that failed is counted on its own. A file read whole after its digest stays in the share as a miss. The denominator is **every Swift lookup in a session that was a genuine choice between the index and something else**. A saving is an estimate (the source the index's answers stood in for, less what they served, priced against reading each file whole, which leans high), so `report`, `usage` and `audit` state it with that baseline.

What counts against the share — a lookup that went around the index — is narrower than "every Swift
read". Seven kinds are tracked apart from the misses; six are excluded from the share and one stays in
it. `sift audit` prints each with its count:

| | |
| --- | --- |
| **guided** | a *ranged* read of a file an index call located — the second half of digest-then-ranged-Read. |
| **read whole** | a *whole-file* read of a Swift file after its digest. It stays in the denominator: it is the read the index exists to save, paid in full. The transcript records the read, never its reason, so read it as what those reads cost, not a verdict on the digest. |
| **below floor** | a file small enough that `digest` would have served its source anyway. |
| **revisited** | a re-read of a file already open in that context. |
| **text search** | a search for text the index does not record: a symbol no index on this machine declares (even during a quiet spell or with advice off), or a lookup the advisors can name no call for. |
| **not worth** | a lookup the index *could* have answered, withheld because the answer costs more round trips than the command it replaces (an alternation answered one `where` per name, a context grep of one file, the re-run every refusal offers). Counted apart from text search; the row prints the share with these counted as misses. |
| **unreachable** | a lookup from a context that holds no sift tools (a subagent pinned to `tools: Read, Grep, Glob, Bash`). Recognised by 12 or more refusals with never an index call between them, by any route: a `sift` call in Bash disqualifies a context from this row, whatever the subcommand. Decided when the report is assembled, and shown on its own row. The durable fix is the agent definition. |

A cold *ranged* read still counts: the session knew where to look from somewhere other than the index.

**A lookup counts by what answered it, not by the route it took.** A `sift where` in a Bash block is the
index serving a lookup exactly as `mcp__sift__where` is, so it counts in **indexed** (`sift audit` prints
the CLI-served part on a row inside it). A subcommand that answers no lookup — a wrapped build, a
`sift status` — counts in neither the numerator nor the denominator. The share leans low rather than
high: a search that merely mentions Swift still counts as a raw lookup, and the unreachable rule is a
floor (a context that took only eleven refusals stays in the denominator). (Rationale: Design.md §4.)

### Auditing the misses

`sift audit` is the review of the share. It reads finished
transcripts — sessions and subagents — and names the lookups that went around the index:

```sh
sift audit --since today       # or 7d (the default), yesterday, YYYY-MM-DD, --all
sift audit --transcript <path> # one session and its subagents
```

```
  indexed        8  served by sift — 33% of the lookups that had a choice
  cold          14  went around the index  ← the misses
    batched      3  of those, a Swift read on a line the hook let run whole for its other statements — put the sift call on the line instead

  guided         2  ranged reads an index call had located — the loop working
  read whole     2  read whole after its digest — the read a digest exists to save, paid anyway
  below floor    9  files small enough that a digest would have served the source anyway
  revisited      7  re-reads of a file already open in that context
  text search    3  for text the index does not record — a name no index declares, a file no call can name, or a search that names no call at all
  not worth      2  the index could have answered these, but not worth what it would have cost — more round trips than the command in one case, an answer no digest shape gives in another — counted as misses the share is 31%
  unreachable    5  lookups from contexts holding no sift tools — advice that could not land
  (a context that took 12+ refusals and never once called the index: its tool list has no
   sift in it, so nothing it was told to run was there to run. Those lookups are out of the
   share above — the durable fix is the agent definition that spawned it, not anything here.)

cold lookups, worst first:
    12  Developer-Orchard · 3f2a91c4 · 2026-08-06 – 2026-08-08
      RecordStore.swift, WorkQueueTests.swift, ListingTests.swift, +9 more
```

`--since` is resolved in **local** time, unlike `usage --since`, which follows the log's own UTC day key.
It bounds the *lookups* counted rather than the transcripts opened, so a session that began yesterday
contributes only today's half.

Every finding is dated (the day its misses happened, or the span), and the lists of files read whole
after their digest and files opened cold in more than one context carry the most recent day each was seen
(`· last 2026-08-08`). It also breaks the searches down by **the call that would have answered each** —
`where`, `search` or `digest` — using the hook's own advisor, so "250 of them were `digest` questions" is
one habit to close. It names the **index calls that failed** too: the tool, the kind of failure, and what
it was asked.

**Both reports are pseudonymised by default, so sharing one is safe.** Every count, share, date and
latency stays; file, project, symbol, root and target names become salted pseudonyms
(`file-3f2a1b.swift`, `project-9c1d4e`), stable across reports from the same machine. The salt lives at
`~/.sift/redaction-salt` and never leaves the machine. `--unredact` prints the real names. The actionable
parts survive redaction: searches break down by verb, never by query, and a failure carries its *kind*
(`root not indexed`, `argument missing`), not the message text.

Last, it names any indexed root where **at least a tenth of files carry a guessed module** — resolved
from a directory name because no manifest covered them, so those files answer about a module that does
not exist. SwiftPM, XcodeGen and `.xcodeproj` are read without configuration, so a root listed here is
running an older binary (check that first) or is built by something none of the three describe;
`sift init` proposes a `moduleMap` for that case.

Five flags turn the audit on the hook itself, for whoever is changing it:

- **`--replay`** puts every call in the window to the hook as it stands today and reports the share it
  would reach: the cold lookups it would answer in place, those it would still let through, and those
  whose directory is gone. `--shapes <file>` writes every still-cold shape with its count to a file. It
  replays a sample of the window's sessions, each with its subagents, until 100 contexts are replayed, and
  says so; `--sample N` sets the bound in contexts, `--sample 0` replays every session (a week's worth takes
  about 10 minutes, nearly 4 times that with `--against`). On a terminal, or with
  `--progress`, each session replayed is printed on stderr with the time so far, after the audit's own
  scan, which prints its advance there the same way with or without `--replay`.
- **`--replay --against <binary>`** puts every call to another `sift` build's hook as well and lists only
  the calls the two judge differently, grouped rule → rule; a call answered in place by another index call
  is a difference too, listed as `<rule> [call <its call> → <this one's>]` with each call shaped, and under `--unredact`
  the two calls as written beside it.
- **`--scan-diff --against <binary>`** runs both builds' transcript scans over one snapshot and lists each
  window they class differently, up to 100 a group (`--all-windows` lists every one); `--root` scopes both
  scans to the transcripts it keeps.
- **`--summary`** keeps the share, the not-worth rows and the refusal accounting and drops the lists;
  **`--share`** prints only two lines, the headline share and the voluntary share, for a script comparing
  windows.

### One page, on disk — `sift report`

`sift report` renders the same material as a page you can glance at. It writes one self-contained HTML
file (inline stylesheet, hand-drawn SVG bars, no script, no network) to `~/.sift/report.html` (or
`--out`), prints the path, and opens it unless you pass `--no-open`. `--since` and `--root` are
`usage`'s exactly; the window defaults to `7d`. What leads the page is the short list of conditions only
you can clear, each naming the repository, the fact and the command (nothing renders when nothing is
wrong). Below come index share with a bar per day, the estimated saving (gross, with its basis and
baseline, and one line counting the digests whose file a transcript then read whole), failures by reason with their
dates, then calls by root and the most-asked-for targets. `--root` narrows every section together: calls
and conditions by the repository each call was made against, the share by the directory each transcript
was recorded in. Scratch roots are left out here too, calls and sessions alike, with the same one-line
note and the same `--include-scratch` to count them.

**The core loop** is digest-then-ranged-read. A digest gives you the shape plus exact line ranges:

```
$ sift digest ModuleResolver
tree: Sift  head: adc3e08  clean  semantic: syntactic-only
ModuleResolver — SiftCore — Sources/SiftCore/ModuleResolver.swift:12-283 (+3 extensions)
struct ModuleResolver

stored properties:
  private let prefixMap: [(prefix: String, module: String)]  :14  /// Path prefix → module name, longest prefix consulted first.
  let unmappedManifests: [String]  :18  /// Repo-relative SwiftPM manifests that contributed no mapping at all …
  let survey: Survey  :20  /// What each build system contributed, reported by `status` when anything fell back to a guess.
  … (7 more)
members:
  init(repoRoot: URL, config: SiftConfig)  :46-72
  func module(for relativePath: String) -> String  :75-78  /// The module for a repo-relative path; …
```

…so reading `module(for:)` is four lines at `:75`, not the whole file (the sample is trimmed; a real
digest lists every member). `digest` also accepts a file path or a module name, and paginates with `--offset` when a type is huge.

**When you already know the member's name**, skip the round trip — `digest ModuleResolver.module` (or
the labeled `ModuleResolver.module(for:)`) returns that member's source directly. Bodies over 200 lines
truncate with the ranged read that finishes them, and an overloaded name lists the labeled candidates
rather than picking one.

**For a rename or delete sweep**, `where <symbol> --refs` lists every reference site grouped one line
per file:

```
$ sift where ResultCache --refs
references to Lib.ResultCache (118 in 31 files):
  ProductKit/Sources/Lib/Session/Coordinator.swift (4): 21, 44, 58, 91
  ProductKit/Tests/LibTests/ResultCacheEraseTests.swift (7): 12, 19, 27, 28, 40, 63, 70
```

Callers alone won't do — a type has none, and test payloads never appear among them. One boundary
matters here: the index store records **code occurrences only**, so doc comments and string literals
naming the symbol are invisible to it. Grep for those before deleting; the answer says so every time,
so a partial sweep is never mistaken for a complete one.

## 12. Compressing build output — `sift run`

The index covers one half of what a session spends context on: reading code. The other half is what
the toolchain says back. A single `xcodebuild test` prints eight hundred lines of plan, invocation and
argument dump around one result, and an agent pays for every one of them on every verify loop.

Prefix the command you were going to run anyway:

```sh
sift run -- swift test
sift run -- swift build -c release
sift run -- xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17' test
```

A passing run is its verdict, its counts and where the raw log is:

```
✔ swift test
totals: ✔ passed · Swift Testing 8 tests in 1 suite
raw: .sift/runs/run-20260929-090738Z-58a3b1c1.log (26 lines in, 3 out)
```

A skipped test is counted on that line as skipped (`Swift Testing 2 tests in 1 suite, 1 skipped`, and the
same for an `XCTSkip`), so a run whose selected tests all skipped does not read as tests that ran.

The tool's own tally lines are summed into the `totals:` line and left out beside it; whenever the sum
is anything but a plain pass or fail — an exit code that disagrees, a count that would not sum — they are
printed, since they are then the evidence to check it against.

A failing one keeps what you have to act on — errors with their file, line and column, test failures
from both frameworks with their messages, warnings deduplicated and capped at twenty — and nothing else:

```
✘ swift test — exit 1
  aFailingTest() — Tests/SiftCoreTests/DepotStoreTests.swift:11 (body :8-12)
    Expectation failed: depot.count == 2 → false depot.count → 1
totals: ✘ failed · Swift Testing 1 test in 1 suite, 1 failure
raw: .sift/runs/run-20260929-090807Z-1b642cfb.log (17 lines in, 5 out)
```

The heading names the file and line and, where the failure sits inside the test's own body, that body's
range. Two or more failures are led by one line that says whether they are one problem or several —
`9 failures · 1 signature · 2 files · 0 in changed files (matched by name)` — and a failure that resolves
to a helper rather than to its test gets an `in … (syntactic)` line naming the helper.

Six things worth knowing before you wire it into a script:

- **The exit code is the wrapped command's, with two exceptions.** `sift run -- swift test` in a hook
  or a pre-push gate behaves exactly as `swift test` did — except that a run naming its tests
  (`--filter`, `-only-testing:`) that exits 0 with a log showing it executed none of them (SwiftPM's
  no-match warning, closing counts of 0, a parallel runner that started a suite and ran no test, or a non-quiet
  `xcodebuild` success banner over no test line)
  answers ✘ and exits 4. So does a run of several `--filter`s where one matched none of the tests the
  others ran: the headline and the totals line name it, `✘ … no test matched --filter <pattern> — 1 of 3
  filters`, judged against the tests the run's event stream and console name. It is judged only with two
  or more `--filter`s, only where the run shows a test matched by name (an XCTest name the console prints
  without its module leaves it unjudged), and never under `--parallel`. A log merely silent about its tests keeps its exit, but is never recorded as proved.
  An unfiltered `swift test` of a package whose manifest declares test targets, that exits 0 with every
  closing count at 0, answers the same way: `✘ swift test — nothing ran: no test executed, though the package
  declares N test targets`, exit 4, an `inventory:` line naming the declared tests that never reported
  (`inventory: 3 declared, 0 reported — 3 never reported: …`), and no proof for `--proved` to cite.
  The same run whose build failed before any test process started answers `✘ … did not build — no test
  ran` and exits 5, where passed through its 1 or 65 would read as a test that failed.
- **An unfiltered `swift test` checks its own count.** It prints an `inventory:` line setting the tests
  the index declares against the ones the run reported, so a test that silently never ran shows; without
  an index the line says it was not checked. A test the runner reported skipped is named on it as skipped,
  not counted as one that ran.
- **A green run is remembered.** Its tree goes into the proved-run ledger (§10), and
  `sift run --proved -- swift test` answers from it without running anything: exit 0 when this exact tree
  already passed, 1 when no such run is on record, 2 when the question cannot be put. A red run of the
  same command on the same content after the green one revokes it: the red deletes the green record, so
  `--proved` answers that no such run is on record, exit 1, until a green run proves the tree again (where
  a green from another worktree lands while the red is filed, it reads `✘ not proved — a later run of swift
  test on this tree's content failed 3m ago (run <log>)`).
  `SIFT_RUN_LEDGER=0` turns it off, except that a red run of tests under it still revokes the proof, so
  a green filed with the switch on never stands for a tree that later failed with it off.
- **`--coverage` says which changed lines the tests ran.** `sift run --coverage -- swift test` runs with
  coverage on and lists, for each declaration the change touched (from `--from`, default `HEAD`, to the
  working tree), the lines run and not run; `sift diff --coverage` shows the same where the tree is
  unchanged since.
- **Nothing is lost.** The complete raw output goes to a file of its own under `.sift/runs/` as it
  arrives, and every answer ends by naming that path and how many lines it stands for. One file per run,
  named with its start time in UTC (the `Z`), and the five most recent are kept. The log of a run that
  named its tests and did not build, either run of a `--without` proof included, is kept in a pool of its
  own, so later runs do not prune the log its answer names.

- **`swift build`, `swift test` and `xcodebuild` are recognised** — by the command name, not by what
  the output looks like. Anything else runs untouched, with one note on stderr saying so.
- **A failure it cannot explain hands you the raw log instead.** If the command exits nonzero and the
  filter found no error and no test failure, you get the whole transcript rather than a reassuring
  summary of nothing. A summary line does not count as an explanation — `** TEST FAILED **` restates the
  exit code you already have, so a run whose only failure evidence is that verdict still serves raw.
  That transcript is every line, but no line past 8 KB: a longer one is cut and marked, and the log
  keeps it whole.
- **A compiler crash is an explanation.** The answer reads `✘ … compiler crashed`, then the pass and
  function the stack dump names (demangled, `on RunCommand.run()`) and any `Error!` line the compiler
  printed. The `Failed frontend command:` and `Program arguments:` lines, often tens of kilobytes each,
  stay in the raw log.
- **stderr is merged into stdout**, the way `2>&1` does, so the log is ordered as the tool wrote it.
- **Each run files one line in `~/.sift/run.jsonl`** — kind, exit code, lines shown and total,
  repository and duration — kept separate from `usage.jsonl`, which counts index lookups and nothing
  else; `sift usage` reports the runs in a section of their own, and a log that cannot be
  written costs one note on stderr and nothing else.

### Proving a test fails without your change — `--without`

A fix owes a test that fails without it. Instead of stashing, running and re-applying by hand:

```sh
sift run --without Sources/ -- swift test --filter WidgetTests
```

runs the named tests with every uncommitted change under `Sources/` set aside, puts the changes back, runs
the tests again, and answers test by test. **The flag repeats, one pathspec per flag** — `--without
Sources/Depot.swift --without Sources/Orchard.swift` sets both files aside as one unit. A second pathspec
written beside the first instead of behind a flag of its own is refused as what it is, with the flag to
repeat spelled out. A fix already committed is set aside with `--since <rev>` (what the commits since it
changed under the pathspec; refused while anything there is uncommitted), and a fix that cannot build
without its own change with `--without-line <file:line>`, which comments out that one line. The file has
to compile with the line commented out, so name one nothing after it depends on — a one-line
`guard !… else { return }` that binds no name, a call. Nor a guard that is the last reader of a local above
it: the local is left unused, which a warnings-as-errors package refuses, so route it through a helper whose
parameters carry the inputs. A `guard let` or `let` whose name a later line uses
does not compile commented out; nor does a `guard … else {` that opens a block, or the `return` or `throw`
inside it (a guard body must not fall through). A line that assigns one bare name (`settings = updated`) is
set aside as `_ = updated` instead, so the name keeps a reader and the build does not stop on an unused
value; the answer says which form it used, and where the build still fails on nothing but unused values the
line read, it names the `_ = name` hand form. Such a fix needs `--without` or a set-aside by hand:

```
✘ 1 of 2 fails without Sources/ and passes with it
  ✘ sizeIsCarried() — passes without Sources/ too, so it pins nothing
  ✔ shoutingWorks() — fails without Sources/, passes with it
  set aside and put back: 3 paths under Sources/ (1 with staged changes, 1 with unstaged changes, 1 untracked), checked by content hash

without Sources/ — ✘ swift test — exit 1
  Test run with 2 tests in 1 suite failed after 0.001 seconds with 1 issue.
with it — ✔ swift test
  Test run with 2 tests in 1 suite passed after 0.001 seconds.

sift run: 212 lines in, 11 out — raw output at .sift/runs/run-20260818-102214Z-5c1d09aa.log (without Sources/) and .sift/runs/run-20260818-102301Z-e8b7f412.log (with it)
```

- **Your work comes back exactly.** Staged and unstaged edits, untracked files, deletions, renames and
  mode changes all leave the tree and come back as they were, checked by content hash before anything
  else runs. On any mismatch it stops, says which path, and deletes nothing.
- **Nothing written in the meantime is overwritten.** A file you (or an agent beside you) save after the
  changes are recorded and before they are set aside stops the run, and nothing runs. Anything written
  into a set-aside path while the tests ran is kept beside it as `<path>.sift-kept-<id>`; if it cannot
  be kept there, the run stops with exit `3` and says where it is. A branch switched or a commit made
  while the tests ran is reported, and your changes come back on top of it.
- **On every exit path**: tests passing or failing, a build error, Ctrl-C, `SIGTERM`, `SIGHUP`, and
  `sift` itself being killed (a watcher process restores). If even that fails, `.sift/set-aside/` keeps a
  record and a copy of everything, every `sift run` (and `sift reset`) refuses, and the message names
  `sift run --restore`.
- **What it cannot promise.** A process your tests start through a service manager (the simulator,
  `launchd`, the runner `xcodebuild` asks to launch) is not the run's to end: what it writes after the
  changes go back lands in the restored tree. If the watcher dies while your changes are out, the answer
  says so, and they stay out until `sift run --restore`.

- **A suite that did not compile without the change is said separately**: evidence the tests need the
  change, not an assertion that fails without it, claimed only for a compiler error in a file that
  imports XCTest or Testing. Its tests get `◇ … passes with it; without Sources/ it did not compile —
  needed, not pinned`, never a tick.
- **A fix that adds a new file is set aside by removing it**, staged or untracked alike, and the answer
  says so (on stderr before the first run too). It also says what that leaves unanswered: whether a test
  pins what the file *does* rather than merely naming it.
- **The run without the change builds apart, and that build is removed once your changes are back** — it is
  under `.sift/without-build/`, as large as a build of the repository, and the receipt says
  `built without the change in a scratch build (… GB, removed)`. Iterating on one proof, add
  `--keep-without-build`: the next proof of the same package or scheme builds on it, and the receipt
  names it with the `rm -rf` that removes it. A run that could not put your changes back removes nothing
  and says the build was left; the next run clears it. A `.sift` or `.sift/without-build` that is a
  symbolic link is refused before anything is set aside.

- **Name the tests** — `--filter`, or `-only-testing:` for `xcodebuild test`. `--skip-build` and
  `test-without-building` are refused: they run what was built with the change in it. So are
  `--parallel`, which prints no line for an XCTest that passed, `-parallel-testing-enabled YES`, whose
  clones report tests in lines it does not read, and repeated iterations; under
  `-retry-tests-on-failure` a test counts by its last attempt.
- **The exit code is the answer's**: `0` proven, `1` not proven (a test pins nothing, fails both ways,
  nothing ran, the tests did not compile), `2` refused or stopped with nothing out of the tree, `3` your
  changes are **not** back in the tree — run `sift run --restore`, after freeing space if the message says
  the volume is full — and `64` a usage error, said before anything moves: a command that cannot prove
  anything run twice (tests not named, `--skip-build`, `--parallel` and the rest above), a `--since`
  revision git cannot resolve or HEAD does not descend from, a command that builds another checkout, or
  flags that do not go together. Only the second run is recorded in
  `~/.sift/run.jsonl`: the first ran a tree you do not have, and its expected failures would read as
  flakes.

## 13. License

Apache License 2.0 — see [LICENSE](../LICENSE). The open-source components the binary links, and their
licenses, ship as `THIRD-PARTY-NOTICES.txt` beside the binary itself: in the release bundle, in the
Homebrew keg, and in the npm platform package (neither is published yet) — not in the `@agulhas-labs/sift` launcher, which
resolves that package and carries no binary of its own.
