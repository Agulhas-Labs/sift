# Validation projects

Real, generic sample iOS projects that sift's test-running features (`sift test --shards`, run
reconciliation) are validated against. Not a SwiftPM target: `swift test` never touches it.

## TestDemo

`TestDemo/` is an XcodeGen-generated iOS app (`TestDemo.xcodeproj`, not committed — generate it
with `xcodegen generate` before opening or building) with:

- `DemoApp` — a trivial three-screen SwiftUI app (an items list, a detail pushed from it, a second
  tab), with accessibility identifiers the UI tests use.
- `DemoUnitTests` — XCTest and Swift Testing in one bundle: two XCTest classes, two `@Suite`s, a
  parameterised `@Test`, a `.disabled` test, an `XCTSkip`, and a test passing inside `withKnownIssue`.
- `DemoLogicTests` — a second unit bundle, Swift Testing only.
- `Demo Spaced Tests` — a third unit bundle, XCTest only, one class `SpacedTests` with two trivial
  passing tests. **Its name is the point**: spaces are illegal in a Swift identifier, so its module
  name is not its target name (spellings measured below).
- `DemoUITests` — 12 XCUITests across 3 classes, with deliberately uneven `Thread.sleep` costs
  (1 to 20 seconds) so duration-based binning is visible.

### Generating and running

```
cd ValidationProjects/TestDemo
xcodegen generate
sift run -- xcodebuild test -project TestDemo.xcodeproj -scheme TestDemo -testPlan Default \
  -destination 'platform=iOS Simulator,id=<udid>'
```

Reuse an existing stock simulator; this project never creates or deletes one.
`gates.sh <simulator-udid>` runs the same checks end to end.

### Signal gates

`sh ValidationProjects/TestDemo/signal-gates.sh` (from the repository root, after `swift build`) runs
real three-shard runs and signals them (SIGTERM, SIGINT, SIGHUP, SIGKILL, at several points) and passes
only when the exit code is `128 + signal` and no `sift-` simulator, ledger or watcher is left. About 15
minutes. It starts `sift test` directly as its own background job; read its header before changing how.

### Trigger files

`xcodebuild` does not forward the shell's environment to the test process, so triggers are sentinel
files under `.triggers/` (everything but `.gitkeep` is gitignored), read through
`Triggers.isSet(_:)` (`Shared/Triggers.swift`). Absent files mean everything is green.

| File | Effect |
| --- | --- |
| `crash-unit` | `CalculatorTests.testMultiplyCrashesWhenTriggered()` calls `fatalError("boom")`. |
| `crash-ui` | `AboutTabUITests.testCounterIncrementsOnTap()` calls `fatalError("boom")` in the test runner. |
| `fail-once` | `CalculatorTests.testFailsOnce()` fails its first attempt and passes after, recording the attempt in `.triggers/fail-once.seen`. `gates.sh` deletes `.seen` before each run it makes. |
| `fail-always` | `DemoLogicTests.alwaysFailsWhenTriggered()` fails every run. |
| `hang` | `ItemListUITests.testScrollsToLastItem()` spins forever (`while true { Thread.sleep(forTimeInterval: 60) }`). Never run this to completion — end the `xcodebuild` you started by its pid. |

### Test plans

Three plans live in `TestPlans/`, all attached to the one scheme `TestDemo`, with `Default` as
the scheme's default:

- **Default** — all four test targets, everything enabled, no retries, `codeCoverage: false`.
- **Excluding** — the same targets, with `skippedTests` naming one XCTest method
  (`CalculatorTests/testAddition()`) and one Swift Testing function
  (`MathSuite/addsTwoNumbers()`) out of `DemoUnitTests`. What each did is under *Measured behaviour*
  below.
- **Retrying** — the same targets, `testRepetitionMode: retryOnFailure`,
  `maximumTestRepetitions: 3`.

### Measured behaviour (Xcode 27.0, iOS 27.0 simulator, 17 Sep 2026)

From raw `xcodebuild` logs. Re-take them when Xcode changes.

- **One build, one `.xctestrun` per plan** (`TestDemo_Default_iphonesimulator27.0-arm64.xctestrun`,
  …) in `Build/Products/`. `test-without-building -xctestrun <file>` runs from one, and
  `-enumerate-tests` works on it too (7 s, no tests run).
- **Enumeration** (`-enumerate-tests -test-enumeration-style flat -test-enumeration-format json`):
  38 `enabledTests`, `disabledTests` empty. Every framework is spelled `Target/Type/function()` —
  `DemoUnitTests/CalculatorTests/testAddition()`, `DemoUnitTests/MathSuite/addsTwoNumbers()`. The
  parameterised test is one entry, `DemoUnitTests/MathSuite/doublingIsEven(_:)`. The `.disabled`
  test is listed as *enabled*: it is a runtime skip, not an exclusion.
