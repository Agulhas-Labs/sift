//
// Copyright © Agulhas Labs
//

import Foundation

/// A `swift test` whose test process trapped or took a signal: the trap's own line, each process that died, the tests it was running, and how many of the tests it was given never started.
///
/// **SwiftPM's signal line is the evidence, and the only evidence.** A process that dies prints no closing count and no ending for the test it was in; SwiftPM says so with `error: Process '…' exited with unexpected signal code N`, which arrives ahead of the process's own output. Without that line nothing here is reported, so a test that merely prints `Fatal error:` text is never read as a crash.
///
/// **The verdict it earns is a failure**, whatever the other bundle's passing count says: a run that stopped before its selection finished is never a pass.
public struct RunTestCrash: Sendable, Equatable {
    /// Every process SwiftPM said died on a signal, in the order it said so.
    public private(set) var processes: [Process] = []
    /// Every `File.swift:N: Fatal error: …` (or `Precondition failed`, `Assertion failed`) line the run printed, trimmed, in order — once settled, only those inside a crashed test's own stretch of the log where one is known, one raised in the source of a test the event stream left unfinished first.
    public internal(set) var traps: [String] = []
    /// Where each trap line sat, beside ``traps`` until settled.
    var trapMarks: [Mark] = []
    /// Where each test's last start line sat.
    var starts: [String: Mark] = [:]
    /// The tests the run started and never ended, sorted.
    public internal(set) var unfinished: [String] = []
    /// The Swift Testing tests the run's event stream declared, by the name the console prints, under the test target that holds them, or `nil` where no stream was read.
    public internal(set) var declaredSwiftTesting: [String: [String]]?
    /// Where each Swift Testing test the run's event stream started and never ended was declared, empty where no stream was read.
    var unfinishedSources: [DeclaredTestSource] = []
    /// How many tests each process in ``processes``, by its index there, was handed and never started, or no entry where the log does not say what it was handed.
    public internal(set) var neverStarted: [Int: Shortfall] = [:]
    /// The exit code of a run whose test process ended with no signal line, on `exit(N)` or a `SIGKILL`, read from the tests it left unfinished; `nil` for a crash SwiftPM reported on a signal.
    public internal(set) var unsignalledExit: Int32?

    public init() {}
}

public extension RunTestCrash {
    /// The framework whose test process died.
    enum Framework: String, Sendable, Hashable {
        case xctest = "XCTest"
        case swiftTesting = "Swift Testing"
    }

    /// How many of the tests one framework was handed never started, out of how many it was handed.
    struct Shortfall: Sendable, Equatable {
        public let count: Int
        public let selected: Int
    }

    /// Where a line sat in the log: the test process whose output it falls in, counted by the processes that announced themselves before it, and its place among the lines read.
    struct Mark: Sendable, Equatable {
        let process: Int
        let position: Int
    }

    /// One process SwiftPM said died on a signal.
    struct Process: Sendable, Equatable {
        public let framework: Framework
        public let signal: Int
        /// The tests an `xctest -XCTest a,b,c` invocation was handed, in its own `Module.Class/testMethod` spelling; `nil` for a process the line names no list for.
        public let selected: [String]?
        /// The test bundle a `swiftpm-testing-helper` was handed with `--test-bundle-path`, without its `.xctest`; `nil` where the line names none.
        public let bundle: String?
    }

    /// Reads a `swift test` log a line at a time, claiming the signal lines and the trap lines.
    struct Reader: Sendable {
        private var crash = RunTestCrash()
        private var process = 0
        private var position = 0

        public init() {}

        /// Notes that a test process announced itself, so the lines after it are its own.
        mutating func openProcess() {
            process += 1
        }

        /// The crash the log reported, or `nil` where no process died on a signal.
        public var result: RunTestCrash? {
            crash.processes.isEmpty ? nil : crash
        }

