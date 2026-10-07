# Running Builds and Tests

Wrap `swift build`, `swift test` and `xcodebuild` in `sift run --` and read what comes back.

## Overview

Put `sift run --` in front of the command you were going to run anyway:

```sh
sift run -- swift test
sift run -- swift build --build-tests
sift run -- xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The command runs unchanged and its exit code is passed through, with the exceptions below. What changes is
the output: the verdict, the counts and what failed, instead of the whole log. These examples run in the
small package from <doc:GettingStarted>, a module called `Stacks` with three tests.

### A passing run

```text
$ sift run -- swift test
✔ swift test
totals: ✔ passed · Swift Testing 3 tests in 1 suite
inventory: 3 declared, 3 reported
raw: .sift/runs/run-20261005-093443Z-8eb81821.log (18 lines in, 4 out)
```

- The first line is the verdict.
- `totals:` is the sum of the test tool's own tally lines, across Swift Testing and XCTest. A skipped test is
  counted as skipped, so a run whose tests all skipped does not read as tests that ran.
- `inventory:` appears on an unfiltered `swift test`. It sets the tests the index declares against the ones
  the run reported, so a test that silently never ran shows up as a difference. Without an index it says it
  was not checked.
- `raw:` is the complete output, written as it arrived, with the number of lines it stands for and the
  number shown. Nothing is lost: one file per run under `.sift/runs/`, and the five most recent are kept.

### A failing run

A failure keeps what you can act on: errors with file and line, test failures with their messages, and
warnings deduplicated, and drops the rest. To reproduce this one in the sample package, change `== 1` to
`== 2` on the `overdue` line of `LibraryTests.swift`.

```text
$ sift run -- swift test
✘ swift test — exit 1
  overdueCountsLongLoans() — Tests/StacksTests/LibraryTests.swift:32 (body :28-33)
    Expectation failed: library.overdue(after: 14).count == 2 → false library.overdue(after: 14).count → 1
totals: ✘ failed · Swift Testing 3 tests in 1 suite, 1 failure
inventory: 3 declared, 3 reported
raw: .sift/runs/run-20261005-093446Z-6fb07068.log (26 lines in, 6 out)
```

The heading names the file and line and, where the failure is inside the test's own body, that body's range.
If the command exits nonzero and the filter finds no error and no test failure to show, you get the whole raw
transcript instead of a summary of nothing.

### Run some of the tests

Name tests the way `swift test` does, with `sift run -- swift test --filter`:

```text
$ sift run -- swift test --filter overdueCountsLongLoans
✔ swift test
totals: ✔ passed · Swift Testing 1 test in 1 suite
raw: .sift/runs/run-20261005-093444Z-7fb802bf.log (11 lines in, 3 out)
```

A filtered run does not print `inventory:`, since it was asked to run fewer tests than are declared. For
`xcodebuild test` the equivalent is `-only-testing:`.

The one place sift overrides the exit code is a run that names its tests and executes none of them, such
as a filter that matches nothing. `swift test` itself exits 0 there, which reads as success. Sift answers
`✘ swift test — nothing ran`, says which filter matched no test, and exits 4. Exit 5 means such a run did
not build. Both are sift's own.

### Ask whether a tree already passed

A green run is remembered against the content of the tree. `--proved` answers from that record without
running anything:

```text
$ sift run --proved -- swift test
tree-content: 8cf5dd2c9cd2  command: swift test
✔ proved — swift test passed 2s ago on this exact tree content, under this toolchain
  run run-20261005-093443Z-8eb81821.log in ~/code/Shelf, which took 1s — that much not spent again
  not covered: anything git does not track — the build directory, this tool's own state, the environment, the machine; the record is refused past 60m for exactly that reason
```

It exits 0 when this exact tree passed, 1 when no run is on record, and 2 when the question cannot be put.
A red run of the same command on the same content afterwards revokes the record. The proof does not cover
anything git does not track, and it expires after an hour.

### More

`sift run` has more than this: `--coverage` lists which changed lines the tests ran, `--without` proves a
test fails without your change in a single call, `sift test --shards` splits a slow simulator suite, and
`sift affected` names the tests a diff could have broken. Anything other than `swift build`, `swift test`
and `xcodebuild` runs untouched, with one note on stderr saying so.

## Next steps

The guide's section on
[compressing build output](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#12-compressing-build-output--sift-run)
documents every option, and
[proving a test fails without your change](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#proving-a-test-fails-without-your-change----without)
covers `--without`. For the query tools that run beside it, see <doc:TheFourTools>.
