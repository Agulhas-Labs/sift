# Paired benchmark: the same tasks with and without sift

Status: runner and analysis built. Results: `RESULTS.md` (sift's own repository, 60 runs),
`RESULTS-ios-app.md` and `RESULTS-ios-app-10.md` (a private 148k-line iOS app, 3 and 10 repeats), and
`RESULTS-run-compression.md` (`sift run` output against the raw log, no model), `RESULTS-live.md` (the hook
live, with a compiler index) and `RESULTS-single-call.md` (single-call answers).

## What it measures

Ten fixed Swift-code tasks (`tasks.json`), each run by Claude Code in two arms:

- **Arm A, without sift**: no sift hooks, MCP server, rule or binary on `PATH`.
- **Arm B, with sift**: sift installed as a user installs it (hooks, MCP server, the `Sift.md` rule).

Three repeats per arm per task on this corpus (60 runs), one model (`claude-sonnet-5-5`). Every run records, from Claude
Code's `stream-json` result:

- input tokens, raw: uncached input, cache writes (split 5-minute and 1-hour), cache reads, summed over
  every model the run used (`modelUsage`);
- session price, the headline: input-token equivalents for one fresh session with no cache carried in from other
  runs. It prices the context series once at the 5-minute write price, re-reads at the read price on later turns,
  and counts output at five times input; a prompt cache that carries over between repeats cannot flatter an arm;
- input tokens, weighted at list-price multiples of the base input price: uncached 1, 5-minute write 1.25,
  1-hour write 2, read 0.1;
- output tokens, turns, wall time, and `total_cost_usd`, which is a list-price equivalent
  (`costBasis: list`), not money billed;
- task success, decided mechanically (below), never by a model.

Reported per task and in total: the paired difference B minus A, median and range over the repeats, and
success counts per arm.

## The corpus

sift's own repository at commit `27d3aca3`, written out with `git archive` into a fresh one-commit
repository for every run, so no history hints at an injected bug. It is about 93k lines of Swift in three
modules, private, so the model cannot answer from memory.

A public corpus was the first choice and was dropped: the repository's example-name gate
(`ExampleNamesTests`) fails on any camel-cased name that this tree does not declare, and its permit list
forbids names from somebody else's codebase. Task files over sift's own code pass because the tree
declares every name they use. The cost is a coupling: **renaming a symbol a task names fails sift's own
suite on `tasks.json`**, and the task must then be re-pinned. A check whose expected answer states a line
number lists it in `pinned_lines` (`file`, `line`, `contains`), and `validate` fails when the corpus's line no
longer holds that text; `validate` names every task missing its controls at once.

## Tasks and success checks

| Kind | Tasks | Check |
| --- | --- | --- |
| find definition | 1 | the `ANSWER:` line holds the path and start line |
| find references / callers | 2 | the `ANSWER:` line's file names equal the expected set exactly (an `ignore` list is neither required nor penalised) |
| understand a type / behaviour | 2 | exact set of names |
| trace UI string | 2 | file and function on the `ANSWER:` line |
| locate and fix | 2 | a one-line bug is injected (exact find/replace, asserted to match once); success is the named test filter passing afterwards with `Tests/` unchanged |
| run tests and report | 1 | a one-line bug is injected; success is the exact set of failing test functions, with no file changed |

Only the last line starting `ANSWER:` is read (Markdown emphasis and backticks stripped). Each test-based
check needs two controls before it counts: green on the clean corpus, red on the injected one. Those
controls, and the expected failing set of the report task (3 of the 6 `ShellWordTests`), were measured on 1 Oct 2026 and are recorded in `tasks.json`; the "locate and fix" check for the allow rule is the one test `aTrailingWildcardAlsoMatchesTheBareCommand`, because the broader `RunAllowRules` suites stay green under that injection.

## Isolation

Measured on Claude Code 2.1.286, 1 Oct 2026:

- A scratch `CLAUDE_CONFIG_DIR`, or a scratch `HOME`, logs Claude Code out (`Not logged in`): the login
  credential is not found. Both arms therefore use the real configuration directory, with everything in it
  switched off:
  - `--setting-sources project,local`: no user settings, hooks, permissions or plugins;
  - `--strict-mcp-config --mcp-config <arm file>`: arm A's names no server, arm B's names sift;
  - `--settings` carrying `claudeMdExcludes` for `~/.claude/**` and for every `CLAUDE.md`,
    `CLAUDE.local.md`, `.claude/CLAUDE.md`, `.claude/rules/**` and `AGENTS.md` in the run directory's
    ancestors (`~/Library/Caches/sift-bench-run/<checkout>`, `~/Library/Caches`, `~/Library`, `~` and up)
    and in the corpus itself (its own agent instructions describe sift). A probe with these found none of
    the ancestors' `CLAUDE.md` files loaded;
  - `--disable-slash-commands`, `--no-session-persistence`, `--tools Bash,Read,Edit,Write,Grep,Glob`
    (no subagents, so all usage is the run's own), a pinned `--effort`, and `--permission-mode
    bypassPermissions` in both arms: sift's build rewrite reads the mode, and under `dontAsk` it would
    refuse a build once in arm B for a reason the harness made.
- Every run's corpus is at `~/Library/Caches/sift-bench-run/<checkout>/corpus`, where `<checkout>` is the
  first 8 hex digits of the SHA-1 of the checkout's absolute path: one fixed path per checkout, so two
  checkouts can run at once and an index store built at the run path is used from it. The template every
  run is cloned from sits beside it (the rename that makes it and the clone that copies it need one
  volume); the wrapper, scratch home, index store and logs stay in the checkout's `.build/bench`. The
  corpus must not sit under a `.build`, `DerivedData`, `checkouts` or `/tmp` directory: sift's hook treats
  every path under one as build output and lets every Grep and Read of it through. Until 2026-10-01 it sat
  at `.build/bench/run/corpus`, so arm B ran with its hook inert in every run recorded before then.
- **The hook is checked live before any model call.** Once per session (and in `bench.py validate`), arm B
  is installed in a clone at the run path and its hook, through the wrapper and scratch home, judges one
  whole-file `Read` of the corpus's largest tracked Swift file (`sift replay-hook`). Unless the verdict is
  an answer in place the session halts with exit 3, printing the verdict and rule; otherwise `session.json`
  records `hook_live: true`, the rule (`hook_live_rule`), and the Read's and the answer's characters.
- `run.sh` deletes `.build/bench`, the checkout's cache directory and Claude Code's per-project state for
  the run path when it exits, however it exits (a signal is forwarded to the runner, which stops what it
  started first), and refuses to start while either directory exists.
- `PATH` in both arms has every directory holding a `sift` binary removed; arm B puts a wrapper first. The
  wrapper sets `CFFIXED_USER_HOME` to a scratch home, so sift's logs, ledgers and roots registry never
  touch the user's `~/.sift`; the hooks and the server read no Claude path from it at run time.
- Arm B installs at project scope inside the corpus: `sift install-hook --settings
  <corpus>/.claude/settings.json --command "<wrapper> session-start"`, and `Sift.md` at
  `<corpus>/.claude/rules/sift.md`. `--command` repoints only the primer, so the runner repoints every
  other hook at the wrapper and refuses to run unless every command is the wrapper's.
- A run is **invalid** (reported, not counted as a failure) unless: in arm A, the init message lists no MCP
  server and no tool naming sift, no hook event fires, and no Bash command invokes `sift`; in arm B, the
  sift server is `connected`, its tools are listed and a `SessionStart` hook event fires.
- Arm order alternates by task and repeat, so neither arm always runs first.

## A second corpus (v2)

The runner takes `--tasks <file>` and `--corpus <repository>@<commit>`, so a larger private corpus runs
through the same harness. A tasks file over a private codebase names its symbols, so it lives outside this
repository, is passed by path, and uses generic task ids: the table shows only the ids. Keys a tasks file
may add: `corpus.paths` (the subset to archive), `corpus.warm` (the warm build command, or null for none),
`corpus.add_files` (extra files, such as a build log, copied in from beside the tasks file), `preamble`
(text put before every prompt), and the checks `answer_parts` (` | `-separated answers, scored per part),
`answer_set` with `"match": "path"`, and `restored` (a fix checked without a build: the injection is
reverted, or one of the listed alternatives holds, and no other file changed). `tasks.example.json` shows
every key with placeholder names. Each run's corpus ignores, through `.git/info/exclude`, what arm B's
install and index or an attempted build leave (`.claude/`, `.sift/`, `.build/` and the like), so a "no other
file changed" check cannot fail in arm B alone; `validate` plants that debris in every control.

Each task block now starts with an unscored warm-up per arm (`--max-turns 1`, skipped with `--no-warmup`).
Every run records its first-call and peak context (B minus A of the first is sift's fixed start), and
`session.json` records the sift binary's sha256 and mtime, the rule file used, chars/4 estimates of the tool
list, primer and rule, and one cold `sift index` time. `bench.py validate --tasks <file>` checks every
task's check against its controls with no model call.

**An indexed corpus.** Without an index store, arm B's `where` answers callers by written name only
(`mode: syntactic`). `corpus.index_build` (a command, run once per session in the corpus at the fixed run
path, since a store records absolute paths) builds one: the command puts Xcode's derived data at the path in
`BENCH_DERIVED_DATA`, which lies beside the corpus, not in it. The harness keeps only the store directory
(`.build/bench/index-store`, about 70 MB for a 148k-line app), deletes the rest of the derived data, and writes
the corpus afresh from the archive, so whatever the build generated in the tree is gone and both arms see the
plain archive; its files carry the commit's time, older than every unit, so the store reads as fresh. No run
copies the store: arm B's install adds a `.sift.json` naming it, which `.git/info/exclude` hides from the "no
other file changed" checks, and arm A's tree has neither the store nor the setting, nor any build product for a
`grep -r` to wade through. sift never writes to the store (its database goes in the run's own `.sift/`), so
every arm B run starts cold from the same store. For an iOS app the command needs a generic destination,
`xcodebuild … -destination 'generic/platform=iOS Simulator' ARCHS=arm64 build-for-testing`, so no simulator
is created or booted, and `build-for-testing` on each scheme whose tests should be indexed (an app and a local
package are two schemes): a plain `build` leaves the tests out of every caller list. `session.json` records `corpus_indexed`, `index_store_bytes` and `index_build_seconds`;
`validate` skips the build.

## Threats to validity

- **One model.** Results hold for `claude-sonnet-5-5` on one Claude Code version; another model may use
  the tools differently.
- **Task selection.** The tasks were chosen by sift's author, on sift's own code, and most are lookups,
  where sift is designed to help. The corpus documents sift, which arm A can read.
- **Repeat variance.** Three repeats give a median and a range, not a confidence interval; a difference
  smaller than the range is not evidence.
- **Cold index.** Arm B indexes the corpus on its first query, and that time is in its wall time.
- **Not a user's session.** Single-prompt `-p` runs with no prior context; a long interactive session
  amortises the fixed cost of sift's primer and tool list differently.

## Running it

```sh
sh Benchmarks/run.sh --repeats 3                 # every task in tasks.json, both arms
sh Benchmarks/run.sh --task <id> --repeats 1     # one task
sh Benchmarks/run.sh --tasks <file> --corpus <repository>@<commit> --repeats 10
sh Benchmarks/analyse.sh [session]               # the paired table, also written as table.md
python3 Benchmarks/bench.py validate --tasks <file>
python3 Benchmarks/run-compression.py report --out <out>   # see RESULTS-run-compression.md
git show ec096ea3:Sift.md > .build/rule-ec096ea3.md
sh Benchmarks/run.sh --rule-a .build/rule-ec096ea3.md --rule-b Sift.md --repeats 3   # rule vs rule
sh Benchmarks/run.sh --mod-b Distribution/mod --repeats 3   # mod vs no mod
```

`--mod-b <dir>` turns the session into **mod vs no mod**: both arms run with sift under one rule (`--rule-b`'s),
arm B adds `claude --plugin-dir <dir>`, and arm A runs without it and with `SIFT_MOD=off`. Both arms get
`SIFT_HOME` in the run's scratch home, so a `mod-off` file in the user's `~/.sift` cannot switch arm B off. Arm B
is valid only if the stream's init event lists the plugin by its `plugin.json` name, arm A only if it does not.
`session.json` records `mod_dir`, `mod_name`, `mod_commit` and `mod_files_sha256` (the files Claude Code writes on
load, `tsconfig.json` and `.claude-plugin/types/`, left out), the table's header names them, and a voluntary-use
table counts sift calls against Swift Reads and greps per arm. `--mod-b` with `--rule-a` is refused.
A run inherits none of the calling shell's variables, so a mod switch reaches arm B only through `--mod-env
NAME=VALUE` (repeatable; refused without `--mod-b`), such as `--mod-env SIFT_MOD_BASH=on`.
`session.json` records it under `sift_mod_env.B_extra`, and the table's header names it.

`--rule-b <file>` is the rule arm B installs (default: the `Sift.md` shipped with `--sift`). `--rule-a <file>`
turns the session into **rule vs rule**: arm A is installed exactly like arm B (hooks, MCP server, wrapper,
index store) but with that rule, and is held to arm B's validity checks. `session.json` then records
`rule_a_file`/`rule_a_sha256` and `rule_b_file`/`rule_b_sha256`, the table's header names both, and B minus A
is rule B's effect against rule A's. Keep the rule file outside `.build/bench/`, which a run deletes.