        /// Whether `line` is a signal line or a trap line, which reach no other reader.
        public mutating func read(_ line: String) -> Bool {
            position += 1
            if line.contains(" started"), let (name, event) = RunTestOutcomes.xctestEvent(in: line) ?? RunTestOutcomes.swiftTestingEvent(in: line),
               case .started = event
            {
                crash.starts[name] = Mark(process: process, position: position)
            }
            if let process = Self.signalledProcess(line) {
                crash.processes.append(process)
                return true
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard Self.isTrap(trimmed) else {
                return false
            }
            crash.traps.append(trimmed)
            crash.trapMarks.append(Mark(process: process, position: position))
            return true
        }

        /// The process SwiftPM's `error: Process '…' exited with unexpected signal code N` names, or `nil` where `line` is not one.
        static func signalledProcess(_ line: String) -> Process? {
            let head = "error: Process '"
            let tail = "' exited with unexpected signal code "
            guard line.hasPrefix(head), let end = line.range(of: tail, options: .backwards), let signal = Int(line[end.upperBound...]) else {
                return nil
            }
            let command = line[line.index(line.startIndex, offsetBy: head.count) ..< end.lowerBound]
            let words = command.split(separator: " ")
            guard let executable = words.first else {
                return nil
            }
            if executable.hasSuffix("/swiftpm-testing-helper") {
                let path = words.firstIndex(of: "--test-bundle-path").flatMap { words.index(after: $0) < words.endIndex ? words[words.index(after: $0)] : nil }
                let bundle = path?.split(separator: "/").first { $0.hasSuffix(".xctest") }.map { String($0.dropLast(".xctest".count)) }
                return Process(framework: .swiftTesting, signal: signal, selected: nil, bundle: bundle)
            }
            guard executable.hasSuffix("/xctest") else {
                return nil
            }
            let list = words.firstIndex(of: "-XCTest").flatMap { words.index(after: $0) < words.endIndex ? words[words.index(after: $0)] : nil }
            return Process(framework: .xctest, signal: signal, selected: list.map { $0.split(separator: ",").map(String.init) }, bundle: nil)
        }

        /// Whether `line` is the runtime's report of a trap: `File.swift:12: Fatal error: …`, anchored on the location ahead of it.
        static func isTrap(_ line: String) -> Bool {
            trapLocation(line) != nil
        }

        /// The file and line a trap line names ahead of its kind, `File.swift` and `12` in `File.swift:12: Fatal error: …`, or `nil` where `line` is no trap.
        static func trapLocation(_ line: String) -> (file: Substring, line: Int)? {
            for kind in [": Fatal error", ": Precondition failed", ": Assertion failed"] {
                guard let range = line.range(of: kind) else {
                    continue
                }
                let location = line[..<range.lowerBound]
                guard let colon = location.lastIndex(of: ":"), location[location.index(after: colon)...].allSatisfy(\.isNumber),
                      let number = Int(location[location.index(after: colon)...]), !location[..<colon].contains(" ")
                else {
                    return nil
                }
                let rest = line[range.upperBound...]
                return rest.isEmpty || rest.hasPrefix(":") ? (location[..<colon], number) : nil
            }
            return nil
        }
    }
}

// MARK: - Settling and rendering

extension RunTestCrash {
    /// This crash with what the whole log says filled in: the tests left unfinished, and how many each framework's selection never started.
    func settled(by outcomes: RunTestOutcomes) -> RunTestCrash {
        var settled = self
        settled.unfinished = outcomes.names.filter { name in
            guard let tally = outcomes[name] else {
                return false
            }
            return tally.started > tally.passed + tally.failed + tally.skipped
        }
        settled.traps = settled.trapsOfTheCrash()
        settled.trapMarks = []
        for (index, process) in processes.enumerated() {
            switch process.framework {
            case .xctest:
                guard let selected = process.selected else {
                    continue
                }
                let printed = selected.map { "-[\($0.replacingOccurrences(of: "/", with: " "))]" }
                settled.neverStarted[index] = Shortfall(count: printed.count { outcomes[$0] == nil }, selected: printed.count)
            case .swiftTesting:
                // Only the tests of the bundle this process ran: SwiftPM writes one stream per bundle into the one file.
                guard let bundle = process.bundle.map(TestIdentifier.moduleName(ofTarget:)),
                      let declared = declaredSwiftTesting?.first(where: { TestIdentifier.moduleName(ofTarget: $0.key) == bundle })?.value
                else {
                    continue
                }
                settled.neverStarted[index] = Shortfall(count: declared.count { outcomes[$0] == nil }, selected: declared.count)
            }
        }
        return settled
    }

