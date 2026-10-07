# sift run: compression, recall and precision (2026-10-01)

Question: how much does `sift run -- <toolchain command>` shrink build and test output against the raw output
an agent would otherwise read, and does its answer keep every failure (recall) without naming one that is not
there (precision)? Measured, deterministic, no model calls. Base: `main` @ fa8a9622; the installed `sift` (0.1.0) was deployed after that commit.

## Method

- **Same run, both sides.** Each case runs `sift run -- <command>` once. "sift" is its whole stdout, including
  the `raw: …` tail line. "raw" is the complete log sift filed under `.sift/runs/` for that same run, which is
  what `<command> 2>&1` prints. Nothing is run twice, so incremental-build state cannot differ between the sides.
- **Corpus A, this repository:** a clone of fa8a9622 in a scratch cache directory. Each case appends injected
  code to source files or writes one new test file, runs, and restores every file byte for byte, checked by hash.
  `git status` in the clone was clean afterwards. The edits are in `Benchmarks/run-compression.py` (`CASES`).
- **Corpus B, a private iOS app ("the app"):** a real 4,353-line xcodebuild log of the app, with one compile
  error spliced in. sift has no stdin or log mode. Its filter is chosen by the executable's name
  (`RunCommandKind.recognize`), so the log is replayed through a shim executable named `xcodebuild` that cats it
  and exits 65. A green derivative is the same log with the spliced lines and the failure trailer removed
  (exit 0). No simulator was created and nothing in the app was built or run.
- **Tokens** are estimated as bytes / 4. No offline tokenizer is installed, so token reduction equals byte
  reduction throughout.
- **Truth** is parsed from the raw log, ANSI colour stripped. It covers compiler `error:` lines (`warning:` lines
  for the warnings-only build), the driver's `error: path:line:col msg` form, XCTest `error: -[…]` lines,
  Swift Testing `✘ Test … recorded an issue` lines (one per parameterised argument),
  `Undefined symbols` entries, `Fatal error:` lines, `exited with unexpected signal`, and, when a process crashed,
  the test that started and never finished.
- **Recall (full)** means the answer names the location (`File.swift:line`), the test and argument where there
  is one, and the first 40 characters of the message. **Located** means place without message.
- **Precision** means every `File.swift:line` and every `name(` in the answer occurs in the raw log.
- **Baselines** are the same raw log through `tail -50` and `grep error:`, scored the same way. A
  build-output summariser was not installed, so it is not compared.
