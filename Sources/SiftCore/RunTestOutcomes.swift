//
// Copyright © Agulhas Labs
//

import Foundation

/// Every test a run reported on, and how each one ended — read from the lines each framework prints as a test starts and finishes.
///
/// The filter's failure listing names what failed and nothing else, which is all a red run needs. `run --without` needs the other half too: "fails without the change and passes with it" is a claim about both runs of every named test, and the test that passed is exactly the one a failure listing never mentions.
///
/// **A name is the framework's own spelling, kept whole** — `shoutingWorks()` from Swift Testing, `-[WidgetTests.LegacyWidgetTests testNaming]` from XCTest — because that is the spelling the failure listing uses for the same test, and two answers about one test should not call it two things. Swift Testing prints no suite beside a function's name, so two suites that each declare a function of one name print one name twice; the count of finishing lines is kept per name so that case can be *said* rather than quietly folded into one test.
///
/// **Reading is anchored on the first word of the line**, once the status decoration in front of it is gone, and never searched for: a failure's message or a `↳` comment can quote a finishing line, and a quoted `passed after` read as a real one is a pass invented for a test that failed.
public struct RunTestOutcomes: Sendable, Equatable {
    /// What was printed, per name.
    public private(set) var tallies: [String: Tally] = [:]
    /// The last finishing line printed for each name — a test's outcome when a command retries it, since the retry is the attempt that counts.
    public private(set) var lastEndings: [String: Ending] = [:]
    /// Every attempt at each test, in the order the run finished them, with what each one cost.
    ///
    /// The tally counts and `lastEndings` answers "how did this test end"; neither can say *what the first attempt cost*, which is the only attempt a timing may be taken from — a retry is measured against a machine that has already loaded the bundle and already failed once.
    public private(set) var attempts: [String: [Attempt]] = [:]
    /// The iteration the last start line named for each name, held until that name's next finishing line takes it.
    ///
    /// A finishing line never names its own iteration in either framework, so the number has to be carried from the start line that opened the attempt — per name, because both frameworks interleave the starts of tests running beside each other. Taken rather than read, so a second ending with no start of its own is the first attempt it says it is rather than the retry before it.
    private var startedIterations: [String: Int] = [:]
    /// A started test's line `xcodebuild` spliced other output into after its name, held for exactly one line, whose whole ending's words are the test's ending (``RunSplicedTestEnding``).
    private var splicedHead: RunSplicedTestEnding.Held?
    /// Lines in the shape `xcodebuild` prints a test in when it runs them in parallel — `Test case '…' passed on 'Clone 1 of …'` — which are not read as outcomes; counted so a run that reported nothing else can say why, rather than blame the filter.
    public private(set) var parallelLines = 0
    /// Lines in the shape `xcodebuild` prints a suite in when its parallel testing starts one on a runner — `Test suite 'Legacy' started on 'My Mac - xctest (4242)'` — counted because such a line with no `Test case '…' on` line under it is a runner that started and ran nothing.
    public private(set) var parallelSuiteStarts = 0
    /// Every Swift Testing run the output carried, in the order they started.
    ///
    /// `swift test` runs Swift Testing once per test target, one run after another, and each prints its own start line, its suites' endings and its summary. Only the run a test started in can account for it: a suite's pass line names its innermost type alone, so another target's suite of that name says nothing about this one, and a run that crashed prints no summary at all.
    public private(set) var swiftTestingRuns: [SwiftTestingRun] = []
    /// Every name a Swift Testing line reported on, so a reader holding a better record of those tests can set the console's word on them aside.
    public private(set) var swiftTestingNames: Set<String> = []
    /// Every test the run reported skipped, in the order the skips were printed, each named once: `Suite.test` for XCTest, the bare function for Swift Testing, with the reason the log gave where it gave one.
    public private(set) var skips: [Skip] = []
    /// The reason XCTest printed for a skip, held under the test's name until the `skipped` ending that follows it takes it.
    private var xctestSkipReasons: [String: String] = [:]
    /// The wrapped command's exit code where the reader knows it, and `nil` for a log read after the fact.
    ///
    /// A command that exited non-zero failed somewhere, so no summary it printed vouches for a test whose result line is missing.
    public var commandExitCode: Int32?