    /// The trap lines that belong to the crash, one the event stream places in a crashed test's own source first.
    ///
    /// **A trap belongs to a crashed test where it follows that test's start inside the same process's output.** Another test can print the same `File.swift:N: Fatal error: …` text and pass, in another process or before the crashed test began, and that line says nothing about the crash. The start line and the runtime's trap message both go to the test process's standard error, which SwiftPM relays in the order it was written, so the real trap is never before its test's start and never dropped. Inside the crashed test's stretch every trap is kept, and position cannot rank them: a test running beside the crashed one can print the same text to standard output, which reaches the log out of step with standard error, so the printed line can land before or after the trap and even after its own test's ending. Where no unfinished test's start is known, every trap is kept in log order.
    ///
    /// **A trap whose `File.swift:N` lies in the source of a test the event stream started and never ended is listed first.** Swift Testing's stream records no printed text and no event at the crash, so no test id says whose line a trap is; what it does record is where each test is declared, and which tests started and never ended. A trap raised in such a test's own body names a line between its declaration and the next test or suite declared in that file, which a look-alike printed with another location does not. Every other trap inside the stretch follows, the last of each process first, and that order is not a ranking: a trap raised in library code or the standard library, the usual case, names no test's source, and XCTest writes no stream.
    func trapsOfTheCrash() -> [String] {
        let spans = unfinished.compactMap { starts[$0] }
        guard !spans.isEmpty else {
            return traps
        }
        let inside = trapMarks.indices.filter { index in
            spans.contains { $0.process == trapMarks[index].process && $0.position < trapMarks[index].position }
        }
        let leads = Set(inside.map { trapMarks[$0].process }).sorted().compactMap { process in
            inside.last { trapMarks[$0].process == process }
        }
        let unranked = leads + inside.filter { !leads.contains($0) }
        let attributed = unranked.filter { index in
            Reader.trapLocation(traps[index]).map { location in unfinishedSources.contains { $0.holds(file: location.file, line: location.line) } } ?? false
        }
        return (attributed + unranked.filter { !attributed.contains($0) }).map { traps[$0] }
    }

    /// The clause an `inventory:` line carries for this crash, so its counts never read as a run that finished: how many tests started and never ended, and how many selected tests never started, or that the log does not say.
    var inventoryClause: String {
        var clause = "test process crashed"
        if !unfinished.isEmpty {
            clause += "; \(unfinished.count) started and never ended"
        }
        guard !neverStarted.isEmpty else {
            return clause + "; the log does not say how many selected tests never started"
        }
        let count = neverStarted.values.reduce(0) { $0 + $1.count }
        return clause + "; \(count) selected \(count == 1 ? "test" : "tests") never started"
    }

    /// The lines this crash adds beneath the answer's headline: each trap, then each process that died with the tests it was running and the count it never started.
    func lines() -> [String] {
        var lines = traps.map { "  \(RunFailureCensus.clipped($0))" }
        if let unsignalledExit {
            lines.append(RunFailureCensus.clipped("  test process ended without a result (exit \(unsignalledExit) / no signal line); started and never finished: \(unfinished.joined(separator: ", "))"))
        } else if traps.isEmpty {
            lines.append("  no trap message in the log: the process took the signal without printing one")
        }
        for (index, process) in processes.enumerated() {
            let running = unfinished.filter { ($0.hasPrefix("-[") ? Framework.xctest : .swiftTesting) == process.framework }
            var line = "  \(process.framework.rawValue) test process exited on signal \(process.signal)"
            line += running.isEmpty ? ", in no test the log shows started and unfinished" : " while running \(running.joined(separator: ", "))"
            if let never = neverStarted[index] {
                line += "; \(never.count) of \(never.selected) selected \(never.selected == 1 ? "test" : "tests") never started"
            }
            lines.append(RunFailureCensus.clipped(line))
        }
        return lines
    }
}

// MARK: - A process that ended with no signal line

extension RunTestCrash.Reader {
    /// The crash a run shows where its test process ended on `exit(N)` or a `SIGKILL`, which SwiftPM reports with no signal line: a process that opened and never printed its closing, and the tests it started and never finished, named so the answer says what was running.
    ///
    /// `nil` where the run exited 0, where `swift test` itself ended on a signal (an exit code of 128 or more, whose unfinished tests were interrupted rather than lost to their own process), and where no test that started and never finished sits in a process that never closed: a lost ending line in a run whose every process closed is no crash.
    ///
    /// **No trap line is quoted.** A runtime trap ends its process on a signal SwiftPM reports, so a trap-shaped line in a run with no signal line is a test's printed text, never the reason this process ended.
    func unsignalled(exitCode: Int32?, outcomes: RunTestOutcomes, xctestUnclosed: Bool) -> RunTestCrash? {
        guard let exitCode, (1 ..< 128).contains(exitCode) else {
            return nil
        }
        let unfinished = outcomes.names.filter { name in
            guard let tally = outcomes[name], tally.started > tally.passed + tally.failed + tally.skipped else {
                return false
            }
            guard !name.hasPrefix("-[") else {
                return xctestUnclosed
            }
            return outcomes.swiftTestingRuns.contains { $0.ending == nil && $0.unfinished(name) > 0 }
        }
        guard !unfinished.isEmpty else {
            return nil
        }
        var crash = RunTestCrash()
        crash.unfinished = unfinished
        crash.unsignalledExit = exitCode
        return crash
    }
}