- **One Swift Testing function is selectable**:
  `-only-testing:DemoLogicTests/DemoLogicTests/evenNumbersAreEven()` → `Test run with 1 test in 1
  suite passed`; mixed with an XCTest method, each framework ran exactly its one.
  XCTest still prints `Executed 0 tests, with 0 failures` for a bundle it had nothing in.
- **Excluding plan**: the XCTest entry took (`Executed 8 tests` against Default's 9). The Swift
  Testing entry was **ignored**: the test ran and the tally stayed `7 tests in 2 suites`.
- **Retrying + `fail-once`**: XCTest retries **the one failing test** (Iteration 1 of 3 failed,
  Iteration 2 passed) and counts attempts, not tests: `Executed 10 tests, with 1 test skipped and 1 failure` over 9 methods. The run
  ends `** TEST EXECUTE SUCCEEDED **`, exit 0. (A Swift Testing test that records a known issue was
  started three times and printed one ending; a *failing* one is unmeasured.)
- **`crash-unit`**: `CalculatorTests.swift:28: Fatal error: boom`, then `Restarting after unexpected
  exit, crash, or test timeout; …`. The closing tally is the relaunch's alone — `Executed 5 tests, with
  1 test skipped and 0 failures` — without the two that passed before the crash, and reads green. Only
  `Failing tests: CalculatorTests.testMultiplyCrashesWhenTriggered()`, `** TEST EXECUTE FAILED **` and
  exit 65 say otherwise.
- **`crash-ui`**: the same shape from the UI runner, exit 65.
- **`fail-always`**: exit 65, `✘ Test run with 8 tests in 1 suite failed … with 1 issue`, and above it
  XCTest's green `Executed 0 tests` for the same bundle.
- **A failing run stalls for ten minutes collecting diagnostics** (`Timed out after 600.0 seconds`,
  610 s of wall clock over 0.2 s of tests). With `-collect-test-diagnostics never` it took 7 s.
- **A target whose name is not a Swift identifier logs under a different name than it enumerates
  under.** `Demo Spaced Tests` was measured three ways on one build:
  - The **enumeration** keeps the spaces, target name unchanged:
    `Demo Spaced Tests/SpacedTests/testCountsUp()`.
  - The **log** spells the class with the module name, each space an underscore:
    `Test Case '-[Demo_Spaced_Tests.SpacedTests testCountsUp]' started.` The enclosing suite lines keep
    the bundle's real name, so both spellings appear in one transcript.
  - **`-only-testing:` wants the enumeration's spelling, spaces and all**:
    `'-only-testing:Demo Spaced Tests/SpacedTests/testCountsUp()'` ran that one test, exit 0. The
    module-name spelling `'-only-testing:Demo_Spaced_Tests/…'` is **not** silently empty like a misspelt
    method: `xcodebuild: error: … Tests in the target “Demo_Spaced_Tests” can’t be run because
    “Demo_Spaced_Tests” isn’t a member of the specified test plan or scheme.`, exit 70. A wrong *target*
    fails loudly; only a wrong *test* is silent.
- A Swift Testing line may start with U+200B, and a run that passes with a known issue closes on `━`,
  not `✔`.
- A misspelt `-only-testing:` identifier selects nothing, silently:
  `-only-testing:DemoUITests/ItemListUITests/testListAppears()` (no such test) ran zero tests and ended
  `** TEST EXECUTE SUCCEEDED **`, exit 0 — which is what reconciliation's *missing* exists to catch. The
  parenthesised spelling enumeration prints works for XCTest and for a parameterised test
  (`…/MathSuite/doublingIsEven(_:)`, run with its 3 cases).

Not yet run: `hang`, and `gates.sh` end to end.

## SchemeDemo

`SchemeDemo/` is **not a buildable project**: it is two hand-written shared schemes and the container
directory Xcode reads them from, committed so `sift test --analyse` has a real `.xcscheme` to read in
this repository. `TestDemo`'s own schemes cannot serve: they live inside `TestDemo.xcodeproj`, which
XcodeGen generates and nothing commits.

- `GizmoApp.xcscheme` — the legacy shape: a `TestAction` with a `<Testables>` block and no test plan,
  running `GizmoTests` and skipping `LegacyTests`, alongside a `LaunchAction` whose
  `BuildableReference` names the app target and must not be read as a testable.
- `Planned.xcscheme` — the other shape: a `TestAction` naming two of TestDemo's committed plans through
  `TestPlanReference` (`container:../TestDemo/TestPlans/…`, resolved against the directory holding this
  scheme's container), with a `<Testables>` block those plans supersede.

## Repo hygiene

`TestDemo.xcodeproj`, `.derived/` (the `-derivedDataPath` build scratch) and `.gates-logs/` are
gitignored; only `project.yml`, the Swift sources, the test plans and `gates.sh` are committed.