    public init() {}

    public init(tallies: [String: Tally], lastEndings: [String: Ending] = [:]) {
        self.tallies = tallies
        self.lastEndings = lastEndings
    }
}

public extension RunTestOutcomes {
    /// One skipped test as the answer names it.
    struct Skip: Sendable, Equatable {
        /// `Suite.test` for XCTest, the function as Swift Testing prints it for Swift Testing.
        public let name: String
        /// Why the test skipped, or `nil` where the log gave none.
        public let reason: String?

        public init(name: String, reason: String? = nil) {
            self.name = name
            self.reason = reason
        }
    }

    /// How many times each event was printed for one name.
    struct Tally: Sendable, Equatable {
        public var started = 0
        public var passed = 0
        public var failed = 0
        public var skipped = 0

        public init(started: Int = 0, passed: Int = 0, failed: Int = 0, skipped: Int = 0) {
            self.started = started
            self.passed = passed
            self.failed = failed
            self.skipped = skipped
        }
    }

    /// How one attempt at a test ended.
    enum Ending: Sendable, Equatable {
        case passed
        case failed
        case skipped
    }

    /// One finished attempt at a test: how it ended, what the line said it cost, and which iteration of the command's repeats it belonged to.
    ///
    /// `seconds` is `nil` where the framework printed no duration — a Swift Testing skip names a reason and no time — rather than zero, which is a duration a test can genuinely have.
    struct Attempt: Sendable, Equatable {
        public var ending: Ending
        public var seconds: Double?
        /// Which run through the tests this attempt belonged to, counting from 1 — `1` when the line named none, which is every line of a command that was not asked to repeat.
        public var iteration: Int
        /// Why the test was skipped, where the event stream said so; the console's own skip lines are read for theirs apart from this.
        public var skipReason: String?

        public init(ending: Ending, seconds: Double? = nil, iteration: Int = 1, skipReason: String? = nil) {
            self.ending = ending
            self.seconds = seconds
            self.iteration = iteration
            self.skipReason = skipReason
        }
    }

    /// One Swift Testing run's stretch of the output, from its `Test run started.` line to its summary.
    struct SwiftTestingRun: Sendable, Equatable {
        /// How the run's summary ended, or `nil` where it printed none, which is a run that never finished.
        public fileprivate(set) var ending: Ending?
        /// Every suite that printed an ending in this run, under the name it printed, with the worst ending printed under that name.
        public fileprivate(set) var suiteEndings: [String: Ending] = [:]
        /// How many start lines each name printed in this run that no finishing line in it followed.
        public fileprivate(set) var unfinishedStarts: [String: Int] = [:]
        /// How many tests the run's summary says it ran, or `nil` where it printed no summary this reader can count.
        public fileprivate(set) var summaryTests: Int?
        /// Every name that printed a first-iteration start line in this run.
        public fileprivate(set) var firstIterationStarts: Set<String> = []
        /// Every name that printed a line in this run that is neither a start nor an ending this reader knows, which may be an ending in a wording it cannot read.
        public fileprivate(set) var unreadLines: Set<String> = []

        /// Whether this run's summary passed and so did the suite printed as `suite`, which together account for a test of that suite whose result line is missing.
        ///
        /// A suite ends only once every test in it has finished, and passes only where none of them failed, so its pass line hides no failure. A run that started more tests than its summary counts is not one run: another run's start line was lost and a run that crashed before its summary ran on into this one, so this summary cannot speak for what it holds.
        public func vouches(forSuite suite: String) -> Bool {
            guard let summaryTests, firstIterationStarts.count <= summaryTests else {
                return false
            }
            return ending == .passed && suiteEndings[suite] == .passed
        }

        /// How many start lines `name` printed in this run that no ending followed, and none where it also printed a line this reader cannot read, since that line may have been its ending.
        public func unfinished(_ name: String) -> Int {
            unreadLines.contains(name) ? 0 : unfinishedStarts[name, default: 0]
        }
    }
}

