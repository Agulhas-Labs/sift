# The progress contract

What `sift run` promises about the live progress file it keeps while a wrapped build or test runs, for a
pane, a script or an editor plug-in that wants to show the run moving. The design and its reasons are
in [Design.md](Design.md) §3, under *Live progress*; this is the part a consumer codes against.

## 1. Where, and when it changes

- **Path:** one file per run, `<repo>/.sift/progress/run-<runId>.json`, where `<repo>` is the top level of
  the git work tree `sift run` was started in. A linked worktree is its own work tree, with its own
  `.sift/`. The directory sits in the repository's cache directory, beside the run logs in `.sift/runs/`,
  and is already ignored by git. Runs in parallel in one checkout each write their own file.
- **Whole or not at all:** each write is a temporary file in the same directory, a dot-file ending `.tmp`
  that never matches `run-*.json`, renamed over the old one. A reader that lists `run-*.json` and opens one
  gets one complete snapshot; it never needs to retry on a parse error caused by a write in progress.
- **Cadence:** at most one write per 500 ms for changed counts; the start, every phase change and the
  finish write at once. While a run is live and nothing changes, the snapshot is still rewritten at least
  every 2 s, so `updatedAt` is a heartbeat.
- **Lifecycle:** `phase` goes `idle` → `building` → `testing` → `done` | `failed`, skipping any it never
  reaches. `idle` is a run that has started but shown no build or test line yet; a command that neither builds
  nor tests (a linter) stays `idle` until it ends. A run moves from building to testing once: a compile after
  the first test line is not tracked as building again. `done` means sift's own verdict passed and it exits 0;
  `failed` is any nonzero exit of sift's, a cancel or an abandoned run. **`exitCode` is the code `sift run`
  itself exits with**, which is the wrapped command's except where sift answers with its own: 4 for a selected
  run that executed no test (the command exited 0), 5 for one that did not build (it exited 1). A terminal phase
  is final: `exitCode` and `summary` are set with it, and the run never writes the file again. `logPath` of an
  ended run names a file that exists: the log where the answer's `raw:` line names it. The file keeps its
  live phase (`building` or `testing`) through answer rendering, the coverage section, the second tree hash and
  the ledger write, and ends only after them, so `summary.testMs`, `buildMs` and `totalMs` include that time.
- **Switched off:** `SIFT_PROGRESS=off` in `sift run`'s environment writes no file, and neither does a run
  started outside any git work tree. A file that cannot be written is skipped silently; the run's own output,
  exit code and log are the same with or without it.
- **Kept, then pruned:** an ended run's file stays on disk, so its summary can be read after the process
  has gone. A run pruning as it begins keeps the newest five files by name (`runId` sorts by start time)
  and never removes one whose `pid` is alive and whose `updatedAt` is under 10 s old.

## 2. The schema

