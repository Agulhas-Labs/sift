# Troubleshooting

What to check when an answer looks wrong, a hook fails, or the index store is missing.

## Overview

Start with `sift status`: it reports the index's health and which build's index store it found. The samples
here come from the sample package of <doc:GettingStarted> (`Distribution/docs-fixture.sh`), a module called
`Stacks`, and its checkout is shown as `~/code/Shelf`. Paths under your home directory are shortened to `~`.

### An answer says it is stale

The header of an answer says how far to trust it. After you edit a file the compiler has not built yet,
`where` refuses the semantic part and tells you what to run. To see it in the sample package, build it with
`sift run -- swift build --build-tests`, append a comment line to `Sources/Stacks/Library.swift`, and ask:

```text
tree: Shelf  head: ec26cde  dirty: 1  parse_errors: 0  semantic: stale (1 file changed since last build)
where Library.count
mode: syntactic + semantic (index store via .build)

declarations (1):
  Stacks.Library.count(for:) — func — public func count(for borrower: String) -> Int — Sources/Stacks/Library.swift:38-40

semantic REFUSED — changed since the last build; rebuild with `sift run -- swift build`, then retry

syntactic call sites — by written name over the working tree, never stale — see sift help answers (call sites)

"count" (1 call site in 1 file):
  Sources/Stacks/Library.swift:
    :20  in Library.lend(title:to:days:)  | guard count(for: borrower) < limit else {
```

That is the contract working, not a bug. Build again with `sift run -- swift build` and ask again. The
declarations and the call sites by written name stay correct meanwhile, because an answer reparses the files
you edited before it replies.

### Reset the index

The index is a cache under `.sift/` in the repository, and it rebuilds on the next query:

```text
$ sift reset
removed .sift/ — the next query rebuilds it; kept ~/code/Shelf/.git/sift/proved-runs.json: the proved-run ledger every worktree of this repository shares, which dies with the repository (deleting it costs the next proof a run, never an answer)
```

`reset` also deletes the logs `sift run` keeps under `.sift/runs/`, and those are not rebuilt. If the index
only seems to have drifted from the working tree, `sift reconcile` repairs the difference and deletes
nothing. After an upgrade, an index written by an earlier version is dropped and rebuilt once, on its
repository's next query; `sift index` does it up front.

### There is no index store

A repository that has not been built has no index store, and `where` says so in the header and the mode line:

```text
tree: Shelf  head: ec26cde  clean  semantic: none (no index store — see note)
where Library.lend
mode: syntactic (sift help answers); no index store for this tree yet; how to build one: sift help answers, section (index store)
callers/overrides: NOT ANSWERED from the index store; see the mode line above.
```

Without a store, `where` promises declarations, and call sites matched by their written name. It does not
promise callers, overrides or store-recorded conformers, and an empty list there is not "unused". `digest`
needs no store and is unaffected. To get one, build the package so the compiler writes its index:

```sh
sift run -- swift build --build-tests
```

For an Xcode project use `sift run -- xcodebuild -scheme <Scheme> build`; an iOS project also needs a
destination. A package nested below the repository root, or a custom derived data path, needs
`indexStorePath` in `.sift.json`. `sift status` then reports which store it found, or names one it read and
rejected.

### Check the install with `sift doctor`

`sift doctor` proves that each agent sift is installed into really runs it. It reads the registration the
install wrote, runs the registered binary, feeds every hook a canned payload, and starts the MCP server.
Unless you name an agent, it checks the ones found on this machine, and it exits 1 when any check fails:

```text
$ sift doctor --agent claude
doctor: passed — 0 of 11 checks failed
claude hooks: pass — registered for SessionStart, SubagentStart, PreToolUse, PostToolUse, Stop, SubagentStop
claude server: pass — sift — ~/.local/bin/sift mcp
…
claude hook SessionStart: pass — exit 0, silent
…
claude mcp server: pass — started; lists digest, where, search, strings
```

### A hook exits 127

Exit 127 is the shell's "command not found": the hook names a `sift` that is not there. The hooks run the
binary the install was started as, so this follows a binary that moved, was removed, or lived in npx's cache
and was evicted, or a bare `sift` that is not on the `PATH`. `sift doctor` names it, here after the binary
was deleted:

```text
doctor: failed — 8 of 10 checks failed
claude hooks: pass — registered for SessionStart, SubagentStart, PreToolUse, PostToolUse, Stop, SubagentStop
claude server: pass — sift — ~/.local/bin/sift mcp
…
claude mcp server: fail — answered nothing (exit 127) — ~/.local/bin/sift mcp
```

Put `sift` back where the registration says, or run `sift install` again from the binary you want the hooks
to use; it is idempotent and it is the upgrade path. If `sift` is not on your `PATH`, fix that first so the
install records a path that exists. Keep the binary in a fixed place on your `PATH` (see <doc:GettingStarted>; Homebrew and npm put it
there), and not run it from `npx`, which the install refuses.

### Other entries

- **It dies at once with no output (exit 137).** A new binary was copied over an installed one in place. `rm`
  the old one first, then `cp`.
- **The MCP server does not appear in Claude Code.** Start a new session first, then check `claude mcp list`.
  When registering by hand, the scope option must come before the `--`.
- **`where` says the store is "still warming".** A large store takes minutes to read the first time, and the
  query answers with declarations meanwhile. It is not the staleness refusal. Ask again shortly.
- **The first index is slow, or `git status` is.** Narrow `roots` in `.sift.json`. sift runs git with the
  repository's `fsmonitor` hook switched off, so turning it on speeds up your own `git status` and not sift's.
- **A refusal you do not want.** Re-run the identical command, which always goes through, or set
  `SIFT_NO_ADVICE=1`. See <doc:HowTheHooksBehave>.

## Next steps

The guide covers [`sift doctor`](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#sift-doctor),
[getting a repository indexing](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#5-getting-it-indexing)
and [semantic answers](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#7-semantic-answers-need-a-real-build).
The install troubleshooting is in
[INSTALL.md](https://github.com/Agulhas-Labs/sift/blob/main/Distribution/INSTALL.md#troubleshooting).