public extension RunTestOutcomes {
    /// Whether the run printed a start or an end for any test at all — `false` for a run that never reached its tests.
    var isEmpty: Bool {
        tallies.isEmpty
    }

    /// Every name the run reported on, sorted so an answer built from them is deterministic.
    var names: [String] {
        tallies.keys.sorted()
    }

    subscript(name: String) -> Tally? {
        tallies[name]
    }

    /// These outcomes with everything a Swift Testing line reported taken out, its runs included, which leaves what XCTest printed.
    var leavingOutSwiftTesting: RunTestOutcomes {
        var kept = self
        for name in swiftTestingNames {
            kept.tallies[name] = nil
            kept.lastEndings[name] = nil
            kept.attempts[name] = nil
            kept.startedIterations[name] = nil
            kept.skips.removeAll { $0.name == name }
        }
        kept.swiftTestingNames = []
        kept.swiftTestingRuns = []
        return kept
    }

    /// How many times the command ran its tests: the highest iteration any line named, and 1 where none named one.
    ///
    /// A start line that never got its finishing line counts too — a run whose third iteration crashed still ran three, and a caller asking this is deciding whether the run's timings are trustworthy, which a crash settles as firmly as a retry does.
    var iterations: Int {
        let finished = attempts.values.joined().map(\.iteration).max() ?? 1
        return max(1, finished, startedIterations.values.max() ?? 1)
    }

    /// Reads one line of a run's output, already stripped of its newline, its carriage return and XCTest's output barrier.
    ///
    /// Anything that is not a test's own start or end line is passed over, which is nearly everything.
    mutating func read(_ line: String) {
        if let held = splicedHead {
            splicedHead = nil
            if let ending = RunSplicedTestEnding.completed(held.head, by: line) {
                if let name = held.endedTest {
                    retractLastEnding(of: name)
                }
                read(ending)
                return
            }
        }
        if let (name, reason) = Self.xctestSkipReason(in: line) {
            xctestSkipReasons[name] = reason
        }
        let xctest = Self.xctestEvent(in: line)
        guard let (name, event) = xctest ?? Self.swiftTestingEvent(in: line) else {
            if line.hasPrefix("Test case '"), line.contains(" on '") {
                parallelLines += 1
            } else if line.hasPrefix("Test suite '"), line.contains("' started on '") {
                parallelSuiteStarts += 1
            } else if let name = Self.unreadSwiftTestingName(in: line) {
                readUnread(line, of: name)
            } else {
                readSwiftTestingClosing(line)
            }
            return
        }
        if xctest == nil {
            readSwiftTestingEvent(event, of: name)
            swiftTestingNames.insert(name)
        }
        var tally = tallies[name] ?? Tally()
        switch event {
        case let .started(iteration):
            tally.started += 1
            startedIterations[name] = iteration
        case let .passed(seconds):
            tally.passed += 1
            finish(.passed, seconds: seconds, of: name)
        case let .failed(seconds):
            tally.failed += 1
            finish(.failed, seconds: seconds, of: name)
        case let .skipped(seconds):
            tally.skipped += 1
            finish(.skipped, seconds: seconds, of: name)
            if xctest != nil {
                recordSkip(Self.xctestDisplayName(name), reason: xctestSkipReasons.removeValue(forKey: name))
            } else {
                recordSkip(name, reason: Self.swiftTestingSkipReason(in: line))
            }
        }
        tallies[name] = tally
    }

    /// Records an ending of the Swift Testing test printed as `name` that the run's event stream carried and its console never relayed, closing the start line the console did relay for it where there is one.
    mutating func recordStreamed(_ attempt: Attempt, of name: String) {
        var tally = tallies[name] ?? Tally()
        switch attempt.ending {
        case .passed: tally.passed += 1
        case .failed: tally.failed += 1
        case .skipped:
            tally.skipped += 1
            recordSkip(name, reason: attempt.skipReason)
        }
        tallies[name] = tally
        swiftTestingNames.insert(name)
        lastEndings[name] = attempt.ending
        attempts[name, default: []].append(attempt)
        startedIterations.removeValue(forKey: name)
        if let run = swiftTestingRuns.lastIndex(where: { $0.unfinishedStarts[name, default: 0] > 0 }) {
            swiftTestingRuns[run].unfinishedStarts[name, default: 0] -= 1
        }
    }