Every key is always present: a value not known yet is `null`, never a missing key, so a consumer can tell
"unknown" from "this version does not have it". `schemaVersion` changes when a key is added, removed or
changes meaning; a consumer refuses a version it does not know. A key that starts carrying values where it
was always `null` before, as `tests.planned` does, keeps its version: a consumer already handles both. `tree` was added to version 1
before the public release, when no released reader existed; it is the only such addition, and a reader of a
version-1 file without it treats it as `null`. From the public release on, adding a key bumps `schemaVersion`.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "sift run progress",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "command", "current", "destination", "errors", "exitCode", "logPath", "phase", "phaseStartedAt", "pid",
    "repoRoot", "runId", "scheme", "schemaVersion", "startedAt", "summary", "tests", "tree", "updatedAt", "warnings"
  ],
  "properties": {
    "schemaVersion": { "const": 1 },
    "runId": {
      "type": "string",
      "description": "Unique per run and sortable by start: UTC to the millisecond, a dash, 8 hex digits."
    },
    "pid": { "type": "integer", "minimum": 1, "description": "The sift run process." },
    "repoRoot": { "type": "string", "description": "Absolute, symlinks resolved." },
    "phase": { "enum": ["idle", "building", "testing", "done", "failed"] },
    "startedAt": { "type": "string", "format": "date-time", "description": "UTC, milliseconds." },
    "phaseStartedAt": {
      "type": "string",
      "format": "date-time",
      "description": "When the current phase began; for a terminal phase, when the run ended."
    },
    "updatedAt": { "type": "string", "format": "date-time", "description": "UTC, milliseconds." },
    "command": {
      "type": "string",
      "maxLength": 200,
      "description": "The wrapped command on one line; longer is cut to 199 characters and an ellipsis."
    },
    "scheme": { "type": ["string", "null"] },
    "destination": { "type": ["string", "null"] },
    "current": {
      "type": ["string", "null"],
      "description": "The target being compiled or the test now running."
    },
    "tests": {
      "type": "object",
      "additionalProperties": false,
      "required": ["failed", "passed", "planned", "skipped"],
      "properties": {
        "planned": {
          "type": ["integer", "null"],
          "minimum": 0,
          "description": "How many tests the run will report an ending for, skipped ones included; null whenever sift is unsure. Set at most once while the run is live; a terminal snapshot may set it back to null, never to another number."
        },
        "passed": { "type": "integer", "minimum": 0 },
        "failed": { "type": "integer", "minimum": 0 },
        "skipped": { "type": "integer", "minimum": 0 }
      }
    },
    "errors": { "type": "integer", "minimum": 0, "description": "Compiler errors so far." },
    "warnings": { "type": "integer", "minimum": 0 },
    "summary": {
      "type": ["object", "null"],
      "description": "Null until the run ends.",
      "additionalProperties": false,
      "required": ["buildMs", "testMs", "totalMs"],
      "properties": {
        "buildMs": { "type": ["integer", "null"], "minimum": 0, "description": "Null if it never built." },
        "testMs": { "type": ["integer", "null"], "minimum": 0, "description": "Null if it never tested." },
        "totalMs": { "type": "integer", "minimum": 0 }
      }
    },
    "logPath": {
      "type": ["string", "null"],
      "description": "Absolute: the .log.part file while running; once over, the .log file the answer names, which exists. Null if none."
    },
    "exitCode": { "type": ["integer", "null"], "description": "sift run's own exit code; null until the run ends." },
    "tree": {
      "type": ["string", "null"],
      "description": "The tree object naming the content of the work tree the run started on (the key `sift run --proved` and the Stop gate record a green run under). Null for a command that neither builds nor tests, for a plain build with the ledger off, for a run that builds another repository than the one the file sits in, and where the key could not be taken."
    }
  }
}
```

## 3. An example

A run part-way through its tests:

```json
{
  "command": "swift test --parallel",
  "current": "GadgetTests/innerTest()",
  "destination": null,
  "errors": 0,
  "exitCode": null,
  "logPath": "/Users/me/src/app/.sift/runs/run-20261002-101530Z-0a1b2c3d.log.part",
  "phase": "testing",
  "phaseStartedAt": "2026-10-02T10:16:41.507Z",
  "pid": 48213,
  "repoRoot": "/Users/me/src/app",
  "runId": "20261002T101530120Z-0a1b2c3d",
  "schemaVersion": 1,
  "scheme": null,
  "startedAt": "2026-10-02T10:15:30.120Z",
  "summary": null,
  "tests": { "failed": 1, "passed": 212, "planned": null, "skipped": 0 },
  "tree": "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
  "updatedAt": "2026-10-02T10:17:02.884Z",
  "warnings": 3
}
```

## 4. For consumers

- **Find runs by command.** A Bash command starting `sift run` is a wrapped run; the PreToolUse hook
  rewrites a bare `swift test` or `xcodebuild` into that form, so nearly every build or test an agent
  starts arrives as one. There are no MCP build or test tools, by design: `run` is CLI only.
- **List, read, don't lock.** Poll `.sift/progress/` for `run-*.json` (a few times a second is plenty),
  parse each, and pick by `repoRoot`, `pid` liveness and `updatedAt`. A missing directory means no run has
  written one there yet; a file that vanishes between the listing and the read was pruned.
- **Treat a quiet live phase as stale.** A `SIGKILL` cannot clear the file. A snapshot whose `phase` is
  live (`idle`, `building` or `testing`) and whose `updatedAt` is more than 5 s old belongs to a run that
  died; showing it as running would be wrong. Checking that `pid` is still alive is a further, optional test.
- **Match a run to a tree with `tree`.** Where you are judging a work tree's content, a live run whose `tree`
  equals that tree's key is a run of it; one with another `tree` started on content that has since changed, and
  one with a null `tree` says nothing either way. The Stop gate reads it so: it lets a stop through while a run
  of the tree as it stands is live, and does not advise a second build beside a live run of an earlier tree.
- **Match the run you started.** If you know the run you are waiting for, compare `runId` or `pid`; a
  second run in the same checkout writes a file of its own beside it.
- **SwiftPM test counts may arrive at once.** With its output piped, as it is under `sift run`, `swift test`
  on current toolchains writes its test lines in one burst at the end, so for a SwiftPM test run `tests` may
  not move until the run is nearly over. `xcodebuild`, and a run whose output is a terminal, stream them.
- **`tests.planned` is null whenever sift is unsure.** A wrong denominator is worse than none, so a number
  appears only where the run's selection is known exactly before its tests start: today an unfiltered, serial
  `swift test` of the package at the repository's root whose sift index declares every test with no
  condition and nothing outside the run's scope, and an `xcodebuild test-without-building -xctestrun …` on a Mac whose `.xctestrun` has one test configuration. A filtered or skipped run, a list-mode run, a
  simulator or device, a test plan with more than one configuration and a repeated run stay null. The
  number counts what the live counts count: one per test function or `XCTestCase` method (a parameterised
  test is one, however many cases it runs), a disabled or skipped test included, since it ends as skipped;
  a test the run never starts (`-skip-testing`, a test plan's own exclusions) is not in it. It may arrive a
  few seconds into the run, and once set it does not change while the run is live.
- **A terminal snapshot carries the run's final counts, which can differ from the last live one.** At the
  end, `passed`, `failed` and `skipped` are replaced by the run's own record where sift has one: the
  `.xcresult` for an `xcodebuild` run (an expected failure counted as passed), the console and Swift Testing
  event stream together for `swift test`. A count can move either way, since a live line can be lost or
  garbled on the way. `planned` is never filled at the end, so `planned` above
  `passed + failed + skipped` in a terminal snapshot means tests that never reported; where the run
  reported more than `planned` or a test outside its plan, the plan was wrong and the terminal snapshot
  carries `null` instead. `planned` never becomes non-null mid-run.
- **Compose your own verdict line.** The file carries counts and timings, not prose; the one-line
  summary a display wants is the consumer's to word.
