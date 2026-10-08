//
// Copyright © Agulhas Labs
//

import Foundation

/// Counts a build or test run while its output arrives, so a live view can say where the run has got to before it ends.
///
/// Fed the same chunks ``RunOutputFilter`` is, cut into lines and cleaned by the same ``RunOutputLines``, and reading tests through the same ``RunTestOutcomes`` line readers, so what it counts as a test, a suite or an ending cannot drift from what the finished report counts. It keeps one partial line, one ending per test name and one identity per diagnostic, and does no I/O: the caller passes the time each chunk arrived, which is the only clock it reads.
///
/// **It reads the console only.** An ending `swift test` relays solely through its Swift Testing event stream, read after the process exits (``RunEventStreamFold``), is never seen here, so where the console lost lines the live count is short of the final one. `xcodebuild`'s parallel `Test case '…' passed on '…'` lines and SwiftPM's `--parallel` `[k/N] Testing …` lines move the run into testing and name the test, but count nothing, as the finished report does not count them either.
public struct RunLiveTally: Sendable {
    /// Where the run has got to as of the last line read.
    public private(set) var state: RunLiveState
    private var lineBuffer = RunOutputLines()
    /// The iteration the last start line named for each test, taken by its ending the way ``RunTestOutcomes`` takes it.
    private var startedIterations: [String: Int] = [:]
    /// How each counted test last ended, so a repeat moves its test between counts instead of adding one.
    private var endings: [String: RunTestOutcomes.Ending] = [:]
    /// Every test a start line read from its own head has named, which a glued ending or issue must name to be split off (``RunGluedTestLine``).
    private var startedNames: Set<String> = []
    private var seenErrors: Set<RunDiagnostic.Identity> = []
    private var seenWarnings: Set<RunDiagnostic.Identity> = []

    /// A tally for a run that started at `startedAt`.
    public init(startedAt: Date) {
        state = RunLiveState(startedAt: startedAt)
    }

    /// Feeds a chunk of the run's raw output that arrived at `now`; a partial line it ends on is held for the next chunk.
    public mutating func consume(_ data: Data, now: Date) {
        for line in lineBuffer.split(data, keeping: RunLiveLineScreen.mayMatter) {
            consume(line: line, now: now)
        }
    }

    /// Feeds one complete line, without its newline, that arrived at `now`.
    public mutating func consume(line raw: String, now: Date) {
        let line = RunOutputLines.cleaned(raw)
        if let (notice, rest) = RunOutputFilter.splitLockNotice(line) {
            consume(line: notice, now: now)
            consume(line: rest, now: now)
            return
        }
        if let (output, rest) = RunGluedTestLine.split(line, started: startedNames.contains) {
            read(output, now: now)
            read(rest, now: now)
            return
        }
        if let name = RunGluedTestLine.startedTest(in: line) {
            startedNames.insert(name)
        }
        read(line, now: now)
    }

    /// Reads the line the output ended on without a newline, and splits the time from the start to `now` between building and testing: all of it is building where no test line ever arrived.
    public mutating func finish(now: Date) -> RunLiveState.Durations {
        if let trailing = lineBuffer.remainder() {
            consume(line: trailing, now: now)
        }
        return state.durations(until: now)
    }
}

extension RunLiveTally {
    private mutating func read(_ line: String, now: Date) {
        if let (name, event) = RunTestOutcomes.xctestEvent(in: line) ?? RunTestOutcomes.swiftTestingEvent(in: line) {
            enterTesting(at: now)
            record(event, of: name)
            return
        }
        if let name = Self.parallelTestName(in: line) {
            enterTesting(at: now)
            state.current = name
            return
        }
        if Self.opensTesting(line) {
            enterTesting(at: now)
            return
        }
        if state.phase == .building, let step = RunBuildStep.named(in: line) {
            state.current = step
            return
        }
        if state.phase == .building, !state.buildStarted, RunBuildStep.isBareCounter(line) {
            state.buildStarted = true
            return
        }
        count(RunDiagnostic.parse(line))
    }

    private mutating func enterTesting(at now: Date) {
        guard state.phase == .building else {
            return
        }
        state.phase = .testing
        state.testingStartedAt = now
        state.current = nil
    }

    /// Counts a test's ending once per test: an ending under the first iteration is a test finishing, and one under a later iteration is the same test finishing again, which replaces how it ended rather than adding to the count.
    private mutating func record(_ event: RunTestOutcomes.Event, of name: String) {
        let ending: RunTestOutcomes.Ending
        switch event {
        case let .started(iteration):
            startedIterations[name] = iteration
            state.current = name
            return
        case .passed: ending = .passed
        case .failed: ending = .failed
        case .skipped: ending = .skipped
        }
        let iteration = startedIterations.removeValue(forKey: name) ?? 1
        if iteration > 1, let earlier = endings[name] {
            adjust(earlier, by: -1)
        }
        endings[name] = ending
        adjust(ending, by: 1)
    }

    private mutating func adjust(_ ending: RunTestOutcomes.Ending, by delta: Int) {
        switch ending {
        case .passed: state.tests.passed += delta
        case .failed: state.tests.failed += delta
        case .skipped: state.tests.skipped += delta
        }
    }

    private mutating func count(_ diagnostic: RunDiagnostic?) {
        guard let diagnostic, !diagnostic.isXCTestAssertion else {
            return
        }
        switch diagnostic.severity {
        case .error:
            if seenErrors.insert(diagnostic.identity).inserted {
                state.errors += 1
            }
        case .warning:
            if seenWarnings.insert(diagnostic.identity).inserted {
                state.warnings += 1
            }
        }
    }

    /// Whether `line` is a test process, run or suite announcing itself, which no build prints: `Test Suite 'All tests' started at …`, `Test run started.`, `xcodebuild`'s `Test suite '…' started on '…'` and its closing `Testing started`.
    private static func opensTesting(_ line: String) -> Bool {
        if line.hasPrefix("Test Suite '"), line.contains("' started at ") {
            return true
        }
        if line.hasPrefix("Test suite '"), line.contains("' started on '") {
            return true
        }
        return RunOutputFilter.undecorated(line) == "Test run started." || RunLineScan.trimmingWhitespace(line[...]) == "Testing started"
    }

    /// The test a parallel runner reports on, which prints no `started` line: SwiftPM's `[3/12] Testing Suite/testName` and `xcodebuild`'s `Test case 'Suite.testName()' passed on 'My Mac - xctest (…)' (0.001 seconds)`.
    private static func parallelTestName(in line: String) -> String? {
        if line.hasPrefix("Test case '"), line.contains(" on '") {
            let rest = line.dropFirst("Test case '".count)
            return rest.range(of: "' ").map { String(rest[..<$0.lowerBound]) }
        }
        return RunLineScan.parallelTestName(in: line)
    }
}