- Reproduce: `python3 Benchmarks/run-compression.py capture --clone <clone> --out <out>`, then
  `replay --log <xcodebuild.log> --cwd <dir> --out <out>`, then `report --out <out>`.
  Two cases are not in `CASES`: `build-clean` (the clone's first `sift run -- swift build`, with packages resolved from the local cache) and `test-full-green` (one unfiltered `sift run -- swift test` of the pristine clone, 3.5 min). Both were captured by hand as answer plus `.sift/runs/` log, so a re-run of the script yields the other 18.

## Results

| case | family | exit | raw lines / bytes / ~tok | sift lines / bytes / ~tok | byte reduction | sift recall (full+located/n) | invented | tail -50 bytes, recall | grep error: bytes, recall |
|---|---|---|---|---|---|---|---|---|---|
| build-clean | build-green | 0 | 125 / 4476 / 1119 | 3 / 119 / 29 | 97% | - | none | 1408, - | 0, - |
| build-noop | build-green | 0 | 7 / 172 / 43 | 3 / 116 / 29 | 33% | - | none | 172, - | 0, - |
| build-warnings-5 | build-warnings | 0 | 62 / 4442 / 1110 | 10 / 899 / 224 | 80% | 5+0/5 | none | 4156, 5+0/5 | 0, 0+0/5 |
| build-errors-1 | build-errors | 1 | 15 / 10189 / 2547 | 5 / 275 / 68 | 97% | 1+0/1 | none | 10189, 1+0/1 | 583, 1+0/1 |
| build-errors-1-missing-return | build-errors | 1 | 17 / 10329 / 2582 | 5 / 292 / 73 | 97% | 1+0/1 | none | 10329, 1+0/1 | 670, 1+0/1 |
| build-errors-3 | build-errors | 1 | 17 / 51790 / 12947 | 5 / 295 / 73 | 99% | 1+0/1 | none | 51790, 1+0/1 | 515, 1+0/1 |
| build-errors-12 | build-errors | 1 | 135 / 21660 / 5415 | 20 / 2024 / 506 | 91% | 12+0/12 | none | 13044, 4+0/12 | 5050, 12+0/12 |
| build-errors-12-spread | build-errors | 1 | 7 / 7865 / 1966 | 5 / 245 / 61 | 97% | 1+0/1 | none | 7865, 1+0/1 | 354, 1+0/1 |
| build-warnings-as-errors-5 | build-errors | 1 | 19 / 10637 / 2659 | 5 / 365 / 91 | 97% | 1+0/1 | none | 10637, 1+0/1 | 928, 1+0/1 |
| build-linker | build-errors | 1 | 19 / 3513 / 878 | 9 / 557 / 139 | 84% | 1+0/1 | none | 3513, 1+0/1 | 444, 0+1/1 |
| test-narrow-green | test-green | 0 | 76 / 9742 / 2435 | 3 / 141 / 35 | 99% | - | none | 7839, - | 0, - |
| test-full-green | test-green | 0 | 14134 / 1234198 / 308549 | 6 / 407 / 101 | 100% | - | none | 3894, - | 5020, - |
| test-fail-1 | test-failures | 1 | 50 / 2334 / 583 | 5 / 317 / 79 | 86% | 1+0/1 | none | 2334, 1+0/1 | 0, 0+0/1 |
| test-fail-5 | test-failures | 1 | 54 / 3383 / 845 | 14 / 980 / 245 | 71% | 5+0/5 | none | 3264, 5+0/5 | 556, 3+0/5 |
| test-fail-20 | test-failures | 1 | 132 / 8913 / 2228 | 52 / 3784 / 946 | 58% | 24+0/24 | none | 3149, 11+0/24 | 1898, 10+0/24 |
| test-timeout | test-failures | 1 | 22 / 902 / 225 | 5 / 281 / 70 | 69% | 1+0/1 | none | 902, 1+0/1 | 0, 0+0/1 |
| test-crash-swift-testing | test-crash | 1 | 42 / 2853 / 713 | 8 / 1082 / 270 | 62% | **2+0/4** | none | 2853, 4+0/4 | 797, 2+0/4 |
| test-crash-xctest | test-crash | 1 | 38 / 2424 / 606 | 8 / 825 / 206 | 66% | **3+0/4** (2 in substance) | none | 2424, 4+0/4 | 687, 4+0/4 |
| xcodebuild-app-green | xcodebuild-green | 0 | 4345 / 672665 / 168166 | 3 / 112 / 28 | 100% | - | none | 5057, - | 0, - |
| xcodebuild-app-error-1 | xcodebuild-errors | 65 | 4353 / 673553 / 168388 | 5 / 341 / 85 | 100% | 1+0/1 | none | 5047, 0+0/1 | 217, 1+0/1 |

| family | cases | median byte (= ~token) reduction | range |
|---|---|---|---|
| build, green (clean, no-op) | 2 | 65% | 33% to 97% |
| build, warnings only | 1 | 80% | |
| build, errors (compile, linker) | 7 | 97% | 84% to 99% |
| test, green (narrow, full suite) | 2 | 99% | 99% to 100% |
| test, failures (1, 5, 20, timeout) | 4 | 70% | 58% to 86% |
| test, crash (process trap) | 2 | 64% | 62% to 66% |
| xcodebuild (replayed real log), green and 1 error | 2 | ~99.97% | 99.95% to 99.98% |
| **all 20 cases** | 20 | **94%** | 33% to 100% |

**Recall:** 59 of the 63 failures in the raw logs are named in full (the scorer counts 60, but one is the XCTest crash's `testTraps1`, matched only inside an echoed command line). Outside the two crash cases it is 55 of 55
(100%), counting every parameterised argument, both issues of a two-issue test, the timeout, the linker
symbol and the xcodebuild error. **Precision:** no case names a location or test that the raw log lacks. The
test-fail-20 answer's count ("24 failures") matches the raw log's 7 XCTest and 17 Swift Testing issues.
**No answer is larger than its raw log**, in bytes or in lines: a no-op build was 116 B against 172 B raw, and
green runs print 50 to 120 B more than the toolchain's own summary line (below).

### Where sift loses

1. **A test process that traps.** (Fixed since by #447, which names the crashed test and its `Fatal error:` line; not re-measured here.) The `Fatal error:` line is dropped: for Swift Testing, `BenchInjectedTests.swift:8:
   Fatal error: Unexpectedly found nil while unwrapping an Optional value`; for XCTest,
   `Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range`. So is the test that was running
   (`traps1()`; `testTraps1`). The XCTest answer contains `testTraps1` only inside the echoed
   `xctest -XCTest a,b,c` command line, which lists every selected test, so it is not named as the one that
   crashed. Both answers then lead with another bundle's passing summary ("Executed 1 test, with 0 failures";
   "Test run with 1 test in 1 suite passed"). `tail -50` keeps everything here, at 2.4 to 2.9 KB.
   Repro: in any SwiftPM package add
   `@Test func traps() { let value: Int? = nil; _ = value! }` (or the XCTest
   `func testTraps() { let values: [Int] = []; _ = values[1] }`), then run `sift run -- swift test --filter traps`.
2. **A tiny raw log.** The no-op build is 172 bytes raw and 116 through sift. The 3-line answer still costs about
   4x the raw log's own summary line (`Build complete!`, 28 bytes), mostly the `raw:` pointer line.
3. **Failing swift build answers carry a false sentence:** "no closing summary line in the log — the errors
   below are what it reported", although every raw log ends `error: Build failed` (the SwiftBuild backend's
   closing line). This costs about 80 bytes per answer; it is not a recall loss. Repro: inject
   `func f() { undefinedName() }` into any package source file, then run `sift run -- swift build`.

### The green runs: what sift prints when everything passes

| green case | sift bytes | raw's own summary lines, bytes | those lines |
|---|---|---|---|
| build-clean | 119 | 29 | Build complete! |
| build-noop | 116 | 28 | Build complete! |
| test-narrow-green | 141 | 93 | Build complete! / ✔ Test run with 8 tests in 1 suite passed after N seconds. |
| test-full-green | 407 | 286 | Build complete! / two `━ Test run with N tests … passed` lines (one per bundle) / Executed 0 tests |
| xcodebuild-app-green | 112 | 22 | ** BUILD SUCCEEDED ** |

sift prints more than the toolchain's own summary line, never less. The extra 50 to 120 bytes are the `✔ <tool>`
headline, the `raw:` pointer, and, on the full suite, the `inventory: 5182 declared, 5182 reported` check.
An agent that already knows to read only that line saves about 100 bytes by skipping sift. One that reads the
raw log, or `tail -50` (3.9 KB on the full suite), does not.

### Notes on the corpus

- `swift build` (the SwiftBuild backend) stops at the first failing compile job, so the injected count is not
  the reported count:

  | case | injected | the raw log reported |
  |---|---|---|
  | build-errors-3 | 3 | 1, from the emit-module job alone |
  | build-errors-12-spread (across 6 files) | 12 | 1, an `#error` that the driver stops on |
  | build-warnings-as-errors-5 | 5 | 1 |
  | build-errors-12 (one file) | 12 | 12 |

  Recall is scored against what the raw log reports, which is everything an agent could have seen.
- The package sets `.treatAllWarnings(as: .error)` in its manifest, and `-Xswiftc -no-warnings-as-errors` does
  not override it. The warnings-only case therefore takes that line out of the manifest for its one run.
- The 20-failure case has 20 failing test functions and 24 issues: one test with two issues, and one
  parameterised test with four failing arguments.
- The timeout case uses Swift Testing's `.timeLimit(.minutes(1))` on a sleeping test, and ran 77 s.
- Not reproduced: a compiler crash. There is no reliable crasher on this toolchain. sift's crash reader has its
  own fixture tests (`RunCompilerCrashTests`).
- The `grep error:` baseline finds no Swift Testing failures at all, since its lines carry no `error:`. It also
  finds no warnings. `tail -50` loses 8 of 12 compile errors in build-errors-12 and 13 of 24 test failures
  in test-fail-20. Where it does keep everything, it costs 2 to 10 KB, and 51.8 KB on build-errors-3, whose
  frontend command line is a single 50 KB line.
