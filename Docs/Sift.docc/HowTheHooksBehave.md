# How the Hooks Behave

What sift's hooks do in Claude Code, what they stay quiet about, and how to turn the advice off.

## Overview

`sift install` registers six hooks in Claude Code (see <doc:Installing>). Each one is a
call to the `sift` binary that Claude Code makes at a fixed moment. The samples here come from running that
binary in the sample package of <doc:GettingStarted> (`Distribution/docs-fixture.sh`): a module called
`Stacks`, its checkout shown as `~/code/Shelf`. Paths under your home directory are shortened to `~`.

### The session primer

When a session or a subagent starts, the `SessionStart` and `SubagentStart` hooks print a short note naming
the four tools and when to reach for them. It prints nothing unless Swift is in view: not in a directory
with no Swift, and not in a session that never touches it. Run it by hand to see what a directory would get:

```text
$ sift session-start --cwd ~/code/Shelf
**sift indexes this Swift code: ask it before reading or grepping a `.swift` file.**
- `digest <Type>` (or a file, or `.`): member line ranges, then a ranged Read; known `Type.member`s (several per call): their source; a cited line: `digest File.swift:120`
- `where <Symbol>` instead of grepping: definition, callers, conformers, overrides
- `search` for code by shape, `strings "<text>"` for UI text
- `sift run -- swift test` (or a build) from Bash: the failures, the log in `.sift/runs/`

This repo is indexed (`~/code/Shelf`), so queries here need no `root:` argument.

Without sift tools, the CLI answers the same queries from Bash (`sift digest …`).
```

Where the four lookups (`digest`, `where`, `search`, `strings`) run from Bash without a permission prompt, that sentence reads instead: "If sift's tools are deferred or missing, run `sift digest …` from Bash rather than loading them." A subagent's closing also says to use Read/Grep as normal where it has no Bash.

### A read that a smaller answer covers is stopped once

The `PreToolUse` hook watches the calls that can read Swift source: `Read`, `Grep`, `Glob`, and `Bash`
commands such as `grep -n` and `cat` on a `.swift` file. When the index has an answer smaller than what the
call would return, the hook **stops the call once and names the command to run instead**. Refusals stay on
in the release.

Here is a whole-file `Read` of `Library.swift`, made long by `sh Distribution/docs-fixture.sh ~/code/Shelf pad`
(sixty more members, left uncommitted, hence `dirty: 1`) and indexed by a first query, fed to `sift pre-tool-use` as the JSON payload Claude
Code sends. The reply is what the model sees, abridged. It opens by saying what re-running the read would
cost, in lines and in tokens, and by naming the cheaper route: a `Read` of just the member you want, with
`offset` and `limit`, which the hook never interrupts once you hold the digest. Every other answer's first line
ends `re-run the identical command if you wanted its raw output.` instead, and so does a whole read of a file
over 2000 lines, the most a `Read` prints by default.

> sift answered this with `digest Sources/Stacks/Library.swift` instead of running it — re-run the identical command for all 669 lines, about 5.6k tokens, or Read just a member's line range below with offset and limit.

and goes on with the digest:

```text
tree: Shelf  head: ec26cde  dirty: 1  parse_errors: 0  semantic: syntactic-only
Sources/Stacks/Library.swift — module: Stacks
imports: Foundation

public final class Library — 74 members  :3-669
    public private(set) var loans: [Loan] = []  :4
    private var shelf = Shelf()  :5
    private let limit: Int  :6
    …
    public func lend(title: String, to borrower: String, days: Int) -> Loan?  :16-27
    public func count(for borrower: String) -> Int  :38-40
    …
```

The model then reads only the lines it needs. This is a stop, and never a trap:

- **The identical retry always goes through.** The same call is refused once and allowed the second time,
  so nothing is ever unavailable and the worst case is one extra round trip.
- **A hundred distinct refusals in a stretch open a quiet spell**, after which the advice returns.
- **Many reads pass untouched:** a ranged read, a file small enough that a digest would be no smaller than
  the source, a file the context has already had digested, counts, listings, and text being written (a
  commit message, a heredoc).

A small file is answered in place with its source, and the answer says so: "a digest would cost 50% of the
code inside it, so the source itself follows". That is a smaller reply to one call. It is not a claim about
what a session costs.

A raw build or test is pointed at `sift run`, which prints only what failed:

> sift serves this command's failures instead of its whole log:

```text
    sift run -- swift test
    → just the failures and the tool's own summary, with the full output kept under .sift/runs/
```

> If you want the raw output anyway — a progress line, a path the filter drops, a command this has no filter for — re-run this exact command and it will be allowed. That re-run returns the command's whole output. This asks once per command.

Where no permission prompt can follow (an `auto` or `bypassPermissions` session, or allow rules that already
cover `sift run -- …`), the hook rewrites the command in place instead of refusing it.

### After an edit

The `PostToolUse` hook runs after every `Write`, `Edit` or `MultiEdit` of a `.swift` file. If the edit left
the file unparseable, it blocks, so the next turn fixes the file instead of a later build finding it. Delete the
`)` that ends the parameters of `init` in the sample's `Book.swift`, and the reply is:

```text
sift: syntax errors after this edit:
Sources/Stacks/Book.swift:8:58 expected ')' to end parameter clause
The edit left Sources/Stacks/Book.swift unparseable; fix it before going on. …
```

This checks syntax only; a type error still needs a build. The same content is blocked once per session.
When the edit added a function shaped like one that already exists, the hook names the existing one in a
single line. A clean edit with no resemblance prints nothing.

The `Stop` and `SubagentStop` hooks send a context back once to build before it stops, when it edited Swift
since its last green `sift run` build.

### Seeing what the hooks did

Run `sift report` for the index's share of the Swift lookups, the estimated savings and the failures, and `sift audit` for the lookups that went around the index.

### Turn the advice off

Set `SIFT_NO_ADVICE=1` in the environment of the session. The refusals and the reuse nudge stop, with no
change to `settings.json`. Fed the `swift test` call above with it set, the hook prints nothing and exits 0.

To take the hooks out, `sift uninstall-hook` removes them (and a legacy sift status line), and `sift uninstall` removes
all of sift. `sift uninstall-hook --only-advice` removes just the `PreToolUse` hook. See <doc:Installing>.

### Cursor and Codex (experimental)

Both are experimental until their live tests are finished, and neither has the status
line, `sift audit` or the subagent primer.

- **Cursor** gets the session primer and the refusals through `~/.cursor/hooks.json`; a refusal's text
  reaches the model in Cursor's `user_message` field. Hooks Cursor imports from Claude Code's settings
  print nothing, because Cursor shows a refusal to you rather than the model.
- **Codex** gets `SessionStart`, `PreToolUse` and `PostToolUse` in `hooks.json`. It runs a hook only once you
  trust it: approve the prompt on first open, or review the hooks in `/hooks`. An `apply_patch` gets the
  post-edit check for each `.swift` file it adds or updates.

## Next steps

The guide has the full account in
[teach the agent to actually use it](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#4-teach-the-agent-to-actually-use-it),
including [what the hook deliberately stays quiet about](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#what-it-deliberately-stays-quiet-about),
and [seeing what sift did](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#seeing-what-sift-did).
When a hook misbehaves, see <doc:Troubleshooting>.