    /// Reads a line naming the Swift Testing test `name` that is neither its start nor an ending this reader knows: the framework's own words, which may be an ending worded in a way this reader has never seen, or a started test's line with other output spliced in after its name, whose ending is read where it is whole.
    ///
    /// Spliced output is no ending, so it leaves the test's start unfinished rather than unread, and the test lost where its suite and run vouch for it; an ending is taken only for a test whose start is still waiting for one.
    private mutating func readUnread(_ line: String, of name: String) {
        guard case let .spliced(head, ending)? = RunSplicedTestEnding.reading(of: line) else {
            swiftTestingRuns[openRun()].unreadLines.insert(name)
            return
        }
        guard startedIterations[name] != nil else {
            return
        }
        if let ending {
            read(ending)
        }
        splicedHead = RunSplicedTestEnding.Held(head: head, endedTest: ending == nil ? nil : name)
    }

    /// Takes back the ending last read for `name` from a spliced line's closing words, which the next line, the framework's own ending, showed were the spliced output's: the test's start waits again for the ending read next, and the run's count of unfinished starts is restored for that read to settle.
    private mutating func retractLastEnding(of name: String) {
        guard var tried = attempts[name], let attempt = tried.popLast() else {
            return
        }
        switch attempt.ending {
        case .passed: tallies[name]?.passed -= 1
        case .failed: tallies[name]?.failed -= 1
        case .skipped: tallies[name]?.skipped -= 1
        }
        attempts[name] = tried.isEmpty ? nil : tried
        lastEndings[name] = tried.last?.ending
        startedIterations[name] = attempt.iteration
        swiftTestingRuns[openRun()].unfinishedStarts[name, default: 0] += 1
    }

    /// Whether a run's passing summary may account for a missing result line at all, which it never may where the wrapped command is known to have exited non-zero.
    var summariesVouch: Bool {
        (commandExitCode ?? 0) == 0
    }

    /// Reads a Swift Testing suite's ending or a run's summary, both anchored on their first word as a test's lines are.
    private mutating func readSwiftTestingClosing(_ line: String) {
        let undecorated = RunOutputFilter.undecorated(line)
        guard !line[line.startIndex ..< undecorated.startIndex].unicodeScalars.contains(where: Self.continuationMarkers.contains) else {
            return
        }
        if undecorated == "Test run started." {
            swiftTestingRuns.append(SwiftTestingRun())
            return
        }
        if undecorated.hasPrefix("Test run with ") {
            if let ending = Self.closingEnding(of: undecorated) {
                let run = openRun()
                swiftTestingRuns[run].summaryTests = undecorated.prefixMatch(of: #/Test run with (\d+) tests? /#).flatMap { Int($0.output.1) }
                swiftTestingRuns[run].ending = ending
            }
            return
        }
        guard undecorated.hasPrefix("Suite ") else {
            return
        }
        let rest = undecorated.dropFirst("Suite ".count)
        guard let nameEnd = Self.endOfName(in: rest), let ending = Self.closingEnding(of: rest[nameEnd...]) else {
            return
        }
        let suite = String(rest[..<nameEnd])
        let run = openRun()
        swiftTestingRuns[run].suiteEndings[suite] = swiftTestingRuns[run].suiteEndings[suite] == .failed ? .failed : ending
    }

    /// Counts a Swift Testing test's start line against the run it sits in, and its finishing line off it.
    private mutating func readSwiftTestingEvent(_ event: Event, of name: String) {
        let run = openRun()
        if case let .started(iteration) = event {
            swiftTestingRuns[run].unfinishedStarts[name, default: 0] += 1
            if iteration == 1 {
                swiftTestingRuns[run].firstIterationStarts.insert(name)
            }
        } else if let unfinished = swiftTestingRuns[run].unfinishedStarts[name], unfinished > 0 {
            swiftTestingRuns[run].unfinishedStarts[name] = unfinished - 1
        }
    }

    /// The index of the run still printing, opening one where a Swift Testing line arrives with none open: a log that begins after a run's start line, or one whose last run already printed its summary.
    private mutating func openRun() -> Int {
        if let last = swiftTestingRuns.indices.last, swiftTestingRuns[last].ending == nil {
            return last
        }
        swiftTestingRuns.append(SwiftTestingRun())
        return swiftTestingRuns.count - 1
    }

    /// The ending a suite's or a run's closing words name, or `nil` where they name none.
    private static func closingEnding(of text: Substring) -> Ending? {
        if text.contains(" failed after ") {
            .failed
        } else if text.contains(" passed after ") {
            .passed
        } else {
            nil
        }
    }

    /// Adds a skipped test to ``skips`` unless the run already named it, in which case a reason the first mention lacked is filled in.
    private mutating func recordSkip(_ name: String, reason: String?) {
        guard let index = skips.firstIndex(where: { $0.name == name }) else {
            skips.append(Skip(name: name, reason: reason))
            return
        }
        if skips[index].reason == nil, let reason {
            skips[index] = Skip(name: name, reason: reason)
        }
    }

    /// Records a finishing line as `name`'s next attempt, under the iteration the start line left for it.
    private mutating func finish(_ ending: Ending, seconds: Double?, of name: String) {
        lastEndings[name] = ending
        attempts[name, default: []].append(Attempt(ending: ending, seconds: seconds, iteration: startedIterations.removeValue(forKey: name) ?? 1))
    }
}

extension RunTestOutcomes {
    /// What one line said, with everything the line itself carried: a start knows which iteration it opens, and a finishing line knows what the attempt cost.
    ///
    /// The numbers ride on the event rather than being read again later because the line is the only place either one is written, and it is gone by the time the caller has the event.
    enum Event {
        case started(iteration: Int)
        case passed(seconds: Double?)
        case failed(seconds: Double?)
        case skipped(seconds: Double?)
    }

    /// The two spellings of Swift Testing's continuation marker: `↳`, and the SF Symbol it draws in its place, which the captures carry as U+100135.
    static let continuationMarkers: Set<Unicode.Scalar> = ["↳", "\u{100135}"]

    /// XCTest: `Test Case '-[Suite testName]' started.`, then `… passed (0.001 seconds).`, `… failed (…)` or `… skipped (…)`.
    ///
    /// The name is everything between the quotes, which is the span the filter files an XCTest failure under.
    ///
    /// A start under a repeating test plan carries the iteration instead of ending at the word — `started (Iteration 2 of 3).` — and the finishing lines carry a duration, both of which are read here because the line is the only place either is written.
    static func xctestEvent(in line: String) -> (String, Event)? {
        let opening = "Test Case '"
        guard line.hasPrefix(opening) else {
            return nil
        }
        let rest = line.dropFirst(opening.count)
        guard let close = rest.range(of: "' ") else {
            return nil
        }
        let name = String(rest[..<close.lowerBound])
        let tail = rest[close.upperBound...]
        let event: Event? = if tail.hasPrefix("started") {
            .started(iteration: RunLineScan.iterationNumber(in: tail))
        } else if tail.hasPrefix("passed (") {
            .passed(seconds: RunLineScan.xctestSeconds(in: tail))
        } else if tail.hasPrefix("failed (") {
            .failed(seconds: RunLineScan.xctestSeconds(in: tail))
        } else if tail.hasPrefix("skipped (") {
            .skipped(seconds: RunLineScan.xctestSeconds(in: tail))
        } else {
            nil
        }
        guard !name.isEmpty, let event else {
            return nil
        }
        return (name, event)
    }

    /// XCTest's skip reason: `File.swift:4: -[Module.Suite testName] : Test skipped - not here`, with the test's name as its `Test Case` lines print it and the reason, or `nil` for a line of any other shape.
    ///
    /// A text before the bracket, an `error:` among it, is read past. A skip with no reason prints no ` - ` clause, which reads as no reason here.
    static func xctestSkipReason(in line: String) -> (String, String?)? {
        guard let open = line.range(of: "-["), let marker = line.range(of: "] : Test skipped", range: open.upperBound ..< line.endIndex) else {
            return nil
        }
        let name = String(line[open.lowerBound ..< marker.lowerBound]) + "]"
        let tail = line[marker.upperBound...]
        guard name.count > "-[]".count, tail.isEmpty || tail.hasPrefix(" - ") else {
            return nil
        }
        let reason = tail.dropFirst(" - ".count).trimmingCharacters(in: .whitespaces)
        return (name, reason.isEmpty ? nil : reason)
    }

    /// `Suite.test` for an XCTest name as `Test Case` lines print it, `-[Module.Suite test]`: the brackets and the module are left off.
    static func xctestDisplayName(_ name: String) -> String {
        var bare = Substring(name)
        if bare.hasPrefix("-["), bare.hasSuffix("]") {
            bare = bare.dropFirst(2).dropLast()
        }
        let parts = bare.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return String(bare)
        }
        let suite = parts[0].split(separator: ".").last.map(String.init) ?? parts[0]
        return "\(suite).\(parts[1])"
    }

    /// The reason a Swift Testing skip line gives, without its quotes.
    ///
    /// `Test switchedOff() skipped: "not yet"` gives `not yet`; a bare `skipped.` and any line that is not a skip give `nil`.
    static func swiftTestingSkipReason(in line: String) -> String? {
        guard let (_, tail) = swiftTestingLine(in: line), tail.hasPrefix(" skipped: ") else {
            return nil
        }
        var reason = tail.dropFirst(" skipped: ".count)
        if reason.count >= 2, reason.hasPrefix("\""), reason.hasSuffix("\"") {
            reason = reason.dropFirst().dropLast()
        }
        return reason.isEmpty ? nil : String(reason)
    }

    /// Swift Testing: `Test shoutingWorks() started.`, then `… passed after 0.001 seconds.`, `… failed after … with 1 issue.` or `… skipped.`
    ///
    /// **The name is read by its own shape rather than cut off at a marker.** A function's name carries no space (`sizeIsCarried(size:)`), and a display name is quoted (`"The grid keeps its headings"`), so both end at a point the line itself makes plain — and a display name that happens to contain the words `passed after` cannot move that point, which a search for the marker would let it do. A parameterized test's `with 3 test cases` clause between the name and the event is read past, for the reason the filter reads past it: it counts cases, it is not part of what the function is called.
    ///
    /// The run's own lines (`Test run started.`, `Test run with 3 tests in 1 suite passed after …`) begin with the same word and are turned away by name: `run` followed by a space is never a test function's spelling, which always carries its parentheses.
    ///
    /// **A retry's start line is `… started (repetition 2).`, not `… started.`** — so a reader that asks for the shorter spelling exactly counts the first attempt at a repeated test and silently none of the rest, which is a test that appears to have run once where the transcript above it shows it running three times.
    ///
    /// A test that cancelled itself — `… was cancelled after 0.001 seconds: "probe"` — is read as skipped: it ended, and it did not pass.
    static func swiftTestingEvent(in line: String) -> (String, Event)? {
        guard let (name, rest) = swiftTestingLine(in: line) else {
            return nil
        }
        var tail = rest
        // Each pattern is asked only of a tail opening on its literal words: a regex literal is built
        // again on every evaluation, and over a full suite's log that cost was most of the reading.
        if tail.hasPrefix(" with "), let cases = tail.prefixMatch(of: #/ with \d+ test cases?/#) {
            tail = tail[cases.range.upperBound...]
        }
        let event: Event? = if tail == " started." {
            .started(iteration: 1)
        } else if tail.hasPrefix(" started (repetition "), let repetition = tail.wholeMatch(of: #/ started \(repetition (\d+)\)\./#) {
            .started(iteration: Int(repetition.output.1) ?? 1)
        } else if tail.hasPrefix(" passed after ") {
            .passed(seconds: RunLineScan.swiftTestingSeconds(in: tail))
        } else if tail.hasPrefix(" failed after ") {
            .failed(seconds: RunLineScan.swiftTestingSeconds(in: tail))
        } else if tail == " skipped." || tail.hasPrefix(" skipped: ") {
            .skipped(seconds: nil)
        } else if tail.hasPrefix(" was cancelled after ") {
            .skipped(seconds: nil)
        } else {
            nil
        }
        guard let event else {
            return nil
        }
        return (name, event)
    }

    /// The name a Swift Testing line gives a test, for a line that is neither its start nor an ending this reader knows: an issue recorded, or an ending in a wording it has never seen.
    ///
    /// Only a function's spelling, which carries its parentheses, or a quoted display name counts, so a parameterized case's `Test case passing …` line and XCTest's `Test Suite '…'` lines name nothing. A known issue recorded is no failure and names nothing either: the test's suite and run still say how it ended.
    static func unreadSwiftTestingName(in line: String) -> String? {
        guard let (name, tail) = swiftTestingLine(in: line), name.hasPrefix("\"") || name.contains("("),
              !tail.hasPrefix(" recorded a known issue")
        else {
            return nil
        }
        return name
    }

    /// A Swift Testing line about one test, split into the name it prints and everything after that name, or `nil` for any other line.
    static func swiftTestingLine(in line: String) -> (String, Substring)? {
        let undecorated = RunOutputFilter.undecorated(line)
        // A continuation line is an author's comment printed under a failure, and it can say anything at
        // all — including a sentence that reads exactly like a finishing line. Its marker is `↳` where the
        // output is plain and a private-use symbol where Swift Testing draws SF Symbols, and either one in
        // front of the first word says the line is somebody's prose rather than the framework's report.
        let decoration = line[line.startIndex ..< undecorated.startIndex]
        guard !decoration.unicodeScalars.contains(where: continuationMarkers.contains) else {
            return nil
        }
        guard undecorated.hasPrefix("Test "), !undecorated.hasPrefix("Test run ") else {
            return nil
        }
        let rest = undecorated.dropFirst("Test ".count)
        guard let nameEnd = endOfName(in: rest) else {
            return nil
        }
        return (String(rest[..<nameEnd]), rest[nameEnd...])
    }

    /// Where a Swift Testing test's name ends: after the closing quote of a display name, or at the first space after a function's.
    private static func endOfName(in text: Substring) -> Substring.Index? {
        guard let first = text.first else {
            return nil
        }
        if first == "\"" {
            let body = text.dropFirst()
            guard let closing = body.firstIndex(of: "\"") else {
                return nil
            }
            return text.index(after: closing)
        }
        let end = text.firstIndex(of: " ") ?? text.endIndex
        return end == text.startIndex ? nil : end
    }
}

public extension RunTestOutcomes {
    /// The last attempt at a test, which is its outcome — `nil` where the log started it and never finished it.
    static func lastAttempt(of attempts: [Attempt]) -> Attempt? {
        var last: Attempt?
        for attempt in attempts where attempt.iteration >= (last?.iteration ?? Int.min) {
            last = attempt
        }
        return last
    }

    /// `endings` ordered worst first — failed, then skipped, then passed.
    ///
    /// The order a group of tests one reported name cannot be told apart must spend its endings in: which ending the log printed first says nothing about which of them it belonged to, so counting in log order makes the verdict depend on the order a failure happened to arrive in.
    static func worstFirst(_ endings: [Ending]) -> [Ending] {
        endings.sorted { rank(of: $0) < rank(of: $1) }
    }

    /// Where one ending sorts when endings are ranked worst first.
    private static func rank(of ending: Ending) -> Int {
        switch ending {
        case .failed: 0
        case .skipped: 1
        case .passed: 2
        }
    }

    /// The first iteration that ended a test more than once and how many endings it printed, or `nil` where none did.
    ///
    /// One rule for every reconciliation, because getting it wrong in either direction makes the answer worse than none: a retry across iterations is an attempt and not a duplicate, and a second ending inside one iteration is a duplicate that no retry setting explains.
    static func repeatWithinAnIteration(of attempts: [Attempt]) -> (iteration: Int, endings: Int)? {
        Dictionary(grouping: attempts, by: \.iteration)
            .filter { $0.value.count > 1 }
            .min { $0.key < $1.key }
            .map { ($0.key, $0.value.count) }
    }
}
